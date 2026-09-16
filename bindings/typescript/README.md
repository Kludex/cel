# CEL for TypeScript

```sh
npm ci --prefix bindings/typescript
npm run build --prefix bindings/typescript
node --input-type=module <<'JS'
import { CELType, Program, UInt, Double, EvaluateError } from "./bindings/typescript/dist/index.js";

const policy = new Program("request.user.active && request.user.age >= 18");
const allowed = policy.evaluate({ request: { user: { active: true, age: 21 } } });
if (allowed !== true) throw new Error("Unexpected policy decision");

const unsigned = new Program("n + 1u").evaluate({ n: new UInt(2n) });
if (!(unsigned instanceof UInt) || unsigned.value !== 3n) throw new Error("Unexpected uint");
const integerType = new Program("type(1)").evaluate({});
if (!(integerType instanceof CELType) || integerType.name !== "int") throw new Error("Unexpected type");
if (new Program("n + 1.0").evaluate({ n: new Double(2) }) !== 3) throw new Error("Unexpected double");

try {
  new Program("1 / zero").evaluate({ zero: 0 });
} catch (error) {
  if (!(error instanceof EvaluateError) || error.code !== "DivisionByZero") throw error;
}
JS
```

Run these commands from the repository root. You need Zig 0.16.0, Node.js 22 or newer, and Node headers. The build searches standard Node installation paths. Set `NODE_INCLUDE` to the directory containing `node_api.h` when necessary.

The package uses the shared Zig engine through Node-API. Inputs cross the native boundary directly, without JSON serialization. Compiled programs are immutable and released by garbage collection. The package is experimental and is not published.

Each npm archive contains one platform's native binary. Build and pack it on the destination platform. Alpha.13's Linux arm64 archive passes the public tests on Node 22 and 24, including Node 24 on glibc 2.28. Multi-platform npm installation remains unfinished.

## Reuse local values

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { CELType, Environment } from "./bindings/typescript/dist/index.js";

const policy = new Environment({ variables: { batches: new CELType("list", [new CELType("dyn")]) } }).compile(
  "cel.bind(jobs, batches.flatten(), jobs.size() >= 2 && " +
  "jobs.distinct().size() == jobs.size() && jobs.sort().slice(0, 2) == [1, 2])",
);
assert.equal(policy.evaluate({ batches: [[3, 1], [2]] }), true);
assert.equal(policy.evaluate({ batches: [[1, 1], [2]] }), false);
JS
```

`cel.bind(name, initializer, body)` computes a local value on first use and caches its value or CEL error for that binding. The initializer captures the outer scope. Caches do not survive requests or reentrant evaluations. Checked compilation validates unused initializers, and host callback exceptions remain fatal when used.

Input conversion still runs first; this is not lazy JavaScript property access. Only the exact `cel.bind` receiver expands the macro. A leading dot bypasses local variable scope and prevents macro expansion for `.cel.bind`.

## Indexed expression blocks

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { Environment } from "./bindings/typescript/dist/index.js";

const program = new Environment().compile(
  "cel.block([[3, 1, 2], cel.index(0).sort()], cel.index(1).slice(0, 2))",
);
assert.deepEqual(program.evaluate({}), [1n, 2n]);
JS
```

`cel.block` and `cel.index` expose the pinned optimizer/conformance format, not standard CEL-Go source functions. Numbered slots initialize lazily and cache values or CEL errors for one block evaluation. Initializers capture block-entry scope; nested blocks, requests, and reentrant evaluations do not share caches.

Indices are nonnegative integer literals. Forward references are allowed; a used missing or cyclic reference produces an evaluation error. Checked compilation validates all initializers and conservatively types unresolved forward dependencies. Optional markers in the structural initializer list do not compact indices or unwrap slot values.

`cel.iterVar` and `cel.accuVar` create private lexical identifiers used by the conformance format. Activation properties cannot impersonate them.

## List policies

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { Environment } from "./bindings/typescript/dist/index.js";

