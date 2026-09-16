import assert from "node:assert/strict";
import test from "node:test";

import { CELType, Environment, OptionalValue, Program } from "../index.js";

const identity = new Program("value");

test("plain objects and native maps bypass mutable optional instance checks", () => {
  const previous = Object.getOwnPropertyDescriptor(OptionalValue, Symbol.hasInstance);
  let calls = 0;
  let result: unknown;
  try {
    Object.defineProperty(OptionalValue, Symbol.hasInstance, {
      configurable: true,
      value: () => {
        calls += 1;
        throw new Error("optional instance hook ran");
      },
    });
    const plain = Object.assign(Object.create(null), { allowed: true });
    result = identity.evaluate({ value: { plain, map: new Map([["allowed", true]]) } });
  } finally {
    if (previous) Object.defineProperty(OptionalValue, Symbol.hasInstance, previous);
    else Reflect.deleteProperty(OptionalValue, Symbol.hasInstance);
  }
  assert.deepEqual(result, { plain: { allowed: true }, map: { allowed: true } });
  assert.equal(calls, 0);
});

test("optional subclasses and reentrant getters preserve value conversion order", () => {
  class Present extends OptionalValue {}
  const unwrap = new Program("value.value()");
  assert.equal(unwrap.evaluate({ value: new Present(true, 1) }), 1n);
  const visited: string[] = [];
  const value = Object.create(OptionalValue.prototype, {
    hasValue: {
      get() {
        visited.push("hasValue");
        assert.equal(unwrap.evaluate({ value: OptionalValue.of(2) }), 2n);
        return true;
      },
    },
    value: {
      get() {
        visited.push("value");
        return 3;
      },
    },
  }) as OptionalValue;
  assert.equal(unwrap.evaluate({ value }), 3n);
  assert.deepEqual(visited, ["hasValue", "value"]);
});

test("enumerable key snapshots retain order and ignore later additions", () => {
  const visited: string[] = [];
  const value: Record<string, unknown> = {
    get first() {
      visited.push("first");
      value.late = 3;
      return 1;
    },
    get second() {
      visited.push("second");
      return 2;
    },
  };
  Object.defineProperty(value, "hidden", { value: 4 });
  Object.defineProperty(value, Symbol("hidden"), { value: 5 });
  assert.deepEqual(identity.evaluate({ value } as never), { first: 1n, second: 2n });
  assert.deepEqual(visited, ["first", "second"]);
});

test("enumerable symbol errors follow earlier string-keyed getter effects", () => {
  let visited = 0;
  const value = {
    get first() {
      visited += 1;
      return 1;
    },
    [Symbol("unsupported")]: 2,
  };
  assert.throws(() => identity.evaluate({ value } as never), TypeError);
  assert.equal(visited, 1);

  const marker = new Error("earlier getter");
  const throwing = {
    get first(): never {
      throw marker;
    },
    [Symbol("unsupported")]: 2,
  };
  assert.throws(
    () => identity.evaluate({ value: throwing } as never),
    (error) => error === marker,
  );
});

test("symbol key snapshots do not invoke inherited array setters", () => {
  const value = { [Symbol("unsupported")]: true };
  const previous = Object.getOwnPropertyDescriptor(Array.prototype, "0");
  let calls = 0;
  let failure: unknown;
  try {
    Object.defineProperty(Array.prototype, "0", {
      configurable: true,
      set() {
        calls += 1;
      },
    });
    try {
      identity.evaluate({ value } as never);
    } catch (error) {
      failure = error;
    }
  } finally {
    if (previous) Object.defineProperty(Array.prototype, "0", previous);
    else Reflect.deleteProperty(Array.prototype, "0");
  }
  assert.ok(failure instanceof TypeError);
  assert.equal(calls, 0);
});

test("property enumeration uses captured intrinsics for values and environments", () => {
  const keys = Object.keys;
  const symbols = Object.getOwnPropertySymbols;
  const enumerable = Object.prototype.propertyIsEnumerable;
  const value = { visible: 1 };
  Object.defineProperty(value, Symbol("hidden"), { value: 2 });
  const variables = { value: new CELType("int") };
  let result: unknown;
  let environment: Environment;
  try {
    Object.keys = () => {
      throw new Error("replaced Object.keys");
    };
    Object.getOwnPropertySymbols = () => {
      throw new Error("replaced Object.getOwnPropertySymbols");
    };
    Object.prototype.propertyIsEnumerable = () => {
      throw new Error("replaced propertyIsEnumerable");
    };
    result = identity.evaluate({ value });
    environment = new Environment({ variables, constants: { constant: value } });
  } finally {
    Object.keys = keys;
    Object.getOwnPropertySymbols = symbols;
    Object.prototype.propertyIsEnumerable = enumerable;
  }
  assert.deepEqual(result, { visible: 1n });
  assert.equal(environment.compile("value == constant.visible").evaluate({ value: 1 }), true);
});
