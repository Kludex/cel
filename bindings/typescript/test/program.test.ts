import assert from "node:assert/strict";
import test from "node:test";

import {
  CELType,
  CompileError,
  Double,
  Environment,
  EvaluateError,
  Program,
  UInt,
} from "../index.js";

test("Program compiles once and evaluates native bindings", () => {
  const program = new Program(
    'request.user.active && request.user.age >= 18 && "admin" in request.roles',
  );

  assert.equal(
    program.evaluate({
      request: { user: { active: true, age: 21 }, roles: ["admin"] },
    }),
    true,
  );
  assert.equal(
    program.evaluate({
      request: { user: { active: false, age: 21 }, roles: ["admin"] },
    }),
    false,
  );
});

test("values cross the native boundary without JSON conversion", () => {
  assert.equal(new Program("i").evaluate({ i: 9_007_199_254_740_991 }), 9_007_199_254_740_991n);
  assert.equal(new Program("i").evaluate({ i: -9n }), -9n);
  assert.deepEqual(
    new Program("u").evaluate({ u: new UInt(18_446_744_073_709_551_615n) }),
    new UInt(18_446_744_073_709_551_615n),
  );
  const unsigned = new Program("1u").evaluate({});
  assert.ok(unsigned instanceof UInt);
  assert.deepEqual(new Program("x + 1u").evaluate({ x: unsigned }), new UInt(2n));
  assert.equal(new Program("d").evaluate({ d: new Double(2) }), 2);
  assert.equal(new Program("d").evaluate({ d: 2.5 }), 2.5);
  assert.deepEqual(new Program("xs").evaluate({ xs: [1, "two", null] }), [1n, "two", null]);
  assert.deepEqual(new Program("m").evaluate({ m: { answer: 42 } }), { answer: 42n });
  assert.deepEqual(new Program("{1: 'one'}").evaluate({}), new Map([[1n, "one"]]));

  const bytes = new Uint8Array([0, 127, 255]);
  const result = new Program("data").evaluate({ data: bytes });
  assert.ok(result instanceof Uint8Array);
  assert.deepEqual([...result], [...bytes]);
});

test("type values round trip and macros preserve native data", () => {
  assert.deepEqual(new Program("type(1)").evaluate({}), new CELType("int"));
  assert.equal(
    new Program("t == int && type(t) == type && t != 'int'").evaluate({ t: new CELType("int") }),
    true,
  );
  assert.throws(() => new CELType(1 as never), TypeError);
  assert.throws(() => new CELType(""), RangeError);
  const program = new Program(
    "items.transformMap(i, v, v.`unit-price`).transformList(k, v, k + v)",
  );
  assert.deepEqual(program.evaluate({ items: [{ "unit-price": 10 }, { "unit-price": 20 }] }), [
    10n,
    21n,
  ]);
});

test("regex policies use RE2 and defer pattern errors until evaluation", () => {
  const program = new Program(
    "request.path.matches('^/v[0-9]+/orders/[a-z]+$') && matches(request.user, pattern)",
  );
  const request = { path: "/v1/orders/abc", user: "admin-1" };
  assert.equal(program.evaluate({ request, pattern: "^admin" }), true);
  assert.equal(program.evaluate({ request, pattern: "^guest" }), false);
  assert.equal(new Program(String.raw`'世界'.matches(r'\p{Han}+')`).evaluate({}), true);
  const invalid = new Program("'text'.matches('(')");
  assert.throws(
    () => invalid.evaluate({}),
    (error: unknown) => error instanceof EvaluateError && error.code === "InvalidArgument",
  );
  assert.equal(new Program("false && 'text'.matches('(')").evaluate({}), false);
  assert.throws(() => new Program(String.raw`'aa'.matches(r'(a)\1')`).evaluate({}), EvaluateError);
});

test("environments own declarations and check complete policies", () => {
  const constants = { "acme.policy.minimum": 18 };
  const environment = new Environment({
    container: "acme.policy",
    variables: { "acme.age": new CELType("int") },
    constants,
  });
  constants["acme.policy.minimum"] = 100;
  const program = environment.compile("age >= minimum");
  assert.deepEqual(program.resultType, new CELType("bool"));
  assert.equal(program.evaluate({ "acme.age": 21 }), true);
  assert.equal(new Program("1").resultType, null);
  assert.equal(new Program("age", { environment }).evaluate({ "acme.age": 21 }), 21n);
  assert.deepEqual(new Program("1", { check: true }).resultType, new CELType("int"));
  assert.equal(environment.compile("age", { check: false }).evaluate({ "acme.age": 21 }), 21n);
  assert.throws(() => environment.compile("false && 1 + 'a' == 1"), CompileError);
  assert.throws(() => environment.compile("unknown"), CompileError);
  assert.throws(() => new Environment({ container: ".invalid" }), CompileError);
  const integers = new CELType("list", [new CELType("int")]);
  const mapped = new Environment({ variables: { items: integers } }).compile("items.map(x, x + 1)");
  assert.deepEqual(mapped.resultType, integers);
  assert.deepEqual(mapped.evaluate({ items: [1, 2] }), [2n, 3n]);
  assert.throws(() => new Program("x").evaluate({ x: integers }), TypeError);
  assert.throws(() => new CELType("list", [1] as never), TypeError);
  assert.throws(() => new CELType("list", null as never), TypeError);
  assert.throws(() => new Program("1", { check: 1 as never }), TypeError);
  assert.throws(() => new Program("1", { environment: {} as never }), TypeError);
  assert.throws(() => new Environment({ variables: [] as never }), TypeError);
  assert.deepEqual(new Environment().compile("1").resultType, new CELType("int"));
  const nested = { "policy.items": [1, 2] };
  const saved = new Environment({ container: "policy", constants: nested }).compile(
    "items.map(x, x + 1)",
  );
  nested["policy.items"].length = 0;
  global.gc?.();
  assert.deepEqual(saved.evaluate({}), [2n, 3n]);
});

