from __future__ import annotations

import base64
import json
import subprocess
from pathlib import Path
from typing import Any, cast

import pytest

ADAPTER = Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "cel-conformance"


def run_adapter(data: str) -> list[dict[str, Any]]:
    process = subprocess.run([str(ADAPTER)], input=data, capture_output=True, text=True, timeout=30)
    assert process.returncode == 0, process.stderr
    return cast(list[dict[str, Any]], json.loads(process.stdout))


def test_zig_adapter_preserves_scalar_types_messages_and_temporal_results() -> None:
    expressions = [
        ("null", {"nullValue": None}),
        ("true", {"boolValue": True}),
        ("-9223372036854775808", {"int64Value": "-9223372036854775808"}),
        ("18446744073709551615u", {"uint64Value": "18446744073709551615"}),
        ("1.0", {"doubleValue": 1.0}),
        ("0.0 / 0.0", {"doubleValue": "NaN"}),
        ("1.0 / 0.0", {"doubleValue": "Infinity"}),
        ("-1.0 / 0.0", {"doubleValue": "-Infinity"}),
        ("b'\\x00\\xff'", {"bytesValue": "AP8="}),
        ("'owned string'", {"stringValue": "owned string"}),
        ("type(1)", {"typeValue": "int"}),
        ("timestamp('2000-01-01T00:00:00.000000001Z')", {"timestampValue": {"seconds": "946684800", "nanos": 1}}),
        ("duration('-1ns')", {"durationValue": "-1"}),
    ]
    requests = [{"id": str(index), "expr": source, "bindings": {}} for index, (source, _) in enumerate(expressions)]
    outcomes = run_adapter(json.dumps(requests))
    for index, (_, expected) in enumerate(expressions):
        assert outcomes[index] == {"id": str(index), "outcome": "value", "value": expected}

    value = {"messageValue": {"typeName": "google.protobuf.DescriptorProto", "data": "CgFL"}}
    outcome = run_adapter(json.dumps([{"id": "wire", "expr": "v", "bindings": {"v": value}}]))[0]
    assert outcome == {"id": "wire", "outcome": "value", "value": value}


def test_zig_adapter_checks_all_supported_type_descriptions() -> None:
    cases = [
        ({"primitive": "INT64"}, {"int64Value": "1"}, {"primitive": "INT64"}),
        ({"wrapper": "INT64"}, {"int64Value": "1"}, {"wrapper": "INT64"}),
        ({"wellKnown": "ANY"}, {"boolValue": True}, {"dyn": {}}),
        ({"wellKnown": "LIST_VALUE"}, {"listValue": {}}, {"listType": {"elemType": {"dyn": {}}}}),
        (
            {"wellKnown": "STRUCT"},
            {"mapValue": {}},
            {
                "mapType": {"keyType": {"primitive": "STRING"}, "valueType": {"dyn": {}}},
            },
        ),
        ({"wellKnown": "TIMESTAMP"}, {"timestampValue": {"seconds": "0", "nanos": 1}}, {"wellKnown": "TIMESTAMP"}),
        ({"wellKnown": "DURATION"}, {"durationValue": "1"}, {"wellKnown": "DURATION"}),
        ({"type": {"primitive": "INT64"}}, {"typeValue": "int"}, {"type": {"primitive": "INT64"}}),
        ({"type": {}}, {"typeValue": "int"}, {"type": {}}),
        ({"null": None}, {"nullValue": "NULL_VALUE"}, {"null": None}),
    ]
    requests = [
        {"id": str(index), "expr": "v", "check": True, "variables": {"v": declared}, "bindings": {"v": value}}
        for index, (declared, value, _) in enumerate(cases)
    ]
    outcomes = run_adapter(json.dumps(requests))
    for outcome, (_, _, expected) in zip(outcomes, cases, strict=True):
        assert outcome["outcome"] == "value"
        assert outcome["checked_type"] == expected


