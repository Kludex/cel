import { createRequire } from "node:module";
import { types } from "node:util";

export type CompileErrorCode =
  | "OutOfMemory"
  | "InvalidSyntax"
  | "InvalidLiteral"
  | "SourceLimitExceeded"
  | "DepthLimitExceeded"
  | "NodeLimitExceeded"
  | "RegexLimitExceeded"
  | "InvalidDeclaration"
  | "DeclarationLimitExceeded"
  | "CheckLimitExceeded"
  | "UndeclaredReference"
  | "TypeMismatch"
  | "UnsupportedType"
  | "InvalidDescriptor"
  | "ProtobufLimitExceeded";

export type EvaluateErrorCode =
  | "OutOfMemory"
  | "UndeclaredReference"
  | "NoMatchingOverload"
  | "Overflow"
  | "DivisionByZero"
  | "NoSuchKey"
  | "IndexOutOfBounds"
  | "DuplicateKey"
  | "CostLimitExceeded"
  | "DepthLimitExceeded"
  | "CollectionLimitExceeded"
  | "InvalidArgument"
  | "RegexLimitExceeded"
  | "UnsupportedType"
  | "ProtobufLimitExceeded"
  | "MissingFunction"
  | "HostFunctionError";

export class CompileError extends Error {
  override readonly name = "CompileError";

  constructor(
    readonly code: CompileErrorCode,
    options?: ErrorOptions,
  ) {
    super(code, options);
  }
}

export class EvaluateError extends Error {
  override readonly name = "EvaluateError";

  constructor(
    readonly code: EvaluateErrorCode,
    options?: ErrorOptions,
  ) {
    super(code, options);
  }
}

export class UInt {
  readonly value: bigint;

  constructor(value: bigint) {
    if (typeof value !== "bigint") throw new TypeError("UInt requires a bigint");
    if (value < 0n || value > 18_446_744_073_709_551_615n) {
      throw new RangeError("UInt must be between 0 and 2^64 - 1");
    }
    this.value = value;
  }
}

export class Double {
  constructor(readonly value: number) {
    if (typeof value !== "number") throw new TypeError("Double requires a number");
  }
}

export type CELTypeKind = "concrete" | "parameter" | "abstract";

export class CELType {
  readonly parameters: readonly CELType[];

  constructor(
    readonly name: string,
    parameters: readonly CELType[] = [],
    readonly kind: CELTypeKind = "concrete",
  ) {
    if (typeof name !== "string") throw new TypeError("CELType requires a string name");
    if (name.length === 0) throw new RangeError("CELType name must not be empty");
    if (
      !Array.isArray(parameters) ||
      parameters.some((parameter) => !(parameter instanceof CELType))
    ) {
      throw new TypeError("CELType parameters must be an array of CELType values");
    }
    if (kind !== "concrete" && kind !== "parameter" && kind !== "abstract") {
      throw new RangeError("CELType kind must be concrete, parameter, or abstract");
    }
    this.parameters = [...parameters];
  }

  static parameter(name: string): CELType {
    return new CELType(name, [], "parameter");
  }

  static abstract(name: string, parameters: readonly CELType[] = []): CELType {
    return new CELType(name, parameters, "abstract");
  }
}

export type FunctionOptions = { overloadId?: string; member?: boolean };
export type FunctionImplementation = { call(...args: CelOutput[]): CelInput }["call"];

export class FunctionDeclaration {
  readonly parameters: readonly CELType[];
  readonly overloadId: string;
  readonly member: boolean;

  constructor(
    readonly name: string,
    parameters: readonly CELType[],
    readonly result: CELType,
    readonly implementation: FunctionImplementation | undefined = undefined,
    options: FunctionOptions = {},
  ) {
    if (typeof name !== "string") throw new TypeError("FunctionDeclaration requires a string name");
    if (name.length === 0) throw new RangeError("FunctionDeclaration name must not be empty");
    if (!Array.isArray(parameters) || parameters.some((value) => !(value instanceof CELType))) {
      throw new TypeError("function parameters must be an array of CELType values");
    }
    if (!(result instanceof CELType)) throw new TypeError("function result must be a CELType");
    if (implementation !== undefined && typeof implementation !== "function") {
      throw new TypeError("function implementation must be a function");
    }
    if (options === null || typeof options !== "object") {
      throw new TypeError("function options must be an object");
    }
    if (options.overloadId !== undefined && typeof options.overloadId !== "string") {
      throw new TypeError("overloadId must be a string");
    }
    if (options.member !== undefined && typeof options.member !== "boolean") {
      throw new TypeError("member must be a boolean");
    }
    this.parameters = [...parameters];
    this.overloadId = options.overloadId ?? "";
    this.member = options.member ?? false;
  }
}

