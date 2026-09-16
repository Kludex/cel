import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { Environment, Program, compilePlainDataPlan } from "../index.js";
import type { CelInput } from "../index.js";

type Workload = {
  name: string;
  expression: string;
  cases: { name: string; bindings: Record<string, CelInput>; expected: CelInput }[];
};
const workloads = JSON.parse(
  readFileSync(new URL("../../../../benchmarks/workloads.json", import.meta.url), "utf8"),
) as Workload[];

test("plain-data mode agrees with the native engine on every workload decision", () => {
  let fast = 0;
  for (const workload of workloads) {
    const program = new Program(workload.expression);
    if (program.hasFastPath) fast += 1;
    for (const item of workload.cases) {
      assert.equal(
        program.evaluate(item.bindings, { plainData: true }),
        item.expected,
        `${workload.name}/${item.name}`,
      );
      assert.equal(program.evaluate(item.bindings), item.expected);
    }
  }
  // Authorization, routing, data validation, and cart validation are inside the subset; the others use
  // regular expressions, temporal, optional, math, list, string, encoder, or network functions.
  assert.equal(fast, 4);
  assert.equal(new Program(workloads[1]!.expression).hasFastPath, true, workloads[1]!.name);
  assert.equal(new Program(workloads[2]!.expression).hasFastPath, true, workloads[2]!.name);
  assert.equal(new Program(workloads[3]!.expression).hasFastPath, true, workloads[3]!.name);
  assert.equal(new Program(workloads[0]!.expression).hasFastPath, true);
});

test("plain-data mode falls back to the native engine on every type or shape surprise", () => {
  const program = new Program("request.method == 'GET' && principal.count == 3 && principal.ok");
  assert.equal(program.hasFastPath, true);
  const good = { request: { method: "GET" }, principal: { count: 3, ok: true } };
  assert.equal(program.evaluate(good, { plainData: true }), true);
  // Each of these leaves the compiled shape; the engine's answer (value or error) must be preserved.
  const surprises: Record<string, CelInput>[] = [
    { request: { method: "GET" }, principal: { count: 3n, ok: true } },
    { request: { method: "GET" }, principal: { count: 3.0, ok: true } },
    { request: new Map([["method", "GET"]]), principal: { count: 3, ok: true } },
    { request: { method: "GET" }, principal: { count: 3, ok: true }, "principal.ok": false },
    { request: { method: "GET" }, principal: { count: 3, ok: true }, "request.method": "POST" },
  ];
  for (const bindings of surprises) {
    assert.equal(
      program.evaluate(bindings, { plainData: true }),
      program.evaluate(bindings),
      String(Object.keys(bindings)),
    );
  }
  for (const bindings of [
    { request: { method: "GET" }, principal: { count: 3, ok: 1 } },
    { request: ["GET"], principal: { count: 3, ok: true } },
  ] as Record<string, CelInput>[]) {
    assert.throws(() => program.evaluate(bindings, { plainData: true }), /NoMatchingOverload/);
    assert.throws(() => program.evaluate(bindings), /NoMatchingOverload/);
  }
  // `5 == 'GET'` is false under CEL heterogeneous equality, so the engine short-circuits; the fast path bails
  // on the non-string and must reach the same value.
  assert.equal(
    program.evaluate({ request: { method: 5 }, principal: good.principal }, { plainData: true }),
    false,
  );
  assert.equal(
    new Program("principal.count == 3").evaluate(
      { principal: { count: "3" } },
      { plainData: true },
    ),
    false,
  );
  const nullPrototype = Object.assign(Object.create(null), { method: "GET" }) as Record<
    string,
    string
  >;
  assert.equal(
    program.evaluate({ request: nullPrototype, principal: good.principal }, { plainData: true }),
    true,
  );
  assert.throws(
    () => program.evaluate({ principal: good.principal }, { plainData: true }),
    /UndeclaredReference/,
  );
  assert.throws(
    () => program.evaluate({ request: {}, principal: good.principal }, { plainData: true }),
    /NoSuchKey/,
  );
  const proxied = new Proxy({ method: "GET" }, {});
  assert.throws(
    () => program.evaluate({ request: proxied, principal: good.principal }, { plainData: true }),
    TypeError,
  );
  assert.throws(() => program.evaluate(null as never, { plainData: true }), TypeError);
  // Unused fields are never read in plain-data mode, so an invalid unused value is not an error there.
  const unusedInvalid = {
    request: { method: "GET" },
    principal: { count: 3, ok: true, extra: undefined },
  } as never;
  assert.equal(program.evaluate(unusedInvalid, { plainData: true }), true);
  assert.throws(() => program.evaluate(unusedInvalid), TypeError);
});

