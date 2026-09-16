# CEL SDK

```sh
./scripts/build-python
uv run --project bindings/python python - <<'PY'
from cel import Program

policy = Program("user.active && 'admin' in user.roles")
allowed = policy.evaluate({"user": {"active": True, "roles": ["admin"]}})
assert allowed is True
PY
```

CEL is the Common Expression Language. You compile a policy once, then evaluate it against different inputs. This project uses one Zig engine with native Python and TypeScript bindings. Neither binding serializes inputs through JSON.

**Experimental:** this is not a complete CEL implementation or a production-ready policy engine. The [conformance audit](conformance/README.md) records failures and unsupported features. The [benchmarks](benchmarks/README.md) include comparisons where this implementation is slower. There is no claim that it is currently the fastest SDK.

## Toolchains

| Component | Requirement |
| --- | --- |
| Engine | Zig 0.16.0 |
| Python | CPython 3.10 or newer, uv, Python headers |
| TypeScript | Node.js 22 or newer, npm, Node headers |
| Conformance import only | Go 1.24.9 or newer |

Native builds currently target macOS and Linux. The full SDK test suites run in CI on macOS arm64 and Linux x86-64, and locally on Linux arm64 down to glibc 2.28. Windows, browser bindings, and published package artifacts remain work in progress. You do not need Python or Node to build or test the Zig engine. Zig also compiles pinned RE2, protobuf, and Abseil sources; the first build needs network access unless those packages are already cached. Normal builds do not require CMake or system RE2 libraries.

## Linux build baseline

```sh
zig build test-install -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe \
  --prefix /tmp/cel-linux-arm64 -j4
```

GNU/Linux builds default to glibc 2.28, the system C library version. This prevents a newer build host from introducing symbols unavailable on older systems. You can override the version with an explicit target such as `-Dtarget=aarch64-linux-gnu.2.31`.

Alpha.13's core and installed Python/Node packages pass public tests on Linux arm64 with glibc 2.28. Linux x86-64 core tests pass under emulation; current x86-64 binding packages are not runtime-verified. The [validation record](validation/2026-09-15-linux/) includes source builds, minimum-runtime checks, and wheel ABI audits. Package publishing, other platforms, and remote CI remain unverified.

## TypeScript

```sh
npm ci --prefix bindings/typescript
npm run build --prefix bindings/typescript
node --input-type=module <<'JS'
import { Program } from "./bindings/typescript/dist/index.js";

const policy = new Program("user.active && 'admin' in user.roles");
const allowed = policy.evaluate({ user: { active: true, roles: ["admin"] } });
if (allowed !== true) throw new Error("Unexpected policy decision");
JS
```

The binding uses Node-API, Node's stable native-extension interface. See [TypeScript values and errors](bindings/typescript/README.md) for integer, unsigned integer, double, and Unicode conversion rules. Malformed JavaScript UTF-16 strings now raise `TypeError` instead of silently changing their contents. Set `NODE_INCLUDE` if your Node headers are not in a standard installation directory.

## Zig

```sh
zig build example-authorization -Dexamples=true
```

The complete [authorization example](examples/authorization.zig) uses `Program.compile()`, `Program.evaluate()`, and native `Value` inputs. The expected output is `allowed: true`.

A program owns its source and syntax tree. You pass an allocator for compilation and an arena for evaluation. Results can borrow the program, input values, and evaluation arena. Keep all three alive until you finish using the result. Python and TypeScript return independent host-language values instead. Each binding uses a private 4 KiB stack buffer for temporary evaluation data, then falls back to an arena for larger requests. Nested evaluations get separate storage; no request data is cached on the program.

## Python values and errors

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, CompileError, EvaluationError, Program, UInt

assert Program("type(1)")({}) == CELType("int")
assert Program("n + 1u")({"n": UInt(2)}) == UInt(3)
assert Program("n + 1.0")({"n": 2.0}) == 3.0
assert Program("data + b'!'")({"data": b"hello"}) == b"hello!"

try:
    Program("1 +")
except CompileError as error:
    assert str(error) == "InvalidSyntax"

try:
    Program("1 / zero")({"zero": 0})
except EvaluationError as error:
    assert str(error) == "DivisionByZero"
