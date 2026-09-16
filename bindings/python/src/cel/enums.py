from __future__ import annotations

import operator
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class EnumValue:
    type_name: str
    number: int

    def __post_init__(self) -> None:
        if type(self.type_name) is not str:
            raise TypeError("EnumValue requires a string type name")
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*", self.type_name) is None:
            raise ValueError("EnumValue type_name must be a qualified name")
        if type(self.number) is bool:
            raise TypeError("EnumValue requires an integer number")
        try:
            number = operator.index(self.number)
        except TypeError:
            raise TypeError("EnumValue requires an integer number") from None
        if not -(2**31) <= number < 2**31:
            raise ValueError("EnumValue number must fit a signed 32-bit integer")
        object.__setattr__(self, "number", number)
