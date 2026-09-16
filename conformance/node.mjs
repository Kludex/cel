import {
  CELType,
  CompileError,
  Double,
  Duration,
  Environment,
  FunctionDeclaration,
  EnumValue,
  EvaluateError,
  Message,
  OptionalValue,
  IPAddress,
  CIDR,
  Timestamp,
  UInt,
} from "../bindings/typescript/dist/index.js";
import { decodeType, encodeType } from "./node-types.mjs";
import { readFileSync } from "node:fs";

const descriptors = readFileSync(
  new URL("./protobuf/cel-spec-test-descriptors.pb", import.meta.url),
);
const environments = new Map();

class UnsupportedError extends Error {}

function object(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  return value;
}

function onlyKeys(value, allowed, label) {
  const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
  if (unknown.length)
    throw new UnsupportedError(`${label} has unsupported fields: ${unknown.join(", ")}`);
}

function decodeInteger(value, label) {
  if (typeof value !== "string" || !/^-?(?:0|[1-9][0-9]*)$/.test(value)) {
    throw new TypeError(`${label} must be a decimal string`);
  }
  return BigInt(value);
}

function decodeDouble(value) {
  if (value === "NaN") return NaN;
  if (value === "Infinity") return Infinity;
  if (value === "-Infinity") return -Infinity;
  if (typeof value !== "number")
    throw new TypeError("doubleValue must be a number or special value");
  return value;
}

function decodeBytes(value) {
  if (
    typeof value !== "string" ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
  ) {
    throw new TypeError("bytesValue must be valid base64");
  }
  return new Uint8Array(Buffer.from(value, "base64"));
}

function decodeValue(input) {
  const value = object(input, "CEL value");
  const keys = Object.keys(value);
  if (keys.length !== 1)
    throw new UnsupportedError(`unsupported CEL value shape: ${keys.join(", ") || "empty"}`);

  const kind = keys[0];
  if (kind === "nullValue") {
    if (value[kind] !== null && value[kind] !== "NULL_VALUE" && value[kind] !== 0) {
      throw new TypeError("nullValue must represent protobuf NULL_VALUE");
    }
    return null;
  }
  if (kind === "boolValue") {
    if (typeof value[kind] !== "boolean") throw new TypeError("boolValue must be a boolean");
    return value[kind];
  }
  if (kind === "int64Value") return decodeInteger(value[kind], kind);
  if (kind === "uint64Value") return new UInt(decodeInteger(value[kind], kind));
  if (kind === "doubleValue") return new Double(decodeDouble(value[kind]));
  if (kind === "stringValue") {
    if (typeof value[kind] !== "string") throw new TypeError("stringValue must be a string");
    return value[kind];
  }
  if (kind === "bytesValue") return decodeBytes(value[kind]);
  if (kind === "ipValue") return new IPAddress(value[kind]);
  if (kind === "cidrValue") return new CIDR(value[kind]);
  if (kind === "optionalValue") {
    const optional = object(value[kind], "optionalValue");
    if (Object.keys(optional).some((key) => key !== "value"))
      throw new TypeError("invalid optionalValue shape");
    return "value" in optional
      ? OptionalValue.of(decodeValue(optional.value))
      : OptionalValue.none();
  }
  if (kind === "enumValue") return new EnumValue(value[kind].type, value[kind].value ?? 0);
  if (kind === "typeValue") return new CELType(value[kind]);
  if (kind === "messageValue")
    return new Message(value[kind].typeName, decodeBytes(value[kind].data));
  if (kind === "listValue") {
    const list = object(value[kind], "listValue");
    onlyKeys(list, ["values"], "listValue");
    const values = list.values ?? [];
    if (!Array.isArray(values)) throw new TypeError("listValue.values must be an array");
    return values.map(decodeValue);
  }
  if (kind === "mapValue") {
    const map = object(value[kind], "mapValue");
    onlyKeys(map, ["entries"], "mapValue");
    const entries = map.entries ?? [];
    if (!Array.isArray(entries)) throw new TypeError("mapValue.entries must be an array");
    const result = new Map();
    for (const rawEntry of entries) {
      const entry = object(rawEntry, "map entry");
      onlyKeys(entry, ["key", "value"], "map entry");
      const key = decodeValue(entry.key);
      if (result.has(key)) throw new TypeError("duplicate map key in transport");
      result.set(key, decodeValue(entry.value));
    }
    return result;
  }
  throw new UnsupportedError(`unsupported CEL value: ${kind}`);
}

function encodeDouble(value) {
  if (Number.isNaN(value)) return "NaN";
  if (value === Infinity) return "Infinity";
  if (value === -Infinity) return "-Infinity";
  return value;
}

