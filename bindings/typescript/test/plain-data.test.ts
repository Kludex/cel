import assert from "node:assert/strict";
import test from "node:test";

import { Double, Message, OptionalValue, Program, Timestamp, UInt } from "../index.js";
import type { CelInput } from "../index.js";

const identity = new Program("value");

test("plain request bindings convert getters exactly once in enumeration order", () => {
  const visited: string[] = [];
  const request = {
    get method() {
      visited.push("method");
      return "GET";
    },
    get nested() {
      visited.push("nested");
      return {
        get inner() {
          visited.push("inner");
          return [1, "two", null, 2.5, true];
        },
      };
    },
  };
  const program = new Program("request.method == 'GET' && request.nested.inner[1] == 'two'");
  assert.equal(program.evaluate({ request }), true);
  assert.deepEqual(visited, ["method", "nested", "inner"]);
});

test("unsupported values after plain data preserve earlier getter effects and error identity", () => {
  let visited = 0;
  const marker = new Error("late getter");
  const bindings = {
    first: {
      get value() {
        visited += 1;
        return "text";
      },
    },
    second: new Date(),
  };
  assert.throws(() => identity.evaluate({ value: bindings } as never), TypeError);
  assert.equal(visited, 1);
  assert.throws(
    () =>
      identity.evaluate({
        value: {
          get a() {
            visited += 1;
            return 1;
          },
          get b(): never {
            throw marker;
          },
        },
      }),
    (error) => error === marker,
  );
  assert.equal(visited, 2);
  assert.throws(() => identity.evaluate({ value: { a: 1, b: undefined } } as never), TypeError);
  assert.throws(() => identity.evaluate({ value: { a: 1, b: Symbol("s") } } as never), TypeError);
  assert.throws(() => identity.evaluate({ value: { a: 1, b: () => 1 } } as never), TypeError);
});

test("plain data keeps exact numeric, string, and byte semantics", () => {
  const value = {
    safe: Number.MAX_SAFE_INTEGER,
    negative: -9_007_199_254_740_991,
    fraction: 0.1,
    negativeZero: -0,
    nan: Number.NaN,
    infinity: Number.POSITIVE_INFINITY,
    big: -9n,
    text: "héllo 😃 \u0000 end",
    empty: "",
    long: "x".repeat(70_000),
    bytes: new Uint8Array([0, 127, 255]),
    unsigned: new UInt(18_446_744_073_709_551_615n),
    double: new Double(2),
    list: [1, [2, [3, []]], {}, { k: [] }],
  };
  const result = identity.evaluate({ value }) as Record<string, unknown>;
  assert.equal(result.safe, 9_007_199_254_740_991n);
  assert.equal(result.negative, -9_007_199_254_740_991n);
  assert.equal(result.fraction, 0.1);
  assert.ok(Object.is(result.negativeZero, -0));
  assert.ok(Number.isNaN(result.nan));
  assert.equal(result.infinity, Number.POSITIVE_INFINITY);
  assert.equal(result.big, -9n);
  assert.equal(result.text, value.text);
  assert.equal(result.empty, "");
  assert.equal(result.long, value.long);
  assert.deepEqual([...(result.bytes as Uint8Array)], [0, 127, 255]);
  assert.deepEqual(result.unsigned, value.unsigned);
  assert.equal(result.double, 2);
  assert.deepEqual(result.list, [1n, [2n, [3n, []]], {}, { k: [] }]);
  assert.equal(new Program("value == 2.0").evaluate({ value: new Double(2) }), true);
  assert.equal(new Program("type(value) == double").evaluate({ value: new Double(2) }), true);
  assert.throws(() => identity.evaluate({ value: Number.MAX_SAFE_INTEGER + 1 }), RangeError);
  assert.throws(() => identity.evaluate({ value: 2n ** 63n }), RangeError);
  assert.throws(() => identity.evaluate({ value: "\ud800" }), TypeError);
  assert.throws(() => identity.evaluate({ value: { nested: ["ok", "\udfff tail"] } }), TypeError);
  assert.equal(identity.evaluate({ value: "\ufffd literal" }), "\ufffd literal");
});