export class EnumValue {
  constructor(
    readonly typeName: string,
    readonly number: number,
  ) {
    if (typeof typeName !== "string") throw new TypeError("EnumValue requires a string typeName");
    if (!/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(typeName)) {
      throw new RangeError("EnumValue typeName must be a qualified name");
    }
    if (typeof number !== "number" || !Number.isInteger(number)) {
      throw new TypeError("EnumValue requires an integer number");
    }
    if (number < -2_147_483_648 || number > 2_147_483_647) {
      throw new RangeError("EnumValue number must fit a signed 32-bit integer");
    }
  }
}

export class Message {
  readonly data: Uint8Array;

  constructor(
    readonly typeName: string,
    data: Uint8Array = new Uint8Array(),
  ) {
    if (typeof typeName !== "string" || typeName.length === 0)
      throw new TypeError("Message requires a protobuf type name");
    if (!(data instanceof Uint8Array)) throw new TypeError("Message data must be a Uint8Array");
    this.data = new Uint8Array(data);
  }
}

export class Timestamp {
  constructor(
    readonly seconds: bigint,
    readonly nanos: number = 0,
  ) {
    if (typeof seconds !== "bigint") throw new TypeError("Timestamp seconds must be a bigint");
    if (
      seconds < -62135596800n ||
      seconds > 253402300799n ||
      !Number.isInteger(nanos) ||
      nanos < 0 ||
      nanos >= 1000000000
    ) {
      throw new RangeError("Timestamp must be normalized and between UTC years 1 and 9999");
    }
  }
}

export class Duration {
  constructor(readonly nanoseconds: bigint) {
    if (typeof nanoseconds !== "bigint")
      throw new TypeError("Duration nanoseconds must be a bigint");
    if (nanoseconds < -(2n ** 63n) || nanoseconds >= 2n ** 63n)
      throw new RangeError("Duration must fit signed 64-bit nanoseconds");
  }
}

export class OptionalValue {
  constructor(
    readonly hasValue: boolean = false,
    readonly value: CelInput = null,
  ) {
    if (typeof hasValue !== "boolean") {
      throw new TypeError("OptionalValue hasValue must be a boolean");
    }
    if (!hasValue && value !== null) {
      throw new TypeError("an absent OptionalValue must have a null value");
    }
  }

  static of(value: CelInput): OptionalValue {
    return new OptionalValue(true, value);
  }

  static none(): OptionalValue {
    return new OptionalValue();
  }
}

export class IPAddress {
  readonly value: string;

  constructor(value: string) {
    if (typeof value !== "string") throw new TypeError("IPAddress requires a string");
    this.value = native.normalizeNetwork(value, false);
  }

  toString(): string {
    return this.value;
  }
}

export class CIDR {
  readonly value: string;

  constructor(value: string) {
    if (typeof value !== "string") throw new TypeError("CIDR requires a string");
    this.value = native.normalizeNetwork(value, true);
  }

  toString(): string {
    return this.value;
  }
}

export interface CelObject {
  readonly [key: string]: CelInput;
}

export type CelMapKey = boolean | number | bigint | string | UInt;

export interface CelMap extends ReadonlyMap<CelMapKey, CelInput> {}

export type CelInput =
  | null
  | boolean
  | number
  | bigint
  | string
  | Uint8Array
  | UInt
  | Double
  | CELType
  | EnumValue
  | Message
  | Timestamp
  | Duration
  | OptionalValue
  | IPAddress
  | CIDR
  | readonly CelInput[]
  | CelObject
  | CelMap;

export interface CelOutputObject {
  [key: string]: CelOutput;
}

export interface CelOutputMap extends Map<CelMapKey, CelOutput> {}

