import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  CELType,
  CompileError,
  Duration,
  EnumValue,
  Environment,
  EvaluateError,
  FunctionDeclaration,
  Message,
  Program,
  Timestamp,
} from "../index.js";

const boolType = new CELType("bool");
const intType = new CELType("int");
const stringType = new CELType("string");

test("custom functions support global, receiver, and scalar overloads", () => {
  const calls: unknown[][] = [];
  const functions = [
    new FunctionDeclaration(
      "echo",
      [intType],
      intType,
      (value) => {
        calls.push([value]);
        return value;
      },
      { overloadId: "echo_int" },
    ),
    new FunctionDeclaration("echo", [stringType], stringType, (value) => value, {
      overloadId: "echo_string",
    }),
    new FunctionDeclaration(
      "atLeast",
      [intType, intType],
      boolType,
      (value, minimum) => (value as bigint) >= (minimum as bigint),
      { member: true },
    ),
  ];
  const program = new Environment({ functions }).compile(
    "echo(1) == 1 && echo('x') == 'x' && (21).atLeast(18)",
  );
  assert.equal(program.evaluate({}), true);
  assert.deepEqual(calls, [[1n]]);
});

test("generic custom functions preserve type metadata", () => {
  const parameter = CELType.parameter("T");
  const list = new CELType("list", [parameter]);
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("identity", [parameter], parameter, (value) => value),
      new FunctionDeclaration("identityList", [list], list, (value) => value),
      new FunctionDeclaration("makeTuple", [parameter], CELType.abstract("tuple", [parameter])),
    ],
  });
  const identity = environment.compile("identity(1)");
  const identityList = environment.compile("identityList([1, 2])");
  const tuple = environment.compile("makeTuple(1)");
  assert.equal(identity.evaluate({}), 1n);
  assert.equal(environment.compile("identity('x')").evaluate({}), "x");
  assert.deepEqual(identityList.evaluate({}), [1n, 2n]);
  assert.deepEqual(tuple.resultType, CELType.abstract("tuple", [intType]));
});

test("custom function failures preserve CEL and JavaScript errors", () => {
  const missing = new Environment({
    functions: [new FunctionDeclaration("missing", [], boolType)],
  }).compile("missing()");
  assert.throws(
    () => missing.evaluate({}),
    (error: unknown) => error instanceof EvaluateError && error.code === "MissingFunction",
  );

  const typed = new Environment({
    functions: [new FunctionDeclaration("typed", [intType], intType, (value) => value)],
  });
  assert.throws(() => typed.compile("typed('wrong')"), CompileError);
  const wrongArgument = typed.compile("typed('wrong')", { check: false });
  assert.throws(
    () => wrongArgument.evaluate({}),
    (error: unknown) => error instanceof EvaluateError && error.code === "NoMatchingOverload",
  );

  const wrongResult = new Environment({
    functions: [new FunctionDeclaration("wrong", [], boolType, () => "wrong")],
  }).compile("wrong()");
  assert.throws(
    () => wrongResult.evaluate({}),
    (error: unknown) => error instanceof EvaluateError && error.code === "NoMatchingOverload",
  );

  const expected = new Error("callback failed");
  const throwing = new Environment({
    functions: [
      new FunctionDeclaration("throwing", [], boolType, () => {
        throw expected;
      }),
    ],
  }).compile("throwing() || true");
  assert.throws(
    () => throwing.evaluate({}),
    (error: unknown) => error === expected,
  );

  const promised = new Environment({
    functions: [
      new FunctionDeclaration("promised", [], boolType, () => Promise.resolve(true) as never),
    ],
  }).compile("promised()");
  assert.throws(() => promised.evaluate({}), TypeError);
});

test("checked generic return contracts reject mismatched callback values", () => {
  const t = CELType.parameter("T");
  const environment = new Environment({
    functions: [new FunctionDeclaration("identity", [t], t, () => "wrong")],
  });
  assert.throws(
    () => environment.compile("identity(1)").evaluate({}),
    (error: unknown) => error instanceof EvaluateError && error.code === "NoMatchingOverload",
  );
});

test("host exception identity is preserved even with native-looking error codes", () => {
  const failure = Object.assign(new Error("host failure"), { code: "CEL_EVALUATE_Overflow" });
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("fail", [], new CELType("bool"), () => {
        throw failure;
      }),
    ],
  });
  assert.throws(
    () => environment.compile("fail() || true").evaluate({}),
    (error) => error === failure,
  );
  assert.throws(
    () =>
      new Program("x").evaluate({
        get x(): never {
          throw failure;
        },
      }),
    (error) => error === failure,
  );
  assert.throws(
    () =>
      new Environment({
        constants: {
          get value(): never {
            throw "host";
          },
        },
      }),
    (error) => error === "host",
  );
});

