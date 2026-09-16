import { CELType } from "../bindings/typescript/dist/index.js";

const primitives = {
  BOOL: "bool",
  INT64: "int",
  UINT64: "uint",
  DOUBLE: "double",
  STRING: "string",
  BYTES: "bytes",
};

export function decodeType(value) {
  if ("typeParam" in value) return CELType.parameter(value.typeParam);
  if ("abstractType" in value)
    return CELType.abstract(
      value.abstractType.name,
      (value.abstractType.parameterTypes ?? []).map(decodeType),
    );
  if ("primitive" in value) return new CELType(primitives[value.primitive]);
  if ("wrapper" in value) return new CELType("wrapper", [new CELType(primitives[value.wrapper])]);
  if (value.wellKnown === "TIMESTAMP") return new CELType("google.protobuf.Timestamp");
  if (value.wellKnown === "DURATION") return new CELType("google.protobuf.Duration");
  if (value.wellKnown === "ANY") return new CELType("dyn");
  if (value.wellKnown === "LIST_VALUE") return new CELType("list", [new CELType("dyn")]);
  if (value.wellKnown === "STRUCT")
    return new CELType("map", [new CELType("string"), new CELType("dyn")]);
  if ("dyn" in value) return new CELType("dyn");
  if ("messageType" in value) return new CELType(value.messageType);
  if ("null" in value) return new CELType("null_type");
  if ("listType" in value) return new CELType("list", [decodeType(value.listType.elemType)]);
  if ("mapType" in value)
    return new CELType("map", [
      decodeType(value.mapType.keyType),
      decodeType(value.mapType.valueType),
    ]);
  if ("type" in value)
    return new CELType("type", Object.keys(value.type).length ? [decodeType(value.type)] : []);
  throw new TypeError(`Unsupported static type: ${JSON.stringify(value)}`);
}

export function encodeType(type) {
  if (type.kind === "parameter") return { typeParam: type.name };
  if (type.kind === "abstract")
    return {
      abstractType: {
        name: type.name,
        parameterTypes: type.parameters.map(encodeType),
      },
    };
  for (const [key, name] of Object.entries(primitives)) {
    if (type.name === name) return { primitive: key };
  }
  if (type.name === "wrapper")
    return {
      wrapper: Object.keys(primitives).find((name) => primitives[name] === type.parameters[0].name),
    };
  if (type.name === "google.protobuf.Timestamp") return { wellKnown: "TIMESTAMP" };
  if (type.name === "google.protobuf.Duration") return { wellKnown: "DURATION" };
  if (type.name === "dyn") return { dyn: {} };
  if (type.name === "null_type") return { null: null };
  if (type.name === "list") return { listType: { elemType: encodeType(type.parameters[0]) } };
  if (type.name === "map")
    return {
      mapType: {
        keyType: encodeType(type.parameters[0]),
        valueType: encodeType(type.parameters[1]),
      },
    };
  if (type.name === "type")
    return { type: type.parameters.length ? encodeType(type.parameters[0]) : {} };
  return { messageType: type.name };
}
