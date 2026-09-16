from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any, cast

from typing_extensions import Literal, TypeAlias

PlainType: TypeAlias = Literal["bool", "string", "int", "object", "list", "any"]
Plan: TypeAlias = list[Any]
FastFunction: TypeAlias = Callable[[dict[str, Any]], object]

BAIL = object()
"""Returned by a compiled function when the bindings leave its compiled shape; the caller falls back to the engine."""

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1

_ORDERING = ("<", "<=", ">", ">=")
_ARITHMETIC = {"+": "_add", "-": "_sub", "*": "_mul", "/": "_div", "%": "_rem"}
_PREDICATES = ("startsWith", "endsWith", "contains")
_BOOLEAN_KINDS = ("==", "!=", "&&", "||", "!", "in", "all", "exists", *_ORDERING, *_PREDICATES)


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


def _checked(value: int) -> int:
    return value if INT64_MIN <= value <= INT64_MAX else cast(int, _bail())


def _add(a: int, b: int) -> int:
    return _checked(a + b)


def _sub(a: int, b: int) -> int:
    return _checked(a - b)


def _mul(a: int, b: int) -> int:
    return _checked(a * b)


def _div(a: int, b: int) -> int:
    if b == 0:
        _bail()
    quotient = abs(a) // abs(b)
    return _checked(quotient if (a < 0) == (b < 0) else -quotient)


def _rem(a: int, b: int) -> int:
    if b == 0:
        _bail()
    return a - b * _div(a, b)


def _size(value: object) -> int:
    if type(value) is str:
        return len(value) if _well_formed(value) else cast(int, _bail())
    return len(value) if type(value) is list else cast(int, _bail())