test("plain-data mode keeps CEL logical semantics and does not read unused fields", () => {
  const program = new Program("a.flag || b.value == 'x'");
  let reads = 0;
  const bindings = {
    a: { flag: true },
    b: {
      get value() {
        reads += 1;
        return "x";
      },
    },
  };
  assert.equal(program.evaluate(bindings, { plainData: true }), true);
  assert.equal(reads, 0);
  assert.equal(program.evaluate(bindings), true);
  assert.equal(reads, 1);
  assert.equal(
    new Program("!a.flag && b.value != 'y'").evaluate(
      { a: { flag: false }, b: { value: "x" } },
      { plainData: true },
    ),
    true,
  );
  assert.equal(
    new Program("a.b.c.d == 'deep'").evaluate(
      { a: { b: { c: { d: "deep" } } } },
      { plainData: true },
    ),
    true,
  );
  assert.equal(new Program("a == b").evaluate({ a: "same", b: "same" }, { plainData: true }), true);
  assert.equal(
    new Program("s.startsWith('ab') && s.endsWith('yz') && s.contains('mn')").evaluate(
      { s: "abmnyz" },
      { plainData: true },
    ),
    true,
  );
  assert.throws(
    () => new Program("s.startsWith('ab')").evaluate({ s: 5 }, { plainData: true }),
    /NoMatchingOverload/,
  );
});

test("programs outside the subset report no fast path and still evaluate in plain-data mode", () => {
  for (const source of [
    "a.b < 'x'",
    "has(a.b)",
    "a.`b-c` == 1",
    "size(a) == 1",
    "a == 1.5",
    "a.?b.orValue(1) == 1",
  ]) {
    const program = new Program(source);
    assert.equal(program.hasFastPath, false, source);
  }
  assert.equal(new Program("size(a) == 1").evaluate({ a: [2] }, { plainData: true }), true);
  assert.equal(
    new Program("a.`b-c` == 1").evaluate({ a: { "b-c": 1 } }, { plainData: true }),
    true,
  );
  const environment = new Environment({ container: "ns" });
  assert.equal(environment.compile("a.b == 1", { check: false }).hasFastPath, false);
  assert.throws(
    () => new Program("a").evaluate({ a: 1 }, { plainData: "yes" as never }),
    TypeError,
  );
});