export type CelOutput =
  | null
  | boolean
  | bigint
  | number
  | string
  | Uint8Array
  | CELType
  | UInt
  | EnumValue
  | Message
  | Timestamp
  | Duration
  | OptionalValue
  | IPAddress
  | CIDR
  | CelOutput[]
  | CelOutputObject
  | CelOutputMap;

type Native = {
  normalizeNetwork(value: string, isCIDR: boolean): string;
  compile(source: string, errorType: typeof CompileError): unknown;
  compileIn(
    environment: unknown,
    source: string,
    check: boolean,
    errorType: typeof CompileError,
  ): unknown;
  resultType(
    handle: unknown,
    celType: typeof CELType,
    errorType: typeof CompileError,
  ): CELType | null;
  environment(
    variables: Readonly<Record<string, CELType>>,
    constants: Readonly<Record<string, CelInput>>,
    container: string,
    descriptors: Uint8Array,
    strongEnums: boolean,
    functions: readonly (readonly [
      string,
      string,
      readonly CELType[],
      CELType,
      boolean,
      boolean,
    ])[],
    uintType: typeof UInt,
    doubleType: typeof Double,
    celType: typeof CELType,
    enumType: typeof EnumValue,
    messageType: typeof Message,
    durationType: typeof Duration,
    timestampType: typeof Timestamp,
    objectPrototype: object,
    mapConstructor: MapConstructor,
    mapSnapshot: typeof snapshotMap,
    mapSet: typeof Map.prototype.set,
    errorType: typeof CompileError,
    optionalType: typeof OptionalValue,
    propertyNames: typeof enumerableKeys,
    ipType: typeof IPAddress,
    cidrType: typeof CIDR,
  ): unknown;
  evaluate(
    handle: unknown,
    bindings: Readonly<Record<string, CelInput>>,
    environment: unknown,
    callbacks: readonly (FunctionImplementation | undefined)[],
    uintType: typeof UInt,
    doubleType: typeof Double,
    celType: typeof CELType,
    enumType: typeof EnumValue,
    objectPrototype: object,
    messageType: typeof Message,
    durationType: typeof Duration,
    timestampType: typeof Timestamp,
    mapConstructor: MapConstructor,
    mapSnapshot: typeof snapshotMap,
    mapSet: typeof Map.prototype.set,
    errorType: typeof EvaluateError,
    optionalType: typeof OptionalValue,
    propertyNames: typeof enumerableKeys,
    ipType: typeof IPAddress,
    cidrType: typeof CIDR,
    plainNumbers: Float64Array,
    plainLength: number,
    plainBytes: Uint8Array,
    plainDeferred: readonly unknown[],
  ): CelOutput;
};

const mapConstructor = Map;
const mapForEach = Map.prototype.forEach;
const mapSet = Map.prototype.set;
const setPrototypeOf = Object.setPrototypeOf;
const getPrototypeOf = Object.getPrototypeOf;
const objectKeys = Object.keys;
const getOwnPropertySymbols = Object.getOwnPropertySymbols;
const propertyIsEnumerable = Object.prototype.propertyIsEnumerable;
const reflectApply = Reflect.apply;
const isMap = types.isMap;
const isProxy = types.isProxy;
const RangeErrorConstructor = RangeError;
const TypeErrorConstructor = TypeError;
const native = createRequire(import.meta.url)("../cel.node") as Native;
const objectPrototype: object = Object.prototype;
const arrayIsArray = Array.isArray;
const isUint8Array = types.isUint8Array;
const textEncoder = new TextEncoder();
const stringIsWellFormed = String.prototype.isWellFormed;

function nullPrototypeArray<T>(): T[] {
  const array: T[] = [];
  setPrototypeOf(array, null);
  return array;
}

/// Tags for the flattened plain-data stream. Native code reads the same constants.
const PLAIN_NULL = 0;
const PLAIN_FALSE = 1;
const PLAIN_TRUE = 2;
const PLAIN_NUMBER = 3;
const PLAIN_STRING = 4;
const PLAIN_LIST = 5;
const PLAIN_MAP = 6;
const PLAIN_DEFERRED = 7;
const PLAIN_BIGINT = 8;
const maxPlainDepth = 128;
const maxPlainBytes = 1_048_576;
const maxPlainValues = 100_000;

