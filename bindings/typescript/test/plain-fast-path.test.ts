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
  // Only the authorization policy is inside the subset today; the others use macros, arithmetic,
  // conditionals, or extension functions.
  assert.equal(fast, 1);
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
    "a.b < 3",
    "has(a.b)",
    "a.`b-c` == 1",
    "size(a) == 1",
    "a == 1.5",
    "a.?b.orValue(1) == 1",
  ]) {
    const program = new Program(source);
    assert.equal(program.hasFastPath, false, source);
  }
  assert.equal(new Program("a.b < 3").evaluate({ a: { b: 2 } }, { plainData: true }), true);
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
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify(["==", ["&&", ["ident", "a"], ["ident", "b"]], ["ident", "c"]]),
    ),
    undefined,
  );
  assert.equal(compilePlainDataPlan(JSON.stringify(["string", "x"])), undefined);
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
  assert.equal(
    compilePlainDataPlan(
      JSON.stringify(["==", ["ident", "a"], ["&&", ["ident", "b"], ["ident", "c"]]]),
    ),
    undefined,
  );
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