const policy = new Environment().compile(
  "[[3, 1], [2, 3]].flatten().distinct().sort().reverse() == [3, 2, 1] && " +
  "lists.range(4).sortBy(item, -item).slice(0, 2) == [3, 2]",
);
assert.equal(policy.evaluate({}), true);
JS
```

You can slice, flatten, deduplicate, reverse, and sort lists, or generate integer ranges. `sortBy` evaluates its receiver once and each key once. Equal sort keys retain input order; keys must have one comparable type after protobuf adaptation. Multi-element NaN sorting raises `InvalidArgument`, unlike CEL-Go's current silent comparison-error handling.

Scalar `distinct` uses hash buckets and verifies collisions with CEL equality. Compound values retain budgeted recursive comparisons. These operations do not mutate your inputs, and collection, depth, and work limits still apply.

## String policies

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { Program } from "./bindings/typescript/dist/index.js";

const policy = new Program(
  "name.trim().lowerAscii().replace(' ', '-') == 'alice-smith' && " +
  "'%.2f'.format([amount]) == '2.67'",
);
assert.equal(policy.evaluate({ name: " Alice Smith ", amount: 2.675 }), true);
assert.equal(new Program("text.substring(1,3).reverse()").evaluate({ text: "A😀Z" }), "Z😀");
JS
```

`charAt`, `substring`, `indexOf`, and `lastIndexOf` count Unicode code points, not JavaScript UTF-16 units. You can also use ASCII casing, Unicode trimming, replacement, splitting, joining, reversal, CEL quoting, and bounded `%s`/numeric formatting.

Fixed/scientific formatting uses locale-independent binary floating-point conversion. `%s` collapses each invalid byte run to one replacement character and formats durations through floating-point seconds. Duration values and arithmetic still preserve their nanoseconds. The pinned corpus's out-of-range search errors differ from newer CEL-Go behavior; reference differences remain documented rather than hidden.

## Base64 and protobuf helpers

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Environment, Program } from "./bindings/typescript/dist/index.js";

