from __future__ import annotations

import gc
from concurrent.futures import ThreadPoolExecutor
from typing import cast

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Program, UInt, Value


def test_reusable_authorization_program() -> None:
    program = Program("request.active && request.age >= 18 && 'admin' in request.roles")
    for active in [True, False, True]:
        assert program.evaluate({"request": {"active": active, "age": 21, "roles": ["admin"]}}) is active


@pytest.mark.parametrize(
    ("source", "bindings", "expected"),
    [
        ("1 + 2 * 3", {}, 7),
        ("-7 / 3", {}, -2),
        ("1u + n", {"n": UInt(2)}, UInt(3)),
        ("n + 1.0", {"n": 2.0}, 3.0),
        ("s + '世界'", {"s": "hello "}, "hello 世界"),
        ("b + b'\\xff'", {"b": b"\x00"}, b"\x00\xff"),
        ("[1, 2, 3].filter(x, x > 1).map(x, x * 2)", {}, [4, 6]),
        ("{'a': null, 'b': true}", {}, {"a": None, "b": True}),
        ("data[1]", {"data": {1: "one"}}, "one"),
        ("missing && false", {}, False),
        ("has(request.optional)", {"request": {}}, False),
    ],
)
def test_value_conversion(source: str, bindings: dict[str, Value], expected: object) -> None:
    result = Program(source).evaluate(bindings)
    assert result == expected
    assert type(result) is type(expected)


def test_cel_type_values_round_trip_without_string_coercion() -> None:
    assert Program("type(1)")({}) == CELType("int")
    assert Program("type(t) == type && t == int && t != 'int'")({"t": CELType("int")}) is True
    assert Program("[type(1), type(1u), type(null)]")({}) == [CELType("int"), CELType("uint"), CELType("null_type")]
    with pytest.raises(TypeError):
        CELType(cast(str, 1))
    with pytest.raises(ValueError):
        CELType("")


def test_two_variable_macros_and_quoted_fields() -> None:
    program = Program("items.transformMap(i, v, v.`unit-price`).transformList(k, v, k + v)")
    assert program({"items": [{"unit-price": 10}, {"unit-price": 20}]}) == [10, 21]


def test_regex_policies_use_re2_and_defer_invalid_patterns() -> None:
    program = Program("request.path.matches(r'^/v[0-9]+/orders/[a-z]+$') && matches(request.user, pattern)")
    request: Value = {"path": "/v1/orders/abc", "user": "admin-1"}
    assert program({"request": request, "pattern": "^admin"}) is True
    assert program({"request": request, "pattern": "^guest"}) is False
    assert Program(r"'世界'.matches(r'\p{Han}+')")({}) is True
    invalid = Program("'text'.matches('(')")
    with pytest.raises(EvaluationError, match="InvalidArgument"):
        invalid({})
    assert Program("false && 'text'.matches('(')")({}) is False
    with pytest.raises(EvaluationError, match="InvalidArgument"):
        Program(r"'aa'.matches(r'(a)\1')")({})


def test_environments_check_declarations_and_own_configuration() -> None:
    configuration: dict[str, Value] = {"acme.policy.minimum": 18}
    environment = Environment(
        container="acme.policy",
        variables={"acme.age": CELType("int")},
        constants=configuration,
    )
    configuration["acme.policy.minimum"] = 100
    program = environment.compile("age >= minimum")
    assert program.result_type == CELType("bool")
    assert program({"acme.age": 21}) is True
    assert Program("1").result_type is None
    assert Program("1", check=True).result_type == CELType("int")
    with pytest.raises(TypeError, match="check must be a bool"):
        Program("1", check=cast(bool, 1))
    assert environment.compile("age", check=False)({"acme.age": 21}) == 21
    with pytest.raises(CompileError, match="TypeMismatch"):
        environment.compile("false && 1 + 'a' == 1")
    with pytest.raises(CompileError, match="UndeclaredReference"):
        environment.compile("unknown")
    with pytest.raises(CompileError, match="InvalidDeclaration"):
        Environment(container=".invalid")
    with pytest.raises(CompileError, match="UnsupportedType"):
        Environment(variables={"x": CELType("NotRegistered")})