test("byte inputs are captured before later getters run", () => {
  const bytes = new Uint8Array([1, 2, 3]);
  const bindings = {
    bytes,
    get later() {
      bytes.fill(9);
      return null;
    },
  };
  assert.deepEqual(new Program("bytes").evaluate(bindings), Buffer.from([1, 2, 3]));
});

test("negative zero remains a double and wrappers validate inputs", () => {
  assert.equal(new Program("1.0 / x").evaluate({ x: -0 }), -Infinity);
  assert.throws(() => new UInt("1" as never), TypeError);
  assert.throws(() => new Double("1" as never), TypeError);
  assert.throws(() => new Program("x").evaluate({ x: new Uint16Array([1]) } as never), TypeError);
});

test("compile and evaluation failures have distinct typed codes", () => {
  assert.throws(
    () => new Program("1 +"),
    (error: unknown) =>
      error instanceof CompileError &&
      error.code === "InvalidSyntax" &&
      error.message === "InvalidSyntax",
  );

  assert.throws(
    () => new Program(" ".repeat(1_048_577)),
    (error: unknown) => error instanceof CompileError && error.code === "SourceLimitExceeded",
  );

  const program = new Program("missing");
  assert.throws(
    () => program.evaluate({}),
    (error: unknown) =>
      error instanceof EvaluateError &&
      error.code === "UndeclaredReference" &&
      error.message === "UndeclaredReference",
  );
});

test("invalid JavaScript inputs are rejected", () => {
  const identity = new Program("value");
  const evaluateUnknown = (value: unknown): unknown => identity.evaluate({ value } as never);
  assert.throws(() => evaluateUnknown(undefined), TypeError);
  assert.throws(() => evaluateUnknown(Number.MAX_SAFE_INTEGER + 1), RangeError);
  assert.throws(() => evaluateUnknown(9_223_372_036_854_775_808n), RangeError);
  assert.throws(() => new UInt(-1n), RangeError);
  assert.throws(() => new UInt(2n ** 64n), RangeError);
  assert.throws(() => new Program(null as never), TypeError);
  assert.throws(
    () =>
      identity.evaluate({
        get value(): never {
          throw 42;
        },
      }),
    (error: unknown) => error === 42,
  );
  assert.throws(() => evaluateUnknown(new Date()), TypeError);
  assert.throws(() => evaluateUnknown({ [Symbol("key")]: true }), TypeError);

  const getterError = Object.assign(new Error("getter failed"), { code: "Overflow" });
  const getter = Object.defineProperty({}, "value", {
    enumerable: true,
    get: () => {
      throw getterError;
    },
  });
  assert.throws(
    () => evaluateUnknown(getter),
    (error: unknown) => error === getterError,
  );

  const cyclic: Record<string, unknown> = {};
  cyclic.self = cyclic;
  assert.throws(() => evaluateUnknown(cyclic), RangeError);

  let deep: unknown = null;
  for (let index = 0; index < 129; index += 1) deep = [deep];
  assert.throws(() => evaluateUnknown(deep), RangeError);

  assert.throws(() => evaluateUnknown(Array.from({ length: 100_001 }, () => null)), RangeError);
});

test("native conversion uses captured intrinsics and accepts numeric wrapper subclasses", () => {
  const program = new Program("request.allowed && request.values.all(x, x > 0)");
  const original = globalThis.Object;
  try {
    globalThis.Object = class Replacement {} as typeof Object;
    assert.equal(program.evaluate({ request: { allowed: true, values: [1, 2] } }), true);
  } finally {
    globalThis.Object = original;
  }
  class Unsigned extends UInt {}
  class Floating extends Double {}
  class TypeValue extends CELType {}
  assert.deepEqual(new Program("x + 1u").evaluate({ x: new Unsigned(2n) }), new UInt(3n));
  assert.equal(new Program("x + 1.0").evaluate({ x: new Floating(2) }), 3);
  assert.equal(new Program("x == int").evaluate({ x: new TypeValue("int") }), true);
});

test("binding names and maps use own enumerable string properties", () => {
  const value = Object.create(null) as { hidden?: number; visible: number };
  value.visible = 2;
  Object.defineProperty(value, "hidden", { enumerable: false, value: 1 });
  assert.equal(new Program("value.visible == 2 && !has(value.hidden)").evaluate({ value }), true);

  assert.throws(() => new Program("value").evaluate([] as never), TypeError);
  assert.throws(() => new Program("value").evaluate(null as never), TypeError);
  assert.throws(() => new Program("value").evaluate("text" as never), TypeError);
  assert.throws(() => new Program("value").evaluate(new Date() as never), TypeError);
});

test("native programs can be reclaimed by garbage collection", () => {
  for (let index = 0; index < 1_000; index += 1) new Program("true");
  global.gc?.();
  assert.equal(new Program("true").evaluate({}), true);
});
