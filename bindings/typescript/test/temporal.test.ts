import assert from "node:assert/strict";
import test from "node:test";

import { CELType, Duration, Environment, EvaluateError, Program, Timestamp } from "../index.js";

test("temporal values preserve nanoseconds and static types", () => {
  const program = new Environment({
    variables: {
      start: new CELType("google.protobuf.Timestamp"),
      delay: new CELType("google.protobuf.Duration"),
    },
  }).compile("start + delay");
  const start = new Timestamp(1234567890n, 123456789);
  const delay = new Duration(999999999n);
  assert.deepEqual(program.resultType, new CELType("google.protobuf.Timestamp"));
  assert.deepEqual(program.evaluate({ start, delay }), new Timestamp(1234567891n, 123456788));
  assert.deepEqual(
    new Program("duration('-9223372036854775808ns')").evaluate({}),
    new Duration(-(2n ** 63n)),
  );
  assert.deepEqual(new Program("timestamp(0)").evaluate({}), new Timestamp(0n));
  assert.equal(new Program("duration('1.234s').getMilliseconds()").evaluate({}), 234n);
  assert.deepEqual(
    new Program("google.protobuf.Duration{seconds:-1,nanos:-2}").evaluate({}),
    new Duration(-1000000002n),
  );
});

test("temporal ranges and timezone inputs reject invalid data", () => {
  assert.throws(() => new Timestamp(-62135596801n), RangeError);
  assert.throws(() => new Timestamp(253402300800n), RangeError);
  assert.throws(() => new Timestamp(0n, -1), RangeError);
  assert.throws(() => new Timestamp(0n, 1000000000), RangeError);
  assert.throws(() => new Timestamp(0n, 0.5), RangeError);
  assert.throws(() => new Timestamp(0 as never), TypeError);
  assert.throws(() => new Duration(1 as never), TypeError);
  assert.throws(() => new Duration(2n ** 63n), RangeError);
  assert.throws(() => new Duration(-(2n ** 63n) - 1n), RangeError);
  assert.throws(
    () => new Program("timestamp(0).getHours('../etc/passwd')").evaluate({}),
    EvaluateError,
  );
});
