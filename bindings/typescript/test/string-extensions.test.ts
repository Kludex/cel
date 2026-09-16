import assert from "node:assert/strict";
import test from "node:test";

import { CELType, CompileError, Environment, EvaluateError, Program } from "../index.js";

test("complete text policies normalize names labels and formatted revisions", () => {
  const source =
    "request.name.trim().lowerAscii().replace(' ', '-').matches('^[a-z-]+$') && request.labels.split(',').map(x, x.trim().upperAscii()).join('|') == 'ADMIN|READ' && '%s:%d'.format([request.name.trim(), request.revision]) == 'Alice Smith:3'";
  const environment = new Environment({ variables: { request: new CELType("dyn") } });
  for (const program of [new Program(source), environment.compile(source)]) {
    assert.equal(
      program.evaluate({
        request: { name: "  Alice Smith  ", labels: "admin, read", revision: 3 },
      }),
      true,
    );
    assert.equal(
      program.evaluate({ request: { name: "Alice!", labels: "admin, read", revision: 3 } }),
      false,
    );
  }
});

test("Unicode string operations index code points rather than UTF-16 units", () => {
  assert.equal(new Program("text.charAt(1)").evaluate({ text: "A😀e\u0301Z" }), "😀");
  assert.equal(
    new Program("text.substring(1,4).reverse()").evaluate({ text: "A😀e\u0301Z" }),
    "\u0301e😀",
  );
  assert.equal(new Program("'A😀Z'.charAt(3)").evaluate({}), "");
  assert.equal(new Program("'A😀Z'.indexOf('😀')").evaluate({}), 1n);
  assert.equal(new Program("'😀a😀b'.lastIndexOf('😀', 1)").evaluate({}), 0n);
  assert.equal(new Program("'😀ab'.replace('', '-', 3)").evaluate({}), "-😀-a-b");
  assert.deepEqual(new Program("'😀ab'.split('', 2)").evaluate({}), ["😀", "ab"]);
  assert.deepEqual(new Program("''.split('')").evaluate({}), []);
});

test("quoting formatting and error boundaries preserve CEL values", () => {
  assert.equal(new Program("'%.400f'.format([1.25])").evaluate({}), "1.25" + "0".repeat(398));
  assert.equal(new Program("'%.20f'.format([1.1])").evaluate({}), "1.10000000000000008882");
  assert.equal(
    new Program("'%s'.format([value])").evaluate({
      value: new Uint8Array([255, 255, 65, 192, 175, 66]),
    }),
    "\ufffdA\ufffdB",
  );
  assert.equal(
    new Program("strings.quote(text)").evaluate({ text: '"😀\n\\\x07' }),
    '"\\"😀\\n\\\\\\a"',
  );
  assert.equal(
    new Program("'%.0f|%.3f|%.2e|%X|%b'.format([2.5, 1.25, 10.0, b'az', true])").evaluate({}),
    "2|1.250|1.00e+01|617A|1",
  );
  assert.equal(
    new Program("'%s'.format([{'b': [2, true], 'a': null}])").evaluate({}),
    "{a: null, b: [2, true]}",
  );
  for (const source of [
    "'abc'.charAt(4)",
    "'abc'.substring(2,1)",
    "'abc'.indexOf('a',30)",
    "'abc'.lastIndexOf('a',-1)",
    "'%a'.format([1])",
    "'%d'.format([])",
  ]) {
    assert.throws(() => new Program(source).evaluate({}), EvaluateError);
  }
  for (const source of [
    "'abc'.substring(true)",
    "'abc'.replace('a', 1)",
    "[1].join()",
    "'%s'.format(1)",
  ]) {
    assert.throws(() => new Environment().compile(source), CompileError);
  }
});