def test_generic_result_types_and_declaration_validation() -> None:
    integer = CELType("int")
    environment = Environment(variables={"items": CELType("list", (integer,))})
    program = environment.compile("items.map(x, x + 1)")
    assert program.result_type == CELType("list", (integer,))
    assert program({"items": [1, 2]}) == [2, 3]
    with pytest.raises(TypeError):
        CELType("list", cast(tuple[CELType, ...], [integer]))
    with pytest.raises(TypeError):
        CELType("list", (cast(CELType, 1),))
    with pytest.raises(TypeError):
        Program("x")({"x": CELType("list", (integer,))})
    with pytest.raises(CompileError, match="InvalidDeclaration"):
        Environment(variables={"x": CELType("list", (integer, integer))})


def test_checked_program_outlives_its_environment_and_nested_constants() -> None:
    constants: dict[str, Value] = {"policy.items": [1, 2]}
    environment = Environment(container="policy", constants=constants)
    program = environment.compile("items.map(x, x + 1)")
    cast(list[Value], constants["policy.items"]).clear()
    del environment
    gc.collect()
    assert program({}) == [2, 3]


def test_program_is_callable() -> None:
    assert Program("x + 1")({"x": 41}) == 42


def test_compile_and_evaluation_errors_are_distinct() -> None:
    with pytest.raises(CompileError, match="InvalidSyntax"):
        Program("1 +")
    with pytest.raises(EvaluationError, match="DivisionByZero"):
        Program("1 / zero").evaluate({"zero": 0})
    with pytest.raises(EvaluationError, match="Overflow"):
        Program("9223372036854775807 + 1").evaluate({})


@pytest.mark.parametrize("value", [2**63, -(2**63) - 1, object(), {1.5: 1}])
def test_unsupported_inputs_are_rejected(value: object) -> None:
    with pytest.raises((TypeError, OverflowError)):
        Program("x").evaluate({"x": cast(Value, value)})


def test_input_conversion_does_not_invoke_user_attributes() -> None:
    class Unexpected:
        def __getattribute__(self, name: str) -> object:
            raise AssertionError("Input conversion executed user code")

    unexpected = Unexpected()
    with pytest.raises(AssertionError, match="executed user code"):
        _ = unexpected.__class__
    with pytest.raises(TypeError, match="unsupported"):
        Program("x").evaluate({"x": cast(Value, unexpected)})


def test_cycles_and_excessive_depth_are_rejected() -> None:
    cyclic: list[Value] = []
    cyclic.append(cyclic)
    with pytest.raises(ValueError, match="depth"):
        Program("x").evaluate({"x": cyclic})


def test_inputs_and_results_have_independent_lifetimes() -> None:
    program = Program("items.map(x, x + 'b')")
    items: list[Value] = ["a", "c"]
    result = program.evaluate({"items": items})
    items.clear()
    del program
    gc.collect()
    assert result == ["ab", "cb"]


def test_program_can_be_shared_between_threads() -> None:
    program = Program("x * 2")
    with ThreadPoolExecutor(max_workers=4) as pool:
        assert list(pool.map(lambda x: program.evaluate({"x": x}), range(100))) == list(range(0, 200, 2))


def test_input_byte_limit_is_enforced() -> None:
    with pytest.raises(ValueError, match="byte limit"):
        Program("x").evaluate({"x": b"a" * 1_048_576})


def test_result_survives_input_mutation_during_uint_construction(monkeypatch: pytest.MonkeyPatch) -> None:
    data: dict[str, Value] = {"x": "a" * 8192}

    def clear_inputs(self: UInt) -> None:
        data.clear()

    monkeypatch.setattr(UInt, "__post_init__", clear_inputs)
    result = Program("[1u, x]").evaluate(data)
    assert data == {}
    assert result == [UInt(1), "a" * 8192]


def test_unsigned_range_is_validated() -> None:
    assert UInt(2**64 - 1).value == 2**64 - 1
    for invalid in [-1, 2**64]:
        with pytest.raises(ValueError):
            UInt(invalid)
    with pytest.raises(TypeError):
        UInt(True)
