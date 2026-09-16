from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any, cast

from typing_extensions import Literal, TypeAlias

PlainType: TypeAlias = Literal["bool", "string", "int", "object"]
Plan: TypeAlias = list[Any]
FastFunction: TypeAlias = Callable[[dict[str, Any]], object]

BAIL = object()
"""Returned by a compiled function when the bindings leave its compiled shape; the caller falls back to the engine."""

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1


class _Bail(Exception):
    """Raised inside generated code when a value falls outside the compiled shape."""


def _bail() -> object:
    raise _Bail


def _well_formed(text: str) -> bool:
    if text.isascii():
        return True
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _result_type(node: Plan) -> PlainType | None:
    kind = node[0]
    if kind in ("bool", "string"):
        return cast(PlainType, kind)
    if kind == "?:":
        return _result_type(node[2]) or _result_type(node[3])
    if kind in ("ident", "select", "index", "int"):
        return None
    return "bool"


class _Compiler:
    def __init__(self) -> None:
        self.lines: list[str] = []
        # Root bindings are read once at function start. The engine converts every binding before it
        # evaluates anything, so a non-dictionary root fails there regardless of control flow.
        self.roots: list[str] = []
        self.counter = 0
        # Object reads are cached per lexical block so `a.b == 1 && a.c == 2` reads `a` once. Blocks are
        # keyed by indentation because a read made inside a conditional branch is not in scope afterwards.
        self.objects: dict[tuple[str, str], str] = {}
        # Qualified names such as `request.method` that the engine would resolve as dotted binding keys.
        self.dotted: set[str] = set()

    def fresh(self) -> str:
        self.counter += 1
        return f"v{self.counter}"

    def cached_object(self, path: str, source: str, indent: str) -> str:
        # A read made at an enclosing indentation is still in scope; a deeper or sibling block's is not.
        for depth in range(len(indent), -1, -4):
            cached = self.objects.get((indent[:depth], path))
            if cached is not None:
                return cached
        name = self.read(source, "object", indent, checked_text=False)
        self.objects[(indent, path)] = name
        return name

    def root_object(self, name: str) -> str:
        cached = self.objects.get(("", name))
        if cached is not None:
            return cached
        variable = self.fresh()
        self.roots.append(f"        {variable} = b.get({name!r}, _MISSING)")
        self.roots.append(f"        if type({variable}) is not dict: _bail()")
        self.objects[("", name)] = variable
        return variable

    def read(self, source: str, expected: PlainType, indent: str, *, checked_text: bool) -> str:
        name = self.fresh()
        self.lines.append(f"{indent}{name} = {source}")
        if expected == "object":
            check = f"type({name}) is not dict"
        elif expected == "string":
            # A lone surrogate can never equal a well-formed literal, so the encode check is only needed
            # when the string itself is compared with another read or returned.
            check = f"type({name}) is not str" + ("" if not checked_text else f" or not _well_formed({name})")
        elif expected == "bool":
            check = f"type({name}) is not bool"
        else:
            check = f"type({name}) is not int or not {INT64_MIN} <= {name} <= {INT64_MAX}"
        self.lines.append(f"{indent}if {check}: _bail()")
        return name

    def emit(self, node: Plan, expected: PlainType, indent: str, *, checked_text: bool = True) -> str | None:
        kind = node[0]
        if kind in ("bool", "string", "int"):
            return repr(node[1]) if kind == expected else None
        if kind == "ident":
            if expected == "object":
                return self.root_object(node[1])
            return self.read(f"b.get({node[1]!r}, _MISSING)", expected, indent, checked_text=checked_text)
        if kind in ("select", "index"):
            if kind == "select":
                qualified = _qualified_name(node)
                if qualified is not None:
                    self.dotted.add(qualified)
            target = self.emit(node[1], "object", indent)
            if target is None:
                return None
            source = f"{target}.get({node[2]!r}, _MISSING)"
            if expected == "object":
                return self.cached_object(f"{target}.{node[2]}", source, indent)
            return self.read(source, expected, indent, checked_text=checked_text)
        if kind in ("&&", "||"):
            if expected != "bool":
                return None
            left = self.emit(node[1], "bool", indent)
            if left is None:
                return None
            result = self.fresh()
            self.lines.append(f"{indent}{result} = {left}")
            self.lines.append(f"{indent}if {'' if kind == '&&' else 'not '}{result}:")
            right = self.emit(node[2], "bool", indent + "    ")
            if right is None:
                return None
            self.lines.append(f"{indent}    {result} = {right}")
            return result
        if kind in ("==", "!="):
            if expected != "bool":
                return None
            kind_type = _literal_type(node[1]) or _literal_type(node[2]) or "string"
            against_literal = kind_type == "string" and (_literal_type(node[1]) or _literal_type(node[2])) is not None
            left = self.emit(node[1], kind_type, indent, checked_text=not against_literal)
            right = self.emit(node[2], kind_type, indent, checked_text=not against_literal)
            if left is None or right is None:
                return None
            return f"({left} {kind} {right})"
        if kind == "!":
            if expected != "bool":
                return None
            operand = self.emit(node[1], "bool", indent)
            return None if operand is None else f"(not {operand})"
        if kind == "?:":
            if expected == "object":
                return None
            condition = self.emit(node[1], "bool", indent)
            if condition is None:
                return None
            result = self.fresh()
            self.lines.append(f"{indent}if {condition}:")
            yes = self.emit(node[2], expected, indent + "    ")
            if yes is None:
                return None
            self.lines.append(f"{indent}    {result} = {yes}")
            self.lines.append(f"{indent}else:")
            no = self.emit(node[3], expected, indent + "    ")
            if no is None:
                return None
            self.lines.append(f"{indent}    {result} = {no}")
            return result
        if kind in ("startsWith", "endsWith", "contains"):
            if expected != "bool":
                return None
            # Predicates against a well-formed literal cannot be fooled by a lone surrogate either.
            literal_argument = _literal_type(node[2]) == "string"
            receiver = self.emit(node[1], "string", indent, checked_text=not literal_argument)
            argument = self.emit(node[2], "string", indent, checked_text=not literal_argument)
            if receiver is None or argument is None:
                return None
            if kind == "contains":
                return f"({argument} in {receiver})"
            return f"{receiver}.{kind.lower()}({argument})"
        return None