test("plain data mixed with wrapper classes and native maps converts consistently", () => {
  const value = {
    when: new Timestamp(1n, 5),
    maybe: OptionalValue.of("x"),
    none: OptionalValue.none(),
    message: new Message("google.protobuf.Empty", new Uint8Array()),
    map: new Map<number | string, CelInput>([
      [1, "one"],
      ["two", [2]],
    ]),
    plain: { deep: { list: ["a", { b: null }] } },
  };
  const result = identity.evaluate({ value }) as Record<string, unknown>;
  assert.deepEqual(result.when, new Timestamp(1n, 5));
  assert.deepEqual(result.maybe, OptionalValue.of("x"));
  assert.deepEqual(result.none, OptionalValue.none());
  assert.ok(result.message instanceof Message);
  assert.deepEqual(
    result.map,
    new Map<bigint | string, unknown>([
      [1n, "one"],
      ["two", [2n]],
    ]),
  );
  assert.deepEqual(result.plain, { deep: { list: ["a", { b: null }] } });
});

test("reentrant evaluations during deferred conversion keep outer plain data intact", () => {
  const large = Array.from({ length: 5_000 }, (_, index) => ({
    key: `k${index}`,
    text: "x".repeat(40),
  }));
  let inner: unknown;
  const value = {
    before: "outer before",
    marker: OptionalValue.of({
      get late() {
        inner = identity.evaluate({ value: large });
        assert.equal(identity.evaluate({ value: "inner" }), "inner");
        assert.throws(() => identity.evaluate({ value: { bad: undefined } } as never), TypeError);
        return "late";
      },
    }),
    after: ["outer", "after", 3],
  };
  const result = identity.evaluate({ value }) as Record<string, unknown>;
  assert.equal(result.before, "outer before");
  assert.deepEqual(result.marker, OptionalValue.of({ late: "late" }));
  assert.deepEqual(result.after, ["outer", "after", 3n]);
  assert.deepEqual(inner, large);
  assert.deepEqual(identity.evaluate({ value: { again: "ok" } }), { again: "ok" });
});

test("deferred maps snapshot entries before later plain getters run", () => {
  const map = new Map<string, number>([["x", 1]]);
  const bindings = {
    map,
    get mutate() {
      map.set("x", 2);
      map.set("added", 3);
      return 0;
    },
  };
  assert.equal(new Program('map["x"] == 1 && !("added" in map)').evaluate(bindings), true);
  const nested = new Map<string, CelInput>([["inner", { deep: 1 }]]);
  const bindingsNested = {
    nested,
    get mutate() {
      nested.set("inner", { deep: 2 });
      return 0;
    },
  };
  assert.equal(new Program("nested.inner.deep == 1").evaluate(bindingsNested), true);
});

test("collection budgets stop plain traversal before reading every element", () => {
  let lastRead = false;
  const values: unknown[] = new Array(100_000).fill(0);
  Object.defineProperty(values, 99_999, {
    enumerable: true,
    get() {
      lastRead = true;
      return 0;
    },
  });
  assert.throws(() => new Program("true").evaluate({ values } as never), RangeError);
  assert.equal(lastRead, false);

  let objectRead = false;
  const wide: Record<string, unknown> = {};
  for (let index = 0; index < 60_000; index += 1) wide[`k${index}`] = 0;
  Object.defineProperty(wide, "last", {
    enumerable: true,
    get() {
      objectRead = true;
      return 0;
    },
  });
  assert.throws(() => new Program("true").evaluate({ wide } as never), RangeError);
  assert.equal(objectRead, false);

  const exact = new Array(99_999).fill(true);
  assert.equal(new Program("list.size()").evaluate({ list: exact }), 99_999n);
  assert.throws(() => new Program("true").evaluate({ list: exact, extra: 1 }), RangeError);
});

test("plain data enforces cycle, depth, collection, and byte limits", () => {
  const cyclic: Record<string, unknown> = { name: "root" };
  cyclic.self = { child: cyclic };
  assert.throws(() => identity.evaluate({ value: cyclic } as never), RangeError);
  const shared = { ok: true };
  assert.deepEqual(identity.evaluate({ value: [shared, shared] }), [{ ok: true }, { ok: true }]);

  let deep: unknown = "leaf";
  for (let index = 0; index < 127; index += 1) deep = { deep };
  assert.ok(identity.evaluate({ value: deep } as never));
  deep = { deep };
  assert.throws(() => identity.evaluate({ value: deep } as never), RangeError);

  const wide = Object.fromEntries(Array.from({ length: 49_999 }, (_, index) => [`k${index}`, 1]));
  assert.ok(identity.evaluate({ value: wide }));
  assert.throws(
    () =>
      identity.evaluate({
        value: Object.fromEntries(Array.from({ length: 50_000 }, (_, index) => [`k${index}`, 1])),
      }),
    RangeError,
  );
  assert.throws(() => identity.evaluate({ value: ["x".repeat(1_048_577)] }), RangeError);
  assert.throws(
    () => identity.evaluate({ value: ["x".repeat(600_000), { y: "x".repeat(600_000) }] }),
    RangeError,
  );
});
