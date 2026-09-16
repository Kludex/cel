from __future__ import annotations

from typing import cast

import pytest
from cel import Program, Value


def test_small_and_large_evaluations_return_independent_results_after_errors() -> None:
    program = Program("x")
    values: list[Value] = [{"name": f"row-{index}😃", "count": index} for index in range(1000)]
    expected: list[Value] = [{"name": f"row-{index}😃", "count": index} for index in range(1000)]
    small = program({"x": ["kept", {"number": 42}]})
    result = program({"x": values})
    values.clear()
    with pytest.raises(TypeError):
        program({"x": cast(Value, {1.5: "invalid key"})})
    for index in range(20):
        assert program({"x": index}) == index
    assert small == ["kept", {"number": 42}]
    assert result == expected


def test_borrowed_inputs_survive_callbacks_that_drop_and_mutate_bindings() -> None:
    import gc

    from cel import CELType, Environment, Function

    original = "temporary-" + "x" * 5000
    bindings: dict[str, Value] = {"name": original, "payload": bytes(range(256)) * 20}
    expected_payload = bytes(range(256)) * 20

    def clobber(value: str) -> str:
        nonlocal original
        bindings.clear()
        del original
        gc.collect()
        for index in range(64):
            bindings[f"filler{index}"] = "y" * 5000 + str(index)
        return value.upper()

    environment = Environment(
        variables={"name": CELType("string"), "payload": CELType("bytes")},
        functions=(Function("clobber", (CELType("string"),), CELType("string"), clobber),),
    )
    program = environment.compile("[clobber(name), name, payload, string(payload.size())]")
    result = program.evaluate(bindings)
    assert result == ["TEMPORARY-" + "X" * 5000, "temporary-" + "x" * 5000, expected_payload, "5120"]
    assert len(bindings) == 64
    text = "".join(chr(0x1F600 + index) for index in range(300))
    assert Program("value + value").evaluate({"value": text}) == text + text


def test_string_key_lookup_matches_general_equality_charges_and_depth() -> None:
    from cel import EvaluationError

    long_a, long_b = "a" * 500_000, "b" * 500_000
    mixed_first: Value = {long_a: 0, 0: 0}
    mixed_last: Value = {0: 0, long_a: 0}
    assert Program("k in m").evaluate({"k": long_b, "m": mixed_first}) is False
    assert Program("k in m").evaluate({"k": long_b, "m": mixed_last}) is False
    assert Program("m[k]").evaluate({"k": "x", "m": {"x": 1, 0: 2}}) == 1
    assert Program("m[k]").evaluate({"k": 0, "m": {"x": 1, 0: 2}}) == 2
    for key in ("y", 0):
        left: Value = {"x": 0}
        right: Value = {key: 0}
        for _ in range(126):
            left, right = [left], [right]
        with pytest.raises(EvaluationError, match="DepthLimitExceeded"):
            Program("a == b").evaluate({"a": left, "b": right})
