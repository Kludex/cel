from __future__ import annotations

import base64
import random

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Program


def test_base64_functions_preserve_binary_values_and_static_types() -> None:
    environment = Environment(variables={"data": CELType("bytes")})
    program = environment.compile("base64.decode(base64.encode(data))")
    assert program.result_type == CELType("bytes")
    for data in (b"", b"hello", b"\x00\xff\xfe\x80"):
        assert program.evaluate({"data": data}) == data
        assert Program("base64.encode(data)").evaluate({"data": data}) == base64.b64encode(data).decode("ascii")
    assert Program("base64.decode('aGVsbG8')").evaluate({}) == b"hello"
    assert Program("base64.decode('aG\\r\\nVsbG8=')").evaluate({}) == b"hello"
    assert Program("base64.encodeUrl(b'\\xff\\xff\\xff')").evaluate({}) == "____"
    assert Program("base64.decodeUrl('____')").evaluate({}) == b"\xff\xff\xff"


def test_base64_rejects_malformed_input_and_preserves_go_padding_compatibility() -> None:
    for text in ("a", "a===", "aGV sbG8=", "aGV\tsbG8=", "aGVsbG8===", "a=GVsbG8", "____"):
        with pytest.raises(EvaluationError):
            Program("base64.decode(text)").evaluate({"text": text})
    for text in ("Zh==", "Zh"):
        assert Program("base64.decode(text)").evaluate({"text": text}) == b"f"
    assert Program("base64.decode('Zm9=')").evaluate({}) == b"fo"
    for source in ("base64.encode('text')", "base64.decode(b'text')"):
        with pytest.raises(CompileError):
            Environment().compile(source)
    assert Environment(container="base64.child").compile("encode(b'x')").evaluate({}) == "eA=="
    assert Environment(variables={"base64": CELType("bool")}).compile(".base64.encode(b'x')").evaluate({}) == "eA=="


def test_base64_matches_independent_python_codec_for_generated_binary_payloads() -> None:
    random_values = random.Random(1729)
    encode = Program("base64.encode(data)")
    decode = Program("base64.decode(text)")
    for size in range(128):
        data = random_values.randbytes(size)
        expected = base64.b64encode(data).decode("ascii")
        assert encode.evaluate({"data": data}) == expected
        assert decode.evaluate({"text": expected}) == data
        assert decode.evaluate({"text": expected.rstrip("=")}) == data