test("hand-built plans outside the compiler's vocabulary are refused", () => {
  assert.equal(compilePlainDataPlan(null), undefined);
  assert.equal(compilePlainDataPlan(JSON.stringify(["size", ["ident", "a"]])), undefined);
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["&&", ["ident", "a"], ["string", "x"]])),
    undefined,
  );
  assert.equal(compilePlainDataPlan(JSON.stringify(["!", ["string", "x"]])), undefined);
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["startsWith", ["ident", "a"], ["int", 1]])),
    undefined,
  );
  // `(a && b) == c` is a boolean comparison and compiles; `c` is read as a boolean.
  const booleanEquality = compilePlainDataPlan(
    JSON.stringify(["==", ["&&", ["ident", "a"], ["ident", "b"]], ["ident", "c"]]),
  );
  assert.ok(booleanEquality);
  assert.equal(booleanEquality({ a: true, b: false, c: false }), true);
  assert.equal(compilePlainDataPlan(JSON.stringify(["int", 1])), undefined);
  assert.equal(compilePlainDataPlan(JSON.stringify(["ident", "a"])), undefined);
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]])),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["?:", ["ident", "f"], ["int", 1], ["int", 2]])),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify(["select", ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]], "c"]),
    ),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify([
        "==",
        ["select", ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]], "c"],
        ["string", "x"],
      ]),
    ),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify(["==", ["select", ["size", ["ident", "a"]], "c"], ["string", "x"]]),
    ),
    undefined,
  );
  const literal = compilePlainDataPlan(JSON.stringify(["string", "x"]));
  assert.ok(literal);
  assert.equal(literal({}), "x");
  // Boolean-producing nodes in a string position: `'x' == (a == b)` style plans the engine never emits.
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify(["==", ["string", "x"], ["==", ["ident", "a"], ["ident", "b"]]]),
    ),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["==", ["string", "x"], ["!", ["ident", "a"]]])),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify(["==", ["string", "x"], ["contains", ["ident", "a"], ["string", "b"]]]),
    ),
    undefined,
  );
  const booleanRight = compilePlainDataPlan(
    JSON.stringify(["==", ["ident", "a"], ["&&", ["ident", "b"], ["ident", "c"]]]),
  );
  assert.ok(booleanRight);
  assert.equal(booleanRight({ a: false, b: true, c: false }), true);
  assert.equal(compilePlainDataPlan(JSON.stringify(["!", ["size", ["ident", "a"]]])), undefined);
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["contains", ["ident", "a"], ["size", ["ident", "b"]]])),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["contains", ["size", ["ident", "a"]], ["string", "x"]])),
    undefined,
  );
  assert.equal(
    compilePlainDataPlan(JSON.stringify(["select", ["size", ["ident", "a"]], "b"])),
    undefined,
  );
  const constant = compilePlainDataPlan(JSON.stringify(["==", ["string", "x"], ["string", "x"]]));
  assert.ok(constant);
  assert.equal(constant({}), true);
  const compiled = compilePlainDataPlan(JSON.stringify(["==", ["ident", "a"], ["int", 1]]));
  assert.ok(compiled);
  assert.equal(compiled({ a: 1 }), true);
  assert.equal(compiled({ a: 2 }), false);
});

test("plain-data mode rejects lone surrogates like the engine and documents its direct-read differences", () => {
  const same = new Program("x == x");
  assert.throws(() => same.evaluate({ x: "\ud800" }), TypeError);
  assert.throws(() => same.evaluate({ x: "\ud800" }, { plainData: true }), TypeError);
  assert.equal(same.evaluate({ x: "ok \u{1F600}" }, { plainData: true }), true);
  // Direct reads see non-enumerable properties and re-read getters; the converter does neither.
  const hidden = Object.defineProperty({}, "x", { value: true }) as Record<string, boolean>;
  assert.throws(() => new Program("x == true").evaluate(hidden), /UndeclaredReference/);
  assert.equal(new Program("x == true").evaluate(hidden, { plainData: true }), true);
  let reads = 0;
  const counter = {
    get x() {
      reads += 1;
      return String(reads);
    },
  };
  assert.equal(same.evaluate(counter), true);
  assert.equal(same.evaluate(counter, { plainData: true }), false);
});

