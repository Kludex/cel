from __future__ import annotations

from typing import Any

from cel import CELType

PRIMITIVES = {
    "BOOL": "bool",
    "INT64": "int",
    "UINT64": "uint",
    "DOUBLE": "double",
    "STRING": "string",
    "BYTES": "bytes",
}


def decode_type(source: dict[str, Any]) -> CELType:
    if "typeParam" in source:
        return CELType.parameter(source["typeParam"])
    if "abstractType" in source:
        value = source["abstractType"]
        return CELType.abstract(value["name"], tuple(decode_type(item) for item in value.get("parameterTypes", [])))
    if "primitive" in source:
        return CELType(PRIMITIVES[source["primitive"]])
    if "wrapper" in source:
        return CELType("wrapper", (CELType(PRIMITIVES[source["wrapper"]]),))
    if "wellKnown" in source:
        if source["wellKnown"] == "TIMESTAMP":
            return CELType("google.protobuf.Timestamp")
        if source["wellKnown"] == "DURATION":
            return CELType("google.protobuf.Duration")
        if source["wellKnown"] == "ANY":
            return CELType("dyn")
        if source["wellKnown"] == "LIST_VALUE":
            return CELType("list", (CELType("dyn"),))
        if source["wellKnown"] == "STRUCT":
            return CELType("map", (CELType("string"), CELType("dyn")))
    if "dyn" in source:
        return CELType("dyn")
    if "null" in source:
        return CELType("null_type")
    if "listType" in source:
        return CELType("list", (decode_type(source["listType"]["elemType"]),))
    if "mapType" in source:
        return CELType("map", (decode_type(source["mapType"]["keyType"]), decode_type(source["mapType"]["valueType"])))
    if "type" in source:
        return CELType("type", (decode_type(source["type"]),) if source["type"] else ())
    if "messageType" in source:
        return CELType(source["messageType"])
    raise ValueError(f"Unsupported static type: {source}")


def encode_type(value: CELType) -> dict[str, Any]:
    if value.kind == "parameter":
        return {"typeParam": value.name}
    if value.kind == "abstract":
        return {"abstractType": {"name": value.name, "parameterTypes": [encode_type(t) for t in value.parameters]}}
    primitives = {value: key for key, value in PRIMITIVES.items()}
    if value.name in primitives:
        return {"primitive": primitives[value.name]}
    if value.name == "wrapper":
        return {"wrapper": primitives[value.parameters[0].name]}
    if value.name == "google.protobuf.Timestamp":
        return {"wellKnown": "TIMESTAMP"}
    if value.name == "google.protobuf.Duration":
        return {"wellKnown": "DURATION"}
    if value.name == "dyn":
        return {"dyn": {}}
    if value.name == "null_type":
        return {"null": None}
    if value.name == "list":
        return {"listType": {"elemType": encode_type(value.parameters[0])}}
    if value.name == "map":
        return {"mapType": {"keyType": encode_type(value.parameters[0]), "valueType": encode_type(value.parameters[1])}}
    if value.name == "type":
        return {"type": encode_type(value.parameters[0]) if value.parameters else {}}
    return {"messageType": value.name}


def unsupported_type(source: dict[str, Any]) -> str | None:
    if "wellKnown" in source:
        return None
    if "abstractType" in source:
        for parameter in source["abstractType"].get("parameterTypes", []):
            reason = unsupported_type(parameter)
            if reason:
                return reason
    for key in ("listType", "mapType"):
        for parameter in source.get(key, {}).values():
            reason = unsupported_type(parameter)
            if reason:
                return reason
    if "type" in source:
        return unsupported_type(source["type"])
    return None
