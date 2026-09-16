from __future__ import annotations

import gc
import operator
from dataclasses import FrozenInstanceError
from pathlib import Path
from typing import cast

import pytest
from cel import CELType, CompileError, EnumValue, Environment, EvaluationError, MapKey, Message, Value

DESCRIPTORS = (Path(__file__).resolve().parents[3] / "conformance/protobuf/cel-spec-test-descriptors.pb").read_bytes()


@pytest.mark.parametrize("syntax", ["proto2", "proto3"])
def test_strong_enums_preserve_types_conversions_defaults_and_wire_values(syntax: str) -> None:
    container = f"cel.expr.conformance.{syntax}"
    enum_name = f"{container}.GlobalEnum"
    nested_name = f"{container}.TestAllTypes.NestedEnum"
    environment = Environment(descriptors=DESCRIPTORS, container=container, strong_enums=True)

    assert environment.compile("GlobalEnum.GAZ")({}) == EnumValue(enum_name, 2)
    assert environment.compile("GlobalEnum(-33)")({}) == EnumValue(enum_name, -33)
    assert environment.compile("GlobalEnum('GAR')")({}) == EnumValue(enum_name, 1)
    assert environment.compile("int(GlobalEnum.GAZ)")({}) == 2
    assert environment.compile("TestAllTypes{}.standalone_enum")({}) == EnumValue(nested_name, 0)
    if syntax == "proto2":
        assert environment.compile("TestAllTypes{}.single_nested_enum")({}) == EnumValue(nested_name, 1)

    message = environment.compile(
        "TestAllTypes{standalone_enum:TestAllTypes.NestedEnum.BAZ,repeated_nested_enum:[TestAllTypes.NestedEnum.BAR]}"
    )({})
    assert isinstance(message, Message)
    reader = Environment(
        descriptors=DESCRIPTORS,
        variables={"m": CELType(message.type_name)},
        strong_enums=True,
    ).compile("[m.standalone_enum, m.repeated_nested_enum[0]]")
    assert reader({"m": message}) == [EnumValue(nested_name, 2), EnumValue(nested_name, 1)]


def test_legacy_enums_remain_integers_by_default() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.expr.conformance.proto3")
    assert environment.compile("[GlobalEnum.GAZ, TestAllTypes{}.standalone_enum]")({}) == [2, 0]


def test_enum_declarations_constants_and_nested_inputs() -> None:
    type_name = "cel.expr.conformance.proto3.TestAllTypes.NestedEnum"
    value = EnumValue(type_name, 99)
    constants: dict[str, Value] = {"saved": [value, {"value": value}]}
    environment = Environment(
        descriptors=DESCRIPTORS,
        variables={"value": CELType(type_name), "values": CELType("list", (CELType(type_name),))},
        constants=constants,
        strong_enums=True,
    )
    declared = environment.compile("[value]")
    constants.clear()
    program = environment.compile("[value, values[0], saved[0], saved[1].value]")
    del environment
    gc.collect()
    assert program({"value": value, "values": [value]}) == [value, value, value, value]
    assert declared.result_type == CELType("list", (CELType(type_name),))


def test_enum_values_validate_python_and_native_inputs() -> None:
    class Index:
        def __index__(self) -> int:
            return 1

    value = EnumValue("example.Status", cast(int, Index()))
    assert value.number == 1
    with pytest.raises(FrozenInstanceError):
        setattr(value, "number", 2)
    with pytest.raises(TypeError, match="string"):
        EnumValue(cast(str, 1), 1)
    for name in ["", ".example.Status", "example..Status", "example.bad-name", "éxample.Status"]:
        with pytest.raises(ValueError, match="qualified"):
            EnumValue(name, 1)
    for number in [True, 1.0, "1", object()]:
        with pytest.raises(TypeError, match="integer"):
            EnumValue("example.Status", cast(int, number))
    for number in [-(2**31) - 1, 2**31]:
        with pytest.raises(ValueError, match="32-bit"):
            EnumValue("example.Status", number)

    spoofed = object.__new__(EnumValue)
    object.__setattr__(spoofed, "type_name", "bad-name")
    object.__setattr__(spoofed, "number", 1)
    with pytest.raises(ValueError, match="type name"):
        Environment(constants={"value": spoofed})
    object.__setattr__(spoofed, "type_name", "example.Status")
    object.__setattr__(spoofed, "number", True)
    with pytest.raises(TypeError, match="number"):
        Environment(constants={"value": spoofed})

    for name in [".".join("a" for _ in range(129)), "a" * 1_048_576]:
        with pytest.raises(ValueError):
            Environment(constants={"value": EnumValue(name, 1)})

    object.__setattr__(spoofed, "number", Index())
    with pytest.raises(TypeError, match="integer"):
        Environment().compile("x", check=False)({"x": spoofed})

    assert operator.index(value.number) == 1


def test_enum_boundaries_and_overloads_are_rejected() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.expr.conformance.proto3", strong_enums=True)
    for source in ["GlobalEnum(2147483648)", "GlobalEnum(-2147483649)"]:
        with pytest.raises(EvaluationError, match="Overflow"):
            environment.compile(source, check=False)({})
    for source in ["GlobalEnum(true)", "GlobalEnum(1u)", "GlobalEnum(1.0)", "GlobalEnum.GAR + 1"]:
        with pytest.raises(CompileError, match="TypeMismatch"):
            environment.compile(source)
    with pytest.raises(EvaluationError, match="InvalidArgument"):
        environment.compile("GlobalEnum('MISSING')", check=False)({})
    enum_key = cast(dict[MapKey, Value], {EnumValue("example.Status", 1): "bad"})
    with pytest.raises(TypeError, match="map keys"):
        environment.compile("x", check=False)({"x": enum_key})


def test_enum_constants_cannot_claim_non_enum_types() -> None:
    for name in ("int", "google.protobuf.DescriptorProto", "missing.Enum"):
        value = EnumValue(name, 1)
        constants: tuple[Value, ...] = value, [value], {"value": value}
        for constant in constants:
            with pytest.raises(CompileError, match="InvalidDeclaration"):
                Environment(constants={"fake": constant}, strong_enums=True)


def test_strong_enum_flag_is_validated() -> None:
    with pytest.raises(TypeError, match="strong_enums"):
        Environment(strong_enums=cast(bool, 1))
