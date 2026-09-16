import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { CELType, CompileError, EnumValue, Environment, EvaluateError, Message } from "../index.js";

const descriptors = readFileSync(
  new URL("../../../../conformance/protobuf/cel-spec-test-descriptors.pb", import.meta.url),
);

for (const syntax of ["proto2", "proto3"] as const) {
  test(`strong ${syntax} enums preserve types, conversions, defaults, and wire values`, () => {
    const container = `cel.expr.conformance.${syntax}`;
    const enumName = `${container}.GlobalEnum`;
    const nestedName = `${container}.TestAllTypes.NestedEnum`;
    const environment = new Environment({ descriptors, container, strongEnums: true });

    assert.deepEqual(
      environment.compile("GlobalEnum.GAZ").evaluate({}),
      new EnumValue(enumName, 2),
    );
    assert.deepEqual(
      environment.compile("GlobalEnum(-33)").evaluate({}),
      new EnumValue(enumName, -33),
    );
    assert.deepEqual(
      environment.compile("GlobalEnum('GAR')").evaluate({}),
      new EnumValue(enumName, 1),
    );
    assert.equal(environment.compile("int(GlobalEnum.GAZ)").evaluate({}), 2n);
    assert.deepEqual(
      environment.compile("TestAllTypes{}.standalone_enum").evaluate({}),
      new EnumValue(nestedName, 0),
    );
    if (syntax === "proto2") {
      assert.deepEqual(
        environment.compile("TestAllTypes{}.single_nested_enum").evaluate({}),
        new EnumValue(nestedName, 1),
      );
    }

    const message = environment
      .compile(
        "TestAllTypes{standalone_enum:TestAllTypes.NestedEnum.BAZ," +
          "repeated_nested_enum:[TestAllTypes.NestedEnum.BAR]}",
      )
      .evaluate({});
    assert.ok(message instanceof Message);
    const reader = new Environment({
      descriptors,
      variables: { m: new CELType(message.typeName) },
      strongEnums: true,
    }).compile("[m.standalone_enum, m.repeated_nested_enum[0]]");
    assert.deepEqual(reader.evaluate({ m: message }), [
      new EnumValue(nestedName, 2),
      new EnumValue(nestedName, 1),
    ]);
  });
}

test("legacy enums remain integers by default", () => {
  const environment = new Environment({ descriptors, container: "cel.expr.conformance.proto3" });
  assert.deepEqual(
    environment.compile("[GlobalEnum.GAZ, TestAllTypes{}.standalone_enum]").evaluate({}),
    [2n, 0n],
  );
});

test("enum declarations, constants, and nested inputs preserve ownership", () => {
  const typeName = "cel.expr.conformance.proto3.TestAllTypes.NestedEnum";
  const value = new EnumValue(typeName, 99);
  const constants = { saved: [value, { value }] };
  const options = {
    descriptors,
    variables: {
      value: new CELType(typeName),
      values: new CELType("list", [new CELType(typeName)]),
    },
    constants,
    strongEnums: true,
  };
  const environment = new Environment(options);
  const declared = environment.compile("[value]");
  constants.saved.length = 0;
  options.strongEnums = false;
  const program = environment.compile("[value, values[0], saved[0], saved[1].value]");
  assert.deepEqual(program.evaluate({ value, values: [value] }), [value, value, value, value]);
  assert.deepEqual(declared.resultType, new CELType("list", [new CELType(typeName)]));
});

test("EnumValue validates wrapper and spoofed native inputs", () => {
  const value = new EnumValue("example.Status", 1);
  assert.equal(value.typeName, "example.Status");
  assert.equal(value.number, 1);
  assert.throws(() => new EnumValue(1 as never, 1), TypeError);
  for (const name of [
    "",
    ".example.Status",
    "example..Status",
    "example.bad-name",
    "éxample.Status",
  ]) {
    assert.throws(() => new EnumValue(name, 1), RangeError);
  }
  for (const number of [true, 1n, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => new EnumValue("example.Status", number as never), TypeError);
  }
  for (const number of [-2_147_483_649, 2_147_483_648]) {
    assert.throws(() => new EnumValue("example.Status", number), RangeError);
  }

  const spoofed = Object.create(EnumValue.prototype) as EnumValue & {
    typeName: unknown;
    number: unknown;
  };
  Object.defineProperties(spoofed, {
    typeName: { configurable: true, value: "bad-name" },
    number: { configurable: true, value: 1 },
  });
  assert.throws(() => new Environment({ constants: { value: spoofed } }), RangeError);
  Object.defineProperty(spoofed, "typeName", { configurable: true, value: "example.Status" });
  Object.defineProperty(spoofed, "number", { configurable: true, value: 1n });
  assert.throws(() => new Environment({ constants: { value: spoofed } }), TypeError);

  for (const name of [Array.from({ length: 129 }, () => "a").join("."), "a".repeat(1_048_576)]) {
    assert.throws(
      () => new Environment({ constants: { value: new EnumValue(name, 1) } }),
      RangeError,
    );
  }
});

test("enum constants cannot claim primitive, message, or unregistered types", () => {
  for (const typeName of ["int", "google.protobuf.DescriptorProto", "missing.Enum"]) {
    const value = new EnumValue(typeName, 1);
    for (const constant of [value, [value], { value }]) {
      assert.throws(
        () => new Environment({ strongEnums: true, constants: { fake: constant } }),
        (error: unknown) => error instanceof CompileError && error.code === "InvalidDeclaration",
      );
    }
  }
});

test("enum ranges, wrong overloads, map keys, and strongEnums type are rejected", () => {
  const environment = new Environment({
    descriptors,
    container: "cel.expr.conformance.proto3",
    strongEnums: true,
  });
  for (const source of ["GlobalEnum(2147483648)", "GlobalEnum(-2147483649)"]) {
    assert.throws(
      () => environment.compile(source, { check: false }).evaluate({}),
      (error: unknown) => error instanceof EvaluateError && error.code === "Overflow",
    );
  }
  for (const source of [
    "GlobalEnum(true)",
    "GlobalEnum(1u)",
    "GlobalEnum(1.0)",
    "GlobalEnum.GAR + 1",
  ]) {
    assert.throws(() => environment.compile(source), CompileError);
  }
  assert.throws(
    () => environment.compile("GlobalEnum('MISSING')", { check: false }).evaluate({}),
    EvaluateError,
  );
  assert.throws(
    () => environment.compile("{GlobalEnum.GAR: 1}", { check: false }).evaluate({}),
    EvaluateError,
  );
  assert.throws(() => new Environment({ strongEnums: 1 as never }), TypeError);
});