assert.equal(new Program("base64.encode(data)").evaluate({ data: Buffer.from("hello") }), "aGVsbG8=");
assert.deepEqual(new Program("base64.decode(text)").evaluate({ text: "aGVsbG8" }), Buffer.from("hello"));
const environment = new Environment({
  descriptors: readFileSync("conformance/protobuf/cel-spec-test-descriptors.pb"),
  container: "cel.expr.conformance.proto2",
});
assert.equal(environment.compile(
  "proto.getExt(TestAllTypes{}, cel.expr.conformance.proto2.int32_ext)",
).evaluate({}), 0n);
JS
```

Base64 encoding uses padding; decoding accepts padded or unpadded standard/URL-safe input. CR/LF are ignored, while spaces, tabs, malformed padding, and the wrong alphabet fail. `encodeUrl` and `decodeUrl` select the URL-safe alphabet. Decoding preserves CEL-Go's permissive unused-tail-bit behavior; encoding is canonical. These are transport operations, not authentication.

`proto.hasExt` and `proto.getExt` capture a qualified extension-name expression and reuse descriptor-backed presence/selection. The name is not read from your activation. Scalars preserve explicit-default presence, and repeated extensions use nonempty presence. Register the message/extension descriptors before compilation. The macro's selection behavior also permits string-key maps, as in CEL-Go.

## Values

| JavaScript input | CEL value | JavaScript output |
| --- | --- | --- |
| `null`, `boolean`, `string` | Same scalar type | Same scalar type |
| Safe integer `number` | `int` | `bigint` |
| Fractional `number`, negative zero, NaN, infinity | `double` | `number` |
| Signed 64-bit `bigint` | `int` | `bigint` |
| `new UInt(value)` | `uint` | `UInt` |
| `new Double(value)` | `double` | `number` |
| `new CELType(name)` | `type` | `CELType` |
| `new EnumValue(typeName, number)` | Named enum | `EnumValue` |
| `new IPAddress(text)` | `net.IP` | `IPAddress` |
| `new CIDR(text)` | `net.CIDR` | `CIDR` |
| `Uint8Array` or `Buffer` | `bytes` | `Buffer` |
| Array | `list` | Array |
| Plain object | String-keyed `map` | Plain object for string keys, otherwise `Map` |
| Native `Map` | Typed-key `map` | Plain object for string keys, otherwise `Map` |

Use `Double` when an integer-valued JavaScript number must remain a CEL `double`. Unsafe integer numbers and out-of-range bigints are rejected instead of rounded. Unsigned results retain their `UInt` wrapper, so reusing them does not silently change `uint` to `int`. This changes the experimental alpha.1 behavior, which returned a bare `bigint`. Native `Map` inputs preserve boolean, integer, unsigned integer, and string keys. Map brands and plain records are recognized before optional wrapper checks. Mutating `OptionalValue[Symbol.hasInstance]` therefore does not intercept their conversion. Proxies are rejected before wrapper prototype traps run.

The converter reads own enumerable string properties in JavaScript key order. It snapshots keys before reading values, ignores non-enumerable properties, and rejects enumerable symbol keys after earlier string-keyed values have been converted. Class instances, `undefined`, cycles, and unsupported typed arrays are rejected. Getters may execute during conversion, so pass plain data objects for predictable behavior. Byte inputs and native `Map` entries are captured when first reached, before later getters can mutate them.

`Program.evaluate` flattens plain request data (`null`, booleans, numbers, strings, bigints, arrays, and plain objects) into two typed buffers in JavaScript and hands them to the native engine in one call. Wrapper classes, `Map`, and byte inputs are converted individually by the native converter. Both paths apply the same limits, error classes, and read order, and the public tests exercise them side by side. This is why a complete authorization request costs about 1.2 us warm rather than 2.2 us; it is not a change in CEL semantics.

Qualified binding names such as `a.b.c` take precedence over shorter global names. Comprehension variables shadow matching roots; a leading dot, such as `.a.b.c`, bypasses that local scope. Quoted field access supports names such as ``request.`content-type` ``.

Input conversion accepts at most 100,000 values, 1 MiB of string and byte data, and 128 nested levels. Map keys and values both count toward the value budget, including plain-object maps. This makes a single map with 49,999 scalar entries fit, while 50,000 entries exceed the budget. The core also bounds source size, syntax nodes, evaluation depth, and work.

## Typed maps

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { Program, UInt } from "./bindings/typescript/dist/index.js";

const values = new Map([[true, "enabled"], [1n, "standard"], [new UInt(2n), "unsigned"]]);
const policy = new Program(
  "m[true] == 'enabled' && m[1u] == 'standard' && m[2u] == 'unsigned'",
);
assert.equal(policy.evaluate({ m: values }), true);
const result = new Program("m").evaluate({ m: values });
assert.ok(result instanceof Map);
assert.equal(new Program("m[1]").evaluate({ m: result }), "standard");
JS
```

CEL keeps boolean and numeric keys distinct. It considers signed and unsigned representations of the same number equal. A JavaScript map containing both `1` and `1n`, or `new UInt(1n)` and `1n`, therefore raises `TypeError` instead of creating ambiguous CEL entries. Fractional numbers, null, objects, byte arrays, and enum values are not valid map keys.

The SDK snapshots map entries before converting their values. A value getter may mutate the original map, but cannot add or remove entries from that snapshot. Compiled constants and returned results own their data. Native map subclasses and maps with changed prototypes retain their entries; overridden map methods and replaced global constructors are not used.

Proxies are rejected as CEL input values, map keys, and binding records. JavaScript does not expose a proxy's target safely, so accepting a proxy with a spoofed prototype could silently discard map entries. Pass the underlying data or an explicit plain snapshot instead.

## String validation

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { Program } from "./bindings/typescript/dist/index.js";