def test_zig_adapter_keeps_compile_input_and_evaluation_errors_separate() -> None:
    malformed = {
        "mapValue": {
            "entries": [
                {"key": {"int64Value": "1"}, "value": {"boolValue": True}},
                {"key": {"uint64Value": "1"}, "value": {"boolValue": False}},
            ]
        }
    }
    requests = [
        {"id": "parse", "expr": "1 +", "bindings": {"v": malformed}},
        {"id": "input", "expr": "true", "bindings": {"v": malformed}},
        {"id": "evaluate", "expr": "1 / 0", "bindings": {}},
        {"id": "check", "expr": "false && 1", "bindings": {}, "check": True},
        {"id": "only", "expr": "1", "check": True, "checkOnly": True, "bindings": {"v": malformed}},
        {
            "id": "invalid_wire",
            "expr": "v.name",
            "bindings": {
                "v": {
                    "messageValue": {
                        "typeName": "google.protobuf.DescriptorProto",
                        "data": base64.b64encode(b"\x80").decode(),
                    }
                }
            },
        },
    ]
    outcomes = run_adapter(json.dumps(requests))
    assert [outcome["outcome"] for outcome in outcomes] == [
        "compile_error",
        "input_error",
        "eval_error",
        "compile_error",
        "checked",
        "eval_error",
    ]
    assert outcomes[4]["checked_type"] == {"primitive": "INT64"}
    assert outcomes[2]["error"] == "DivisionByZero"


@pytest.mark.parametrize(
    "value",
    [
        {"boolValue": 1},
        {"bytesValue": "!!"},
        {"int64Value": "9223372036854775808"},
        {"uint64Value": "-1"},
        {"enumValue": {"type": "int", "value": 2**31}},
        {"stringValue": "x", "boolValue": True},
        {"listValue": {"unexpected": []}},
        {"typeValue": ""},
        {"enumValue": {"type": ""}},
        {"enumValue": {"type": "bad..Name"}},
        {"messageValue": {"typeName": "", "data": ""}},
        {"mapValue": {"entries": [{"key": {"doubleValue": 1.5}, "value": {"boolValue": True}}]}},
    ],
)
def test_zig_adapter_rejects_malformed_typed_values(value: dict[str, Any]) -> None:
    outcome = run_adapter(json.dumps([{"id": "bad", "expr": "true", "bindings": {"v": value}}]))[0]
    assert outcome["outcome"] == "input_error"


def test_zig_adapter_bounds_values_bytes_and_transport_nesting() -> None:
    value: dict[str, Any] = {"boolValue": True}
    for _ in range(130):
        value = {"listValue": {"values": [value]}}
    inputs = [
        value,
        {"stringValue": "x" * 1_048_576},
        {"listValue": {"values": [{"nullValue": None}] * 100_000}},
    ]
    for value in inputs:
        outcome = run_adapter(json.dumps([{"id": "limited", "expr": "true", "bindings": {"v": value}}]))[0]
        assert outcome["outcome"] == "input_error"
        assert "LimitExceeded" in outcome["error"]
    outcome = run_adapter("[" * 1025 + "]" * 1025)[0]
    assert outcome["outcome"] == "input_error"
    assert outcome["error"] == "JSONDepthLimitExceeded"


def test_zig_adapter_enforces_batch_bytes_requests_and_token_budgets() -> None:
    assert run_adapter("[]" + " " * (32 * 1024 * 1024 - 2)) == []
    assert run_adapter(" " * (32 * 1024 * 1024 + 1))[0]["error"] == "StreamTooLong"
    assert len(run_adapter(json.dumps([None] * 10_000))) == 10_000
    assert run_adapter(json.dumps([None] * 10_001))[0]["outcome"] == "input_error"
    assert run_adapter("[" + ",".join(["[]"] * 1_000_000) + "]")[0]["error"] == "JSONValueLimitExceeded"


@pytest.mark.parametrize("data", ["", "{", "]", "{}", '[{"id":[],"expr":"true"}]', '[{"id":"x","expr":true}]'])
def test_zig_adapter_rejects_bad_request_documents(data: str) -> None:
    assert run_adapter(data)[0]["outcome"] == "input_error"
