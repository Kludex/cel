from __future__ import annotations

import gc
import ipaddress
import random

import pytest
from cel import CIDR, CELType, Environment, EvaluationError, Function, IPAddress, Program, Value


def test_network_values_are_canonical_lossless_and_reusable() -> None:
    address = IPAddress("2001:0DB8:0:0:0:0:0:1")
    prefix = CIDR("192.168.0.1/24")
    assert address.value == "2001:db8::1"
    assert prefix.value == "192.168.0.1/24"
    assert str(address) == address.value
    assert str(prefix) == prefix.value
    assert Program("value").evaluate({"value": address}) == address
    assert Program("value").evaluate({"value": prefix}) == prefix
    assert Program("ip('192.168.1.1')").evaluate({}) == IPAddress("192.168.1.1")
    assert Program("cidr('192.168.0.1/24').masked()").evaluate({}) == CIDR("192.168.0.0/24")


def test_checked_network_policy_preserves_nominal_types_and_host_bits() -> None:
    environment = Environment(variables={"source": CELType.abstract("net.IP"), "network": CELType.abstract("net.CIDR")})
    program = environment.compile("network.containsIP(source) && source.isGlobalUnicast() && !source.isLoopback()")
    assert program.evaluate({"source": IPAddress("10.0.1.2"), "network": CIDR("10.0.0.17/8")}) is True
    assert program.evaluate({"source": IPAddress("127.0.0.1"), "network": CIDR("0.0.0.0/0")}) is False
    assert environment.compile("source").result_type == CELType.abstract("net.IP")
    assert Program("type(ip('10.0.0.1')) == net.IP && type(cidr('10.0.0.1/8')) == net.CIDR").evaluate({}) is True
    assert Program("cidr('10.0.0.1/8') == cidr('10.0.0.0/8')").evaluate({}) is False
    assert Program("cidr('10.0.0.1/8').containsCIDR('10.2.0.0/16')").evaluate({}) is True


def test_network_parsing_is_strict_and_nonthrowing_predicates_are_explicit() -> None:
    for text in ("01.2.3.4", "1.2.3", "1.2.3.256", "fe80::1%eth0", "[::1]", "::ffff:192.0.2.1", "::ffff:c000:201", ""):
        with pytest.raises(ValueError):
            IPAddress(text)
        assert Program("isIP(text)").evaluate({"text": text}) is False
    for text in ("10.0.0.0/33", "::/129", "::/-1", "::/", "fe80::1%lo/64"):
        with pytest.raises(ValueError):
            CIDR(text)
        assert Program("isCIDR(text)").evaluate({"text": text}) is False
    with pytest.raises(TypeError):
        IPAddress(1)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        CIDR(None)  # type: ignore[arg-type]
    with pytest.raises(EvaluationError):
        Program("ip.isCanonical('invalid')").evaluate({})
    assert Program("ip.isCanonical('2001:DB8::1')").evaluate({}) is False


def test_network_constants_callbacks_and_nested_results_own_their_values() -> None:
    address = IPAddress("10.0.0.1")
    environment = Environment(
        constants={"saved": address},
        functions=(Function("echo", (CELType.abstract("net.IP"),), CELType.abstract("net.IP"), lambda value: value),),
    )
    program = environment.compile("[echo(saved), cidr('10.0.0.1/8')]")
    result = program.evaluate({})
    del program, environment
    gc.collect()
    assert result == [address, CIDR("10.0.0.1/8")]
    malformed = IPAddress("10.0.0.1")
    object.__setattr__(malformed, "value", "not an address")
    with pytest.raises(ValueError):
        Program("value").evaluate({"value": malformed})


def test_network_ipv6_and_ipv4_match_independent_standard_library() -> None:
    randomizer = random.Random(7823)
    program = Program("[string(ip(address)), string(cidr(network).masked()), cidr(network).containsIP(address)]")
    for size in (32, 128):
        for _ in range(150):
            constructor = ipaddress.IPv4Address if size == 32 else ipaddress.IPv6Address
            address = constructor(randomizer.getrandbits(size))
            host = constructor(randomizer.getrandbits(size))
            prefix = randomizer.randrange(size + 1)
            network = f"{host}/{prefix}"
            expected = ipaddress.ip_network(network, strict=False)
            assert program.evaluate({"address": address.exploded, "network": network}) == [
                str(address),
                str(expected),
                address in expected,
            ]


def test_large_network_allowlists_can_be_deduplicated_with_default_work_budget() -> None:
    addresses: list[Value] = [f"10.0.{index // 256}.{index % 256}" for index in range(3_000)]
    source = "addresses.map(address, ip(address)).distinct().size() == addresses.size()"
    assert Program(source).evaluate({"addresses": addresses}) is True
    source = "addresses.map(address, cidr(address + '/24')).distinct().size() == addresses.size()"
    assert Program(source).evaluate({"addresses": addresses}) is True


def test_cidr_containment_matches_independent_python_networks() -> None:
    program = Program("cidr(network).containsIP(ip(address))")
    for prefix in (0, 1, 8, 16, 24, 31, 32):
        network = f"192.168.1.17/{prefix}"
        expected = ipaddress.ip_network(network, strict=False)
        for address in ("0.0.0.0", "192.168.1.16", "192.168.1.17", "192.168.1.18", "192.168.2.1", "255.255.255.255"):
            assert program.evaluate({"network": network, "address": address}) is (
                ipaddress.ip_address(address) in expected
            )