assert.equal(new Program("value.size()").evaluate({ value: "é𐐷" }), 2n);
assert.throws(() => new Program("true").evaluate({ unused: "\ud800" }), TypeError);
assert.equal(
  new Program("value").evaluate({ value: "\ud800".toWellFormed() }),
  "\ufffd",
);
JS
```

JavaScript can store an unpaired UTF-16 surrogate, which cannot be encoded as valid UTF-8. The SDK rejects these strings in source, binding names, values, and environment metadata, including unused inputs. Alpha.7 and earlier silently replaced them with `U+FFFD`. You can call JavaScript's `toWellFormed()` yourself if you explicitly want replacement.

Valid replacement characters and supplementary code points round-trip unchanged. Input budgets count UTF-8 bytes, not JavaScript string length. Strings, bytes, and result objects are still copied before evaluation storage is released.

## Checked environments

```sh
node --input-type=module <<'JS'
import { CELType, Environment, CompileError } from "./bindings/typescript/dist/index.js";

const environment = new Environment({
  container: "policy",
  variables: { "policy.score": new CELType("int") },
  constants: { "policy.threshold": 80 },
});
const program = environment.compile("score >= threshold");
if (program.resultType?.name !== "bool" || !program.evaluate({ "policy.score": 88 })) {
  throw new Error("Unexpected checked policy result");
}

const integers = new CELType("list", [new CELType("int")]);
const transform = new Environment({ variables: { items: integers } }).compile("items.map(x, x + 1)");
if (transform.resultType?.parameters[0]?.name !== "int") throw new Error("Unexpected result type");
try {
  environment.compile("false && (1 + 'x' == 2)");
} catch (error) {
  if (!(error instanceof CompileError) || error.code !== "TypeMismatch") throw error;
}
JS
```

`Environment.compile()` checks all branches and returns a reusable program with `resultType`. Environment data is copied; later changes to your declarations or constants do not change compiled policies. Declared types describe the values you promise to supply, rather than replacing host-language input validation.

Use `environment.compile(source, { check: false })` for unchecked namespace resolution. `new Program(source)` stays unchecked and reports `resultType = null`. You can opt in with `new Program(source, { check: true })` or supply an `environment` option explicitly. Parameterized `CELType` descriptions belong in declarations, not runtime input values.

## Custom functions

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { CELType, Environment, FunctionDeclaration } from "./bindings/typescript/dist/index.js";

const string = new CELType("string");
const environment = new Environment({
  container: "policy",
  variables: { role: string, owner: string, user: string },
  functions: [new FunctionDeclaration(
    "policy.allowed", [string, string, string], new CELType("bool"),
    (role, owner, user) => role === "admin" || owner === user,
  )],
});
const policy = environment.compile("allowed(role, owner, user)");
assert.equal(policy.evaluate({ role: "member", owner: "alice", user: "alice" }), true);
assert.equal(policy.evaluate({ role: "member", owner: "alice", user: "bob" }), false);
JS
```

Each `FunctionDeclaration` describes one overload. Give overloaded declarations distinct `overloadId` values in the fifth argument. Set `member: true` there for receiver-style calls; the first declared parameter is the receiver. Conflicting signatures are rejected after generic type variables are erased.

Use `CELType.parameter("T")` for a fresh per-call type variable. `CELType.abstract(name, parameters)` describes a nominal extension type during checking, not a runtime implementation. Missing implementations allow checking but raise `MissingFunction` during evaluation. The built-in optional type supports runtime values; arbitrary user-defined abstract runtime values remain incomplete.

The environment snapshots declarations and callback references. Programs retain their environment, and callback cycles remain visible to V8's garbage collector. Arguments and results are converted through the same bounded native path as ordinary values. Reentrant calls use independent evaluation storage.

Implementations must be synchronous and return valid CEL input values. Checked calls validate their inferred return type, but `dyn` and unchecked generic contracts deliberately allow erased types. Host exceptions propagate unchanged, including errors with native-looking `code` fields. They are not suppressed by CEL logical operators. Cost limits cannot preempt trusted callback code or bound its external side effects.

## Optional values

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { OptionalValue, Program } from "./bindings/typescript/dist/index.js";