/// Flattens plain request data into typed buffers so native conversion needs one boundary crossing.
/// Values that need wrapper, byte, or Map handling are deferred to the native per-value converter
/// together with their plain ancestors so cycle detection stays exact.
class PlainEncoder {
  numbers = new Float64Array(256);
  length = 0;
  bytes = new Uint8Array(4096);
  byteLength = 0;
  deferred: unknown[] = nullPrototypeArray();
  /// Active ancestors occupy indexes below `depth`; stale entries above it are never read.
  readonly ancestors: object[] = nullPrototypeArray();
  depth = 0;
  /// Mirrors the native value budget so oversized inputs stop before every element is read.
  remaining = maxPlainValues;

  bindings(input: object): void {
    this.length = 0;
    this.byteLength = 0;
    this.remaining = maxPlainValues;
    this.ancestors[0] = input;
    this.depth = 1;
    const keys = enumerableKeys(input);
    this.push(PLAIN_MAP);
    this.push(keys.length);
    this.entries(input, keys, 0);
    this.depth = 0;
  }

  private push(value: number): void {
    if (this.length === this.numbers.length) {
      const grown = new Float64Array(this.numbers.length * 2);
      grown.set(this.numbers);
      this.numbers = grown;
    }
    this.numbers[this.length] = value;
    this.length += 1;
  }

  private string(text: string): void {
    const length = text.length;
    let start = this.byteLength;
    if (start + length * 3 > this.bytes.length) {
      if (start + length > maxPlainBytes)
        throw new RangeErrorConstructor("input exceeds byte limit");
      let size = this.bytes.length * 2;
      while (size < start + length * 3) size *= 2;
      const grown = new Uint8Array(size);
      grown.set(this.bytes);
      this.bytes = grown;
    }
    const bytes = this.bytes;
    let index = 0;
    for (; index < length; index += 1) {
      const code = text.charCodeAt(index);
      if (code >= 0x80) break;
      bytes[start] = code;
      start += 1;
    }
    let written = length;
    if (index < length) {
      const rest = index === 0 ? text : text.slice(index);
      const encoded = textEncoder.encodeInto(rest, bytes.subarray(start)).written;
      if (!reflectApply(stringIsWellFormed, rest, [])) {
        throw new TypeErrorConstructor("strings must not contain unpaired UTF-16 surrogates");
      }
      written = index + encoded;
    }
    if (written > maxPlainBytes - this.byteLength) {
      throw new RangeErrorConstructor("input exceeds byte limit");
    }
    let numbers = this.numbers;
    if (this.length + 2 > numbers.length) {
      numbers = new Float64Array(numbers.length * 2);
      numbers.set(this.numbers);
      this.numbers = numbers;
    }
    numbers[this.length] = PLAIN_STRING;
    numbers[this.length + 1] = written;
    this.length += 2;
    this.byteLength += written;
  }

  private defer(value: unknown, snapshot: unknown): void {
    this.push(PLAIN_DEFERRED);
    this.push(this.deferred.length);
    this.deferred[this.deferred.length] = value;
    const ancestors = nullPrototypeArray<object>();
    for (let index = 0; index < this.depth; index += 1) ancestors[index] = this.ancestors[index]!;
    this.deferred[this.deferred.length] = ancestors;
    this.deferred[this.deferred.length] = snapshot;
  }

  private enter(input: object): void {
    const ancestors = this.ancestors;
    for (let index = 0; index < this.depth; index += 1) {
      if (ancestors[index] === input) throw new RangeErrorConstructor("input contains a cycle");
    }
    ancestors[this.depth] = input;
    this.depth += 1;
  }