PY
```

Python `int` maps to CEL `int` and must fit signed 64-bit range. `UInt` represents an unsigned 64-bit integer. Python `float` always maps to CEL `double`, including integral values such as `2.0`. Lists, dictionaries, bytes, strings, booleans, and `None` map to the corresponding CEL values. `CELType` represents a CEL type value without conflating it with a string.

Python dictionaries can collapse distinct CEL keys such as `True` and `1` before the SDK sees them. Use `CELMap` when you need to preserve those entries. The native binding currently holds the Python interpreter lock throughout evaluation.

## Typed maps

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELMap, CELType, Environment, Program

values = CELMap(((True, "enabled"), (1, "standard")))
environment = Environment(variables={
    "m": CELType("map", (CELType("dyn"), CELType("string"))),
})
policy = environment.compile("m[true] == 'enabled' && m[1u] == 'standard'")
assert policy({"m": values}) is True
assert Program("{true:'enabled', 1:'standard'}")({}) == values
assert Program("a == b")({"a": values, "b": CELMap(tuple(reversed(values.entries)))}) is True
PY
```

`CELMap` stores a tuple of key-value tuples without applying Python dictionary equality. Keys may be `bool`, signed `int`, `UInt`, or `str`. CEL treats `1` and `1u` as the same numeric key, so duplicate numeric keys are rejected. Boolean `true` and integer `1` remain different keys.

Python results remain dictionaries when they can represent every key. A map containing both `True` and `1`, or both `False` and `0`, returns `CELMap` instead of losing an entry. You can pass either representation back into another program. Environment constants copy nested map data.

