import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { CELType, CompileError, Environment, Program } from "../index.js";

test("strings and keys preserve code points across inline and allocated conversion", () => {
  const program = new Program("x");
  for (const length of [0, 1, 30, 31, 32, 61, 62, 63, 64, 65, 127, 128, 255]) {
    for (const suffix of ["", "\u0000", "é", "世界", "😃", "\uFFFD"]) {
      const value = "a".repeat(length) + suffix;
      assert.equal(program.evaluate({ x: value }), value);
      assert.deepEqual(program.evaluate({ x: { [value]: value } }), { [value]: value });
      assert.equal(new Program(JSON.stringify(value)).evaluate({}), value);
    }
  }
  const values = Array.from({ length: 100 }, (_, index) => `${index}😃`);
  assert.deepEqual(program.evaluate({ x: values }), values);
});

test("lone surrogates are rejected rather than replaced in source and activations", () => {
  const program = new Program("true");
  for (const prefix of ["", "a".repeat(62), "a".repeat(63), "a".repeat(1000)]) {
    for (const suffix of ["\uD800", "\uDC00", "\uD800a", "\uD800\uD800", "\uDC00\uD800"]) {
      const value = prefix + suffix;
      assert.throws(() => program.evaluate({ unused: value }), TypeError);
      assert.throws(() => program.evaluate({ [value]: true }), TypeError);
      assert.throws(() => program.evaluate({ unused: { [value]: true } }), TypeError);
      assert.throws(() => new Program(`'${value}'`), TypeError);
      assert.throws(() => new Environment({ constants: { unused: value } }), TypeError);
      assert.throws(() => new Environment({ container: value }), TypeError);
      assert.throws(
        () => new Environment({ variables: { [value]: new CELType("string") } }),
        TypeError,
      );
    }
  }
  assert.throws(() => new Program("'\\ud800'"), CompileError);
});

test("UTF-8 byte budgets stay exact for ASCII, multibyte, and supplementary characters", () => {
  const program = new Program("x");
  const bytes = 1_048_575;
  for (const character of ["a", "é", "世", "😃"]) {
    const width = Buffer.byteLength(character);
    const value = character.repeat(Math.floor(bytes / width)) + "a".repeat(bytes % width);
    assert.equal(program.evaluate({ x: value }), value);
    assert.throws(() => program.evaluate({ x: value + "a" }), RangeError);
  }
  assert.throws(
    () => new Program(JSON.stringify("世".repeat(349_526))),
    (error: unknown) => error instanceof CompileError && error.code === "SourceLimitExceeded",
  );
});

test("public string conversion agrees with lossless Node Unicode round trips", () => {
  const program = new Program("x");
  for (let index = 0; index < 512; index += 1) {
    const value = createHash("sha256").update(String(index)).digest().toString("utf16le");
    if (Buffer.from(value, "utf8").toString("utf8") === value) {
      assert.equal(program.evaluate({ x: value }), value);
    } else {
      assert.throws(() => program.evaluate({ x: value }), TypeError);
    }
  }
});