test("environment errors preserve host identity with compile-looking codes", () => {
  const failure = Object.assign(new Error("host"), { code: "CEL_COMPILE_TypeMismatch" });
  assert.throws(
    () =>
      new Environment({
        constants: {
          get value(): never {
            throw failure;
          },
        },
      }),
    (error) => error === failure,
  );
});

test("function declarations accept precisely typed host callbacks", () => {
  const increment = (value: bigint): bigint => value + 1n;
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("increment", [new CELType("int")], new CELType("int"), increment),
    ],
  });
  assert.equal(environment.compile("increment(1)").evaluate({}), 2n);
});

test("callbacks are reentrant and environment snapshots cannot be retargeted", () => {
  let inner: Program;
  const first = new FunctionDeclaration("value", [], intType, () => inner.evaluate({}) as bigint);
  const declarations = [first];
  const environment = new Environment({ functions: declarations });
  inner = environment.compile("1");
  const outer = environment.compile("value() + 1");

  (first as { implementation: () => bigint }).implementation = () => 99n;
  declarations[0] = new FunctionDeclaration("value", [], intType, () => 100n);
  global.gc?.();
  assert.equal(outer.evaluate({}), 2n);
});

test("callbacks own converted message and enum values for the duration of the call", () => {
  const descriptors = readFileSync(
    new URL("../../../../conformance/protobuf/test-schema-descriptor.pb", import.meta.url),
  );
  let seenMessage: Message | undefined;
  let seenEnum: EnumValue | undefined;
  let seenTimestamp: Timestamp | undefined;
  let seenDuration: Duration | undefined;
  const environment = new Environment({
    descriptors,
    container: "cel.conformance.fixture",
    strongEnums: true,
    functions: [
      new FunctionDeclaration(
        "inspect",
        [
          new CELType("cel.conformance.fixture.TestSchema"),
          new CELType("cel.conformance.fixture.TestSchema.Status"),
          new CELType("google.protobuf.Timestamp"),
          new CELType("google.protobuf.Duration"),
        ],
        new CELType("cel.conformance.fixture.TestSchema"),
        (message, enumValue, timestamp, duration) => {
          assert.ok(message instanceof Message);
          assert.ok(enumValue instanceof EnumValue);
          assert.ok(timestamp instanceof Timestamp);
          assert.ok(duration instanceof Duration);
          seenMessage = message;
          seenEnum = enumValue;
          seenTimestamp = timestamp;
          seenDuration = duration;
          return message;
        },
      ),
    ],
  });
  const result = environment
    .compile(
      "inspect(TestSchema{signed_value: 3}, TestSchema.Status.STATUS_READY, " +
        "timestamp('2020-01-01T00:00:00Z'), duration('1s'))",
    )
    .evaluate({});
  assert.ok(result instanceof Message);
  assert.ok(seenMessage instanceof Message);
  assert.ok(seenEnum instanceof EnumValue);
  assert.ok(seenTimestamp instanceof Timestamp);
  assert.ok(seenDuration instanceof Duration);
});

test("callback results obey conversion limits", () => {
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("large", [], new CELType("dyn"), () =>
        Array.from({ length: 100_001 }, () => null),
      ),
    ],
  });
  assert.throws(() => environment.compile("large()").evaluate({}), RangeError);
});

test("function and type constructors reject invalid declarations", () => {
  assert.equal(new CELType("int").kind, "concrete");
  assert.deepEqual(CELType.abstract("opaque"), new CELType("opaque", [], "abstract"));
  assert.throws(() => new CELType("int", [], "invalid" as never), RangeError);
  assert.throws(() => CELType.abstract("T", [1] as never), TypeError);
  assert.throws(() => new FunctionDeclaration(1 as never, [], intType), TypeError);
  assert.throws(() => new FunctionDeclaration("", [], intType), RangeError);
  assert.throws(() => new FunctionDeclaration("f", null as never, intType), TypeError);
  assert.throws(() => new FunctionDeclaration("f", [], {} as never), TypeError);
  assert.throws(() => new FunctionDeclaration("f", [], intType, 1 as never), TypeError);
  assert.throws(
    () => new FunctionDeclaration("f", [], intType, undefined, null as never),
    TypeError,
  );
  assert.throws(
    () => new FunctionDeclaration("f", [], intType, undefined, { overloadId: 1 as never }),
    TypeError,
  );
  assert.throws(
    () => new FunctionDeclaration("f", [], intType, undefined, { member: 1 as never }),
    TypeError,
  );
  assert.throws(() => new Environment({ functions: {} as never }), TypeError);
});

test("function declaration limits are enforced", () => {
  const functions = Array.from(
    { length: 100_001 },
    (_, index) => new FunctionDeclaration(`f${index}`, [], intType),
  );
  assert.throws(() => new Environment({ functions }), RangeError);
});
