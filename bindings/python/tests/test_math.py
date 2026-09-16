from __future__ import annotations

import math

import pytest
from cel import CELType, CompileError, Environment, EvaluationError, Function, Program, UInt


def test_math_policies_preserve_types_and_exact_numeric_selection() -> None:
    environment = Environment(variables={"permissions": CELType("uint")})
    policy = environment.compile("math.bitAnd(permissions, 3u) == 3u && math.greatest([1, 2u, 3.5]) == 3.5")
    assert policy({"permissions": UInt(7)}) is True
    assert policy({"permissions": UInt(1)}) is False
    assert Program("math.greatest(1u, 1, 1.0)")({}) == UInt(1)
    assert type(Program("math.least(1.0, 1u, 1)")({})) is float
    tie = Program("math.greatest(9223372036854775807, 9223372036854775808.0)")({})
    assert tie == 9223372036854775807 and type(tie) is int
    swapped = Program("math.greatest(9223372036854775808.0, 9223372036854775807)")({})
    assert swapped == 9223372036854775808.0 and type(swapped) is float
    assert Program("math.least(-1, 18446744073709551615u)")({}) == -1
    assert Program("math.bitShiftRight(-1, 1)")({}) == 2**63 - 1
    assert Program("math.bitShiftLeft(1, 63)")({}) == -(2**63)
    assert Program("math.bitShiftLeft(-1, 64)")({}) == 0


def test_math_rounding_special_values_and_failure_phases() -> None:
    rounded = Program("[math.ceil(-1.2), math.floor(-1.2), math.round(-1.5), math.trunc(-1.2)]")({})
    assert rounded == [-1.0, -2.0, -2.0, -1.0]
    zero = Program("math.sign(-0.0)")({})
    nan = Program("math.sign(0.0 / 0.0)")({})
    assert isinstance(zero, float) and math.copysign(1, zero) == 1
    assert isinstance(nan, float) and math.isnan(nan)
    assert Program("math.isFinite(1.0) && math.isInf(1.0/0.0) && math.isNaN(0.0/0.0)")({}) is True
    for source in ("math.greatest()", "math.least([])", "math.greatest('bad')", "math.least(1, [])"):
        with pytest.raises(CompileError, match="InvalidSyntax"):
            Program(source)
    with pytest.raises(CompileError, match="TypeMismatch"):
        Environment().compile("false && math.abs(true) == 1")
    for source, error in (
        ("math.abs(-9223372036854775808)", "Overflow"),
        ("math.bitShiftRight(1, -1)", "InvalidArgument"),
        ("math.ceil(dyn(1))", "NoMatchingOverload"),
        ("math.greatest(dyn([]))", "InvalidArgument"),
    ):
        with pytest.raises(EvaluationError, match=error):
            Program(source)({})


def test_math_names_do_not_repurpose_variables_or_override_custom_function_families() -> None:
    environment = Environment(container="policy", variables={"math": CELType("int")})
    assert environment.compile("math.abs(-2) + math")({"math": 3}) == 5
    assert environment.compile(".math.abs(-2)")({}) == 2
    custom = Environment(functions=(Function("math.abs", (CELType("bool"),), CELType("bool"), lambda value: value),))
    assert custom.compile("math.abs(true)")({}) is True
