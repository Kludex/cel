import assert from "node:assert/strict";
import test from "node:test";

import { Double, Environment, EnumValue, Message, OptionalValue, Program, UInt } from "../index.js";
import type { CelInput, CelMapKey } from "../index.js";

const NativeMap = Map;
const identity = new Program("value");
const evaluate = (value: unknown): unknown => identity.evaluate({ value } as never);

test("typed map outputs are valid inputs without assertions or casts", () => {
  const values: ReadonlyMap<CelMapKey, CelInput> = new NativeMap<CelMapKey, CelInput>([
    [true, "boolean"],
    [1n, "integer"],
  ]);
  const result = identity.evaluate({ value: values });
  assert.equal(new Program("m[true] + m[1]").evaluate({ m: result }), "booleaninteger");
});

test("native maps preserve CEL key types and nested maps", () => {
  const nested = new NativeMap<unknown, unknown>([[true, "nested"]]);
  const input = new NativeMap<unknown, unknown>([
    [false, "false"],
    [1, "int"],
    [new UInt(2n), nested],
    ["name", "string"],
  ]);

  const result = evaluate(input);
  assert.ok(result instanceof NativeMap);
  assert.deepEqual(
    result,
    new NativeMap<unknown, unknown>([
      [false, "false"],
      [1n, "int"],
      [new UInt(2n), new NativeMap([[true, "nested"]])],
      ["name", "string"],
    ]),
  );
  assert.equal(new Program("value[true]").evaluate({ value: nested } as never), "nested");
});

test("native maps accept integer boundaries and keep bool distinct from integers", () => {
  const input = new NativeMap<unknown, unknown>([
    [true, "bool"],
    [1n, "int"],
    [-(2n ** 63n), "min int"],
    [2n ** 63n - 1n, "max int"],
    [new UInt(2n ** 64n - 1n), "max uint"],
    [Number.MAX_SAFE_INTEGER, "safe number"],
  ]);

  assert.deepEqual(
    evaluate(input),
    new NativeMap<unknown, unknown>([
      [true, "bool"],
      [1n, "int"],
      [-(2n ** 63n), "min int"],
      [2n ** 63n - 1n, "max int"],
      [new UInt(2n ** 64n - 1n), "max uint"],
      [BigInt(Number.MAX_SAFE_INTEGER), "safe number"],
    ]),
  );
});

test("native maps reject invalid and CEL-equivalent duplicate keys", () => {
  for (const key of [
    1.5,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    new Double(1),
    null,
    {},
    [],
    new Message("example.Message"),
    new EnumValue("example.Enum", 1),
  ]) {
    assert.throws(() => evaluate(new NativeMap([[key, null]])), TypeError);
  }
  assert.throws(() => evaluate(new NativeMap([[Number.MAX_SAFE_INTEGER + 1, null]])), RangeError);
  assert.throws(() => evaluate(new NativeMap([[2n ** 63n, null]])), RangeError);
  assert.throws(
    () =>
      evaluate(
        new NativeMap<unknown, unknown>([
          [1, "number"],
          [1n, "bigint"],
        ]),
      ),
    TypeError,
  );
  assert.throws(
    () =>
      evaluate(
        new NativeMap<unknown, unknown>([
          [new UInt(1n), "uint"],
          [1n, "int"],
        ]),
      ),
    TypeError,
  );
  assert.throws(
    () =>
      new Program("true").evaluate({
        unused: new NativeMap<unknown, unknown>([
          [1, null],
          [1n, null],
        ]),
      } as never),
    TypeError,
  );
});

