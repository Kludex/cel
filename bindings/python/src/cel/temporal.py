from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Timestamp:
    seconds: int
    nanos: int = 0

    def __post_init__(self) -> None:
        if type(self.seconds) is not int or type(self.nanos) is not int:
            raise TypeError("Timestamp requires integer seconds and nanoseconds")
        if not -62_135_596_800 <= self.seconds <= 253_402_300_799 or not 0 <= self.nanos < 1_000_000_000:
            raise ValueError("Timestamp must be normalized and between UTC years 1 and 9999")


@dataclass(frozen=True)
class Duration:
    nanoseconds: int

    def __post_init__(self) -> None:
        if type(self.nanoseconds) is not int:
            raise TypeError("Duration requires integer nanoseconds")
        if not -(2**63) <= self.nanoseconds < 2**63:
            raise ValueError("Duration nanoseconds must fit a signed 64-bit integer")