function encodeValue(value) {
  if (value === null) return { nullValue: null };
  if (typeof value === "boolean") return { boolValue: value };
  if (value instanceof UInt) return { uint64Value: value.value.toString() };
  if (typeof value === "bigint") return { int64Value: value.toString() };
  if (typeof value === "number") return { doubleValue: encodeDouble(value) };
  if (typeof value === "string") return { stringValue: value };
  if (value instanceof Uint8Array) return { bytesValue: Buffer.from(value).toString("base64") };
  if (value instanceof IPAddress) return { ipValue: value.value };
  if (value instanceof CIDR) return { cidrValue: value.value };
  if (value instanceof OptionalValue)
    return { optionalValue: value.hasValue ? { value: encodeValue(value.value) } : {} };
  if (value instanceof EnumValue)
    return { enumValue: { type: value.typeName, value: value.number } };
  if (value instanceof CELType) return { typeValue: value.name };
  if (value instanceof Timestamp)
    return { timestampValue: { seconds: value.seconds.toString(), nanos: value.nanos } };
  if (value instanceof Duration) return { durationValue: value.nanoseconds.toString() };
  if (value instanceof Message)
    return {
      messageValue: { typeName: value.typeName, data: Buffer.from(value.data).toString("base64") },
    };
  if (Array.isArray(value)) return { listValue: { values: value.map(encodeValue) } };
  if (value instanceof Map) {
    return {
      mapValue: {
        entries: [...value].map(([key, item]) => ({
          key: encodeValue(key),
          value: encodeValue(item),
        })),
      },
    };
  }
  if (value !== null && typeof value === "object") {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw new UnsupportedError(`unsupported output type: ${value.constructor?.name ?? "object"}`);
    }
    return {
      mapValue: {
        entries: Object.keys(value).map((key) => ({
          key: { stringValue: key },
          value: encodeValue(value[key]),
        })),
      },
    };
  }
  throw new UnsupportedError(`unsupported output type: ${typeof value}`);
}

function message(error) {
  return error instanceof Error ? error.message : String(error);
}

function run(input) {
  const id = input !== null && typeof input === "object" && "id" in input ? input.id : null;
  try {
    const request = object(input, "input");
    onlyKeys(
      request,
      [
        "id",
        "expr",
        "bindings",
        "variables",
        "container",
        "check",
        "checkOnly",
        "strongEnums",
        "functions",
      ],
      "input",
    );
    if (typeof request.expr !== "string") throw new TypeError("expr must be a string");
    let program;
    try {
      const variables = Object.fromEntries(
        Object.entries(request.variables ?? {}).map(([name, type]) => [name, decodeType(type)]),
      );
      const key = JSON.stringify([
        request.container ?? "",
        request.variables ?? {},
        request.strongEnums ?? false,
        request.functions ?? [],
      ]);
      let environment = environments.get(key);
      if (!environment) {
        environment = new Environment({
          variables,
          container: request.container ?? "",
          descriptors,
          strongEnums: request.strongEnums ?? false,
          functions: (request.functions ?? []).map(
            (f) =>
              new FunctionDeclaration(
                f.name,
                f.params.map(decodeType),
                decodeType(f.resultType),
                undefined,
                { overloadId: f.overloadId, member: f.member },
              ),
          ),
        });
        environments.set(key, environment);
      }
      program = environment.compile(request.expr, { check: request.check ?? false });
    } catch (error) {
      if (error instanceof CompileError)
        return { id, outcome: "compile_error", error: message(error) };
      throw error;
    }

    const metadata =
      program.resultType === null ? {} : { checked_type: encodeType(program.resultType) };
    if (request.checkOnly) return { id, outcome: "checked", ...metadata };
    const rawBindings = object(request.bindings, "bindings");
    const bindings = Object.create(null);
    for (const name of Object.keys(rawBindings)) {
      Object.defineProperty(bindings, name, {
        enumerable: true,
        value: decodeValue(rawBindings[name]),
      });
    }
    try {
      return { id, outcome: "value", value: encodeValue(program.evaluate(bindings)), ...metadata };
    } catch (error) {
      if (error instanceof EvaluateError)
        return { id, outcome: "eval_error", error: message(error), ...metadata };
      throw error;
    }
  } catch (error) {
    return {
      id,
      outcome: error instanceof UnsupportedError ? "unsupported" : "input_error",
      error: message(error),
    };
  }
}

let source = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) source += chunk;

let output;
try {
  const input = JSON.parse(source);
  output = Array.isArray(input)
    ? input.map(run)
    : [{ id: null, outcome: "input_error", error: "input must be an array" }];
} catch (error) {
  output = [{ id: null, outcome: "input_error", error: message(error) }];
}
process.stdout.write(`${JSON.stringify(output)}\n`);