`CELMap.entries` is immutable, but its nested values may be mutable. Wrapper equality compares entries in order and preserves key types; use a CEL expression for order-independent CEL map equality. TypeScript accepts native `Map` inputs and returns native maps for non-string keys; see [TypeScript maps](bindings/typescript/README.md#typed-maps).

## Checked environments

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, CompileError, Environment

environment = Environment(
    container="policy",
    variables={"policy.score": CELType("int")},
    constants={"policy.threshold": 80},
)
program = environment.compile("score >= threshold")
assert program.result_type == CELType("bool")
assert program({"policy.score": 88}) is True

integers = CELType("list", (CELType("int"),))
transform = Environment(variables={"items": integers}).compile("items.map(x, x + 1)")
assert transform.result_type == integers
assert transform({"items": [1, 2]}) == [2, 3]

try:
    environment.compile("false && (1 + 'x' == 2)")
except CompileError as error:
    assert str(error) == "TypeMismatch"
PY
```

`Environment.compile()` checks the whole expression, including branches that will not execute. Declarations describe the types you promise to supply; they are not a host-language data-validation schema. The runtime still checks operation overloads. A program copies its environment, so you can discard or reuse the environment independently.

`Program(source)` remains unchecked. You can use `Program(source, check=True)` for a checked expression without declarations, or `environment.compile(source, check=False)` to retain namespace and constant resolution without checking. An unchecked program has `result_type = None`.

`CELType` parameters describe static collection types. Runtime `type()` results erase those parameters; a parameterized `CELType` cannot be passed as a runtime type value. The checker currently supports primitive, list, map, and type-value descriptions. Registered protobuf message and enum types are checked through their descriptors. Named type parameters and abstract extension type descriptions are supported for function checking. Arbitrary user-defined abstract runtime values remain incomplete; the built-in optional type is supported.

The complete Zig equivalent is available with `zig build example-checked -Dexamples=true`.

## Custom functions

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, Environment, Function


def allowed(role: str, owner: str, user: str) -> bool:
    return role == "admin" or owner == user


string = CELType("string")
environment = Environment(
    container="policy",
    variables={"role": string, "owner": string, "user": string},
    functions=(Function("policy.allowed", (string, string, string), CELType("bool"), allowed),),
)
policy = environment.compile("allowed(role, owner, user)")
assert policy({"role": "member", "owner": "alice", "user": "alice"}) is True
assert policy({"role": "member", "owner": "alice", "user": "bob"}) is False
PY
```

`Function` describes one overload. You give it a name, parameter types, result type, and an optional implementation. Use distinct `overload_id` values for overloads sharing a name. Overlapping signatures are rejected after type-parameter erasure. `member=True` makes the first parameter the receiver of a method-style call.

Function names resolve independently of variables and follow the environment's namespace. A matching custom function family takes precedence over a built-in family with the same resolved name. Omit the implementation for check-only use; evaluation then reports `MissingFunction`.

Programs retain callback environments, and both bindings return independent callback arguments and results. Python callback references remain visible to garbage collection, including cycles. Callback frames are thread-local, so a callback that releases the GIL cannot redirect another evaluation's conversions. Zig callback contexts are borrowed and must outlive their compiled programs.

The complete Zig example runs with `zig build example-functions -Dexamples=true` and uses `cel.Function` with an explicit allocator-aware callback.

Callbacks are synchronous trusted application code. Host exceptions propagate unchanged and are not suppressed by CEL logical operators. CEL resource limits cover engine work and converted data; they cannot preempt a blocking callback or limit its external side effects. Return valid CEL values using the supplied evaluation allocator in Zig.

### Generic signatures

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, Environment, Function

parameter = CELType.parameter("T")
environment = Environment(functions=(Function("identity", (parameter,), parameter, lambda value: value),))
program = environment.compile("identity([1, 2])")
assert program.result_type == CELType("list", (CELType("int"),))
assert program({}) == [1, 2]
PY
```

Each call gets fresh type-parameter substitutions. Checked calls validate returned values against their final inferred type; concrete signature components are also checked at runtime. `dyn` intentionally erases constraints, and unchecked generic return contracts remain the implementation's responsibility.

`CELType.abstract(name, parameters)` describes a nominal extension type for checking. It does not register a runtime value implementation or enable an arbitrary extension library. The built-in `optional_type` has runtime support.

## Optional values

```sh
uv run --project bindings/python python - <<'PY'
from cel import OptionalValue, Program

policy = Program("request.?limit.orValue(10)")
assert policy({"request": {}}) == 10
assert policy({"request": {"limit": None}}) is None
assert Program("optional.of(null)")({}) == OptionalValue.of(None)
assert Program("optional.none()")({}) == OptionalValue.none()
assert Program("[?optional.of(1), ?optional.none()]")({}) == [1]
assert Program("{?'limit': request.?limit}")({"request": {}}) == {}
assert Program("optional.none().optMap(v, 1 / 0).orValue(0)")({}) == 0
PY
```

An optional distinguishes an absent value from a present value, including `null`. `.?field` and `[?key]` return an optional instead of an error when the field or index is absent. Ordinary access on an optional continues the chain. On a present receiver, invalid receiver and index types still produce errors rather than absence. An absent optional stops the chain without evaluating later index expressions.

`or()` chooses the first present optional. `orValue()` unwraps a present value or evaluates a fallback. Both skip the fallback when the receiver is present. `optMap()` transforms a present payload once; `optFlatMap()` requires the transformation to return another optional. The checker validates skipped branches too.

A `?` before a list item, map key, or message field marks an optional initializer. An absent value omits that entry; a present value is unwrapped once. Optional protobuf field access uses presence, so an unset field is absent even when ordinary selection would return a default.

`optional.ofNonZeroValue()` omits zero scalars, empty strings/bytes/collections, and zero protobuf messages. Zero duration is absent. Zero timestamp is year 1 at midnight UTC, not the Unix epoch. Existing optional values are not automatically unwrapped or treated as zero.

`optional.unwrap()` and list `unwrapOpt()` keep only present payloads. List `first()` and `last()` return optionals. `hasValue()` tests presence; `hasValue(value)` also compares the contained value. Calling `value()` on an absent optional raises `NoSuchKey`.

The Zig example runs with `zig build example-optionals -Dexamples=true`. Construct native optionals with `Value.fromOptional(arena, value)` or `Value{ .optional = null }`.

Use `CELType.abstract("optional_type", (inner_type,))` in Python declarations. `OptionalValue.of(value)` and `OptionalValue.none()` are host representations with independent returned data. Their nested values can be mutable; compiled constants copy that data.

## Math extension

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, Environment, Program, UInt

policy = Environment(variables={
    "permissions": CELType("uint"),
    "usage": CELType("int"),
    "capacity": CELType("int"),
}).compile("math.bitAnd(permissions, 4u) == 4u && math.greatest(usage, 0) <= capacity")
assert policy({"permissions": UInt(7), "usage": 8, "capacity": 10}) is True
assert policy({"permissions": UInt(3), "usage": 8, "capacity": 10}) is False
assert Program("math.round(-1.5)")({}) == -2.0
assert Program("math.bitShiftRight(-1, 1)")({}) == 9223372036854775807
PY
```

`math.greatest()` and `math.least()` select from numeric arguments or one nonempty numeric list. The winning value keeps its type, and equal values keep the first argument. Mixed numeric comparisons remain exact. A comparison involving NaN raises `InvalidArgument`; a single NaN argument remains NaN.

`math.ceil`, `math.floor`, `math.round`, and `math.trunc` accept doubles and return doubles. Rounding halfway values goes away from zero. `math.abs` and `math.sign` preserve integer, unsigned, or double types. Absolute value of the minimum signed integer raises `Overflow`. `math.isNaN`, `math.isInf`, and `math.isFinite` accept doubles and return booleans.

`math.bitAnd`, `math.bitOr`, and `math.bitXor` require matching signed or unsigned argument types. `math.bitNot` preserves that type. Shift counts are signed integers: negative counts raise `InvalidArgument`, and counts of 64 or more produce zero. Right shift is logical even for negative signed values; it does not preserve the sign bit.

Extrema are namespace macros, so empty calls and invalid literal arguments are rejected during parsing. Dynamic invalid values remain evaluation errors. Ordinary math functions honor custom-function namespace resolution, while extrema macro expansion happens before that resolution.

## Timestamps and durations

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, Duration, Environment, Timestamp

environment = Environment(variables={
    "start": CELType("google.protobuf.Timestamp"),
    "delay": CELType("google.protobuf.Duration"),
})
policy = environment.compile("start + delay")
assert policy({"start": Timestamp(1_234_567_890, 123_456_789), "delay": Duration(999_999_999)}) == Timestamp(
    1_234_567_891, 123_456_788
)
assert environment.compile("duration('1.234s').getMilliseconds()")({}) == 234
PY
```

`Timestamp` stores UTC seconds and nanoseconds, preserving precision beyond Python's `datetime` and JavaScript's `Date`. `Duration` stores signed 64-bit nanoseconds. Arithmetic reports overflow instead of wrapping. Timestamps are limited to UTC years 1 through 9999.

CEL supports RFC3339 timestamp strings and compound duration strings such as `1h30m` or `-1.5s`. Calendar-dependent duration units such as days and weeks are rejected. Timestamp selectors accept UTC, numeric offsets, and named IANA timezones. Named zones use the host's timezone database; no bundled timezone-data version is claimed. Local-machine aliases and filesystem traversal forms are rejected.

The pinned CEL definition makes duration `getMilliseconds()` return the millisecond component, not total milliseconds. Other duration selectors return total whole hours, minutes, or seconds. This differs from some newer reference implementations and is tested explicitly.

### Debian timezone data

```sh
apt-get update
apt-get install --no-install-recommends -y tzdata tzdata-legacy
```

Run these commands as root in Debian 13 images. `tzdata-legacy` supplies aliases such as `US/Central` that minimal images omit. Missing timezone names return `InvalidArgument`; the SDK does not silently replace them with UTC. Other distributions may package these aliases with `tzdata` itself.

## Protobuf messages

```sh
uv run --project bindings/python python - <<'PY'
from pathlib import Path
from cel import CELType, Environment, Message

descriptors = Path("conformance/protobuf/test-schema-descriptor.pb").read_bytes()
environment = Environment(descriptors=descriptors, container="cel.conformance.fixture")
message = environment.compile("TestSchema{signed_value:12, optional_value:''}")({})
assert isinstance(message, Message)

reader = Environment(
    descriptors=descriptors,
    variables={"m": CELType("cel.conformance.fixture.TestSchema")},
).compile("m.signed_value == 12 && has(m.optional_value) && !has(m.name)")
assert reader({"m": message}) is True
assert message.type_name == "cel.conformance.fixture.TestSchema"
PY
```

`descriptors` is a serialized protobuf `FileDescriptorSet` containing its imports. `Message(type_name, data)` carries a fully qualified type name and protobuf wire bytes. You can pass bytes from an existing protobuf implementation without converting the message to a dictionary. Programs retain their descriptor registry independently of the environment.

The runtime uses protobuf reflection for defaults, presence, repeated fields, maps, oneofs, and registered extensions. Scalar wrappers, `Any`, `Value`, `Struct`, and `ListValue` follow CEL's automatic conversion rules. Regular messages remain distinct from maps. Message equality uses protobuf semantics, including unpacking `Any` payloads, rather than comparing wire byte order.

Native messages live only during evaluation. Returned `Message` values contain independent serialized data. Protobuf wire bytes, conversion work, nesting, and total transferred bytes are bounded; these bounds are not a claim of exact process-heap accounting.

## Protobuf extension helpers

```sh
uv run --project bindings/python python - <<'PY'
from pathlib import Path
from cel import Environment

environment = Environment(
    descriptors=Path("conformance/protobuf/cel-spec-test-descriptors.pb").read_bytes(),
    container="cel.expr.conformance.proto2",
)
policy = environment.compile(
    "cel.bind(msg, TestAllTypes{`cel.expr.conformance.proto2.int32_ext`: 42}, "
    "proto.hasExt(msg, cel.expr.conformance.proto2.int32_ext) && "
    "proto.getExt(msg, cel.expr.conformance.proto2.int32_ext) == 42)"
)
assert policy.evaluate({}) is True
PY
```

`proto.hasExt` and `proto.getExt` expand into presence and selection operations. Their second argument is a qualified identifier expression, not a string or an activation value. You must register descriptors for the message and its extensions. The existing descriptor lookup validates the containing message and supplies field defaults, repeated values, and enum types.

Presence distinguishes an unset scalar from an explicitly set default. Empty repeated extensions have no presence. Quoted identifier components are supported, but relative or leading-dot extension names are not resolved against the environment container. As in CEL-Go's macro expansion, a string-key map can also supply the resulting qualified field key.

## Strong enums

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, Environment, EnumValue

name = "google.protobuf.FieldDescriptorProto.Type"
environment = Environment(strong_enums=True)
program = environment.compile(
    "google.protobuf.FieldDescriptorProto{"
    "type: google.protobuf.FieldDescriptorProto.Type.TYPE_STRING}.type"
)
assert program({}) == EnumValue(name, 9)
assert program.result_type == CELType(name)
assert environment.compile("int(google.protobuf.FieldDescriptorProto.Type.TYPE_STRING)")({}) == 9
assert Environment().compile("google.protobuf.FieldDescriptorProto.Type.TYPE_STRING")({}) == 9
PY
```

`strong_enums=True` preserves an enum's fully qualified type name and signed 32-bit number. Different enum types remain distinct, even when their numbers match. The default stays `False` to preserve CEL's legacy enum-as-int behavior. The example uses descriptors built into protobuf; you register your own enums with `descriptors`.

Use the enum type as a conversion function, such as `google.protobuf.FieldDescriptorProto.Type('TYPE_STRING')` or `google.protobuf.FieldDescriptorProto.Type(9)`. String inputs must be exact symbols. Integer inputs may be unnamed values within signed 32-bit range. `int(enum_value)` returns the number. Arithmetic and ordering require an explicit integer conversion.

Strong enum fields require matching enum values, including repeated fields and map values. Closed protobuf enum fields reject unnamed numbers. Enum values are not valid CEL map keys. You can declare enum variables with `CELType` and pass `EnumValue` inputs or constants without losing their identity.

The Zig equivalent is available with `zig build example-enums -Dexamples=true`. Set `Environment.strong_enums = true` and pass `Value.enum_value` with borrowed `EnumValue` metadata.

## Collection policies

```sh
uv run --project bindings/python python - <<'PY'
from cel import Program

policy = Program("items.transformMap(i, v, v.`unit-price`).transformList(k, v, k + v)")
assert policy({"items": [{"unit-price": 10}, {"unit-price": 20}]}) == [10, 21]

check = Program("[{'b': {'c': 4}}].all(a, a.b.c == 4 && .a.b.c == 3)")
assert check({"a.b.c": 3}) is True
PY
```

One-variable macros iterate list elements or map keys. Two-variable macros bind a list index and value, or a map key and value. `transformList`, `transformMap`, and `transformMapEntry` also accept a filter before the transformation expression.

Qualified global names use longest-prefix resolution. Local comprehension variables shadow matching roots. A leading dot bypasses local scope. Quoted field selection allows punctuation without treating the field as part of a qualified variable name.

## Local bindings

```sh
uv run --project bindings/python python - <<'PY'
from cel import CELType, Environment

policy = Environment(variables={"batches": CELType("list", (CELType("dyn"),))}).compile(
    "cel.bind(jobs, batches.flatten(), "
    "jobs.size() >= 2 && jobs.distinct().size() == jobs.size() && "
    "jobs.sort().slice(0, 2) == [1, 2])"
)
assert policy.evaluate({"batches": [[3, 1], [2]]}) is True
assert policy.evaluate({"batches": [[1, 1], [2]]}) is False
PY
```

`cel.bind(name, initializer, body)` creates a local variable. The initializer sees the outer scope; the body sees the new variable. It runs only on first use, and its value or CEL error is reused for the rest of that binding. Each evaluation and each enclosing loop iteration creates a fresh cache. This avoids repeated computation without retaining request values in the compiled program.

Checked compilation still validates unused initializers. Used host callback exceptions remain fatal. Input conversion happens before CEL evaluation, so this does not defer JavaScript property getters or host input validation.

The macro uses the exact `cel.bind` spelling. `.cel.bind` is an ordinary function call, which can resolve a declared custom function. Absolute references such as `.x` bypass local variables, including an unusable binding named `.x`.

## Indexed expression blocks

```sh
uv run --project bindings/python python - <<'PY'
from cel import Environment

program = Environment().compile(
    "cel.block([[3, 1, 2], cel.index(0).sort()], cel.index(1).slice(0, 2))"
)
assert program.evaluate({}) == [1, 2]
PY
```

`cel.block(initializers, result)` assigns each initializer a numbered slot. `cel.index(number)` reads that slot. Values and CEL errors are computed once on demand within each block evaluation. Slots capture the scope where the block starts, not the scope at a later reference. Nested blocks have separate slots. No request state is stored in the compiled program.

These names expose the pinned corpus's optimizer/conformance format. They are not ordinary CEL-Go source functions. [Reference notes](conformance/reference/blocks-notes.md) map them to CEL-Go's AST-only operators.

Indices must be nonnegative integer literals. Forward references are allowed. A cycle or missing slot produces an evaluation error when used; unused slots stay unevaluated. Checked compilation validates every initializer and reference, with conservative `dyn` types for unresolved forward dependencies. The initializer list is structural: optional markers do not remove slots or unwrap their values.

`cel.iterVar(depth, id)` and `cel.accuVar(depth, id)` produce private lexical identifiers for optimizer-generated expressions. Their numbers identify names, not runtime stack positions. You can use these identifiers as macro variables, but activation keys cannot supply them.

## List extension

```sh
uv run --project bindings/python python - <<'PY'
from cel import Environment

policy = Environment().compile(
    "[[3, 1], [2, 3]].flatten().distinct().sort().reverse() == [3, 2, 1]"
    " && lists.range(4).sortBy(item, -item).slice(0, 2) == [3, 2]"
)
assert policy.evaluate({}) is True
PY
```

| Function | Behavior |
| --- | --- |
| `list.slice(start, end)` | Selects a half-open range. Indices must be nonnegative integers within the list. |
| `list.flatten()` / `list.flatten(depth)` | Flattens one level by default. Zero preserves nesting; negative depths fail. |
| `list.distinct()` | Retains the first value in each CEL equality group, including mixed numeric aliases. |
| `lists.range(size)` | Produces integers from zero up to, but not including, `size`. |
| `list.reverse()` | Reverses order without mutating the input. |
| `list.sort()` | Sorts values of one comparable type in ascending order. |
| `list.sortBy(item, key)` | Evaluates the receiver once and one key per element, then sorts by those keys. |

Sorting accepts integers, unsigned integers, doubles, booleans, strings, bytes, timestamps, and durations after protobuf wrapper adaptation. Mixed numeric tags are not valid sort keys. Equal keys preserve input order. A NaN in a list with more than one element raises `InvalidArgument`; a singleton needs no comparison. CEL-Go currently discards NaN comparison errors and can reorder equal-key groups. [Reference probes](conformance/reference/lists.txt) retain these differences rather than claiming identical behavior.

All operations obey collection and evaluation-work limits. Scalar deduplication uses hash buckets with CEL equality checks. Compound values use budgeted recursive equality and can still require quadratic work. `sortBy` stops at the first key-expression error and never suppresses a host callback exception. The checker preserves list element types where known; `flatten` returns `list(dyn)`.

## String extension

```sh
uv run --project bindings/python python - <<'PY'
from cel import Program

policy = Program(
    "request.name.trim().lowerAscii().replace(' ', '-').matches('^[a-z-]+$') && "
    "request.labels.split(',').map(x, x.trim().upperAscii()).join('|') == 'ADMIN|READ' && "
    "'%s:%d'.format([request.name.trim(), request.revision]) == 'Alice Smith:3'"
)
assert policy.evaluate({"request": {"name": " Alice Smith ", "labels": "admin, read", "revision": 3}}) is True
assert Program("text.substring(1, 3).reverse()").evaluate({"text": "A😀Z"}) == "Z😀"
PY
```

String indices count Unicode code points, not UTF-8 bytes, UTF-16 units, or grapheme clusters. `charAt`, `substring`, `indexOf`, and `lastIndexOf` use those indices. `lowerAscii` and `upperAscii` change only ASCII letters. `trim` removes Unicode whitespace but preserves zero-width spaces and the byte-order mark. `reverse` reverses code points.

`replace` accepts an optional replacement count; a negative count replaces all matches. `split` accepts an optional maximum number of pieces; zero returns an empty list and a negative count means no piece limit. Empty separators operate at code-point boundaries. `join` joins string list elements with an optional separator. `strings.quote` escapes CEL control characters, double quotes, and backslashes.

`format` supports `%s`, `%d`, `%b`, `%o`, `%x`, `%X`, `%f`, `%e`, and `%%`. Decimal precision applies to fixed and scientific output. Locale-independent C++ standard-library conversion supplies exact binary floating-point rounding, including ties to even. Output size, precision, collection size, and work are bounded before amplification. Extra format values are ignored after the argument list is evaluated.

`%s` formats lists recursively and orders map entries by their formatted keys. Invalid byte runs become one replacement character per run. Duration display uses floating-point seconds as specified; it can lose nanosecond digits, unlike CEL duration arithmetic. [Reference records](conformance/reference/strings.txt) retain differences from current CEL-Go: this SDK follows the pinned search-boundary errors and the specification's collapsed invalid-byte replacement rule. No locale-selection API is exposed.

## Base64 functions

```sh
uv run --project bindings/python python - <<'PY'
from cel import Program

assert Program("base64.encode(data)").evaluate({"data": b"hello"}) == "aGVsbG8="
assert Program("base64.decode(text)").evaluate({"text": "aGVsbG8"}) == b"hello"
assert Program("base64.encodeUrl(data)").evaluate({"data": b"\xff\xff\xff"}) == "____"
PY
```

`base64.encode` and `base64.encodeUrl` return padded standard or URL-safe Base64. Their decoders accept padded and unpadded input and ignore CR/LF, but reject spaces, tabs, malformed padding, and the other alphabet. As in CEL-Go, decoding accepts nonzero unused tail bits; encoding always emits canonical bits and padding. Output and work limits apply before allocation or decoding amplification.

Base64 is a transport encoding, not encryption or authentication. Other encoder-library functions, such as JSON conversion, are not implied by this support.

## IP addresses and network prefixes

```sh
uv run --project bindings/python python - <<'PY'
from cel import CIDR, IPAddress, CELType, Environment

policy = Environment(variables={
    "source": CELType.abstract("net.IP"),
    "network": CELType.abstract("net.CIDR"),
}).compile("network.containsIP(source) && source.isGlobalUnicast() && !source.isLoopback()")
assert policy.evaluate({
    "source": IPAddress("10.24.3.8"),
    "network": CIDR("10.24.0.17/16"),
}) is True
assert IPAddress("2001:0DB8::1").value == "2001:db8::1"
assert CIDR("10.24.0.17/16").value == "10.24.0.17/16"
PY
```

`IPAddress` represents an IPv4 or IPv6 address. `CIDR` represents an address and a prefix length, the number of bits that identify its network. Both wrappers use the Zig parser and expose canonical text in `value`. They preserve their CEL identities across inputs, constants, callbacks, and results. Neither type is a CEL map key.

In CEL, `ip(text)` and `cidr(text)` construct values. `isIP(text)` and `isCIDR(text)` return `false` for malformed strings. `ip.isCanonical(text)` checks spelling but raises an evaluation error for malformed input. Zones, brackets, ports, leading-zero IPv4 components, and every IPv4-mapped IPv6 form are rejected. Parsing performs no DNS lookup or network I/O.

CIDR values retain host bits: `cidr('10.24.0.17/16')` differs from `cidr('10.24.0.0/16')`. Call `.masked()` to clear those bits. Containment ignores host bits and requires matching address families. `.containsIP()` and `.containsCIDR()` accept either typed values or strings; `.ip()` and `.prefixLength()` expose the original address and prefix length.

!!! warning "Global unicast does not mean publicly routable"
    `.isGlobalUnicast()` includes private addresses, matching CEL-Go's network semantics. It excludes unspecified, loopback, link-local unicast, multicast, and IPv4 broadcast addresses. Use an explicit allowlist when deciding which networks may access a service.

Other IP methods are `.family()`, `.isUnspecified()`, `.isLoopback()`, `.isLinkLocalMulticast()`, and `.isLinkLocalUnicast()`. The Zig equivalent is `zig build example-network -Dexamples=true`; you pass `Value.ip` and `Value.cidr` with borrowed fixed-size `IP` and `CIDR` metadata. [Reference notes](conformance/reference/README.md#network-extension) retain corpus and checker-phase disagreements.

## Plain-data fast path

```sh
uv run --project bindings/python python - <<'PY'
from cel import Program

policy = Program('request.method == "GET" && principal.authenticated && (principal.role == "admin" || resource.owner == principal.id)')
request = {
    "request": {"method": "GET"},
    "principal": {"authenticated": True, "role": "member", "id": "user-42"},
    "resource": {"owner": "user-42"},
}
assert policy.has_fast_path
assert policy.evaluate(request, plain_data=True) is True
PY
```

`plain_data=True` runs a Python function compiled from the program when it uses only string, boolean, and integer literals, unquoted field selection, string-keyed indexing, `==`, `!=`, `&&`, `||`, `!`, `?:`, and the `startsWith`, `endsWith`, and `contains` predicates. Bindings must be dictionaries of dictionaries, `str`, `bool`, and int64 `int` values; anything else sends the call to the engine so the result is unchanged. Unused keys are never read in this mode. It is about 1.5x faster than the default path on the authorization and routing benchmarks; the TypeScript binding has the same option as `{ plainData: true }`.

## Regular expressions

```sh
uv run --project bindings/python python - <<'PY'
from cel import EvaluationError, Program

policy = Program(r"path.matches('^/v[0-9]+/orders/[a-z]+$') && user.matches(pattern)")
assert policy({"path": "/v1/orders/abc", "user": "admin-1", "pattern": "^admin"}) is True
assert Program(r"matches('世界', r'\p{Han}+')")({}) is True
assert Program("false && 'text'.matches('(')")({}) is False

try:
    Program("'text'.matches('(')")({})
except EvaluationError as error:
    assert str(error) == "InvalidArgument"
PY
```

Both `string.matches(pattern)` and `matches(string, pattern)` use upstream RE2. Matching searches for a substring unless you add anchors. RE2 rejects lookaround and backreferences rather than running an unsafe backtracking fallback.

A compiled program reuses literal patterns. Dynamic patterns are cached only during one evaluation. Invalid patterns remain evaluation errors, so normal CEL short-circuiting still works. [Native dependency notes](third_party/README.md) document versions, linking, licenses, and allocator limitations.

## Resource limits

```sh
zig build example-limits -Dexamples=true
```

The complete [limits example](examples/limits.zig) sets `max_steps = 2` and prints `CostLimitExceeded`. You pass `Limits` as the third argument to `Program.compile()`.

| Limit | Default |
| --- | --- |
| `max_source_bytes` | 1,048,576 |
| `max_depth` | 128 |
| `max_nodes` | 100,000 |
| `max_steps` | 1,000,000 |
| `max_check_steps` | 1,000,000 |
| `max_collection_size` | 100,000 |
| `regex.max_patterns` | 64 per cache |
| `regex.max_pattern_bytes` | 65,536 |
| `regex.max_memory_bytes` | 1,048,576 per RE2 program/DFA budget |
| `regex.max_program_size` | 10,000 instructions |

Limits cap syntax growth, evaluation nesting, and work on collections. A resource-limit error is not suppressed by logical operators. The language bindings currently use these defaults and additionally bound input conversion to 100,000 values and 1 MiB of string and byte data.

## Tests

```sh
npm ci --prefix bindings/typescript
./scripts/test
./scripts/check
zig build test --fuzz=100000
zig build test --fuzz=100000 -Dtest-filter='dynamic RE2'
zig build test --fuzz=100000 -Dtest-filter='checked source'
zig build test --fuzz=100000 -Dtest-filter='protobuf wire input'
zig build test --fuzz=100000 -Dtest-filter='temporal parsing'
zig build test --fuzz=100000 -Dtest-filter='strong enum conversion'
zig build test --fuzz=100000 -Dtest-filter='typed map key validation'
zig build test --fuzz=100000 -Dtest-filter='optional source'
zig build test --fuzz=100000 -Dtest-filter='math shifts and extrema'
bindings/python/.venv/bin/python conformance/run.py --engine python --mode evaluation --report /tmp/python-evaluation.json
bindings/python/.venv/bin/python conformance/run.py --engine node --mode evaluation --report /tmp/node-evaluation.json
bindings/python/.venv/bin/python conformance/run.py --mode full --report /tmp/full-conformance.json
zig build conformance -Dconformance=true -Doptimize=ReleaseSafe
bindings/python/.venv/bin/python conformance/run.py --engine zig --mode full --report /tmp/zig-conformance.json
```

The tests drive public compile/evaluate APIs. Zig tests also inject every allocator failure. The built-in fuzzer feeds untrusted source through compilation and evaluation. Zig 0.16.0 has an error-trace type mismatch in its fuzz runner, so test builds disable error-return tracing while retaining safety checks.

Python and TypeScript wrapper coverage gates require 100%. Those percentages do not measure Zig/native coverage. Native line coverage is measured separately with kcov on Linux Debug binaries; the [latest record](validation/2026-09-16-native-coverage/) reports 95.66% for the Zig core and C++ bridges with the Zig tests and both corpus modes merged, and lists every uncovered line. Branch coverage and full conformance are still pending. Python, Node, and the direct Zig adapter share the audit corpus and comparison logic. The Zig executable calls the public core API directly, independently of either binding. Full mode additionally accounts for requested type checking and exits with status 1 when any case fails or is unsupported. Evaluation-only results never claim full conformance.

## Build a Python wheel

```sh
uv build --project bindings/python --out-dir dist/python
```

The build creates a source distribution, then builds a native wheel from that distribution. The wheel uses CPython's stable ABI with a Python 3.10 minimum. A wheel remains specific to its operating system and CPU architecture.

## Remaining work

[TODO.md](TODO.md) lists the open work; [PLAN.md](PLAN.md) tracks the full objective: complete CEL semantics, typed and protobuf values, all-language conformance, native coverage, portable packages, and measured performance leadership. Current application workloads are useful evidence, not a substitute for those requirements.
