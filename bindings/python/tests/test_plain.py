from __future__ import annotations

import json
from pathlib import Path

import pytest
from cel import CELType, Environment, EvaluationError, Program, Value
from cel.plain import compile_plain

WORKLOADS = json.loads((Path(__file__).resolve().parents[3] / "benchmarks/workloads.json").read_text())


def test_plain_data_mode_agrees_with_the_engine_on_every_workload_decision() -> None:
    fast = 0
    for workload in WORKLOADS:
        program = Program(workload["expression"])
        fast += program.has_fast_path
        for case in workload["cases"]:
            assert program.evaluate(case["bindings"], plain_data=True) == case["expected"], case["name"]
            assert program.evaluate(case["bindings"]) == case["expected"]
    assert fast == 4
    for index in (0, 1, 2, 3):
        assert Program(WORKLOADS[index]["expression"]).has_fast_path, WORKLOADS[index]["name"]


def test_plain_data_mode_bails_to_the_engine_on_every_type_or_shape_surprise() -> None:
    program = Program("request.method == 'GET' && principal.count == 3 && principal.ok")
    assert program.has_fast_path
    good: dict[str, Value] = {"request": {"method": "GET"}, "principal": {"count": 3, "ok": True}}
    assert program.evaluate(good, plain_data=True) is True
    surprises: list[dict[str, Value]] = [
        {"request": {"method": "GET"}, "principal": {"count": True, "ok": True}},
        {"request": {"method": "GET"}, "principal": {"count": 3.0, "ok": True}},
        {"request": {"method": "GET"}, "principal": {"count": 2**63, "ok": True}},
        {"request": {"method": "GET"}, "principal": {"count": -(2**63) - 1, "ok": True}},
        {"request": {"method": 5}, "principal": {"count": 3, "ok": True}},
        {"request": {"method": "GET"}, "principal": {"count": 3, "ok": True}, "principal.ok": False},
        {"request": {"method": "GET"}, "principal": {"count": 3, "ok": True}, "request.method": "POST"},
    ]
    for bindings in surprises:
        try:
            expected: object = program.evaluate(bindings)
        except (EvaluationError, OverflowError, TypeError) as error:
            with pytest.raises(type(error)):
                program.evaluate(bindings, plain_data=True)
        else:
            assert program.evaluate(bindings, plain_data=True) == expected, list(bindings)
    erroring: list[dict[str, Value]] = [
        {"request": {"method": "GET"}, "principal": {"count": 3, "ok": 1}},
        {"request": ["GET"], "principal": {"count": 3, "ok": True}},
    ]
    for bindings in erroring:
        with pytest.raises(EvaluationError, match="NoMatchingOverload"):
            program.evaluate(bindings, plain_data=True)
    with pytest.raises(EvaluationError, match="UndeclaredReference"):
        program.evaluate({"principal": good["principal"]}, plain_data=True)
    with pytest.raises(EvaluationError, match="NoSuchKey"):
        program.evaluate({"request": {}, "principal": good["principal"]}, plain_data=True)
    with pytest.raises(TypeError):
        program.evaluate(None, plain_data=True)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        program.evaluate(good, plain_data="yes")  # type: ignore[arg-type]
    lone = Program("x == x")
    with pytest.raises(UnicodeEncodeError):
        lone.evaluate({"x": "\ud800"})
    with pytest.raises(UnicodeEncodeError):
        lone.evaluate({"x": "\ud800"}, plain_data=True)
    assert lone.evaluate({"x": "ok \U0001f600"}, plain_data=True) is True


def test_plain_data_mode_keeps_logical_semantics_and_string_results() -> None:
    assert Program("a.flag || b.value == 'x'").evaluate({"a": {"flag": True}, "b": {}}, plain_data=True) is True
    assert Program("!a.flag && b.value != 'y'").evaluate({"a": {"flag": False}, "b": {"value": "x"}}, plain_data=True)
    assert Program("a.b.c.d == 'deep'").evaluate({"a": {"b": {"c": {"d": "deep"}}}}, plain_data=True) is True
    predicates = Program("s.startsWith('ab') && s.endsWith('yz') && s.contains('mn')")
    assert predicates.evaluate({"s": "abmnyz"}, plain_data=True)
    route = Program(
        'request.path.startsWith("/admin") ? "admin" : '
        'request.path.startsWith("/api") && request.headers["x-canary"] == "1" ? "canary" : "default"'
    )
    assert route.has_fast_path
    assert route.evaluate({"request": {"path": "/admin/x", "headers": {}}}, plain_data=True) == "admin"
    assert route.evaluate({"request": {"path": "/api/x", "headers": {"x-canary": "1"}}}, plain_data=True) == "canary"
    with pytest.raises(EvaluationError, match="NoSuchKey"):
        route.evaluate({"request": {"path": "/api/x", "headers": {}}}, plain_data=True)
    label = Program("flag ? name : 'none'")
    assert label.evaluate({"flag": True, "name": 5}, plain_data=True) == 5
    assert Program("m['k'] == 1 ? 'one' : 'other'").evaluate({"m": {"k": 1}}, plain_data=True) == "one"
    # A nested object read in the outer block is reused inside a later branch.
    nested = Program("a.b.c == 'x' && (a.b.d == 'y' || a.b.e == 'z')")
    assert nested.evaluate({"a": {"b": {"c": "x", "d": "n", "e": "z"}}}, plain_data=True) is True
    assert nested.has_fast_path and nested.has_fast_path


