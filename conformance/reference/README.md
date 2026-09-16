# CEL-Go semantic probes

```sh
probe="$PWD/conformance/reference-probe.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

Run this from the SDK repository root. `cel-go.jsonl` records the observed output from CEL-Go commit [`16c2ebb13679d18704cee890f3fdc861fe2ca7b1`](https://github.com/cel-expr/cel-go/commit/16c2ebb13679d18704cee890f3fdc861fe2ca7b1), using its public parse/program/evaluate APIs with two-variable comprehensions enabled. This is a functional probe, not a benchmark or complete differential suite. The unchecked `has(a.b.c)` case returns an integer in this reference configuration; that observation is not treated as normative boolean-presence behavior.

## Decisions supported by the probe

- Only matching macro signatures expand. Calls such as `[].map(x)` remain ordinary calls instead of producing syntax errors solely because of their arity.
- `.has(...)` is an absolute function call, not the `has(...)` macro.
- `int(-9223372036854775808.0)` raises overflow. The pinned language definition explicitly excludes both integer endpoints for double-to-int conversions in its **Overflow** section.
- Qualified variable names use longest-prefix resolution. Comprehension variables shadow unqualified roots; a leading dot bypasses that local scope.

## Generic runtime erasure

```sh
probe="$PWD/conformance/reference/function-generics.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`function-generics.txt` records a public custom-function probe on the same reference commit. A shared `(T, T)` signature rejects `same(1, 'x')` while checking, but accepts `same(dyn(1), 'x')` and `same(dyn(1), dyn('x'))` at runtime. The SDK preserves that erasure instead of enforcing a new runtime type-equality rule after `dyn` removed the static constraint.

The pinned language definition also requires overload argument types to be non-overlapping after type-variable erasure. The SDK rejects alpha-equivalent signatures such as `(T) -> T` and `(U) -> U` under the same function name.

## Optional edge behavior

```sh
probe="$PWD/conformance/reference/optionals.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`optionals.txt` retains the observed results. An absent optional skips a later index expression, including division by zero. Optional wrappers themselves are not zero values, and timestamp zero is year 1 rather than the Unix epoch. Fractional list indexes are errors, not absent entries. Public SDK tests protect these behaviors.

Not every reference configuration is normative: the pinned corpus expects an error for invalid field access on a present scalar, while newer optional-library configurations may tolerate bad presence tests. The SDK keeps the pinned cases visible and does not claim the probe is a complete differential suite.

## Math extension

```sh
probe="$PWD/conformance/reference/math.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`math.txt` records public checks for dynamic extrema result types, first-tie selection, NaN comparisons, empty extrema, and fixed-width shifts. In particular, `math.greatest(1, dyn(2.5))` has dynamic type, and signed right shift is logical. These observations informed separate public SDK tests rather than replacing the pinned corpus.

## List extension

```sh
probe="$PWD/conformance/reference/lists.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`lists.txt` records receiver/key evaluation counts, scope shadowing, invalid macro forms, numeric aliases, nested equality, container lookup, and inferred types. Equal-key groups may reorder in CEL-Go. NaN comparison errors are discarded inside its sorting callback. The SDK instead preserves equal-key order and rejects NaNs in multi-element sorts; these are explicit differences, not claims of matching every reference edge case.

The SDK preserves list types with dynamic elements instead of choosing CEL-Go's ambiguous overload result (`dyn`, or `list(int)` for an empty literal). Pinned corpus agreement does not resolve these wider checker differences.

## Local bindings

```sh
probe="$PWD/conformance/reference/bindings.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`bindings.txt` records lazy initialization, cached values and CEL errors, repeated evaluations, lexical capture, and macro namespace rules. It also shows that `.x` is accepted as a binding name, but absolute `.x` references bypass that binding. `.cel.bind` does not expand the macro and can invoke a custom declared function instead.

The probe's `probe.fail` function returns a CEL `types.NewErr` value. That is not a Python or JavaScript host exception. This SDK's host exceptions remain fatal under the existing callback contract.

## Indexed blocks

```sh
probe="$PWD/conformance/reference/blocks.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

The probe installs the conformance-only source aliases and uses public AST APIs to exercise CEL-Go's block runtime. [Mapping notes](blocks-notes.md) distinguish the `cel.block` source helper from the `cel.@block` AST-only operator.

`blocks.txt` records lazy values/errors, forward references, cycles, nested frames, lexical iteration handles, and slot initialization outside use-site scopes. It also records optional slot markers retaining their values rather than compacting the slot list. The pinned repository has no normative block document beyond this test format, so broader portability is not inferred from these cases.

## String extension

```sh
probe="$PWD/conformance/reference/strings.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`strings.txt` records code-point operations, search boundaries, formatting, precision, extra arguments, and duration display. Finite fixed/scientific formatting is also checked against Python's independent formatter over 200 generated binary doubles.

