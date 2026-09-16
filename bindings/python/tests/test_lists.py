from __future__ import annotations

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Function, Message, Program, Value


def test_collection_policy_and_static_types() -> None:
    environment = Environment(variables={"batches": CELType("list", (CELType("dyn"),))})
    program = environment.compile(
        "batches.flatten().distinct().sort().slice(0, 3).reverse() == [3, 2, 1] && lists.range(3).all(i, i < 3)"
    )
    assert program.evaluate({"batches": [[3, 1], [2, 3], [4]]}) is True
    assert program.result_type == CELType("bool")
    assert environment.compile("batches.flatten()").result_type == CELType("list", (CELType("dyn"),))
    assert Environment().compile("[3, 1].sort()").result_type == CELType("list", (CELType("int"),))


def test_sort_by_evaluates_receiver_and_keys_once_and_preserves_input() -> None:
    calls: list[int] = []
    values: list[Value] = [
        {"id": "first", "rank": 2},
        {"id": "second", "rank": 1},
        {"id": "third", "rank": 2},
    ]
    receivers = 0

    def items() -> list[Value]:
        nonlocal receivers
        receivers += 1
        return values

    def key(value: int) -> int:
        calls.append(value)
        return value

    environment = Environment(
        variables={"value": CELType("string")},
        functions=(
            Function("items", (), CELType("list", (CELType("dyn"),)), items),
            Function("key", (CELType("int"),), CELType("int"), key),
        ),
    )
    result = environment.compile("items().sortBy(value, key(value.rank)).map(item, item.id)").evaluate({})
    assert result == ["second", "first", "third"]
    assert calls == [2, 1, 2]
    assert receivers == 1
    assert values == [{"id": "first", "rank": 2}, {"id": "second", "rank": 1}, {"id": "third", "rank": 2}]


def test_sort_by_callback_errors_are_fatal_and_stop_later_keys() -> None:
    calls: list[int] = []
    marker = RuntimeError("key failed")

    def key(value: int) -> int:
        calls.append(value)
        if value == 2:
            raise marker
        return value

    environment = Environment(functions=(Function("key", (CELType("int"),), CELType("int"), key),))
    with pytest.raises(RuntimeError) as captured:
        environment.compile("[0,1,2,3].sortBy(item, key(item)) == [] || true").evaluate({})
    assert captured.value is marker
    assert calls == [0, 1, 2]


def test_list_range_resolves_container_and_absolute_names() -> None:
    for container in ("lists", "lists.child"):
        assert Environment(container=container).compile("range(3)").evaluate({}) == [0, 1, 2]
    assert Environment(variables={"lists": CELType("bool")}).compile(".lists.range(2)").evaluate({}) == [0, 1]


def test_sort_by_macro_rejects_invalid_receivers_and_bindings() -> None:
    for source in ("1.sortBy(x, x)", "{'x': 1}.sortBy(x, x)", "[1].sortBy(1, 1)", "[1].sortBy(x.y, 1)"):
        with pytest.raises(CompileError):
            Program(source)


def test_large_collection_policies_fit_the_default_work_budget() -> None:
    ids: list[Value] = list(range(1500))
    request: Value = {"ids": ids + ids}
    program = Program("request.ids.distinct().sort().slice(0, 3) == [0, 1, 2]")
    assert program.evaluate({"request": request}) is True


def test_checked_sorting_adapts_protobuf_scalar_wrappers() -> None:
    source = "[google.protobuf.Int64Value{value: 2}, google.protobuf.Int64Value{value: 1}]"
    assert Environment().compile(source + ".sort()").evaluate({}) == [1, 2]
    assert Environment().compile(source + ".sortBy(v, v)").evaluate({}) == [1, 2]


def test_distinct_adapts_nested_protobuf_wrapper_values() -> None:
    values: list[Value] = [[Message("google.protobuf.Int64Value", b"\x08\x01")], [1]]
    assert Program("values.distinct().size()").evaluate({"values": values}) == 1
    assert Program("values[0] == values[1]").evaluate({"values": values}) is True


def test_list_boundaries_and_nested_equality() -> None:
    assert Program("[1, 1u, 1.0, true, true, {'x': [1]}, {'x': [1u]}].distinct().size()").evaluate({}) == 3
    assert Program("[[], [1, [2]], 3].flatten(0)").evaluate({}) == [[], [1, [2]], 3]
    assert Program("[[], [1, [2]], 3].flatten(2)").evaluate({}) == [1, 2, 3]
    assert Program("[].sortBy(item, item.missing)").evaluate({}) == []
    assert Program("math.isNaN([0.0 / 0.0].sort()[0])").evaluate({}) is True
    with pytest.raises(EvaluationError, match="InvalidArgument"):
        Program("[1.0, 0.0 / 0.0].sort()").evaluate({})
    for source in ("[].slice(-1, 0)", "[1].slice(0, 2)", "[].flatten(-1)", "lists.range(-1)"):
        with pytest.raises(EvaluationError):
            Program(source).evaluate({})
    for source in ("[1, 1u].sort()", "[{}].sort()", "[null].sort()", "lists.range(2u)"):
        with pytest.raises(EvaluationError):
            Program(source).evaluate({})
