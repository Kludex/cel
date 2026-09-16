from __future__ import annotations

import gc
import weakref
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from typing import Any, cast

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Function, Message, Program, Value

DESCRIPTORS = (Path(__file__).resolve().parents[3] / "conformance/protobuf/test-schema-descriptor.pb").read_bytes()


def test_primitive_and_generic_functions() -> None:
    t = CELType.parameter("T")
    environment = Environment(
        functions=(
            Function("double", (CELType("int"),), CELType("int"), lambda value: value * 2),
            Function("identity", (t,), t, lambda value: value),
            Function("head", (CELType("list", (t,)),), t, lambda values: values[0]),
        )
    )
    assert environment.compile("double(3)")({}) == 6
    assert environment.compile("identity(1)")({}) == 1
    assert environment.compile("identity('x')")({}) == "x"
    assert environment.compile("identity(1) == 1 && identity(true)")({}) is True
    program = environment.compile("head([2, 3])")
    assert program.result_type == CELType("int")
    assert program({}) == 2


def test_namespace_receiver_and_overload_resolution() -> None:
    environment = Environment(
        container="policy",
        functions=(
            Function(
                "policy.echo",
                (CELType("int"),),
                CELType("int"),
                lambda value: value,
                overload_id="echo_int",
            ),
            Function(
                "policy.echo",
                (CELType("string"),),
                CELType("string"),
                lambda value: value,
                overload_id="echo_string",
            ),
            Function(
                "policy.atLeast",
                (CELType("int"), CELType("int")),
                CELType("bool"),
                lambda value, minimum: value >= minimum,
                member=True,
            ),
        ),
    )
    assert environment.compile("echo(1)")({}) == 1
    assert environment.compile("echo('x')")({}) == "x"
    assert environment.compile("(21).atLeast(18)")({}) is True


def test_missing_implementation_and_runtime_contract_errors() -> None:
    missing = Environment(functions=(Function("declared", (), CELType("bool")),))
    with pytest.raises(EvaluationError, match="MissingFunction"):
        missing.compile("declared()")({})

    environment = Environment(
        functions=(Function("positive", (CELType("int"),), CELType("bool"), lambda value: "yes"),)
    )
    with pytest.raises(CompileError, match="TypeMismatch"):
        environment.compile("positive('wrong')")
    with pytest.raises(EvaluationError, match="NoMatchingOverload"):
        environment.compile("positive('wrong')", check=False)({})
    with pytest.raises(EvaluationError, match="NoMatchingOverload"):
        environment.compile("positive(1)")({})
    t = CELType.parameter("T")
    wrong_generic = Environment(functions=(Function("identity", (t,), t, lambda value: "wrong"),))
    with pytest.raises(EvaluationError, match="NoMatchingOverload"):
        wrong_generic.compile("identity(1)")({})


def test_host_exceptions_are_not_suppressed_by_cel() -> None:
    class HostError(Exception):
        """A trusted callback failed."""

    def fail() -> Value:
        raise HostError("from callback")

    environment = Environment(functions=(Function("fail", (), CELType("bool"), fail),))
    with pytest.raises(HostError, match="from callback"):
        environment.compile("fail() || true")({})


def test_callback_messages_and_results_have_owned_lifetimes() -> None:
    captured: list[Message] = []

    def echo(message: Message) -> Message:
        captured.append(message)
        return message

    message_type = CELType("cel.conformance.fixture.TestSchema")
    environment = Environment(
        descriptors=DESCRIPTORS,
        container="cel.conformance.fixture",
        functions=(Function("echo", (message_type,), message_type, echo),),
    )
    program = environment.compile("echo(TestSchema{signed_value: 42})")
    result = program({})
    del program, environment
    gc.collect()
    assert result == Message("cel.conformance.fixture.TestSchema", b"\x08*")
    assert captured == [result]


def test_program_retains_function_environment() -> None:
    environment = Environment(
        functions=(Function("append", (CELType("string"),), CELType("string"), lambda value: value + "!"),)
    )
    program = environment.compile("append('kept')")
    del environment
    gc.collect()
    assert program({}) == "kept!"


