import assert from "node:assert/strict";
import test from "node:test";

import {
  CELType,
  CompileError,
  Environment,
  EvaluateError,
  FunctionDeclaration,
  Program,
} from "../index.js";

test("indexed blocks preserve heterogeneous slot types and lazy memoization", () => {
  const source =
    "cel.block([1, 'ok', [cel.index(0)], cel.index(0)+2], [cel.index(1), cel.index(2), cel.index(3)])";
  for (const program of [new Program(source), new Environment().compile(source)]) {
    assert.deepEqual(program.evaluate({}), ["ok", [1n], 3n]);
  }
  let calls = 0;
  const environment = new Environment({
    functions: [new FunctionDeclaration("tick", [], new CELType("int"), () => ++calls)],
  });
  assert.equal(environment.compile("cel.block([tick(), 1/0], true)").evaluate({}), true);
  assert.equal(calls, 0);
  const program = environment.compile("cel.block([tick()], cel.index(0)+cel.index(0))");
  assert.equal(program.evaluate({}), 2n);
  assert.equal(program.evaluate({}), 4n);
  assert.equal(calls, 2);
  assert.equal(
    environment
      .compile("cel.block([tick()/0], (cel.index(0) == 1 || true) && (cel.index(0) == 1 || true))")
      .evaluate({}),
    true,
  );
  assert.equal(calls, 3);
});

test("block scope and iterator handles cannot be redirected by use-site bindings", () => {
  const environment = new Environment({ variables: { x: new CELType("int") } });
  assert.deepEqual(
    environment.compile("cel.block([x+1], [2].map(x, cel.index(0)))").evaluate({ x: 10 }),
    [11n],
  );
  assert.equal(
    new Environment()
      .compile(
        "cel.block([10], cel.bind(outer, cel.index(0), cel.block([2, outer+cel.index(0)], cel.index(1))))",
      )
      .evaluate({}),
    12n,
  );
  assert.deepEqual(
    new Environment()
      .compile(
        "[1,2].map(cel.iterVar(0,0), [3].map(cel.iterVar(1,0), cel.iterVar(0,0)+cel.iterVar(1,0)))",
      )
      .evaluate({}),
    [[4n], [5n]],
  );
  assert.throws(
    () => new Program("cel.iterVar(0,0)").evaluate({ "@itervar_0_0": 9 }),
    EvaluateError,
  );
});

test("block syntax and lazy dependency errors preserve host exception behavior", () => {
  for (const source of [
    "cel.index(-1)",
    "cel.index(0u)",
    "cel.index(0.0)",
    "cel.block([1], cel.index(1-1))",
    "cel.block(values, true)",
  ]) {
    assert.throws(() => new Program(source), CompileError);
  }
  assert.equal(
    new Environment().compile("cel.block([cel.index(1)+1, 5], cel.index(0))").evaluate({}),
    6n,
  );
  assert.equal(new Program("cel.block([cel.index(0)], true)").evaluate({}), true);
  assert.equal(
    new Program("cel.block([cel.index(0) == 1 || true], cel.index(0))").evaluate({}),
    true,
  );
  for (const source of [
    "cel.index(0)",
    "cel.block([1], cel.index(1))",
    "cel.block([cel.index(0)], cel.index(0))",
  ]) {
    assert.throws(() => new Program(source).evaluate({}), EvaluateError);
  }
  const marker = new Error("slot failed");
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("fail", [], new CELType("int"), () => {
        throw marker;
      }),
    ],
  });
  assert.equal(environment.compile("cel.block([fail()], true)").evaluate({}), true);
  assert.throws(
    () => environment.compile("cel.block([fail()], cel.index(0) == 0 || true)").evaluate({}),
    (error) => error === marker,
  );
});
