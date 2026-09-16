from __future__ import annotations

from pathlib import Path
from typing import Any, cast

import pytest
from cel import (
    CELType,
    Duration,
    EnumValue,
    Environment,
    EvaluationError,
    Function,
    Message,
    OptionalValue,
    Program,
    Timestamp,
    Value,
)


def test_optional_value_constructors() -> None:
    assert OptionalValue() == OptionalValue.none()
    assert OptionalValue.of(None) == OptionalValue(True, None)
    assert OptionalValue.of(1) == OptionalValue(True, 1)
    with pytest.raises(TypeError, match="bool"):
        OptionalValue(cast(bool, 1))
    with pytest.raises(ValueError, match="absent"):
        OptionalValue(False, 1)


def test_optional_operations_and_static_type() -> None:
    assert Program("optional.none()")({}) == OptionalValue.none()
    assert Program("optional.of(null)")({}) == OptionalValue.of(None)
    assert Program("optional.of(2).value()")({}) == 2
    assert Program("optional.ofNonZeroValue(0)")({}) == OptionalValue.none()
    assert Program("optional.ofNonZeroValue(2)")({}) == OptionalValue.of(2)
    with pytest.raises(EvaluationError, match="NoSuchKey"):
        Program("optional.none().value()")({})

    optional_int = CELType.abstract("optional_type", (CELType("int"),))
    program = Environment(variables={"value": optional_int}).compile("value")
    assert program.result_type == optional_int
    assert program({"value": OptionalValue.of(1)}) == OptionalValue.of(1)
    assert program({"value": OptionalValue.none()}) == OptionalValue.none()


def test_nested_optional_values_and_present_null_round_trip() -> None:
    value = OptionalValue.of(None)
    result = cast(list[Value], Program("[value, {'nested': value}]")({"value": value}))
    assert result == [value, {"nested": value}]
    assert cast(OptionalValue, result[0]).has_value is True


def test_optional_constants_are_owned() -> None:
    payload: list[Value] = [1, OptionalValue.of(2)]
    environment = Environment(constants={"saved": OptionalValue.of(payload)})
    program = environment.compile("saved")
    payload.clear()
    assert program({}) == OptionalValue.of([1, OptionalValue.of(2)])


def test_callbacks_accept_and_return_optional_values() -> None:
    optional_int = CELType.abstract("optional_type", (CELType("int"),))
    seen: list[Value] = []

    def echo(value: Value) -> Value:
        seen.append(value)
        return value

    environment = Environment(functions=(Function("echo", (optional_int,), optional_int, echo),))
    result = environment.compile("echo(optional.of(1))")({})
    assert result == OptionalValue.of(1)
    assert seen == [OptionalValue.of(1)]


def test_native_conversion_validates_optional_metadata() -> None:
    malformed = object.__new__(OptionalValue)
    object.__setattr__(malformed, "has_value", 1)
    object.__setattr__(malformed, "value", None)
    with pytest.raises(TypeError, match="bool"):
        Program("value")({"value": malformed})

    malformed = object.__new__(OptionalValue)
    object.__setattr__(malformed, "has_value", False)
    object.__setattr__(malformed, "value", 1)
    with pytest.raises(ValueError, match="absent"):
        Program("value")({"value": malformed})


def test_optional_conversion_limits_and_cycles() -> None:
    cyclic = OptionalValue.of(None)
    object.__setattr__(cyclic, "value", cyclic)
    with pytest.raises(ValueError, match="depth|cycle"):
        Program("value")({"value": cyclic})

    deep: Value = None
    for _ in range(129):
        deep = OptionalValue.of(deep)
    with pytest.raises(ValueError, match="depth"):
        Program("value")({"value": deep})

    with pytest.raises(ValueError, match="byte limit"):
        Program("value")({"value": OptionalValue.of(b"a" * 1_048_576)})

    values = cast(list[Value], [OptionalValue.none() for _ in range(100_000)])
    with pytest.raises(ValueError, match="collection limit"):
        Program("value")({"value": values})


def test_optional_payload_value_kinds() -> None:
    values: list[Value] = [
        EnumValue("example.Status", 1),
        Timestamp(1, 2),
        Duration(3),
        CELType("int"),
    ]
    for value in values:
        wrapped = OptionalValue.of(value)
        assert Program("value")({"value": wrapped}) == wrapped

    descriptors = (Path(__file__).resolve().parents[3] / "conformance/protobuf/test-schema-descriptor.pb").read_bytes()
    message_type = CELType("cel.conformance.fixture.TestSchema")
    optional_message = CELType.abstract("optional_type", (message_type,))
    program = Environment(descriptors=descriptors, variables={"value": optional_message}).compile("value")
    message = Message(message_type.name, b"\x08*")
    assert program({"value": OptionalValue.of(message)}) == OptionalValue.of(message)


def test_optional_wrapper_rejects_unsupported_payload() -> None:
    with pytest.raises(TypeError, match="unsupported"):
        Program("value")({"value": OptionalValue.of(cast(Any, object()))})
