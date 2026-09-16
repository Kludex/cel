from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Function, OptionalValue, Program


def test_indexed_blocks_infer_heterogeneous_slots_and_reuse_values() -> None:
    source = "cel.block([1, 'ok', [cel.index(0)], cel.index(0) + 2], [cel.index(1), cel.index(2), cel.index(3)])"
    for program in (Program(source), Environment().compile(source)):
        assert program.evaluate({}) == ["ok", [1], 3]
    assert Environment().compile("cel.block([1, cel.index(0)+1], cel.index(1))").result_type == CELType("int")
    assert Program("cel.block([], true)").evaluate({}) is True


def test_block_slots_are_lazy_and_cache_cel_errors_per_request() -> None:
    calls = 0

    def tick() -> int:
        nonlocal calls
        calls += 1
        return calls

    environment = Environment(functions=(Function("tick", (), CELType("int"), tick),))
    assert environment.compile("cel.block([tick(), 1/0], true)").evaluate({}) is True
    assert calls == 0
    program = environment.compile("cel.block([tick(), cel.index(0)+cel.index(0)], cel.index(1))")
    assert program.evaluate({}) == 2
    assert program.evaluate({}) == 4
    assert calls == 2
    assert (
        environment.compile(
            "cel.block([tick()/0], (cel.index(0) == 0 || true) && (cel.index(0) == 0 || true))"
        ).evaluate({})
        is True
    )
    assert calls == 3


def test_slots_capture_declaration_scope_not_their_use_site() -> None:
    environment = Environment(variables={"x": CELType("int")})
    assert environment.compile("cel.block([x+1], [2].map(x, cel.index(0)))").evaluate({"x": 10}) == [11]
    source = "cel.block([10], cel.bind(outer, cel.index(0), cel.block([2, outer+cel.index(0)], cel.index(1))))"
    assert Environment().compile(source).evaluate({}) == 12
    assert Environment().compile("[1,2].map(x, cel.block([x+1], [cel.index(0),cel.index(0)]))").evaluate({}) == [
        [2, 2],
        [3, 3],
    ]


def test_iterator_handles_are_lexical_and_cannot_be_supplied_by_activations() -> None:
    source = "[1,2].map(cel.iterVar(0,0), [3].map(cel.iterVar(1,0), cel.iterVar(0,0)+cel.iterVar(1,0)))"
    assert Environment().compile(source).evaluate({}) == [[4], [5]]
    assert Program("cel.bind(cel.accuVar(0,0), 7, cel.accuVar(0,0))").evaluate({}) == 7
    with pytest.raises(EvaluationError):
        Program("cel.accuVar(0,0)").evaluate({"@ac:0:0": 9})
    with pytest.raises(EvaluationError):
        Program("cel.iterVar(0,0).field").evaluate({"@it:0:0.field": 9})
    with pytest.raises(EvaluationError):
        Program("cel.iterVar(0,0)").evaluate({"@it:0:0": 9})
    with pytest.raises(CompileError):
        Environment(variables={"x": CELType("int")}).compile("cel.iterVar(0,0)")


def test_forward_dependencies_and_cycles_follow_lazy_slot_resolution() -> None:
    assert Program("cel.block([cel.index(1)+1, 5], cel.index(0))").evaluate({}) == 6
    assert Environment().compile("cel.block([cel.index(1)+1, 5], cel.index(0))").evaluate({}) == 6
    assert Program("cel.block([cel.index(0)], true)").evaluate({}) is True
    assert Program("cel.block([cel.index(2)], true)").evaluate({}) is True
    assert Program("cel.block([cel.index(0) == 1 || true], cel.index(0))").evaluate({}) is True
    for source in (
        "cel.index(0)",
        "cel.block([1], cel.index(1))",
        "cel.block([cel.index(0)], cel.index(0))",
        "cel.block([1], cel.block([], cel.index(0)))",
    ):
        with pytest.raises(EvaluationError):
            Program(source).evaluate({})


def test_block_indices_reject_nonliteral_indices_and_invalid_constructors() -> None:
    for source in (
        "cel.index(-1)",
        "cel.index(0u)",
        "cel.index(0.0)",
        "cel.block([1], cel.index(1-1))",
        "cel.block(values, true)",
    ):
        with pytest.raises(CompileError):
            Program(source)


def test_block_slots_preserve_optional_values_without_compacting_indices() -> None:
    assert Environment().compile("cel.block([?optional.of(1), 2], cel.index(0))").evaluate({}) == OptionalValue.of(1)
    assert Environment().compile("cel.block([?optional.none(), 2], [cel.index(0), cel.index(1)])").evaluate({}) == [
        OptionalValue.none(),
        2,
    ]


def test_block_caches_survive_reentry_and_callbacks_releasing_the_gil() -> None:
    barrier = Barrier(2)
    identity = Program("cel.block([value], [cel.index(0), cel.index(0)])")

    def pause(value: int) -> int:
        assert identity.evaluate({"value": value}) == [value, value]
        barrier.wait(timeout=5)
        return value

    environment = Environment(
        variables={"value": CELType("int")}, functions=(Function("pause", (CELType("int"),), CELType("int"), pause),)
    )
    program = environment.compile("cel.block([pause(value)], cel.index(0)+cel.index(0))")
    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(program.evaluate, {"value": 1})
        second = executor.submit(program.evaluate, {"value": 2})
        assert first.result(timeout=10) == 2
        assert second.result(timeout=10) == 4
