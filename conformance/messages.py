from __future__ import annotations

import base64
from pathlib import Path
from typing import Any

from cel import Duration, Message, Timestamp
from google.protobuf import descriptor_pb2, descriptor_pool, duration_pb2, json_format, message_factory, timestamp_pb2

DESCRIPTORS = (Path(__file__).with_name("protobuf") / "cel-spec-test-descriptors.pb").read_bytes()
POOL = descriptor_pool.DescriptorPool()
FILES = descriptor_pb2.FileDescriptorSet.FromString(DESCRIPTORS)
PENDING = {file.name: file for file in FILES.file}
while PENDING:
    ready = [file for file in PENDING.values() if all(dependency not in PENDING for dependency in file.dependency)]
    if not ready:
        raise RuntimeError("Descriptor fixture dependencies are cyclic")
    for file in ready:
        POOL.AddSerializedFile(file.SerializeToString())
        del PENDING[file.name]


def decode_message(value: dict[str, Any]) -> Message:
    type_url = value["@type"]
    type_name = type_url.rsplit("/", 1)[-1]
    cls = message_factory.GetMessageClass(POOL.FindMessageTypeByName(type_name))
    instance = cls()
    fields = {key: item for key, item in value.items() if key != "@type"}
    special = type_name.startswith("google.protobuf.") and type_name.rsplit(".", 1)[-1] in {
        "Any",
        "Duration",
        "Timestamp",
        "FieldMask",
        "Value",
        "ListValue",
        "Struct",
        "BoolValue",
        "BytesValue",
        "DoubleValue",
        "FloatValue",
        "Int32Value",
        "Int64Value",
        "StringValue",
        "UInt32Value",
        "UInt64Value",
    }
    payload = fields.get("value", {}) if special else fields
    json_format.ParseDict(payload, instance, descriptor_pool=POOL)
    return Message(type_name, instance.SerializePartialToString(deterministic=True))


def encode_message(value: Message) -> dict[str, Any]:
    cls = message_factory.GetMessageClass(POOL.FindMessageTypeByName(value.type_name))
    instance = cls()
    instance.ParseFromString(value.data)
    fields = json_format.MessageToDict(instance, descriptor_pool=POOL)
    type_url = f"type.googleapis.com/{value.type_name}"
    special = value.type_name.startswith("google.protobuf.") and value.type_name.rsplit(".", 1)[-1] in {
        "Any",
        "Duration",
        "Timestamp",
        "FieldMask",
        "Value",
        "ListValue",
        "Struct",
        "BoolValue",
        "BytesValue",
        "DoubleValue",
        "FloatValue",
        "Int32Value",
        "Int64Value",
        "StringValue",
        "UInt32Value",
        "UInt64Value",
    }
    return {"@type": type_url, "value": fields} if special else {"@type": type_url, **fields}


def encode_temporal(value: Timestamp | Duration) -> dict[str, Any]:
    if isinstance(value, Timestamp):
        timestamp = timestamp_pb2.Timestamp(seconds=value.seconds, nanos=value.nanos)
        return encode_message(Message("google.protobuf.Timestamp", timestamp.SerializeToString()))
    seconds = abs(value.nanoseconds) // 1_000_000_000
    if value.nanoseconds < 0:
        seconds = -seconds
    duration = duration_pb2.Duration(seconds=seconds, nanos=value.nanoseconds - seconds * 1_000_000_000)
    return encode_message(Message("google.protobuf.Duration", duration.SerializeToString()))


def messages_equal(left: dict[str, Any], right: dict[str, Any]) -> bool:
    a, b = decode_message(left), decode_message(right)
    if a.type_name != b.type_name:
        return False
    return encode_message(a) == encode_message(b)


def transport(value: Any) -> Any:
    if isinstance(value, list):
        return [transport(item) for item in value]
    if not isinstance(value, dict):
        return value
    if "objectValue" in value:
        message = decode_message(value["objectValue"])
        return {"messageValue": {"typeName": message.type_name, "data": base64.b64encode(message.data).decode()}}
    return {key: transport(item) for key, item in value.items()}


def normalize(value: Any) -> Any:
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if not isinstance(value, dict):
        return value
    if "timestampValue" in value:
        time = value["timestampValue"]
        return {"objectValue": encode_temporal(Timestamp(int(time["seconds"]), time["nanos"]))}
    if "durationValue" in value:
        return {"objectValue": encode_temporal(Duration(int(value["durationValue"])))}
    if "messageValue" in value:
        message = value["messageValue"]
        return {"objectValue": encode_message(Message(message["typeName"], base64.b64decode(message["data"])))}
    return {key: normalize(item) for key, item in value.items()}