The pinned string-extension corpus expects out-of-range search errors; this newer CEL-Go revision returns `-1` or clamps empty-needle searches in some of those cases. The SDK keeps the pinned behavior. The pinned `doc/extensions/strings.md` requires one replacement character per adjacent invalid byte run; CEL-Go currently emits multiple replacements. The SDK follows the document.

Duration `%s` display intentionally uses floating-point seconds in both the document and CEL-Go. That can lose nanosecond digits; it does not change this SDK's exact duration storage or arithmetic. The document's `%d` table omits doubles, but its example and CEL-Go accept them; the SDK accepts that documented example. These discrepancies remain evidence, not claims of complete independent compatibility.

## Protobuf helpers and Base64

```sh
probe="$PWD/conformance/reference/proto-encoders.go"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe")
```

`proto-encoders.txt` records extension presence/defaults, repeated fields, wrong containing messages, quoted names, macro precedence, and map receivers. Names are captured literally; relative or leading-dot extension paths are not container-expanded.

The Base64 probe confirms padded output, padded/unpadded input, CR/LF skipping, rejection of other whitespace and mismatched alphabets, and acceptance of nonzero unused tail bits. The SDK preserves this decoder behavior and emits canonical encoding. URL-safe operations are included in the current reference defaults, but encoder-library JSON functions are outside this implemented surface.

## Network extension

```sh
probe="$PWD/conformance/reference/network.go"
workloads="$PWD/benchmarks/workloads.json"
reference="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-go.git "$reference"
git -C "$reference" checkout 16c2ebb13679d18704cee890f3fdc861fe2ca7b1
(cd "$reference" && go run "$probe" "$workloads")
```

`network.txt` records checking and unchecked execution separately, plus all seven complete gateway-policy decisions. The larger 600-prefix gateway workload also agrees with CEL-Go. Python's standard `ipaddress` library independently checks canonical spelling, masking, and containment across 300 generated IPv4/IPv6 cases.

Both SDKs reject every IPv4-mapped IPv6 representation. Two pinned cases nevertheless expect hexadecimal mapped addresses to compare as IPv4, while another case explicitly rejects the equivalent dotted notation. Those two disagreements remain audit failures. Another case is named `is_ip_cidr_compile_error` but requests `evalError`; this SDK and CEL-Go correctly reject its overload during checking. That phase disagreement also remains visible.

CEL-Go additionally validates malformed literal constructor arguments during checking. This SDK checks their types, then rejects invalid text during evaluation. CIDR preserves host bits until `.masked()`; containment requires matching families. Global unicast classification includes private addresses and must not be mistaken for public routability.

## Mixed numeric comparison

```sh
probe="$PWD/conformance/reference/numeric.go"
expressions="$PWD/validation/2026-09-16-numeric/expressions.json"
(cd "$reference" && go run "$probe" "$expressions" /tmp/cel-go-results.json)
```

CEL-Go (`common/types/compare.go`, `compareDoubleInt`/`compareDoubleUint`) and CEL-C++ (`internal/number.h`, `DoubleCompareVisitor` at commit `8d22c5b66f28dc5f72b99b5c70fabd7587a592f2`) implement the same algorithm: a double is first clamped against the integer range (`d < MinInt64`, `d > MaxInt64`, `d < 0`, `d > MaxUint64`, each computed against the double-rounded bound), and otherwise the integer is converted to double and the two doubles are ordered. Integers beyond 2^53 therefore round before comparison, which is why `9223372036854775807 == 9223372036854775808.0` and `9007199254740993 == 9007199254740992.0` are both true, while `9223372036854775807 < 9223372036854777857.0` is also true.

The pinned language definition's **Numbers** section describes a continuous number line, and an exact comparison was this SDK's earlier reading of that text. Both reference implementations and the pinned corpus (`comparisons/*_literal/*lossy*`, whose descriptions say "the conversion of the int to double is lossy") encode the rounding behavior, so this SDK now implements it. `validation/2026-09-16-numeric/` records 4,000 generated cross-type comparisons across all six operators agreeing with CEL-Go's runtime and with an independent transcription of CEL-C++'s visitors, with zero mismatches. Extrema (`math.greatest`/`math.least`) keep the first argument on such ties, matching CEL-Go.
