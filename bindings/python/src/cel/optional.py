from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from cel.values import Value


@dataclass(frozen=True)
class OptionalValue:
    has_value: bool = False
    value: Value = None

    def __post_init__(self) -> None:
        if type(self.has_value) is not bool:
            raise TypeError("OptionalValue has_value must be a bool")
        if not self.has_value and self.value is not None:
            raise ValueError("an absent OptionalValue must have a None value")

    @classmethod
    def of(cls, value: Value) -> OptionalValue:
        return cls(True, value)

    @classmethod
    def none(cls) -> OptionalValue:
        return cls()
