import assert from "node:assert/strict";
import test from "node:test";

import {
  CELType,
  CompileError,
  Environment,
  FunctionDeclaration,
  OptionalValue,
  Program,
} from "../index.js";
import type { CelOutput } from "../index.js";

test("local bindings evaluate complete policies and preserve lexical scope", () => {
  const environment = new Environment({
    variables: { batches: new CELType("list", [new CELType("dyn")]) },
  });
  const source =
    "cel.bind(jobs, batches.flatten(), jobs.size() >= 2 && jobs.distinct().size() == jobs.size() && jobs.sort().slice(0,2) == [1,2])";
  for (const program of [new Program(source), environment.compile(source)]) {
    assert.equal(program.evaluate({ batches: [[3, 1], [2]] }), true);
    assert.equal(program.evaluate({ batches: [[1, 1], [2]] }), false);
  }
  assert.deepEqual(environment.compile(source).resultType, new CELType("bool"));
  assert.deepEqual(
    new Environment()
      .compile("cel.bind(x, 10, [1,2].map(y, cel.bind(z, x+y, cel.bind(x, 100, z+z))))")
      .evaluate({}),
    [22n, 24n],
  );
  assert.equal(new Program("cel.bind(x, x + 1, x)").evaluate({ x: 3 }), 4n);
  assert.equal(new Program("cel.bind(x, missing, 7)").evaluate({}), 7n);
  assert.throws(() => new Environment().compile("cel.bind(x, missing, 7)"), CompileError);
});

test("local initializer values and CEL errors are cached only for one evaluation", () => {
  let calls = 0;
  const environment = new Environment({
    functions: [new FunctionDeclaration("tick", [], new CELType("int"), () => ++calls)],
  });
  assert.equal(environment.compile("cel.bind(x, tick(), 42)").evaluate({}), 42n);
  assert.equal(calls, 0);
  const program = environment.compile("cel.bind(x, tick(), x+x)");
  assert.equal(program.evaluate({}), 2n);
  assert.equal(program.evaluate({}), 4n);
  assert.equal(calls, 2);
  assert.equal(
    environment.compile("cel.bind(x, tick()/0, (x == 1 || true) && (x == 1 || true))").evaluate({}),
    true,
  );
  assert.equal(calls, 3);
});

test("cached empty values and absolute names preserve their meaning", () => {
  let calls = 0;
  const environment = new Environment({
    variables: { input: new CELType("dyn"), x: new CELType("int") },
    functions: [
      new FunctionDeclaration(
        "identity",
        [new CELType("dyn")],
        new CELType("dyn"),
        (value: CelOutput) => {
          calls += 1;
          return value;
        },
      ),
    ],
  });
  const program = environment.compile("cel.bind(x, identity(input), [x,x])");
  const values = [null, false, 0n, [], OptionalValue.none(), OptionalValue.of(null)];
  for (const input of values) assert.deepEqual(program.evaluate({ input }), [input, input]);
  assert.equal(calls, values.length);
  assert.equal(environment.compile("cel.bind(.x, 1/0, .x)").evaluate({ x: 3 }), 3n);
});

test("bind expansion uses the exact namespace before custom function lookup", () => {
  for (const source of ["cel.bind(1, 2, 3)", "cel.bind(x.y, 1, x.y)"]) {
    assert.throws(() => new Program(source), CompileError);
  }
  for (const source of [
    "cel.bind(x, 1)",
    "cel.bind(x, 1, x, x)",
    ".cel.bind(x, 1, x)",
    "other.bind(x, 1, x)",
  ]) {
    assert.throws(() => new Environment().compile(source), CompileError);
  }
  const environment = new Environment({
    variables: { cel: new CELType("bool") },
    functions: [
      new FunctionDeclaration(
        "cel.bind",
        [new CELType("int"), new CELType("int"), new CELType("int")],
        new CELType("int"),
        (a: bigint, b: bigint, c: bigint) => a + b + c,
      ),
    ],
  });
  assert.equal(environment.compile("cel.bind(v, 7, v)").evaluate({}), 7n);
  assert.equal(environment.compile(".cel.bind(1, 2, 3)").evaluate({}), 6n);
});

test("local initialization preserves host errors and reentrant result storage", () => {
  const marker = new Error("initializer failed");
  const identity = new Program("cel.bind(x, value, [x, x])");
  let calls = 0;
  const environment = new Environment({
    functions: [
      new FunctionDeclaration("fail", [], new CELType("int"), () => {
        throw marker;
      }),
      new FunctionDeclaration("nested", [], new CELType("int"), () => {
        calls += 1;
        assert.deepEqual(identity.evaluate({ value: 9 }), [9n, 9n]);
        return 2;
      }),
    ],
  });
  assert.equal(environment.compile("cel.bind(x, fail(), true)").evaluate({}), true);
  assert.throws(
    () => environment.compile("cel.bind(x, fail(), x == 0 || true)").evaluate({}),
    (error) => error === marker,
  );
  const result = environment.compile("cel.bind(x, [nested(), 3], [x, x])").evaluate({});
  global.gc?.();
  assert.deepEqual(result, [
    [2n, 3n],
    [2n, 3n],
  ]);
  assert.equal(calls, 1);
});