test("plain-data mode compiles string conditionals and string-keyed indexing", () => {
  const route = new Program(
    'request.path.startsWith("/admin") ? "admin" : request.path.startsWith("/api") && request.headers["x-canary"] == "1" ? "canary" : "default"',
  );
  assert.equal(route.hasFastPath, true);
  assert.equal(
    route.evaluate({ request: { path: "/admin/x", headers: {} } }, { plainData: true }),
    "admin",
  );
  assert.equal(
    route.evaluate(
      { request: { path: "/api/x", headers: { "x-canary": "1" } } },
      { plainData: true },
    ),
    "canary",
  );
  assert.equal(
    route.evaluate(
      { request: { path: "/api/x", headers: { "x-canary": "0" } } },
      { plainData: true },
    ),
    "default",
  );
  // A missing header is a NoSuchKey error in the engine; the fast path must bail into that error.
  assert.throws(
    () => route.evaluate({ request: { path: "/api/x", headers: {} } }, { plainData: true }),
    /NoSuchKey/,
  );
  assert.equal(
    route.evaluate({ request: { path: "/other", headers: new Map() } }, { plainData: true }),
    "default",
  );
  const label = new Program("flag ? name : 'none'");
  assert.equal(label.evaluate({ flag: true, name: "n" }, { plainData: true }), "n");
  assert.equal(label.evaluate({ flag: false, name: 5 }, { plainData: true }), "none");
  // The engine happily returns an int from the other branch; the fast path bails and yields the same value.
  assert.equal(label.evaluate({ flag: true, name: 5 }, { plainData: true }), 5n);
  assert.equal(
    new Program("m['k'] == 1 ? 'one' : 'other'").evaluate({ m: { k: 1 } }, { plainData: true }),
    "one",
  );
  for (const source of ["flag ? 1 : 'x'", "flag ? true : 'x'"]) {
    assert.equal(new Program(source).hasFastPath, false, source);
  }
  // A dynamic key reads a string; an integer key reads a list; mismatches bail into the engine's answer.
  assert.equal(
    new Program("m[key] == 1").evaluate({ m: { k: 1 }, key: "k" }, { plainData: true }),
    true,
  );
  assert.equal(new Program("xs[0] == 'a'").evaluate({ xs: ["a"] }, { plainData: true }), true);
  assert.equal(new Program("m[0] == 1").evaluate({ m: [1] }, { plainData: true }), true);
  assert.throws(
    () => new Program("m[0] == 1").evaluate({ m: { "0": 1 } }, { plainData: true }),
    /NoSuchKey/,
  );
});