  private value(input: unknown, depth: number): void {
    if (depth >= maxPlainDepth) throw new RangeErrorConstructor("input exceeds depth limit");
    if (this.remaining === 0) throw new RangeErrorConstructor("input exceeds collection limit");
    this.remaining -= 1;
    switch (typeof input) {
      case "boolean":
        this.push(input ? PLAIN_TRUE : PLAIN_FALSE);
        return;
      case "number":
        this.push(PLAIN_NUMBER);
        this.push(input);
        return;
      case "string":
        this.string(input);
        return;
      case "bigint":
        if (input >= -9_223_372_036_854_775_808n && input <= 9_223_372_036_854_775_807n) {
          this.push(PLAIN_BIGINT);
          this.push(Number(BigInt.asIntN(32, input >> 32n)));
          this.push(Number(BigInt.asUintN(32, input)));
          return;
        }
        throw new RangeErrorConstructor("bigint must fit signed 64-bit CEL int");
      case "undefined":
        throw new TypeErrorConstructor("undefined is not a CEL value");
      case "symbol":
        throw new TypeErrorConstructor("unsupported CEL input type");
      case "object":
        break;
      default:
        this.defer(input, null);
        return;
    }
    if (input === null) {
      this.push(PLAIN_NULL);
      return;
    }
    // Proxy and Map brands are checked before any prototype lookup so traps never run.
    if (isProxy(input)) throw new TypeErrorConstructor("Proxies are not supported as CEL inputs");
    if (isMap(input)) {
      // Entries are captured now so later getters cannot change what native conversion sees.
      const snapshot = snapshotMap(input, this.remaining >>> 1) as [unknown, unknown][];
      this.remaining -= snapshot.length;
      this.defer(input, snapshot);
      return;
    }
    if (arrayIsArray(input)) {
      this.enter(input);
      const length = input.length;
      if (length > this.remaining)
        throw new RangeErrorConstructor("input exceeds collection limit");
      this.push(PLAIN_LIST);
      this.push(length);
      for (let index = 0; index < length; index += 1) this.value(input[index], depth + 1);
      this.depth -= 1;
      return;
    }
    if (isUint8Array(input)) {
      // A later property getter may detach or mutate this ArrayBuffer.
      this.defer(new Uint8Array(input), null);
      return;
    }
    const prototype = getPrototypeOf(input);
    if (prototype === objectPrototype || prototype === null) {
      this.enter(input);
      const keys = enumerableKeys(input);
      if (keys.length > this.remaining >>> 1) {
        throw new RangeErrorConstructor("input exceeds collection limit");
      }
      this.remaining -= keys.length;
      this.push(PLAIN_MAP);
      this.push(keys.length);
      this.entries(input, keys, depth + 1);
      this.depth -= 1;
      return;
    }
    this.defer(input, null);
  }

  private entries(input: object, keys: readonly (string | symbol)[], depth: number): void {
    for (let index = 0; index < keys.length; index += 1) {
      const key = keys[index]!;
      if (typeof key !== "string") throw new TypeErrorConstructor("expected a string");
      this.string(key);
      this.value((input as Record<string, unknown>)[key], depth);
    }
  }
}

const plainEncoder = new PlainEncoder();
let encoderBusy = false;

function enumerableKeys(input: object): (string | symbol)[] {
  const keys: (string | symbol)[] = objectKeys(input);
  const symbols = getOwnPropertySymbols(input);
  if (symbols.length > 0) {
    setPrototypeOf(keys, null);
    for (let index = 0; index < symbols.length; index += 1) {
      const symbol = symbols[index]!;
      if (reflectApply(propertyIsEnumerable, input, [symbol])) keys[keys.length] = symbol;
    }
  }
  return keys;
}

function snapshotMap(input: object, entryBudget: number): [unknown, unknown][] | boolean {
  if (isProxy(input)) throw new TypeErrorConstructor("Proxies are not supported as CEL inputs");
  if (!isMap(input)) {
    const prototype = getPrototypeOf(input);
    return prototype === objectPrototype || prototype === null;
  }
  const entries: [unknown, unknown][] = [];
  setPrototypeOf(entries, null);
  reflectApply(mapForEach, input, [
    (value: unknown, key: unknown) => {
      if (entries.length >= entryBudget) {
        throw new RangeErrorConstructor("input exceeds collection limit");
      }
      if (isProxy(key)) throw new TypeErrorConstructor("Proxy map keys are not supported");
      entries[entries.length] = [key, value];
    },
  ]);
  return entries;
}

const environmentHandles = new WeakMap<Environment, unknown>();
const environmentCallbacks = new WeakMap<
  Environment,
  readonly (FunctionImplementation | undefined)[]
>();

export type EnvironmentOptions = {
  variables?: Readonly<Record<string, CELType>>;
  constants?: Readonly<Record<string, CelInput>>;
  container?: string;
  descriptors?: Uint8Array;
  strongEnums?: boolean;
  functions?: readonly FunctionDeclaration[];
};