def _infer(node: Plan) -> PlainType | None:
    """Static type of a plan node when the node itself determines it; reads have none."""
    kind = node[0]
    if kind in ("bool", "string", "int", "list"):
        return cast(PlainType, kind)
    if kind == "size" or kind == "neg" or kind in _ARITHMETIC:
        return "int"
    if kind == "?:":
        return _infer(node[2]) or _infer(node[3])
    if kind in _BOOLEAN_KINDS:
        return "bool"
    return None


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
        # Comprehension variables in scope, innermost last, mapped to the Python local that holds them.
        self.scopes: list[dict[str, str]] = []

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
        if expected == "any":
            return name
        if expected == "object":
            check = f"type({name}) is not dict"
        elif expected == "list":
            check = f"type({name}) is not list"
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

    def local(self, name: str) -> str | None:
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        return None

    def emit(self, node: Plan, expected: PlainType, indent: str, *, checked_text: bool = True) -> str | None:
        kind = node[0]
        if kind in ("bool", "string", "int"):
            return repr(node[1]) if kind == expected else None
        if expected == "any" and kind not in ("ident", "select", "index"):
            return None
        if kind == "ident":
            local = self.local(node[1])
            if local is not None:
                return self.read(local, expected, indent, checked_text=checked_text)
            if expected == "object":
                return self.root_object(node[1])
            return self.read(f"b.get({node[1]!r}, _MISSING)", expected, indent, checked_text=checked_text)
        if kind == "select":
            qualified = _qualified_name(node)
            if qualified is not None and self.local(qualified.split(".", 1)[0]) is None:
                self.dotted.add(qualified)
            target = self.emit(node[1], "object", indent)
            if target is None:
                return None
            source = f"{target}.get({node[2]!r}, _MISSING)"
            if expected == "object":
                return self.cached_object(f"{target}.{node[2]}", source, indent)
            return self.read(source, expected, indent, checked_text=checked_text)
        if kind == "index":
            key_type = _infer(node[2]) or "string"
            if key_type == "string":
                target = self.emit(node[1], "object", indent)
                key = self.emit(node[2], "string", indent, checked_text=False)
                if target is None or key is None:
                    return None
                return self.read(f"{target}.get({key}, _MISSING)", expected, indent, checked_text=checked_text)
            if key_type != "int":
                return None
            target = self.emit(node[1], "list", indent)
            key = self.emit(node[2], "int", indent)
            if target is None or key is None:
                return None
            source = f"{target}[{key}] if 0 <= {key} < len({target}) else _MISSING"
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
            kind_type = _infer(node[1]) or _infer(node[2]) or "string"
            if kind_type in ("object", "list", "any"):
                return None
            literal_side = _literal_type(node[1]) or _literal_type(node[2])
            against_literal = kind_type == "string" and literal_side is not None
            left = self.emit(node[1], kind_type, indent, checked_text=not against_literal)
            right = self.emit(node[2], kind_type, indent, checked_text=not against_literal)
            if left is None or right is None:
                return None
            return f"({left} {kind} {right})"
        if kind in _ORDERING:
            # Only integers order the same way here and in CEL; strings would need code-point order.
            if expected != "bool":
                return None
            left = self.emit(node[1], "int", indent)
            right = self.emit(node[2], "int", indent)
            if left is None or right is None:
                return None
            return f"({left} {kind} {right})"
        if kind in _ARITHMETIC:
            if expected != "int":
                return None
            left = self.emit(node[1], "int", indent)
            right = self.emit(node[2], "int", indent)
            if left is None or right is None:
                return None
            return f"{_ARITHMETIC[kind]}({left}, {right})"
        if kind == "neg":
            if expected != "int":
                return None
            operand = self.emit(node[1], "int", indent)
            return None if operand is None else f"_checked(-{operand})"
        if kind == "!":
            if expected != "bool":
                return None
            operand = self.emit(node[1], "bool", indent)
            return None if operand is None else f"(not {operand})"
        if kind == "size":
            if expected != "int":
                return None
            inner_type = _infer(node[1])
            if inner_type == "string":
                text = self.emit(node[1], "string", indent)
                return None if text is None else f"len({text})"
            if inner_type is not None:
                return None
            value = self.emit(node[1], "any", indent)
            return None if value is None else f"_size({value})"
        if kind == "in":
            if expected != "bool" or node[2][0] != "list":
                return None
            needle = self.emit(node[1], "string", indent, checked_text=False)
            return None if needle is None else f"({needle} in {set(node[2][1:])!r})"
        if kind in ("all", "exists"):
            if expected != "bool":
                return None
            items = self.emit(node[1], "list", indent)
            if items is None:
                return None
            result, element = self.fresh(), self.fresh()
            self.lines.append(f"{indent}{result} = {kind == 'all'}")
            self.lines.append(f"{indent}for {element} in {items}:")
            self.scopes.append({node[2]: element})
            predicate = self.emit(node[3], "bool", indent + "    ")
            self.scopes.pop()
            if predicate is None:
                return None
            self.lines.append(f"{indent}    if {'not ' if kind == 'all' else ''}{predicate}:")
            self.lines.append(f"{indent}        {result} = {kind != 'all'}")
            self.lines.append(f"{indent}        break")
            return result
        if kind == "?:":
            if expected in ("object", "list", "any"):
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
        if kind in _PREDICATES:
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
    return cast(PlainType, kind) if kind in ("bool", "string", "int") else None


def compile_plain(plan: str | None) -> FastFunction | None:
    """Compile a `Program` plain-data plan into a Python function, or return None when it is refused.

    The function returns the CEL result for plain dictionaries of dictionaries, lists, strings, booleans,
    and int64 integers, and `BAIL` when any value falls outside that shape.
    """
    if plan is None:
        return None
    root: Plan = json.loads(plan)
    result_type = _infer(root)
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
        "_checked": _checked,
        "_add": _add,
        "_sub": _sub,
        "_mul": _mul,
        "_div": _div,
        "_rem": _rem,
        "_size": _size,
        "_MISSING": BAIL,
        "BAIL": BAIL,
        "_Bail": _Bail,
        "_dotted": frozenset(compiler.dotted),
    }
    exec(compile(source, "<cel-plain-data>", "exec"), namespace)
    fast: FastFunction = namespace["fast"]
    return fast