const policy = new Program("request.?limit.orValue(10)");
assert.equal(policy.evaluate({ request: {} }), 10n);
assert.equal(policy.evaluate({ request: { limit: null } }), null);
assert.deepEqual(new Program("optional.of(null)").evaluate({}), OptionalValue.of(null));
assert.deepEqual(new Program("[?optional.of(1), ?optional.none()]").evaluate({}), [1n]);
JS
```

An absent optional is different from a present `null`. Use `OptionalValue.none()` and `OptionalValue.of(value)` to pass either representation explicitly. Optional payloads use normal native conversion, including recursive limits, callback transport, and independent results.

`.?field` and `[?key]` preserve absence through an access chain. `or()` and `orValue()` evaluate their fallback only when absent. `optMap()` transforms a present payload once; `optFlatMap()` requires an optional result. Invalid index or receiver types on a present value remain errors; an absent optional skips later index expressions. A `?` initializer in a list, map, or protobuf message omits absent values and unwraps present ones.

Declare optional values with `CELType.abstract("optional_type", [innerType])`. The [root reference](../../README.md#optional-values) describes zero-value rules, list helpers, and protobuf presence. The wrapper's `value` property is just stored host data; CEL `value()` raises `NoSuchKey` when the optional is absent.

## Math policies

```sh
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { Program, UInt } from "./bindings/typescript/dist/index.js";

const policy = new Program(
  "math.bitAnd(permissions, 4u) == 4u && math.greatest(usage, 0) <= capacity",
);
assert.equal(policy.evaluate({ permissions: new UInt(7n), usage: 8, capacity: 10 }), true);
assert.equal(policy.evaluate({ permissions: new UInt(3n), usage: 8, capacity: 10 }), false);
assert.equal(new Program("math.bitShiftRight(-1, 1)").evaluate({}), 9223372036854775807n);
JS
```

The shared core implements numeric extrema, rounding, absolute value, sign, finite/NaN/infinity predicates, and 64-bit bit operations. Extrema preserve the winning numeric type and the first argument on ties. Integer results remain bigints; unsigned results remain `UInt`.

Right shifts are logical, including signed inputs. Negative shift counts fail, and counts of 64 or more produce zero. See the [math reference](../../README.md#math-extension) for type rules and failure phases.

## Timestamps and durations

```sh
node --input-type=module <<'JS'
import { CELType, Duration, Environment, Timestamp } from "./bindings/typescript/dist/index.js";

const environment = new Environment({ variables: {
  start: new CELType("google.protobuf.Timestamp"),
  delay: new CELType("google.protobuf.Duration"),
} });
const policy = environment.compile("start + delay");
const result = policy.evaluate({ start: new Timestamp(1234567890n, 123456789), delay: new Duration(999999999n) });
if (!(result instanceof Timestamp) || result.seconds !== 1234567891n || result.nanos !== 123456788) {
  throw new Error("Temporal precision was lost");
}
JS
```

`Timestamp` takes bigint UTC seconds and a nanosecond component from 0 through 999,999,999. `Duration` takes signed 64-bit bigint nanoseconds. The wrappers avoid the millisecond precision loss of JavaScript `Date`. Values round-trip through protobuf timestamp and duration fields, including `Any` and JSON conversions.

Selectors support UTC, fixed offsets, and named IANA zones using the host database. The SDK rejects local-machine aliases and path traversal spellings. Minimal Debian 13 images need `tzdata-legacy` for aliases such as `US/Central`; see [timezone installation](../../README.md#debian-timezone-data). Duration `getMilliseconds()` follows the pinned CEL component semantics, not total-millisecond conversion.

## Protobuf messages

```sh
node --input-type=module <<'JS'
import { readFileSync } from "node:fs";
import { CELType, Environment, Message } from "./bindings/typescript/dist/index.js";

