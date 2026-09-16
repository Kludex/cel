import assert from "node:assert/strict";
import test from "node:test";

import {
  CELType,
  Environment,
  EvaluateError,
  FunctionDeclaration,
  Message,
  Program,
} from "../index.js";

test("list extensions evaluate a complete collection policy", () => {
  const environment = new Environment({
    variables: { batches: new CELType("list", [new CELType("dyn")]) },
  });
  const program = environment.compile(
    "batches.flatten().distinct().sort().slice(0, 3).reverse() == [3, 2, 1]" +
      " && lists.range(3).all(i, i < 3)",
  );
  assert.equal(program.evaluate({ batches: [[3, 1], [2, 3], [4]] }), true);
  assert.deepEqual(program.resultType, new CELType("bool"));
  assert.deepEqual(
    environment.compile("batches.flatten()").resultType,
    new CELType("list", [new CELType("dyn")]),
  );
});

test("sortBy scopes its variable and evaluates receiver and keys once", () => {
  const calls: bigint[] = [];
  let receivers = 0;
  const values = [
    { id: "first", rank: 2 },
    { id: "second", rank: 1 },
    { id: "third", rank: 2 },
  ];
  const environment = new Environment({
    variables: { value: new CELType("string") },
    functions: [
      new FunctionDeclaration("items", [], new CELType("list", [new CELType("dyn")]), () => {
        receivers += 1;
        return values;
      }),
      new FunctionDeclaration("key", [new CELType("int")], new CELType("int"), (value: bigint) => {
        calls.push(value);
        return value;
      }),
    ],
  });
  assert.deepEqual(
    environment.compile("items().sortBy(value, key(value.rank)).map(item, item.id)").evaluate({}),
    ["second", "first", "third"],
  );
  assert.deepEqual(calls, [2n, 1n, 2n]);
  assert.equal(receivers, 1);
  assert.deepEqual(
    values.map((value) => value.id),
    ["first", "second", "third"],
  );
});

test("list extensions preserve nested equality and reject invalid boundaries", () => {
  const values = [[new Message("google.protobuf.Int64Value", new Uint8Array([8, 1]))], [1]];
  assert.equal(
    new Program("values.distinct().size() == 1 && values[0] == values[1]").evaluate({ values }),
    true,
  );
  assert.equal(
    new Program("[1, 1u, 1.0, true, true, {'x': [1]}, {'x': [1u]}].distinct().size()").evaluate({}),
    3n,
  );
  assert.deepEqual(new Program("[[], [1, [2]], 3].flatten(0)").evaluate({}), [[], [1n, [2n]], 3n]);
  assert.deepEqual(new Program("[[], [1, [2]], 3].flatten(2)").evaluate({}), [1n, 2n, 3n]);
  assert.deepEqual(new Program("[].sortBy(item, item.missing)").evaluate({}), []);
  for (const source of [
    "[].slice(-1, 0)",
    "[1].slice(0, 2)",
    "[].flatten(-1)",
    "lists.range(-1)",
    "[1, 1u].sort()",
    "[{}].sort()",
    "[null].sort()",
    "lists.range(2u)",
  ]) {
    assert.throws(() => new Program(source).evaluate({}), EvaluateError);
  }
});
