from __future__ import annotations

from pathlib import Path

import pytest
from cel import CELType, CompileError, Environment, EvaluationError

DESCRIPTORS = (Path(__file__).resolve().parents[3] / "conformance/protobuf/cel-spec-test-descriptors.pb").read_bytes()


def test_proto_helpers_reuse_descriptor_presence_defaults_and_field_types() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.expr.conformance.proto2")
    program = environment.compile(
        "cel.bind(msg, TestAllTypes{`cel.expr.conformance.proto2.int32_ext`: 42}, "
        "proto.hasExt(msg, cel.expr.conformance.proto2.int32_ext) && "
        "proto.getExt(msg, cel.expr.conformance.proto2.int32_ext) == 42 && "
        "!proto.hasExt(msg, cel.expr.conformance.proto2.repeated_test_all_types) && "
        "proto.getExt(msg, cel.expr.conformance.proto2.repeated_test_all_types) == [])"
    )
    assert program.evaluate({}) is True
    assert program.result_type == CELType("bool")
    assert environment.compile(
        "proto.getExt(TestAllTypes{}, cel.expr.conformance.proto2.int32_ext)"
    ).result_type == CELType("int")


def test_proto_helper_extension_names_are_syntax_not_activation_values() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.expr.conformance.proto2")
    program = environment.compile("proto.getExt(TestAllTypes{}, cel.expr.conformance.proto2.int32_ext)")
    assert program.evaluate({"cel.expr.conformance.proto2.int32_ext": "redirect"}) == 0
    assert (
        environment.compile("proto.getExt(TestAllTypes{}, cel.expr.conformance.proto2.`int32_ext`)").evaluate({}) == 0
    )
    with pytest.raises(CompileError):
        environment.compile("proto.getExt(TestAllTypes{}, .cel.expr.conformance.proto2.int32_ext)")
    for expression in ("proto.getExt(TestAllTypes{}, 'name')", "proto.hasExt(TestAllTypes{}, int32_ext)"):
        with pytest.raises(CompileError):
            environment.compile(expression)
    with pytest.raises(CompileError):
        environment.compile("proto.getExt(google.protobuf.Empty{}, cel.expr.conformance.proto2.int32_ext)")
    with pytest.raises(EvaluationError):
        environment.compile(
            "proto.getExt(google.protobuf.Empty{}, cel.expr.conformance.proto2.int32_ext)", check=False
        ).evaluate({})


def test_proto_helpers_preserve_strong_enum_identity_and_explicit_default_presence() -> None:
    environment = Environment(descriptors=DESCRIPTORS, container="cel.expr.conformance.proto2", strong_enums=True)
    assert (
        environment.compile(
            "cel.bind(msg, TestAllTypes{`cel.expr.conformance.proto2.int32_ext`: 0, "
            "`cel.expr.conformance.proto2.nested_enum_ext`: TestAllTypes.NestedEnum.BAR}, "
            "proto.hasExt(msg, cel.expr.conformance.proto2.int32_ext) && "
            "proto.getExt(msg, cel.expr.conformance.proto2.nested_enum_ext) == TestAllTypes.NestedEnum.BAR)"
        ).evaluate({})
        is True
    )


def test_proto_helper_macro_selection_also_works_on_qualified_map_keys() -> None:
    assert Environment().compile("proto.getExt({'a.b': 3}, a.b)").evaluate({}) == 3
    assert Environment().compile("proto.hasExt({'a.b': 3}, a.b)").evaluate({}) is True
    assert Environment().compile("proto.hasExt({}, a.b)").evaluate({}) is False