def test_callbacks_can_reenter_programs_using_the_same_environment() -> None:
    nested: dict[str, Program] = {}

    def reenter(value: Value) -> Value:
        return nested["program"]({"value": value})

    environment = Environment(
        variables={"value": CELType("int")},
        functions=(
            Function("increment", (CELType("int"),), CELType("int"), lambda value: value + 1),
            Function("reenter", (CELType("int"),), CELType("int"), reenter),
        ),
    )
    nested["program"] = environment.compile("increment(value)")
    assert environment.compile("reenter(1) + increment(2)")({}) == 5


def test_callbacks_remain_thread_local_when_host_code_releases_the_gil() -> None:
    entered = (Event(), Event())
    released = (Event(), Event())

    def gate(value: int) -> int:
        entered[value].set()
        assert released[value].wait(10)
        return value

    integer = CELType("int")
    environment = Environment(
        variables={"value": integer},
        functions=(
            Function("gate", (integer,), integer, gate),
            Function("identity", (integer,), integer, lambda value: value),
        ),
    )
    program = environment.compile("gate(value) + identity(value)")
    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(program, {"value": 0})
        assert entered[0].wait(10)
        second = executor.submit(program, {"value": 1})
        try:
            assert entered[1].wait(10)
            released[0].set()
            assert first.result(timeout=10) == 0
        finally:
            released[0].set()
            released[1].set()
        assert second.result(timeout=10) == 2


def test_callback_cycles_are_collectable() -> None:
    def make_cycle() -> weakref.ReferenceType[Callable[[], Value]]:
        holder: dict[str, Program] = {}

        def callback() -> Value:
            return holder["program"]({})

        environment = Environment(functions=(Function("callback", (), CELType("int"), callback),))
        holder["program"] = environment.compile("1")
        assert callback() == 1
        return weakref.ref(callback)

    reference = make_cycle()
    gc.collect()
    assert reference() is None


def test_function_metadata_limits_are_enforced() -> None:
    function = Function("a" * 1_048_576, (), CELType("int"), lambda: 1)
    with pytest.raises(CompileError, match="limit"):
        Environment(functions=(function,))


@pytest.mark.parametrize(
    "factory",
    [
        lambda: CELType("int", kind=cast(Any, 1)),
        lambda: CELType("int", kind=cast(Any, "invalid")),
        lambda: Function(cast(str, 1), (), CELType("int")),
        lambda: Function("", (), CELType("int")),
        lambda: Function("f", cast(tuple[CELType, ...], []), CELType("int")),
        lambda: Function("f", (cast(CELType, 1),), CELType("int")),
        lambda: Function("f", (), cast(CELType, 1)),
        lambda: Function("f", (), CELType("int"), cast(Any, 1)),
        lambda: Function("f", (), CELType("int"), overload_id=cast(str, 1)),
        lambda: Function("f", (), CELType("int"), member=cast(bool, 1)),
        lambda: Environment(functions=cast(tuple[Function, ...], [])),
        lambda: Environment(functions=(cast(Function, 1),)),
    ],
)
def test_function_constructor_validation(factory: Callable[[], object]) -> None:
    with pytest.raises((TypeError, ValueError)):
        factory()


def test_type_kinds_are_public_and_preserved() -> None:
    t = CELType.parameter("T")
    abstract = CELType.abstract("tuple", (t, CELType("int")))
    assert t == CELType("T", kind="parameter")
    assert abstract == CELType("tuple", (t, CELType("int")), "abstract")
    with pytest.raises(TypeError, match="declaration"):
        Program("value")({"value": t})

    environment = Environment(
        functions=(
            Function(
                "tuple",
                (t, CELType.parameter("U"), CELType.parameter("V")),
                CELType.abstract("tuple", (t, CELType.parameter("U"), CELType.parameter("V"))),
            ),
        )
    )
    assert environment.compile("tuple(dyn(1), 2u, 3.0)").result_type == CELType.abstract(
        "tuple", (CELType("dyn"), CELType("uint"), CELType("double"))
    )