test("plain-data mode compiles ordering arithmetic size membership and list comprehensions", () => {
  const program = new Program(
    "items.size() > 0 && items.size() <= 3 && items.all(i, i.qty > 0 && i.qty <= stock[i.sku] && i.price * i.qty <= 1000) && tags[0] != '' && codes.all(c, c in ['A', 'B']) && name.size() >= 3",
  );
  assert.equal(program.hasFastPath, true);
  const good = {
    items: [
      { sku: "x", qty: 2, price: 10 },
      { sku: "y", qty: 1, price: 999 },
    ],
    stock: { x: 5, y: 1 },
    tags: ["t"],
    codes: ["A"],
    name: "Bob",
  };
  assert.equal(program.evaluate(good, { plainData: true }), true);
  assert.equal(program.evaluate({ ...good, codes: ["Z"] }, { plainData: true }), false);
  assert.equal(
    program.evaluate({ ...good, items: [{ sku: "x", qty: 9, price: 10 }] }, { plainData: true }),
    false,
  );
  assert.equal(program.evaluate({ ...good, name: "Bo" }, { plainData: true }), false);
  assert.equal(
    program.evaluate({ ...good, name: "\u{1F600}\u{1F600}\u{1F600}" }, { plainData: true }),
    true,
  );
  assert.equal(program.evaluate({ ...good, items: [] }, { plainData: true }), false);
  // Every surprise must reach the engine's answer: a stock key that is missing is NoSuchKey there.
  assert.throws(() => program.evaluate({ ...good, stock: {} }, { plainData: true }), /NoSuchKey/);
  assert.throws(
    () => program.evaluate({ ...good, tags: [] }, { plainData: true }),
    /IndexOutOfBounds/,
  );
  assert.equal(
    program.evaluate({ ...good, items: [{ sku: "x", qty: 2n, price: 10 }] }, { plainData: true }),
    true,
  );
  assert.equal(
    program.evaluate(
      {
        ...good,
        stock: new Map([
          ["x", 5],
          ["y", 1],
        ]),
      },
      { plainData: true },
    ),
    true,
  );
  const overflow = new Program("a * b <= 1");
  assert.throws(
    () => overflow.evaluate({ a: 9007199254740991, b: 9007199254740991 }, { plainData: true }),
    /Overflow/,
  );
  assert.equal(overflow.evaluate({ a: 3037000499, b: 3037000499 }, { plainData: true }), false);
  assert.equal(
    new Program("a - b == -1 && a + b == 3 && b / a == 2 && b % a == 0").evaluate(
      { a: 1, b: 2 },
      { plainData: true },
    ),
    true,
  );
  assert.throws(
    () => new Program("a / b == 1").evaluate({ a: 1, b: 0 }, { plainData: true }),
    /DivisionByZero/,
  );
  assert.equal(
    new Program("-a == -3 && a < b && a >= 3").evaluate({ a: 3, b: 4 }, { plainData: true }),
    true,
  );
  assert.equal(
    new Program("xs.exists(x, x == 'b')").evaluate({ xs: ["a", "b"] }, { plainData: true }),
    true,
  );
  assert.equal(
    new Program("xs.exists(x, x == 'z')").evaluate({ xs: ["a", "b"] }, { plainData: true }),
    false,
  );
  // Comprehension variables shadow bindings, and a list containing a non-matching element type bails
  // into the engine's error.
  assert.equal(
    new Program("xs.all(x, x > 0)").evaluate({ xs: [1, 2], x: -1 }, { plainData: true }),
    true,
  );
  assert.throws(
    () => new Program("xs.all(x, x > 0)").evaluate({ xs: [1, "two"] }, { plainData: true }),
    /NoMatchingOverload/,
  );
  for (const source of [
    "xs.exists_one(x, x > 0)",
    "xs.map(x, x)",
    "a < 'b'",
    "a < 1.5",
    "xs.all(x, y, x > 0)",
  ]) {
    const outside = new Program(source);
    assert.equal(outside.hasFastPath, false, source);
  }
  // Comprehensions over a map compile but bail at run time, because the list guard rejects the object.
  assert.equal(
    new Program("m.all(k, k == 'a')").evaluate({ m: { a: 1 } }, { plainData: true }),
    true,
  );
});