const descriptors = readFileSync("conformance/protobuf/test-schema-descriptor.pb");
const environment = new Environment({ descriptors, container: "cel.conformance.fixture" });
const value = environment.compile("TestSchema{signed_value:12,optional_value:''}").evaluate({});
if (!(value instanceof Message)) throw new Error("Expected a protobuf message");
const reader = new Environment({ descriptors, variables: { m: new CELType(value.typeName) } })
  .compile("m.signed_value == 12 && has(m.optional_value) && !has(m.name)");
if (!reader.evaluate({ m: value })) throw new Error("Unexpected message result");
JS
```

`descriptors` is a `FileDescriptorSet` encoded as bytes, including imports. `Message(typeName, data)` copies wire bytes from a `Uint8Array`. The native runtime uses registered descriptors for message construction, field types, defaults, presence, oneofs, maps, and extensions.

Regular messages are not JavaScript objects or CEL maps. Scalar wrappers and protobuf's dynamic JSON/Any types are converted according to CEL rules. Returned messages contain serialized bytes, not evaluation-local native pointers.

## Strong enums

```sh
node --input-type=module <<'JS'
import { CELType, Environment, EnumValue } from "./bindings/typescript/dist/index.js";

const typeName = "google.protobuf.FieldDescriptorProto.Type";
const environment = new Environment({
  strongEnums: true,
  variables: { fieldType: new CELType(typeName) },
});
const program = environment.compile(
  "fieldType == google.protobuf.FieldDescriptorProto.Type.TYPE_STRING",
);
if (program.evaluate({ fieldType: new EnumValue(typeName, 9) }) !== true) {
  throw new Error("Unexpected enum decision");
}
const result = environment.compile(
  "google.protobuf.FieldDescriptorProto.Type('TYPE_STRING')",
).evaluate({});
if (!(result instanceof EnumValue) || result.typeName !== typeName || result.number !== 9) {
  throw new Error("Enum identity lost");
}
JS
```

`strongEnums: true` preserves each enum's fully qualified type name and signed 32-bit number. The default is `false`, preserving legacy enum-as-int behavior. You can use descriptors built into protobuf, as above, or supply your own `descriptors`.

`EnumValue` takes an integer JavaScript `number`, not a bigint. Enum conversion functions accept CEL integers or exact symbol strings. `int(enumValue)` returns the integer number. Different enum types are not interchangeable. Arithmetic and ordering require an explicit integer conversion.

Strong enum fields require matching enum values, including repeated fields and map values. Closed protobuf enums reject unnamed field values. Enum values are not valid CEL map keys. Returned enum wrappers are independent of the compiled program and descriptor registry.

## Network policies

```sh
node --input-type=module <<'JS'
import { CIDR, IPAddress, CELType, Environment } from "./bindings/typescript/dist/index.js";

const policy = new Environment({
  variables: { source: CELType.abstract("net.IP"), network: CELType.abstract("net.CIDR") },
}).compile("network.containsIP(source) && source.isGlobalUnicast() && !source.isLoopback()");
if (policy.evaluate({ source: new IPAddress("10.24.3.8"), network: new CIDR("10.24.0.17/16") }) !== true) {
  throw new Error("Unexpected network decision");
}
if (new IPAddress("2001:0DB8::1").value !== "2001:db8::1") {
  throw new Error("Address was not canonicalized");
}
JS
```

`IPAddress` and `CIDR` use the shared Zig parser. Their `value` property contains canonical text. CIDR keeps host bits, so `new CIDR("10.24.0.17/16")` retains that address. CEL's `.masked()` returns the normalized network prefix. Containment requires the same address family and ignores host bits.

Use `ip(text)` and `cidr(text)` in expressions, or pass typed wrappers as inputs, constants, and callback results. Static declarations use the parameter-free abstract types `net.IP` and `net.CIDR`. Returned wrappers own their text. Network values are not valid CEL map keys.

Malformed constructor strings raise `RangeError`; non-string arguments raise `TypeError`. CEL's `isIP(text)` and `isCIDR(text)` return `false` for malformed strings. All zones, bracketed/port forms, leading-zero IPv4 components, and IPv4-mapped IPv6 representations are rejected. No DNS or network I/O occurs.

!!! warning "Private addresses are global unicast too"
    `.isGlobalUnicast()` follows CEL-Go, not a public-routability database. Use an explicit CIDR allowlist for access control.

See the root [network reference](../../README.md#ip-addresses-and-network-prefixes) for methods and the pinned-corpus disagreements.

## Plain-data fast path

```sh
node --input-type=module <<'JS'
import { Program } from "./bindings/typescript/dist/index.js";