export class Environment {
  constructor(options: EnvironmentOptions = {}) {
    if (isProxy(options.variables) || isProxy(options.constants)) {
      throw new TypeErrorConstructor("Proxies are not supported in CEL environments");
    }
    if (options.strongEnums !== undefined && typeof options.strongEnums !== "boolean") {
      throw new TypeError("strongEnums must be a boolean");
    }
    if (
      !Array.isArray(options.functions ?? []) ||
      (options.functions ?? []).some((value) => !(value instanceof FunctionDeclaration))
    ) {
      throw new TypeError("functions must be an array of FunctionDeclaration values");
    }
    const functions = options.functions ?? [];
    const signatures = Object.freeze(
      functions.map((declaration) =>
        Object.freeze([
          declaration.name,
          declaration.overloadId,
          Object.freeze([...declaration.parameters]),
          declaration.result,
          declaration.member,
          declaration.implementation !== undefined,
        ] as const),
      ),
    );
    const callbacks = Object.freeze(functions.map(({ implementation }) => implementation));
    environmentHandles.set(
      this,
      native.environment(
        options.variables ?? {},
        options.constants ?? {},
        options.container ?? "",
        options.descriptors ?? new Uint8Array(),
        options.strongEnums ?? false,
        signatures,
        UInt,
        Double,
        CELType,
        EnumValue,
        Message,
        Duration,
        Timestamp,
        objectPrototype,
        mapConstructor,
        snapshotMap,
        mapSet,
        CompileError,
        OptionalValue,
        enumerableKeys,
        IPAddress,
        CIDR,
      ),
    );
    environmentCallbacks.set(this, callbacks);
  }

  compile(source: string, options: { check?: boolean } = {}): Program {
    return new Program(source, { environment: this, check: options.check ?? true });
  }
}

export type ProgramOptions = { environment?: Environment; check?: boolean };

export class Program {
  readonly #handle: unknown;
  readonly #environment: Environment | undefined;

  constructor(source: string, options: ProgramOptions = {}) {
    if (options.check !== undefined && typeof options.check !== "boolean")
      throw new TypeError("check must be a boolean");
    if (options.environment !== undefined && !environmentHandles.has(options.environment)) {
      throw new TypeError("environment must be an Environment");
    }
    this.#environment = options.environment;
    this.#handle =
      options.environment === undefined && !options.check
        ? native.compile(source, CompileError)
        : native.compileIn(
            options.environment === undefined ? null : environmentHandles.get(options.environment),
            source,
            options.check ?? false,
            CompileError,
          );
  }

  get resultType(): CELType | null {
    return native.resultType(this.#handle, CELType, CompileError);
  }

  evaluate(bindings: Readonly<Record<string, CelInput>>): CelOutput {
    if (isProxy(bindings))
      throw new TypeErrorConstructor("Proxies are not supported as CEL bindings");
    if (bindings === null || typeof bindings !== "object" || arrayIsArray(bindings)) {
      throw new TypeErrorConstructor("bindings must be a plain object");
    }
    const prototype = getPrototypeOf(bindings);
    if (prototype !== objectPrototype && prototype !== null) {
      throw new TypeErrorConstructor("bindings must be a plain object");
    }
    // The shared encoder's deferred array is emptied after every call; nested calls get their own encoder.
    const encoder = encoderBusy ? new PlainEncoder() : plainEncoder;
    encoderBusy = true;
    try {
      encoder.bindings(bindings);
      return native.evaluate(
        this.#handle,
        bindings,
        this.#environment === undefined ? undefined : environmentHandles.get(this.#environment),
        this.#environment === undefined ? [] : (environmentCallbacks.get(this.#environment) ?? []),
        UInt,
        Double,
        CELType,
        EnumValue,
        objectPrototype,
        Message,
        Duration,
        Timestamp,
        mapConstructor,
        snapshotMap,
        mapSet,
        EvaluateError,
        OptionalValue,
        enumerableKeys,
        IPAddress,
        CIDR,
        encoder.numbers,
        encoder.length,
        encoder.bytes,
        encoder.deferred,
      );
    } finally {
      if (encoder === plainEncoder) {
        encoderBusy = false;
        if (encoder.deferred.length !== 0) encoder.deferred = nullPrototypeArray();
      }
    }
  }
}
