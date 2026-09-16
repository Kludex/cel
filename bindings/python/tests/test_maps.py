from __future__ import annotations

from dataclasses import FrozenInstanceError
from typing import cast

import pytest
from cel import CELMap, CELType, Environment, MapKey, Program, UInt, Value


def test_typed_maps_keep_boolean_integer_unsigned_and_string_keys_distinct() -> None:
    value = CELMap(((True, "boolean"), (1, "integer"), (False, "false"), (0, "zero"), (UInt(2**64 - 1), "max")))
    program = Program("m[true] == 'boolean' && m[1u] == 'integer' && m[false] == 'false' && m[0] == 'zero'")
    assert program({"m": value}) is True
    result = Program("m")({"m": value})
    assert result == value
    assert Program("m[18446744073709551615u]")({"m": result}) == "max"
    assert Program("{true:'bool', 1:'int'}")({}) == CELMap(((True, "bool"), (1, "int")))
    assert Program("{'x': 1, 'y': 2}")({}) == {"x": 1, "y": 2}
    assert Program("{1: 'int'}")({}) == {1: "int"}
    assert Program("{true: 'bool'}")({}) == {True: "bool"}
    assert CELMap(((True, "x"),)) != CELMap(((1, "x"),))
    assert CELMap(()) != CELMap(((1, "x"),))
    assert CELMap(((1, "x"),)) != CELMap(((1, "y"),))
    assert CELMap(()) != {}


def test_typed_maps_work_with_declarations_macros_constants_and_nested_results() -> None:
    values: list[Value] = [1, 2]
    value = CELMap(((True, values), (1, [3])))
    environment = Environment(
        variables={"m": CELType("map", (CELType("dyn"), CELType("dyn")))}, constants={"saved": value}
    )
    program = environment.compile("m.all(k, k in saved) && saved[true] == [1,2] && saved[1] == [3]")
    values.clear()
    assert program({"m": CELMap(((True, "yes"), (1, "one")))}) is True
    result = environment.compile("[saved, {'nested': saved}]")({})
    assert result == [CELMap(((True, [1, 2]), (1, [3]))), {"nested": CELMap(((True, [1, 2]), (1, [3])))}]
    for _ in range(10):
        assert Program("m.size()")({"m": CELMap(())}) == 0
    assert Program("m[0][true]")({"m": result}) == [1, 2]


def test_typed_maps_reject_invalid_keys_pairs_and_duplicate_cel_keys() -> None:
    invalid_entries: tuple[object, ...] = ([], (1,), ((1,),), ((1, 2, 3),), ([1, 2],))
    for entries in invalid_entries:
        with pytest.raises(TypeError):
            CELMap(cast(tuple[tuple[MapKey, Value], ...], entries))
    for key in (None, 1.5, b"x", (), CELType("int")):
        with pytest.raises(TypeError):
            CELMap(((cast(MapKey, key), "invalid"),))
    for keys in ((1, UInt(1)), (UInt(0), 0), ("x", "x"), (False, False)):
        with pytest.raises(ValueError, match="duplicate"):
            CELMap(((keys[0], "first"), (keys[1], "second")))
    value = CELMap((("x", 1),))
    with pytest.raises(FrozenInstanceError):
        setattr(value, "entries", ())
    for duplicate_map in ({1: "first", UInt(1): "second"}, {UInt(0): "first", 0: "second"}):
        with pytest.raises(ValueError, match="duplicate"):
            Program("true")({"ignored": cast(Value, duplicate_map)})


def test_dictionary_and_typed_map_key_value_budgets_match() -> None:
    entries: tuple[tuple[MapKey, Value], ...] = tuple((str(index), None) for index in range(49_999))
    program = Program("m.size()")
    assert program({"m": CELMap(entries)}) == 49_999
    assert program({"m": dict(entries)}) == 49_999
    entries += (("extra", None),)
    for value in (CELMap(entries), dict(entries)):
        with pytest.raises(ValueError, match="collection limit"):
            program({"m": value})


def test_native_typed_map_validation_rejects_forged_values_cycles_and_limits() -> None:
    program = Program("x")
    forged = object.__new__(CELMap)
    with pytest.raises(TypeError):
        program({"x": forged})
    invalid_entries: tuple[object, ...] = ([], (1,), ((1,),), ((1, 2, 3),), ((1, 2), (UInt(1), 3)), ((None, 1),))
    for entries in invalid_entries:
        object.__setattr__(forged, "entries", entries)
        with pytest.raises((TypeError, ValueError)):
            program({"x": forged})
    object.__setattr__(forged, "entries", (("self", forged),))
    with pytest.raises(ValueError, match="depth|cycle"):
        program({"x": forged})
    for value in (
        CELMap((("huge", "x" * 1_048_576),)),
        CELMap(tuple((index, index) for index in range(50_000))),
    ):
        with pytest.raises(ValueError, match="limit"):
            program({"x": value})
    assert program({"x": CELMap((("small", 1),))}) == {"small": 1}