def _qualified_name(node: Plan) -> str | None:
    """The dotted binding name an unquoted select chain could resolve to, or None for other shapes."""
    if node[0] == "ident":
        return str(node[1])
    if node[0] == "select":
        prefix = _qualified_name(node[1])
        return None if prefix is None else f"{prefix}.{node[2]}"
    return None


def _literal_type(node: Plan) -> PlainType | None:
    kind: str = node[0]
    return kind if kind in ("bool", "string", "int") else None  # type: ignore[return-value]


def compile_plain(plan: str | None) -> FastFunction | None:
    """Compile a `Program` plain-data plan into a Python function, or return None when it is refused.

    The function returns the CEL result for plain dictionaries of dictionaries, strings, booleans, and
    int64 integers, and `BAIL` when any value falls outside that shape.
    """
    if plan is None:
        return None
    root: Plan = json.loads(plan)
    result_type = _result_type(root)
    if result_type not in ("bool", "string"):
        return None
    compiler = _Compiler()
    body = compiler.emit(root, result_type, "        ")
    if body is None:
        return None
    source = "\n".join(
        [
            "def fast(b):",
            "    if type(b) is not dict: return BAIL",
            *(["    if not _dotted.isdisjoint(b): return BAIL"] if compiler.dotted else []),
            "    try:",
            *compiler.roots,
            *compiler.lines,
            f"        return {body}",
            "    except _Bail:",
            "        return BAIL",
        ]
    )
    namespace: dict[str, Any] = {
        "_bail": _bail,
        "_well_formed": _well_formed,
        "_MISSING": BAIL,
        "BAIL": BAIL,
        "_Bail": _Bail,
        "_dotted": frozenset(compiler.dotted),
    }
    exec(compile(source, "<cel-plain-data>", "exec"), namespace)
    fast: FastFunction = namespace["fast"]
    return fast
