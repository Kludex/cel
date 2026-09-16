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
    assert fast == 2
    assert Program(WORKLOADS[0]["expression"]).has_fast_path
    assert Program(WORKLOADS[3]["expression"]).has_fast_path


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
    for source in ["a.b < 3", "has(a.b)", "a.`b-c` == 1", "size(a) == 1", "a == 1.5", "m[key] == 1", "flag ? 1 : 'x'"]:
        assert not Program(source).has_fast_path, source
    assert Program("a.b < 3").evaluate({"a": {"b": 2}}, plain_data=True) is True
    assert not Environment(container="ns").compile("a.b == 1", check=False).has_fast_path
    assert not Environment(variables={"a": CELType("string")}).compile("a == 'x'").has_fast_path


def test_hand_built_plans_outside_the_vocabulary_are_refused() -> None:
    assert compile_plain(None) is None
    for plan in [
        ["size", ["ident", "a"]],
        ["&&", ["ident", "a"], ["string", "x"]],
        ["!", ["string", "x"]],
        ["startsWith", ["ident", "a"], ["int", 1]],
        ["==", ["&&", ["ident", "a"], ["ident", "b"]], ["ident", "c"]],
        ["int", 1],
        ["ident", "a"],
        ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]],
        ["?:", ["ident", "f"], ["int", 1], ["int", 2]],
        ["select", ["?:", ["ident", "f"], ["ident", "a"], ["ident", "b"]], "c"],
        ["==", ["string", "x"], ["==", ["ident", "a"], ["ident", "b"]]],
        ["==", ["string", "x"], ["!", ["ident", "a"]]],
        ["==", ["string", "x"], ["contains", ["ident", "a"], ["string", "b"]]],
        ["==", ["select", ["size", ["ident", "a"]], "c"], ["string", "x"]],
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
