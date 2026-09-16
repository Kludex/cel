# Indexed block reference notes

Reference commits:

- `cel-spec`: `ba58ae5007845f3a1279b488cdeb79645ce958bb`
- `cel-go`: `16c2ebb13679d18704cee890f3fdc861fe2ca7b1`

Reproduce from the SDK repository root:

```sh
probe="$PWD/conformance/reference/blocks.go"
(cd /tmp/cel-go-reference && go run "$probe")
```

`blocks.txt` is the captured output. The probe uses exported `cel`, `ast`, and `ext` APIs. It does not call the private block runtime types.

## Source and AST mapping

The `block_ext.textproto` header calls `cel.block`, `cel.index`, `cel.iterVar`, and `cel.accuVar` test-only macros. They are not installed by `ext.Bindings()`. CEL-Go's conformance-only library maps them as follows:

- `cel.block(slots, result)` -> `cel.@block(slots, result)`
- `cel.index(n)` -> `@indexN`
- `cel.iterVar(depth, unique)` -> `@it:depth:unique`
- `cel.accuVar(depth, unique)` -> `@ac:depth:unique`

The spec comment saying `cel.block` rewrites to `cel.block` conflicts with CEL-Go's conformance macro and runtime. The operational AST name is `cel.@block`. Neither `cel.@block` nor `@indexN` is valid parser input because `@` is rejected. Optimizers create these nodes with the public AST factory and add typed index declarations while checking. This probe mirrors the conformance harness by declaring index aliases as `dyn`.

## Observed rules

- Slots are lazy and memoized once per evaluation, including CEL error values. Unused slots are skipped. Reusing a `cel.Program` starts with empty slots on every evaluation.
- Optional markers on the structural slot list do not compact indices or unwrap values. A marked initializer remains `optional(1)` or `optional.none()` in its original slot.
- A forward reference is accepted. Self, negative, and out-of-range references resolve as missing attributes. Source `cel.index(-1)` is rejected earlier by its test macro.
- Nested blocks have separate frames. The nearest block owns the same `@indexN` spelling.
- A slot evaluates in the frame present when its block starts, not the frame at the reference site. A slot hoisted outside a comprehension cannot capture that comprehension's iteration variable. Checked construction rejects it; unchecked execution also returns a missing-attribute error. Keeping the block inside the comprehension yields `[11, 12]`.
- `@it:depth:unique` names are ordinary comprehension identifiers after macro expansion. Their numbers provide collision-free lexical names, not runtime lookup behavior.
- An empty block evaluates its result. Planning requires exactly two arguments and a list constructor as the first argument. The runtime also accepts a list constant produced by optimization.

## Unresolved

The pinned language repository has no normative block extension document beyond the test-only corpus. It does not define whether hand-built noncanonical aliases or forward references must be portable, even though pinned CEL-Go accepts forward references.
