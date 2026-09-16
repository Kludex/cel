from __future__ import annotations

import gc
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest
from cel import CELType, CompileError, Environment, Function, OptionalValue, Program, Value


def test_local_bindings_reuse_values_in_complete_policies() -> None:
    source = (
        "cel.bind(jobs, batches.flatten(), "
        "jobs.size() >= 2 && jobs.distinct().size() == jobs.size() && "
        "jobs.sort().slice(0,2) == [1,2])"
    )
    environment = Environment(variables={"batches": CELType("list", (CELType("dyn"),))})
    for program in (Program(source), environment.compile(source)):
        assert program.evaluate({"batches": [[3, 1], [2]]}) is True
        assert program.evaluate({"batches": [[1, 1], [2]]}) is False
    assert environment.compile(source).result_type == CELType("bool")


def test_initializers_are_lazy_and_cached_only_within_one_evaluation() -> None:
    calls = 0

    def tick() -> int:
        nonlocal calls
        calls += 1
        return calls

    environment = Environment(functions=(Function("tick", (), CELType("int"), tick),))
    assert environment.compile("cel.bind(x, tick(), 42)").evaluate({}) == 42
    assert calls == 0
    program = environment.compile("cel.bind(x, tick(), x + x)")
    assert program.evaluate({}) == 2
    assert program.evaluate({}) == 4
    assert calls == 2
    assert environment.compile("cel.bind(x, tick() / 0, (x == 1 || true) && (x == 1 || true))").evaluate({}) is True
    assert calls == 3


def test_cached_null_false_and_empty_values_are_not_reinitialized() -> None:
    calls = 0

    def identity(value: Value) -> Value:
        nonlocal calls
        calls += 1
        return value

    environment = Environment(
        variables={"input": CELType("dyn")},
        functions=(Function("identity", (CELType("dyn"),), CELType("dyn"), identity),),
    )
    program = environment.compile("cel.bind(x, identity(input), [x, x])")
    values: list[Value] = [None, False, 0, [], OptionalValue.none(), OptionalValue.of(None)]
    for value in values:
        assert program.evaluate({"input": value}) == [value, value]
    assert calls == len(values)


def test_binding_caches_are_independent_when_callbacks_release_the_gil() -> None:
    barrier = Barrier(2)

    def pause(value: int) -> int:
        barrier.wait(timeout=5)
        return value

    environment = Environment(
        variables={"value": CELType("int")},
        functions=(Function("pause", (CELType("int"),), CELType("int"), pause),),
    )
    program = environment.compile("cel.bind(x, pause(value), x + x)")
    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(program.evaluate, {"value": 1})
        second = executor.submit(program.evaluate, {"value": 2})
        assert first.result(timeout=10) == 2
        assert second.result(timeout=10) == 4


def test_initializers_capture_outer_lexical_scope() -> None:
    source = "cel.bind(x, 10, [1,2].map(y, cel.bind(z, x+y, cel.bind(x, 100, z+z))))"
    assert Environment().compile(source).evaluate({}) == [22, 24]
    environment = Environment(container="policy", variables={"policy.x.y": CELType("int")})
    assert environment.compile("cel.bind(x, {'y': 1}, x.y + .policy.x.y)").evaluate({"policy.x.y": 9}) == 10
    assert Program("cel.bind(x, x + 1, x)").evaluate({"x": 3}) == 4
    assert Environment(variables={"x": CELType("int")}).compile("cel.bind(.x, 1/0, .x)").evaluate({"x": 3}) == 3
    assert Program("cel.bind(x, missing, 7)").evaluate({}) == 7
    with pytest.raises(CompileError):
        Environment().compile("cel.bind(x, missing, 7)")


def test_bind_macro_namespace_and_custom_function_precedence() -> None:
    for source in ("cel.bind(1, 2, 3)", "cel.bind(x.y, 1, x.y)"):
        with pytest.raises(CompileError):
            Program(source)
    for source in ("cel.bind(x, 1)", "cel.bind(x, 1, x, x)", ".cel.bind(x, 1, x)", "other.bind(x, 1, x)"):
        with pytest.raises(CompileError):
            Environment().compile(source)
    environment = Environment(
        variables={"cel": CELType("bool")},
        functions=(Function("cel.bind", (CELType("int"),) * 3, CELType("int"), lambda a, b, c: a + b + c),),
    )
    assert environment.compile("cel.bind(v, 7, v)").evaluate({}) == 7
    assert environment.compile(".cel.bind(1, 2, 3)").evaluate({}) == 6


def test_used_host_errors_remain_fatal_and_unused_calls_do_not_run() -> None:
    marker = RuntimeError("initializer failed")

    def fail() -> int:
        raise marker

    environment = Environment(functions=(Function("fail", (), CELType("int"), fail),))
    assert environment.compile("cel.bind(x, fail(), true)").evaluate({}) is True
    with pytest.raises(RuntimeError) as captured:
        environment.compile("cel.bind(x, fail(), x == 0 || true)").evaluate({})
    assert captured.value is marker


def test_bound_results_survive_program_collection_and_reentrant_evaluation() -> None:
    identity = Program("cel.bind(x, value, [x, x])")
    calls = 0

    def nested() -> int:
        nonlocal calls
        calls += 1
        assert identity.evaluate({"value": 9}) == [9, 9]
        return 2

    environment = Environment(functions=(Function("nested", (), CELType("int"), nested),))
    program = environment.compile("cel.bind(x, [nested(), 3], [x, x])")
    result = program.evaluate({})
    assert calls == 1
    del program, environment
    gc.collect()
    assert result == [[2, 3], [2, 3]]
