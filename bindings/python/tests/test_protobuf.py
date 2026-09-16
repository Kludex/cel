from __future__ import annotations

import gc
from pathlib import Path
from typing import cast

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Message, Program

DESCRIPTORS = (Path(__file__).resolve().parents[3] / "conformance/protobuf/test-schema-descriptor.pb").read_bytes()


def test_message_construction_presence_and_wire_round_trip() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.conformance.fixture")
    program = environment.compile("TestSchema{signed_value:12, values:[1,2], counts:{'x':3}, optional_value:''}")
    message = program({})
    assert isinstance(message, Message)
    assert program.result_type == CELType("cel.conformance.fixture.TestSchema")
    del program
    gc.collect()
    reader = Environment(descriptors=DESCRIPTORS, variables={"m": CELType(message.type_name)}).compile(
        "m.signed_value == 12 && m.values == [1,2] && m.counts['x'] == 3 && has(m.optional_value) && !has(m.name)"
    )
    assert reader({"m": message}) is True
    assert environment.compile("TestSchema{}.nested.value")({}) == ""
    assert Program("google.protobuf.DescriptorProto{name:'Entry'}")({}) == Message(
        "google.protobuf.DescriptorProto", b"\x0a\x05Entry"
    )


def test_message_types_are_not_maps_and_failures_are_reported() -> None:
    assert Program("google.protobuf.DescriptorProto{} != {}")({}) is True
    with pytest.raises(CompileError, match="InvalidDescriptor"):
        Environment(descriptors=b"invalid")
    environment = Environment(descriptors=DESCRIPTORS)
    with pytest.raises(EvaluationError, match="InvalidArgument"):
        environment.compile("m.signed_value", check=False)(
            {"m": Message("cel.conformance.fixture.TestSchema", b"\x80")}
        )
    with pytest.raises(CompileError):
        environment.compile("cel.conformance.fixture.TestSchema{signed_value:'bad'}")
    with pytest.raises(TypeError):
        Message("")
    with pytest.raises(TypeError):
        Message("type.Name", cast(bytes, "bad"))


def test_program_retains_descriptors_after_environment_collection() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.conformance.fixture")
    program = environment.compile("TestSchema{nested:TestSchema.Nested{value:'kept'}}.nested")
    del environment
    gc.collect()
    assert program({}) == Message("cel.conformance.fixture.TestSchema.Nested", b"\x0a\x04kept")
