import assert from "node:assert/strict";
import test from "node:test";

import {
  CELType,
  CompileError,
  Environment,
  EvaluateError,
  FunctionDeclaration,
  Program,
  UInt,
} from "../index.js";

test("math policies preserve numeric result types and permission decisions", () => {
  const environment = new Environment({ variables: { permissions: new CELType("uint") } });
  const policy = environment.compile(
    "math.bitAnd(permissions, 3u) == 3u && math.greatest([1, 2u, 3.5]) == 3.5",
  );
  assert.equal(policy.evaluate({ permissions: new UInt(7n) }), true);
  assert.equal(policy.evaluate({ permissions: new UInt(1n) }), false);
  assert.deepEqual(new Program("math.greatest(1u, 1, 1.0)").evaluate({}), new UInt(1n));
  assert.equal(typeof new Program("math.least(1.0, 1u, 1)").evaluate({}), "number");
  assert.equal(
    new Program("math.greatest(9223372036854775807, 9223372036854775808.0)").evaluate({}),
    9223372036854775807n,
  );
  assert.equal(
    new Program("math.greatest(9223372036854775808.0, 9223372036854775807)").evaluate({}),
    9223372036854775808,
  );
  assert.equal(new Program("math.bitShiftRight(-1, 1)").evaluate({}), 9223372036854775807n);
  assert.equal(new Program("math.bitShiftLeft(1, 63)").evaluate({}), -9223372036854775808n);
  assert.equal(new Program("math.bitShiftLeft(-1, 64)").evaluate({}), 0n);
});

test("math rounding, predicates and errors retain CEL behavior", () => {
  assert.deepEqual(
    new Program("[math.ceil(-1.2), math.floor(-1.2), math.round(-1.5), math.trunc(-1.2)]").evaluate(
      {},
    ),
    [-1, -2, -2, -1],
  );
  assert.equal(Object.is(new Program("math.sign(-0.0)").evaluate({}), 0), true);
  assert.equal(Number.isNaN(new Program("math.sign(0.0 / 0.0)").evaluate({})), true);
  assert.equal(
    new Program("math.isFinite(1.0) && math.isInf(1.0/0.0) && math.isNaN(0.0/0.0)").evaluate({}),
    true,
  );
  for (const source of [
    "math.greatest()",
    "math.least([])",
    "math.greatest('bad')",
    "math.least(1, [])",
  ]) {
    assert.throws(
      () => new Program(source),
      (error) => error instanceof CompileError && error.code === "InvalidSyntax",
    );
  }
  assert.throws(() => new Environment().compile("false && math.abs(true) == 1"), CompileError);
  for (const [source, code] of [
    ["math.abs(-9223372036854775808)", "Overflow"],
    ["math.bitShiftRight(1, -1)", "InvalidArgument"],
    ["math.ceil(dyn(1))", "NoMatchingOverload"],
    ["math.greatest(dyn([]))", "InvalidArgument"],
  ] as const) {
    assert.throws(
      () => new Program(source).evaluate({}),
      (error) => error instanceof EvaluateError && error.code === code,
    );
  }
});

test("math namespaces remain independent of variables and respect function overrides", () => {
  const environment = new Environment({
    container: "policy",
    variables: { math: new CELType("int") },
  });
  assert.equal(environment.compile("math.abs(-2) + math").evaluate({ math: 3 }), 5n);
  assert.equal(environment.compile(".math.abs(-2)").evaluate({}), 2n);
  const custom = new Environment({
    functions: [
      new FunctionDeclaration(
        "math.abs",
        [new CELType("bool")],
        new CELType("bool"),
        (value) => value,
      ),
    ],
  });
  assert.equal(custom.compile("math.abs(true)").evaluate({}), true);
});