test("native map conversion uses captured intrinsics", () => {
  class HostileMap extends NativeMap<unknown, unknown> {
    override entries(): MapIterator<[unknown, unknown]> {
      throw new Error("entries override called");
    }

    override forEach(): void {
      throw new Error("forEach override called");
    }

    override set(): this {
      throw new Error("set override called");
    }
  }

  const input = new HostileMap();
  NativeMap.prototype.set.call(input, 1n, "one");
  const originalForEach = NativeMap.prototype.forEach;
  const originalSet = NativeMap.prototype.set;
  const originalGlobalMap = globalThis.Map;
  const expected = new NativeMap([[1n, "one"]]);
  try {
    NativeMap.prototype.forEach = () => {
      throw new Error("poisoned Map.prototype.forEach called");
    };
    NativeMap.prototype.set = () => {
      throw new Error("poisoned Map.prototype.set called");
    };
    globalThis.Map = class PoisonedMap {
      constructor() {
        throw new Error("poisoned global Map called");
      }
    } as unknown as MapConstructor;
    assert.deepEqual(evaluate(input), expected);
    assert.deepEqual(new Program("{1: 'one'}").evaluate({}), expected);
  } finally {
    NativeMap.prototype.forEach = originalForEach;
    NativeMap.prototype.set = originalSet;
    globalThis.Map = originalGlobalMap;
  }

  assert.throws(() => evaluate(new Proxy(new NativeMap([[1n, "one"]]), {})), TypeError);
});

test("map brands and limits do not depend on mutable prototypes", () => {
  for (const prototype of [null, Object.prototype, OptionalValue.prototype]) {
    const input = new NativeMap([[1n, "one"]]);
    Object.setPrototypeOf(input, prototype);
    assert.deepEqual(evaluate(input), new NativeMap([[1n, "one"]]));
    const excessive = new NativeMap(Array.from({ length: 50_000 }, (_, index) => [index, null]));
    Object.setPrototypeOf(excessive, prototype);
    assert.throws(() => new Program("true").evaluate({ ignored: excessive }), RangeError);
  }
});

test("proxies cannot disguise map brands or wrapper keys", () => {
  const map = new NativeMap([[1n, "one"]]);
  for (const prototype of [null, Object.prototype]) {
    const proxy = new Proxy(map, { getPrototypeOf: () => prototype });
    assert.throws(() => evaluate(proxy), TypeError);
    assert.throws(() => identity.evaluate(proxy as never), TypeError);
    assert.throws(() => new Environment({ constants: proxy as never }), TypeError);
    assert.throws(() => new Environment({ variables: proxy as never }), TypeError);
  }
  for (const value of [[], {}, new UInt(1n), new Uint8Array([1])]) {
    assert.throws(() => evaluate(new Proxy(value, {})), TypeError);
  }
  assert.throws(() => evaluate(new NativeMap([[new Proxy(new UInt(1n), {}), 1]])), TypeError);
});

test("proxy rejection does not execute wrapper prototype traps", () => {
  let calls = 0;
  const marker = new Error("prototype trap ran");
  for (const value of [{}, new NativeMap(), OptionalValue.of(1), []]) {
    const proxy = new Proxy(value, {
      getPrototypeOf() {
        calls += 1;
        throw marker;
      },
    });
    assert.throws(() => evaluate(proxy), TypeError);
    assert.throws(() => new Environment({ constants: { value: proxy } as never }), TypeError);
  }
  assert.equal(calls, 0);
});

test("map snapshot descriptors ignore inherited accessors", () => {
  for (const name of ["get", "set"]) {
    const previous = Object.getOwnPropertyDescriptor(Object.prototype, name);
    const descriptor = { __proto__: null, value: () => undefined, configurable: true };
    let result: unknown;
    try {
      Object.defineProperty(Object.prototype, name, descriptor);
      result = evaluate(new NativeMap([[1n, "one"]]));
    } finally {
      Reflect.deleteProperty(Object.prototype, name);
      if (previous) Object.defineProperty(Object.prototype, name, previous);
    }
    assert.deepEqual(result, new NativeMap([[1n, "one"]]));
  }
});

