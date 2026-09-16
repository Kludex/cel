import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { CELType, CompileError, Environment, EvaluateError, Program } from "../index.js";

const descriptors = readFileSync(
  new URL("../../../../conformance/protobuf/cel-spec-test-descriptors.pb", import.meta.url),
);

test("Base64 operations preserve binary inputs, padding and URL alphabets", () => {
  const environment = new Environment({ variables: { data: new CELType("bytes") } });
  const program = environment.compile("base64.decode(base64.encode(data))");
  assert.deepEqual(program.resultType, new CELType("bytes"));
  for (const data of [Buffer.alloc(0), Buffer.from("hello"), Buffer.from([0, 255, 254, 128])]) {
    assert.deepEqual(program.evaluate({ data }), data);
    assert.equal(new Program("base64.encode(data)").evaluate({ data }), data.toString("base64"));
  }
  assert.deepEqual(new Program("base64.decode('aGVsbG8')").evaluate({}), Buffer.from("hello"));
  assert.deepEqual(
    new Program("base64.decode('aG\\r\\nVsbG8=')").evaluate({}),
    Buffer.from("hello"),
  );
  assert.equal(new Program("base64.encodeUrl(b'\\xff\\xff\\xff')").evaluate({}), "____");
  assert.deepEqual(
    new Program("base64.decodeUrl('____')").evaluate({}),
    Buffer.from([255, 255, 255]),
  );
  for (const text of ["Zh==", "Zh"])
    assert.deepEqual(new Program("base64.decode(text)").evaluate({ text }), Buffer.from("f"));
  for (const text of ["a", "a===", "aGV sbG8=", "aGVsbG8===", "a=GVsbG8", "____"]) {
    assert.throws(() => new Program("base64.decode(text)").evaluate({ text }), EvaluateError);
  }
  assert.equal(
    new Environment({ container: "base64.child" }).compile("encode(b'x')").evaluate({}),
    "eA==",
  );
});

test("protobuf helpers preserve descriptor presence and defaults", () => {
  const environment = new Environment({ descriptors, container: "cel.expr.conformance.proto2" });
  const program = environment.compile(
    "cel.bind(msg, TestAllTypes{`cel.expr.conformance.proto2.int32_ext`: 42}, proto.hasExt(msg, cel.expr.conformance.proto2.int32_ext) && proto.getExt(msg, cel.expr.conformance.proto2.int32_ext) == 42 && !proto.hasExt(msg, cel.expr.conformance.proto2.repeated_test_all_types) && proto.getExt(msg, cel.expr.conformance.proto2.repeated_test_all_types) == [])",
  );
  assert.equal(program.evaluate({}), true);
  const value = environment.compile(
    "proto.getExt(TestAllTypes{}, cel.expr.conformance.proto2.int32_ext)",
  );
  assert.deepEqual(value.resultType, new CELType("int"));
  assert.equal(value.evaluate({ "cel.expr.conformance.proto2.int32_ext": "redirect" }), 0n);
  assert.throws(() => environment.compile("proto.getExt(TestAllTypes{}, 'name')"), CompileError);
  assert.throws(
    () =>
      environment.compile(
        "proto.getExt(google.protobuf.Empty{}, cel.expr.conformance.proto2.int32_ext)",
      ),
    CompileError,
  );
  assert.equal(new Environment().compile("proto.getExt({'a.b': 3}, a.b)").evaluate({}), 3n);
  assert.equal(new Environment().compile("proto.hasExt({}, a.b)").evaluate({}), false);
});
