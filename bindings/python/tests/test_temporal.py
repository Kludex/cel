from __future__ import annotations

from typing import cast

import pytest
from cel import CELType, Duration, Environment, EvaluationError, Program, Timestamp


def test_temporal_values_preserve_nanoseconds_and_round_trip() -> None:
    instant = Timestamp(1_234_567_890, 123_456_789)
    delay = Duration(999_999_999)
    program = Environment(
        variables={"start": CELType("google.protobuf.Timestamp"), "delay": CELType("google.protobuf.Duration")}
    ).compile("start + delay")
    assert program.result_type == CELType("google.protobuf.Timestamp")
    assert program({"start": instant, "delay": delay}) == Timestamp(1_234_567_891, 123_456_788)
    assert Program("end - start")({"start": instant, "end": Timestamp(1_234_567_891, 123_456_788)}) == delay
    assert Program("duration('1.234s').getMilliseconds()")({}) == 234
    assert Program("timestamp(0)")({}) == Timestamp(0)
    assert Program("duration('-9223372036854775808ns')")({}) == Duration(-(2**63))


def test_timestamp_zones_and_protobuf_field_conversion() -> None:
    assert Program("timestamp('2009-02-13T23:31:30Z').getHours('Australia/Sydney')")({}) == 10
    assert Program("google.protobuf.Timestamp{seconds:1,nanos:2}")({}) == Timestamp(1, 2)
    assert Program("google.protobuf.Duration{seconds:-1,nanos:-2}")({}) == Duration(-1_000_000_002)
    assert Program("string(t)")({"t": Timestamp(-62_135_596_800, 1)}) == "0001-01-01T00:00:00.000000001Z"
    with pytest.raises(EvaluationError):
        Program("timestamp(0).getHours('../etc/passwd')")({})


def test_temporal_input_ranges_and_types_are_validated() -> None:
    for seconds, nanos in [(-62_135_596_801, 0), (253_402_300_800, 0), (0, -1), (0, 1_000_000_000)]:
        with pytest.raises(ValueError):
            Timestamp(seconds, nanos)
    with pytest.raises(TypeError):
        Timestamp(True)
    with pytest.raises(TypeError):
        Timestamp(0, cast(int, 0.5))
    with pytest.raises(TypeError):
        Duration(True)
    with pytest.raises(ValueError):
        Duration(2**63)