test("map snapshots do not invoke inherited array setters", () => {
  const source = new NativeMap([
    [1n, "one"],
    [2n, "two"],
  ]);
  const previous = Object.getOwnPropertyDescriptor(Array.prototype, "0");
  let called = false;
  let result: unknown;
  try {
    Object.defineProperty(Array.prototype, "0", {
      configurable: true,
      set() {
        called = true;
      },
      get() {
        return "poison";
      },
    });
    result = evaluate(source);
  } finally {
    if (previous) Object.defineProperty(Array.prototype, "0", previous);
    else Reflect.deleteProperty(Array.prototype, "0");
  }
  assert.equal(called, false);
  assert.deepEqual(result, source);
});

test("native maps snapshot entries before converting values", () => {
  const source = new NativeMap<unknown, unknown>();
  source.set("first", {
    get value() {
      source.clear();
      source.set("late", 2);
      return 1;
    },
  });

  assert.deepEqual(evaluate(source), { first: { value: 1n } });
});

test("native map results and environment constants own their data", () => {
  const source = new NativeMap<unknown, unknown>([[1n, { nested: [1, 2] }]]);
  const result = evaluate(source);
  source.clear();
  assert.deepEqual(result, new NativeMap([[1n, { nested: [1n, 2n] }]]));

  const constants = new NativeMap<unknown, unknown>([[1n, "one"]]);
  const environment = new Environment({ constants: { saved: constants } as never });
  constants.clear();
  assert.equal(environment.compile("saved[1]").evaluate({}), "one");

  const returned = new Program("{1: 'one', true: 'yes'}").evaluate({});
  assert.ok(returned instanceof NativeMap);
  assert.equal(
    new Program("value[1] + value[true]").evaluate({ value: returned } as never),
    "oneyes",
  );
});

test("native maps detect cycles but allow shared noncyclic values", () => {
  const cyclic = new NativeMap<unknown, unknown>();
  cyclic.set("self", cyclic);
  assert.throws(() => evaluate(cyclic), RangeError);

  const shared = { value: 1 };
  assert.deepEqual(
    evaluate(
      new NativeMap([
        ["left", shared],
        ["right", shared],
      ]),
    ),
    {
      left: { value: 1n },
      right: { value: 1n },
    },
  );
});

test("nested native map evaluations keep results independent", () => {
  const program = new Program("value");
  let nested: unknown;
  const outer = new NativeMap<unknown, unknown>([
    [
      1n,
      {
        get value() {
          nested = program.evaluate({ value: new NativeMap([[2n, "inner"]]) } as never);
          return "outer";
        },
      },
    ],
  ]);

  const result = program.evaluate({ value: outer } as never);
  outer.clear();
  assert.deepEqual(result, new NativeMap([[1n, { value: "outer" }]]));
  assert.deepEqual(nested, new NativeMap([[2n, "inner"]]));
});

test("object and native maps charge the same key-value budget", () => {
  const entries = Array.from({ length: 49_999 }, (_, index) => [String(index), null] as const);
  const object = Object.fromEntries(entries);
  const map = new NativeMap(entries);
  const program = new Program("value.size()");
  assert.equal(program.evaluate({ value: object }), 49_999n);
  assert.equal(program.evaluate({ value: map }), 49_999n);
  object.extra = null;
  map.set("extra", null);
  assert.throws(() => program.evaluate({ value: object }), RangeError);
  assert.throws(() => program.evaluate({ value: map }), RangeError);
});

test("native maps preserve collection, depth, and byte limits", () => {
  assert.throws(
    () => evaluate(new NativeMap(Array.from({ length: 100_000 }, (_, index) => [index, null]))),
    RangeError,
  );
  assert.throws(() => evaluate(new NativeMap([["x".repeat(1_048_577), null]])), RangeError);

  let deep: unknown = null;
  for (let index = 0; index < 129; index += 1) deep = new NativeMap([["next", deep]]);
  assert.throws(() => evaluate(deep), RangeError);
});
