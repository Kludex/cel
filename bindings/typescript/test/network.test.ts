import assert from "node:assert/strict";
import test from "node:test";

import {
  CIDR,
  IPAddress,
  CELType,
  Environment,
  EvaluateError,
  FunctionDeclaration,
  Program,
} from "../index.js";

test("network values preserve canonical addresses, host bits and nominal types", () => {
  const ip = new IPAddress("2001:0DB8:0:0:0:0:0:1");
  const cidr = new CIDR("192.168.0.1/24");
  assert.equal(ip.value, "2001:db8::1");
  assert.equal(cidr.value, "192.168.0.1/24");
  assert.equal(ip.toString(), ip.value);
  assert.equal(cidr.toString(), cidr.value);
  const identity = new Program("value");
  assert.deepEqual(identity.evaluate({ value: ip }), ip);
  assert.deepEqual(identity.evaluate({ value: cidr }), cidr);
  assert.deepEqual(
    new Program("cidr('192.168.0.1/24').masked()").evaluate({}),
    new CIDR("192.168.0.0/24"),
  );
  assert.equal(
    new Program("type(ip('10.0.0.1')) == net.IP && type(cidr('10.0.0.1/8')) == net.CIDR").evaluate(
      {},
    ),
    true,
  );
  const environment = new Environment({
    variables: { source: CELType.abstract("net.IP"), network: CELType.abstract("net.CIDR") },
  });
  const policy = environment.compile(
    "network.containsIP(source) && source.isGlobalUnicast() && !source.isLoopback()",
  );
  assert.equal(
    policy.evaluate({ source: new IPAddress("10.0.1.2"), network: new CIDR("10.0.0.17/8") }),
    true,
  );
  assert.equal(
    policy.evaluate({ source: new IPAddress("127.0.0.1"), network: new CIDR("0.0.0.0/0") }),
    false,
  );
  assert.deepEqual(environment.compile("source").resultType, CELType.abstract("net.IP"));
});

test("network parsing rejects zones and all mapped IPv6 representations", () => {
  for (const text of [
    "01.2.3.4",
    "1.2.3",
    "1.2.3.256",
    "fe80::1%eth0",
    "[::1]",
    "::ffff:192.0.2.1",
    "::ffff:c000:201",
    "",
  ]) {
    assert.throws(() => new IPAddress(text), RangeError);
    assert.equal(new Program("isIP(text)").evaluate({ text }), false);
  }
  for (const text of ["10.0.0.0/33", "::/129", "::/-1", "::/", "fe80::1%lo/64"]) {
    assert.throws(() => new CIDR(text), RangeError);
    assert.equal(new Program("isCIDR(text)").evaluate({ text }), false);
  }
  assert.throws(() => new IPAddress(1 as never), TypeError);
  assert.throws(() => new CIDR(null as never), TypeError);
  assert.throws(() => new Program("ip.isCanonical('invalid')").evaluate({}), EvaluateError);
  assert.equal(new Program("ip.isCanonical('2001:DB8::1')").evaluate({}), false);
});

test("network constants callbacks and nested results survive collection", () => {
  const ip = new IPAddress("10.0.0.1");
  const environment = new Environment({
    constants: { saved: ip },
    functions: [
      new FunctionDeclaration(
        "echo",
        [CELType.abstract("net.IP")],
        CELType.abstract("net.IP"),
        (value: IPAddress) => value,
      ),
    ],
  });
  const result = environment.compile("[echo(saved), cidr('10.0.0.1/8')]").evaluate({});
  global.gc?.();
  assert.deepEqual(result, [ip, new CIDR("10.0.0.1/8")]);
  const malformed = Object.create(IPAddress.prototype) as IPAddress;
  Object.defineProperty(malformed, "value", { value: "not an address" });
  assert.throws(() => new Program("value").evaluate({ value: malformed }), RangeError);
});