const policy = new Program(
  'request.method == "GET" && principal.authenticated && (principal.role == "admin" || resource.owner == principal.id)',
);
const request = {
  request: { method: "GET" },
  principal: { authenticated: true, role: "member", id: "user-42" },
  resource: { owner: "user-42" },
};
if (!policy.hasFastPath) throw new Error("expected a compiled plain-data path");
if (policy.evaluate(request, { plainData: true }) !== true) throw new Error("Unexpected decision");
JS
```

`evaluate(bindings, { plainData: true })` runs a JavaScript function compiled from the program when the program uses only string, boolean, and safe-integer literals, unquoted field selection, indexing, `==`, `!=`, integer ordering, integer arithmetic, `!`, unary minus, `?:` with boolean or string branches, `in` against a list literal, `size()`, single-variable `all` and `exists` over lists, `matches` against a literal pattern (evaluated by the engine's RE2), and the `startsWith`, `endsWith`, and `contains` string predicates. `hasFastPath` reports whether the program qualified. The default `evaluate(bindings)` path is unchanged.

The fast path reads properties directly from your objects. Any surprise sends the call to the native engine so the result is the same: a non-plain object, `Map`, array, or proxy where an object is expected; a non-string, non-boolean, non-safe-integer, or lone-surrogate string where a scalar is expected; a missing property; a dotted binding key; or a program compiled with an `Environment` that has a container, constants, functions, or descriptors.

!!! warning "Three behaviors differ from the default path"
    The default path converts the whole activation before evaluating. The fast path reads only what the expression needs, so getters on unused properties do not run and invalid unused values are not errors; a property used twice is read twice rather than snapshotted; and non-enumerable own properties are visible. Plain data without accessors behaves identically. Keep the default path when your inputs have getters with side effects.

On the authorization, routing, data-validation, and cart benchmarks this is 5-7x faster than the default path and 2.2-4.4x faster than `@marcbachmann/cel-js`; see [the measurements](../../benchmarks/results/2026-09-16-plain-fast-path/). Compilation happens on the first plain-data call (`new Function`, about 6 us), so programs that never opt in pay nothing.

## Regular expressions

```sh
node --input-type=module <<'JS'
import { Program, EvaluateError } from "./bindings/typescript/dist/index.js";

const policy = new Program("path.matches('^/v[0-9]+/orders/[a-z]+$') && user.matches(pattern)");
if (!policy.evaluate({ path: "/v1/orders/abc", user: "admin-1", pattern: "^admin" })) {
  throw new Error("Unexpected decision");
}
try {
  new Program("'text'.matches('(')").evaluate({});
} catch (error) {
  if (!(error instanceof EvaluateError) || error.code !== "InvalidArgument") throw error;
}
JS
```

RE2 is statically linked into the addon. Both `matches(text, pattern)` and `text.matches(pattern)` search for a substring unless you add anchors. Literal patterns are reused across requests; dynamic patterns live only for one evaluation. Pattern length, compiled size, cache count, and work are bounded. Resource errors are not suppressed by logical operators. See the root [dependency notes](../../third_party/README.md) for version and memory-budget details.

## Errors

`CompileError` and `EvaluateError` expose the Zig error name in `code`. Invalid host-language inputs raise `TypeError` or `RangeError`. Evaluation errors are separate from compile errors so you can reject invalid policy text before processing requests.

## Tests

```sh
npm test --prefix bindings/typescript
npm run check --prefix bindings/typescript
```

Tests use the public `Program` API. The Node test runner requires 100% line, branch, and function coverage for the JavaScript wrapper. This does not measure native Zig coverage or establish full CEL conformance.
