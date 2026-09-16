import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  CELType,
  Duration,
  EnumValue,
  Environment,
  EvaluateError,
  FunctionDeclaration,
  Message,
  OptionalValue,
  Program,
  Timestamp,
} from "../index.js";
import type { CelInput } from "../index.js";

test("OptionalValue constructors preserve presence", () => {
  assert.deepEqual(new OptionalValue(), OptionalValue.none());
  assert.deepEqual(OptionalValue.of(null), new OptionalValue(true, null));
  assert.deepEqual(OptionalValue.of(1), new OptionalValue(true, 1));
  assert.throws(() => new OptionalValue(1 as never), TypeError);
  assert.throws(() => new OptionalValue(false, 1), TypeError);
});

test("optional operations and static types cross the native boundary", () => {
  assert.deepEqual(new Program("optional.none()").evaluate({}), OptionalValue.none());
  assert.deepEqual(new Program("optional.of(null)").evaluate({}), OptionalValue.of(null));
  assert.equal(new Program("optional.of(2).value()").evaluate({}), 2n);
  assert.deepEqual(new Program("optional.ofNonZeroValue(0)").evaluate({}), OptionalValue.none());
  assert.deepEqual(new Program("optional.ofNonZeroValue(2)").evaluate({}), OptionalValue.of(2n));
  assert.throws(
    () => new Program("optional.none().value()").evaluate({}),
    (error: unknown) => error instanceof EvaluateError && error.code === "NoSuchKey",
  );

  const optionalInt = CELType.abstract("optional_type", [new CELType("int")]);
  const program = new Environment({ variables: { value: optionalInt } }).compile("value");
  assert.deepEqual(program.resultType, optionalInt);
  assert.deepEqual(program.evaluate({ value: OptionalValue.of(1) }), OptionalValue.of(1n));
  assert.deepEqual(program.evaluate({ value: OptionalValue.none() }), OptionalValue.none());
});

test("nested optionals and present null remain distinct", () => {
  const value = OptionalValue.of(null);
  const result = new Program("[value, {'nested': value}]").evaluate({ value });
  assert.deepEqual(result, [value, { nested: value }]);
  assert.equal((result as OptionalValue[])[0]?.hasValue, true);
});

test("optional constants own recursive payloads", () => {
  const payload: CelInput[] = [1, OptionalValue.of(2)];
  const environment = new Environment({ constants: { saved: OptionalValue.of(payload) } });
  const program = environment.compile("saved");
  payload.length = 0;
  assert.deepEqual(program.evaluate({}), OptionalValue.of([1n, OptionalValue.of(2n)]));
});

test("callbacks accept and return optional values", () => {
  const optionalInt = CELType.abstract("optional_type", [new CELType("int")]);
  const seen: CelInput[] = [];
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("echo", [optionalInt], optionalInt, (value) => {
        seen.push(value);
        return value;
      }),
    ],
  });
  const result = environment.compile("echo(optional.of(1))").evaluate({});
  assert.deepEqual(result, OptionalValue.of(1n));
  assert.deepEqual(seen, [OptionalValue.of(1n)]);
});

test("native conversion validates spoofed OptionalValue metadata", () => {
  const malformedFlag = Object.create(OptionalValue.prototype) as {
    hasValue: unknown;
    value: unknown;
  };
  malformedFlag.hasValue = 1;
  malformedFlag.value = null;
  assert.throws(() => new Program("value").evaluate({ value: malformedFlag as never }), TypeError);

  const malformedAbsent = Object.create(OptionalValue.prototype) as {
    hasValue: unknown;
    value: unknown;
  };
  malformedAbsent.hasValue = false;
  malformedAbsent.value = 1;
  assert.throws(
    () => new Program("value").evaluate({ value: malformedAbsent as never }),
    TypeError,
  );
});

test("optional conversion enforces cycles, depth, bytes, and value budgets", () => {
  const cyclic = OptionalValue.of(null);
  (cyclic as { value: CelInput }).value = cyclic;
  assert.throws(() => new Program("value").evaluate({ value: cyclic }), RangeError);

  let deep: CelInput = null;
  for (let index = 0; index < 129; index += 1) deep = OptionalValue.of(deep);
  assert.throws(() => new Program("value").evaluate({ value: deep }), RangeError);

  assert.throws(
    () =>
      new Program("value").evaluate({
        value: OptionalValue.of(new Uint8Array(1_048_576)),
      }),
    RangeError,
  );
  assert.throws(
    () =>
      new Program("value").evaluate({
        value: Array.from({ length: 100_000 }, () => OptionalValue.none()),
      }),
    RangeError,
  );
});

test("optional payloads support enum, proto, temporal, and type values", () => {
  const values: CelInput[] = [
    new EnumValue("example.Status", 1),
    new Timestamp(1n, 2),
    new Duration(3n),
    new CELType("int"),
  ];
  for (const value of values) {
    const result = new Program("value").evaluate({ value: OptionalValue.of(value) });
    assert.ok(result instanceof OptionalValue);
    assert.equal(result.hasValue, true);
    assert.equal((result.value as object).constructor, (value as object).constructor);
  }

  const descriptors = readFileSync(
    new URL("../../../../conformance/protobuf/test-schema-descriptor.pb", import.meta.url),
  );
  const messageType = new CELType("cel.conformance.fixture.TestSchema");
  const optionalMessage = CELType.abstract("optional_type", [messageType]);
  const program = new Environment({ descriptors, variables: { value: optionalMessage } }).compile(
    "value",
  );
  const message = new Message(messageType.name, new Uint8Array([8, 42]));
  assert.deepEqual(
    program.evaluate({ value: OptionalValue.of(message) }),
    OptionalValue.of(message),
  );
});

test("optional wrappers reject unsupported payloads", () => {
  assert.throws(
    () => new Program("value").evaluate({ value: OptionalValue.of(new Date() as never) }),
    TypeError,
  );
});
