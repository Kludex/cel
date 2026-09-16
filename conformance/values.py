from __future__ import annotations

import base64
import math
from typing import Any

from cel import (
    CIDR,
    CELMap,
    CELType,
    Duration,
    EnumValue,
    IPAddress,
    Message,
    OptionalValue,
    Timestamp,
    UInt,
)
from messages import decode_message, encode_message, encode_temporal, messages_equal
from typing_extensions import TypeAlias

ProtoValue: TypeAlias = dict[str, Any]


class UnsupportedValueError(ValueError):
    """The host language cannot represent this CEL input without losing information."""


def decode_value(value: ProtoValue) -> Any:
    if "nullValue" in value:
        return None
    if "boolValue" in value:
        return value["boolValue"]
    if "int64Value" in value:
        return int(value["int64Value"])
    if "uint64Value" in value:
        return UInt(int(value["uint64Value"]))
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "stringValue" in value:
        return value["stringValue"]
    if "bytesValue" in value:
        return base64.b64decode(value["bytesValue"], validate=True)
    if "ipValue" in value:
        return IPAddress(value["ipValue"])
    if "cidrValue" in value:
        return CIDR(value["cidrValue"])
    if "optionalValue" in value:
        optional = value["optionalValue"]
        if not isinstance(optional, dict) or optional.keys() - {"value"}:
            raise ValueError("invalid optionalValue shape")
        return OptionalValue.of(decode_value(optional["value"])) if "value" in optional else OptionalValue.none()
    if "enumValue" in value:
        return EnumValue(value["enumValue"]["type"], value["enumValue"].get("value", 0))
    if "typeValue" in value:
        return CELType(value["typeValue"])
    if "objectValue" in value:
        return decode_message(value["objectValue"])
    if "listValue" in value:
        return [decode_value(item) for item in value["listValue"].get("values", [])]
    if "mapValue" in value:
        return CELMap(
            tuple(
                (decode_value(entry["key"]), decode_value(entry["value"]))
                for entry in value["mapValue"].get("entries", [])
            )
        )
    raise UnsupportedValueError(f"Unsupported CEL input: {sorted(value)}")


def encode_value(value: Any) -> ProtoValue:
    if value is None:
        return {"nullValue": None}
    if type(value) is bool:
        return {"boolValue": value}
    if type(value) is int:
        return {"int64Value": str(value)}
    if isinstance(value, UInt):
        return {"uint64Value": str(value.value)}
    if isinstance(value, IPAddress):
        return {"ipValue": value.value}
    if isinstance(value, CIDR):
        return {"cidrValue": value.value}
    if isinstance(value, OptionalValue):
        return {"optionalValue": {"value": encode_value(value.value)} if value.has_value else {}}
    if isinstance(value, EnumValue):
        return {"enumValue": {"type": value.type_name, "value": value.number}}
    if isinstance(value, CELType):
        return {"typeValue": value.name}
    if isinstance(value, (Timestamp, Duration)):
        return {"objectValue": encode_temporal(value)}
    if isinstance(value, Message):
        return {"objectValue": encode_message(value)}
    if type(value) is float:
        encoded: float | str = value
        if math.isnan(value):
            encoded = "NaN"
        elif value == math.inf:
            encoded = "Infinity"
        elif value == -math.inf:
            encoded = "-Infinity"
        return {"doubleValue": encoded}
    if type(value) is str:
        return {"stringValue": value}
    if type(value) is bytes:
        return {"bytesValue": base64.b64encode(value).decode()}
    if type(value) is list:
        return {"listValue": {"values": [encode_value(item) for item in value]}}
    if isinstance(value, CELMap):
        return {
            "mapValue": {
                "entries": [{"key": encode_value(key), "value": encode_value(item)} for key, item in value.entries]
            }
        }
    if type(value) is dict:
        return {
            "mapValue": {
                "entries": [{"key": encode_value(key), "value": encode_value(item)} for key, item in value.items()]
            }
        }
    raise TypeError(f"Unexpected SDK result type: {type(value).__name__}")


def values_equal(actual: ProtoValue, expected: ProtoValue) -> bool:
    if actual.keys() != expected.keys() or len(expected) != 1:
        return False
    kind = next(iter(expected))
    left, right = actual[kind], expected[kind]
    if kind == "optionalValue":
        return ("value" in left) == ("value" in right) and (
            "value" not in left or values_equal(left["value"], right["value"])
        )
    if kind == "enumValue":
        return bool(left["type"] == right["type"] and left.get("value", 0) == right.get("value", 0))
    if kind == "objectValue":
        return messages_equal(left, right)
    if kind == "nullValue":
        return True
    if kind == "doubleValue":
        x, y = float(left), float(right)
        return x == y or (math.isnan(x) and math.isnan(y))
    if kind in ("int64Value", "uint64Value"):
        return int(left) == int(right)
    if kind == "listValue":
        xs, ys = left.get("values", []), right.get("values", [])
        return len(xs) == len(ys) and all(values_equal(x, y) for x, y in zip(xs, ys))
    if kind == "mapValue":
        unmatched = list(left.get("entries", []))
        entries = right.get("entries", [])
        if len(unmatched) != len(entries):
            return False
        for entry in entries:
            for index, candidate in enumerate(unmatched):
                if values_equal(candidate["key"], entry["key"]) and values_equal(candidate["value"], entry["value"]):
                    unmatched.pop(index)
                    break
            else:
                return False
        return True
    return type(left) is type(right) and bool(left == right)