def test_programs_outside_the_subset_report_no_fast_path_and_still_evaluate() -> None:
    for source in ["a.b < 'x'", "has(a.b)", "a.`b-c` == 1", "size(a) == 1", "a == 1.5", "flag ? 1 : 'x'"]:
        assert not Program(source).has_fast_path, source
    assert Program("size(a) == 1").evaluate({"a": [2]}, plain_data=True) is True
    assert not Environment(container="ns").compile("a.b == 1", check=False).has_fast_path
    assert not Environment(variables={"a": CELType("string")}).compile("a == 'x'").has_fast_path


def test_hand_built_plans_outside_the_vocabulary_are_refused() -> None:
    assert compile_plain(None) is None
    for plan in [
        ["size", ["ident", "a"]],
        ["&&", ["ident", "a"], ["string", "x"]],
        ["!", ["string", "x"]],
        ["startsWith", ["ident", "a"], ["int", 1]],
        ["int", 1],
        ["ident", "a"],
        ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]],
        ["?:", ["ident", "f"], ["int", 1], ["int", 2]],
        ["select", ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]], "c"],
        ["==", ["string", "x"], ["==", ["ident", "a"], ["ident", "b"]]],
        ["==", ["string", "x"], ["!", ["ident", "a"]]],
        ["==", ["string", "x"], ["contains", ["ident", "a"], ["string", "b"]]],
        ["==", ["select", ["size", ["ident", "a"]], "c"], ["string", "x"]],
        ["<", ["nonsense"], ["int", 1]],
        ["<", ["int", 1], ["nonsense"]],
        ["==", ["int", 1], ["+", ["nonsense"], ["int", 1]]],
        ["==", ["int", 1], ["+", ["int", 1], ["nonsense"]]],
        ["==", ["int", 1], ["neg", ["nonsense"]]],
        ["==", ["string", "x"], ["neg", ["ident", "a"]]],
        ["==", ["string", "x"], ["+", ["ident", "a"], ["ident", "b"]]],
        ["==", ["string", "x"], ["<", ["ident", "a"], ["ident", "b"]]],
        ["==", ["string", "x"], ["in", ["ident", "a"], ["list", "x"]]],
        ["in", ["nonsense"], ["list", "x"]],
        ["in", ["ident", "a"], ["ident", "b"]],
        ["==", ["string", "x"], ["all", ["ident", "xs"], "x", ["bool", True]]],
        ["all", ["nonsense"], "x", ["bool", True]],
        ["all", ["ident", "xs"], "x", ["nonsense"]],
        ["==", ["string", "x"], ["size", ["ident", "a"]]],
        ["==", ["int", 1], ["size", ["int", 1]]],
        ["==", ["int", 1], ["size", ["nonsense"]]],
        ["==", ["string", "s"], ["index", ["ident", "m"], ["nonsense"]]],
        ["==", ["string", "s"], ["index", ["ident", "m"], ["bool", True]]],
        ["==", ["string", "s"], ["index", ["nonsense"], ["string", "k"]]],
        ["==", ["string", "s"], ["index", ["nonsense"], ["int", 0]]],
        ["==", ["string", "s"], ["index", ["ident", "m"], ["+", ["nonsense"], ["int", 1]]]],
        ["==", ["string", "s"], ["?:", ["nonsense"], ["string", "a"], ["string", "b"]]],
        ["==", ["string", "s"], ["?:", ["ident", "f"], ["nonsense"], ["string", "b"]]],
        ["==", ["string", "s"], ["?:", ["ident", "f"], ["string", "a"], ["nonsense"]]],
        ["==", ["ident", "a"], ["list", "x"]],
        ["&&", ["nonsense"], ["ident", "b"]],
        ["==", ["string", "s"], ["&&", ["ident", "a"], ["ident", "b"]]],
        ["&&", ["ident", "a"], ["nonsense"]],
        ["!", ["nonsense"]],
        ["startsWith", ["nonsense"], ["string", "x"]],
        ["startsWith", ["ident", "a"], ["nonsense"]],
        ["contains", ["size", ["ident", "a"]], ["string", "x"]],
        ["contains", ["ident", "a"], ["size", ["ident", "b"]]],
        ["&&", ["size", ["ident", "a"]], ["ident", "b"]],
        ["==", ["select", ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]], "c"], ["string", "x"]],
        ["?:", ["size", ["ident", "f"]], ["string", "a"], ["string", "b"]],
        ["?:", ["ident", "f"], ["string", "a"], ["int", 1]],
    ]:
        assert compile_plain(json.dumps(plan)) is None, plan
    constant = compile_plain(json.dumps(["==", ["string", "x"], ["string", "x"]]))
    assert constant is not None and constant({}) is True
    literal = compile_plain(json.dumps(["string", "x"]))
    assert literal is not None and literal({}) == "x"
    compiled = compile_plain(json.dumps(["==", ["ident", "a"], ["int", 1]]))
    assert compiled is not None
    assert compiled({"a": 1}) is True and compiled({"a": 2}) is False
    boolean_equality = compile_plain(json.dumps(["==", ["&&", ["ident", "a"], ["ident", "b"]], ["ident", "c"]]))
    assert boolean_equality is not None and boolean_equality({"a": True, "b": False, "c": False}) is True
    literal_size = compile_plain(json.dumps(["==", ["int", 3], ["size", ["string", "abc"]]]))
    assert literal_size is not None and literal_size({}) is True
    empty_in = compile_plain(json.dumps(["in", ["ident", "a"], ["list"]]))
    assert empty_in is not None and empty_in({"a": "x"}) is False