test("hand-built plans place every new node kind in an impossible position and are refused", () => {
  const unknown = ["nonsense", ["ident", "a"]];
  const refused: unknown[] = [
    // index: key of an unusable kind, non-string/int key, refused target or key on each branch
    ["index", ["ident", "m"], unknown],
    ["index", ["ident", "m"], ["bool", true]],
    ["index", unknown, ["string", "k"]],
    ["index", ["ident", "m"], ["contains", unknown, ["string", "x"]]],
    ["index", unknown, ["int", 0]],
    ["index", ["ident", "xs"], ["+", unknown, ["int", 1]]],
    // comparisons, ordering, arithmetic, negation in the wrong position or with refused operands
    ["==", ["string", "x"], ["&&", ["ident", "a"], ["ident", "b"]]],
    ["==", ["ident", "a"], ["list", "x"]],
    ["==", ["string", "x"], ["<", ["ident", "a"], ["ident", "b"]]],
    ["<", unknown, ["int", 1]],
    ["<", ["int", 1], unknown],
    ["==", ["string", "x"], ["+", ["ident", "a"], ["ident", "b"]]],
    ["+", unknown, ["int", 1]],
    ["+", ["int", 1], unknown],
    ["==", ["string", "x"], ["neg", ["ident", "a"]]],
    ["neg", unknown],
    // membership, comprehensions, size
    ["==", ["string", "x"], ["in", ["ident", "a"], ["list", "x"]]],
    ["in", ["ident", "a"], ["ident", "b"]],
    ["in", unknown, ["list", "x"]],
    ["==", ["string", "x"], ["all", ["ident", "xs"], "x", ["bool", true]]],
    ["all", unknown, "x", ["bool", true]],
    ["all", ["ident", "xs"], "x", unknown],
    ["==", ["string", "x"], ["size", ["ident", "a"]]],
    ["==", ["int", 1], ["size", ["int", 1]]],
    ["==", ["int", 1], ["size", unknown]],
    ["==", ["int", 1], ["size", ["size", ["ident", "a"]]]],
  ];
  for (const plan of refused) {
    assert.equal(compilePlainDataPlan(JSON.stringify(plan)), undefined, JSON.stringify(plan));
  }
  const size = compilePlainDataPlan(
    JSON.stringify(["==", ["int", 3], ["size", ["string", "abc"]]]),
  );
  assert.ok(size);
  assert.equal(size({}), true);
  const rem = compilePlainDataPlan(
    JSON.stringify(["==", ["%", ["ident", "a"], ["ident", "b"]], ["int", 1]]),
  );
  assert.ok(rem);
  assert.equal(rem({ a: 7, b: 3 }), true);
  const inEmpty = compilePlainDataPlan(JSON.stringify(["in", ["ident", "a"], ["list"]]));
  assert.ok(inEmpty);
  assert.equal(inEmpty({ a: "x" }), false);
  const neg = compilePlainDataPlan(JSON.stringify(["==", ["neg", ["ident", "a"]], ["int", -1]]));
  assert.ok(neg);
  assert.equal(neg({ a: 1 }), true);
  // Operands that infer a type but then refuse in that type's position.
  const bad = ["&&", ["string", "x"], ["ident", "b"]];
  for (const plan of [
    ["==", ["string", "s"], ["index", ["ident", "m"], ["contains", ["ident", "a"], ["int", 1]]]],
    ["==", ["string", "s"], ["index", ["ident", "m"], ["+", ["string", "x"], ["int", 1]]]],
    ["==", ["string", "s"], ["index", ["<", ["ident", "a"], ["int", 1]], ["int", 0]]],
    ["==", ["string", "s"], ["index", ["<", ["ident", "a"], ["int", 1]], ["string", "k"]]],
    ["==", ["int", 1], ["+", ["+", ["string", "x"], ["int", 1]], ["int", 1]]],
    ["==", ["int", 1], ["neg", ["+", ["string", "x"], ["int", 1]]]],
    ["==", ["int", 3], ["size", ["?:", bad, ["string", "a"], ["int", 1]]]],
  ]) {
    assert.equal(compilePlainDataPlan(JSON.stringify(plan)), undefined, JSON.stringify(plan));
  }
  const sizeLiteralBranch = compilePlainDataPlan(
    JSON.stringify([
      "==",
      ["int", 1],
      ["size", ["?:", ["ident", "f"], ["string", "a"], ["string", "bc"]]],
    ]),
  );
  assert.ok(sizeLiteralBranch);
  assert.equal(sizeLiteralBranch({ f: true }), true);
  assert.equal(new Program("a % b == 1").evaluate({ a: 7, b: 3 }, { plainData: true }), true);
  assert.throws(
    () => new Program("a % b == 1").evaluate({ a: 7, b: 0 }, { plainData: true }),
    /DivisionByZero/,
  );
  assert.throws(
    () => new Program("s.size() == 1").evaluate({ s: "\ud800" }, { plainData: true }),
    TypeError,
  );
  assert.equal(new Program("s.size() == 1").evaluate({ s: { k: 1 } }, { plainData: true }), true);
  const sizeRead = compilePlainDataPlan(
    JSON.stringify(["==", ["size", ["ident", "a"]], ["int", 2]]),
  );
  assert.ok(sizeRead);
  assert.equal(sizeRead({ a: "\u{1F600}\u{1F600}" }), true);
  assert.equal(sizeRead({ a: [1, 2] }), true);
});
