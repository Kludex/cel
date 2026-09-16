import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { CELType, CompileError, Environment, EvaluateError, Message, Program } from "../index.js";

const descriptors = readFileSync(
  new URL("../../../../conformance/protobuf/test-schema-descriptor.pb", import.meta.url),
);

test("protobuf messages preserve descriptors, wire data, defaults, and presence", () => {
  const environment = new Environment({ descriptors, container: "cel.conformance.fixture" });
  const program = environment.compile(
    "TestSchema{signed_value:12,values:[1,2],counts:{'x':3},optional_value:''}",
  );
  const message = program.evaluate({});
  assert.ok(message instanceof Message);
  assert.deepEqual(program.resultType, new CELType("cel.conformance.fixture.TestSchema"));
  const reader = new Environment({
    descriptors,
    variables: { m: new CELType(message.typeName) },
  }).compile(
    "m.signed_value == 12 && m.values == [1,2] && m.counts['x'] == 3 && has(m.optional_value) && !has(m.name)",
  );
  assert.equal(reader.evaluate({ m: message }), true);
  assert.equal(environment.compile("TestSchema{}.nested.value").evaluate({}), "");
  assert.deepEqual(
    new Program("google.protobuf.DescriptorProto{name:'Entry'}").evaluate({}),
    new Message("google.protobuf.DescriptorProto", new Uint8Array([10, 5, 69, 110, 116, 114, 121])),
  );
  assert.equal(new Program("google.protobuf.DescriptorProto{} != {}").evaluate({}), true);
});

test("protobuf boundary errors preserve failure phases", () => {
  assert.throws(() => new Environment({ descriptors: new Uint8Array([255]) }), CompileError);
  const environment = new Environment({ descriptors });
  const invalid = new Message("cel.conformance.fixture.TestSchema", new Uint8Array([128]));
  assert.throws(
    () => environment.compile("m.signed_value", { check: false }).evaluate({ m: invalid }),
    EvaluateError,
  );
  assert.throws(() => new Message(""), TypeError);
  assert.throws(() => new Message("Type", "invalid" as never), TypeError);
});

test("messages copy their byte inputs and programs retain descriptor ownership", () => {
  const wire = new Uint8Array([10, 4, 107, 101, 112, 116]);
  const expected = new Message("cel.conformance.fixture.TestSchema.Nested", wire);
  wire.fill(0);
  const program = new Environment({ descriptors, container: "cel.conformance.fixture" }).compile(
    "TestSchema{nested:TestSchema.Nested{value:'kept'}}.nested",
  );
  global.gc?.();
  assert.deepEqual(program.evaluate({}), expected);
});