def test_plain_data_mode_compiles_ordering_arithmetic_size_membership_and_comprehensions() -> None:
    program = Program(
        "items.size() > 0 && items.size() <= 3 && items.all(i, i.qty > 0 && i.qty <= stock[i.sku] && "
        "i.price * i.qty <= 1000) && tags[0] != '' && codes.all(c, c in ['A', 'B']) && name.size() >= 3"
    )
    assert program.has_fast_path
    good: dict[str, Value] = {
        "items": [{"sku": "x", "qty": 2, "price": 10}, {"sku": "y", "qty": 1, "price": 999}],
        "stock": {"x": 5, "y": 1},
        "tags": ["t"],
        "codes": ["A"],
        "name": "Bob",
    }
    assert program.evaluate(good, plain_data=True) is True
    assert program.evaluate({**good, "codes": ["Z"]}, plain_data=True) is False
    assert program.evaluate({**good, "items": [{"sku": "x", "qty": 9, "price": 10}]}, plain_data=True) is False
    assert program.evaluate({**good, "name": "Bo"}, plain_data=True) is False
    assert program.evaluate({**good, "name": "\U0001f600" * 3}, plain_data=True) is True
    assert program.evaluate({**good, "items": []}, plain_data=True) is False
    with pytest.raises(EvaluationError, match="NoSuchKey"):
        program.evaluate({**good, "stock": {}}, plain_data=True)
    with pytest.raises(EvaluationError, match="IndexOutOfBounds"):
        program.evaluate({**good, "tags": []}, plain_data=True)
    overflow = Program("a * b <= 1")
    with pytest.raises(EvaluationError, match="Overflow"):
        overflow.evaluate({"a": 2**62, "b": 4}, plain_data=True)
    assert overflow.evaluate({"a": 3037000499, "b": 3037000499}, plain_data=True) is False
    arithmetic = Program("a - b == -1 && a + b == 3 && b / a == 2 && b % a == 0 && -a == -1")
    assert arithmetic.evaluate({"a": 1, "b": 2}, plain_data=True) is True
    # CEL truncates toward zero; Python floors. Both engines must agree on negative operands.
    truncating = Program("a / b == -2 && a % b == -1")
    assert truncating.evaluate({"a": -7, "b": 3}, plain_data=True) is True
    assert truncating.evaluate({"a": -7, "b": 3}) is True
    with pytest.raises(EvaluationError, match="DivisionByZero"):
        Program("a / b == 1").evaluate({"a": 1, "b": 0}, plain_data=True)
    with pytest.raises(EvaluationError, match="DivisionByZero"):
        Program("a % b == 1").evaluate({"a": 1, "b": 0}, plain_data=True)
    assert Program("xs.exists(x, x == 'b')").evaluate({"xs": ["a", "b"]}, plain_data=True) is True
    assert Program("xs.exists(x, x == 'z')").evaluate({"xs": ["a", "b"]}, plain_data=True) is False
    assert Program("xs.all(x, x > 0)").evaluate({"xs": [1, 2], "x": -1}, plain_data=True) is True
    with pytest.raises(EvaluationError, match="NoMatchingOverload"):
        Program("xs.all(x, x > 0)").evaluate({"xs": [1, "two"]}, plain_data=True)
    assert Program("m.all(k, k == 'a')").evaluate({"m": {"a": 1}}, plain_data=True) is True
    assert Program("m[key] == 1").evaluate({"m": {"k": 1}, "key": "k"}, plain_data=True) is True
    assert Program("m[0] == 1").evaluate({"m": [1]}, plain_data=True) is True
    with pytest.raises(EvaluationError, match="NoSuchKey"):
        Program("m[0] == 1").evaluate({"m": {"0": 1}}, plain_data=True)
    with pytest.raises(UnicodeEncodeError):
        Program("s.size() == 1").evaluate({"s": "\ud800"}, plain_data=True)
    assert Program("s.size() == 1").evaluate({"s": {"k": 1}}, plain_data=True) is True
    for source in ["xs.exists_one(x, x > 0)", "xs.map(x, x)", "a < 'b'", "a < 1.5", "xs.all(x, y, x > 0)"]:
        assert not Program(source).has_fast_path, source
