import assert from "node:assert/strict";
import test from "node:test";

import { Program } from "../index.js";

test("nested evaluations keep outer input and result storage independent", () => {
  const program = new Program("x");
  const large = Array.from({ length: 1000 }, (_, index) => ({ key: `${index}😃`, count: index }));
  const expected = large.map(({ key, count }) => ({ key, count: BigInt(count) }));
  let nestedResult: unknown;
  const outer = {
    before: "outer before",
    get nested() {
      assert.equal(program.evaluate({ x: "inner" }), "inner");
      nestedResult = program.evaluate({ x: large });
      assert.throws(() => program.evaluate({ x: { invalid: undefined } } as never), TypeError);
      globalThis.gc?.();
      return "outer after";
    },
  };
  const result = program.evaluate({ x: outer });
  assert.deepEqual(result, { before: "outer before", nested: "outer after" });
  assert.deepEqual(nestedResult, expected);
  large.length = 0;
  for (let index = 0; index < 20; index += 1) program.evaluate({ x: [index, "different"] });
  assert.deepEqual(result, { before: "outer before", nested: "outer after" });
  assert.deepEqual(nestedResult, expected);
});
