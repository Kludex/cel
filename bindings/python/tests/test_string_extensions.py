from __future__ import annotations

import math
import random
import struct

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Program


def test_complete_text_policy_normalizes_request_fields() -> None:
    source = (
        "request.name.trim().lowerAscii().replace(' ', '-').matches('^[a-z-]+$') && "
        "request.labels.split(',').map(x, x.trim().upperAscii()).join('|') == 'ADMIN|READ' && "
        "'%s:%d'.format([request.name.trim(), request.revision]) == 'Alice Smith:3'"
    )
    environment = Environment(variables={"request": CELType("dyn")})
    for program in (Program(source), environment.compile(source)):
        assert (
            program.evaluate({"request": {"name": "  Alice Smith  ", "labels": "admin, read", "revision": 3}}) is True
        )
        assert program.evaluate({"request": {"name": "Alice!", "labels": "admin, read", "revision": 3}}) is False


def test_unicode_operations_use_code_points_and_preserve_empty_boundaries() -> None:
    assert Program("text.charAt(1)").evaluate({"text": "A😀e\u0301Z"}) == "😀"
    assert Program("text.substring(1,4).reverse()").evaluate({"text": "A😀e\u0301Z"}) == "\u0301e😀"
    assert Program("'A😀Z'.charAt(3)").evaluate({}) == ""
    assert Program("'A😀Z'.indexOf('😀')").evaluate({}) == 1
    assert Program("'😀a😀b'.lastIndexOf('😀', 1)").evaluate({}) == 0
    assert Program("'😀ab'.replace('', '-', 3)").evaluate({}) == "-😀-a-b"
    assert Program("'😀ab'.split('', 2)").evaluate({}) == ["😀", "ab"]
    assert Program("''.split('')").evaluate({}) == []
    assert Program("'\u0085\u00a0x\u3000'.trim()").evaluate({}) == "x"
    assert Program("'\u200bx\ufeff'.trim()").evaluate({}) == "\u200bx\ufeff"


def test_formatting_preserves_large_precision_and_sanitizes_invalid_byte_runs() -> None:
    assert Program("'%.400f'.format([1.25])").evaluate({}) == "1.25" + "0" * 398
    assert Program("'%.20f'.format([1.1])").evaluate({}) == format(1.1, ".20f")
    assert Program("'%.2f'.format([2.675])").evaluate({}) == format(2.675, ".2f")
    assert Program("'%s'.format([value])").evaluate({"value": b"\xff\xffA\xc0\xafB"}) == "\ufffdA\ufffdB"
    assert Program("'%s'.format([duration('1.500s')])").evaluate({}) == "1.5s"
    assert Program("'%s'.format([duration('9223372036.854775807s')])").evaluate({}) == "9223372036.854776s"
    assert Program("'%s'.format([duration('2405875930.906139466s')])").evaluate({}) == "2405875930.9061394s"


def test_float_formatting_matches_independent_python_rounding() -> None:
    random_values = random.Random(1729)
    program = Program("template.format([value])")
    values = [float("nan"), float("inf"), float("-inf")]
    values.extend(struct.unpack("!d", random_values.getrandbits(64).to_bytes(8, "big"))[0] for _ in range(200))
    for value in values:
        if not math.isfinite(value):
            expected = "NaN" if math.isnan(value) else "-Infinity" if value < 0 else "Infinity"
            assert program.evaluate({"template": "%f", "value": value}) == expected
            continue
        precision = random_values.randrange(21)
        for conversion in ("f", "e"):
            specifier = f".{precision}{conversion}"
            assert program.evaluate({"template": "%" + specifier, "value": value}) == format(value, specifier)


def test_unicode_search_matches_independent_python_code_point_indexing() -> None:
    random_values = random.Random(42)
    forward = Program("text.indexOf(needle, offset)")
    backward = Program("text.lastIndexOf(needle, offset)")
    for _ in range(200):
        text = "".join(random_values.choice("a😀éab") for _ in range(20))
        needle = "".join(random_values.choice("a😀éab") for _ in range(random_values.randrange(5)))
        offset = random_values.randrange(len(text) + 1)
        assert forward.evaluate({"text": text, "needle": needle, "offset": offset}) == text.find(needle, offset)
        assert backward.evaluate({"text": text, "needle": needle, "offset": offset}) == text.rfind(
            needle, 0, offset + len(needle)
        )


def test_dynamic_formatting_ignores_extra_values_but_evaluates_the_argument_list() -> None:
    program = Program("template.format(values)")
    assert program.evaluate({"template": "%s", "values": ["first", "unused"]}) == "first"
    assert program.evaluate({"template": "plain", "values": [1]}) == "plain"
    with pytest.raises(EvaluationError, match="DivisionByZero"):
        Program("'plain'.format([1/0])").evaluate({})


def test_quoting_formatting_and_invalid_arguments() -> None:
    assert Program("strings.quote(text)").evaluate({"text": '"😀\n\\\a'}) == '"\\"😀\\n\\\\\\a"'
    assert (
        Program("'%.0f|%.3f|%.2e|%X|%b'.format([2.5, 1.25, 10.0, b'az', true])").evaluate({})
        == "2|1.250|1.00e+01|617A|1"
    )
    assert Program("'%s'.format([{'b': [2, true], 'a': null}])").evaluate({}) == "{a: null, b: [2, true]}"
    for source in (
        "'abc'.charAt(4)",
        "'abc'.substring(2,1)",
        "'abc'.indexOf('a',30)",
        "'abc'.lastIndexOf('a',-1)",
        "'%a'.format([1])",
        "'%d'.format([])",
    ):
        with pytest.raises(EvaluationError):
            Program(source).evaluate({})
    for source in ("'abc'.substring(true)", "'abc'.replace('a', 1)", "[1].join()", "'%s'.format(1)"):
        with pytest.raises(CompileError):
            Environment().compile(source)
