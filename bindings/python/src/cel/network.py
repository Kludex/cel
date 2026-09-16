from __future__ import annotations

from dataclasses import dataclass

from cel import _native


@dataclass(frozen=True)
class IPAddress:
    value: str

    def __post_init__(self) -> None:
        if type(self.value) is not str:
            raise TypeError("IPAddress requires a string")
        object.__setattr__(self, "value", _native.normalize_network(self.value, False))

    def __str__(self) -> str:
        return self.value


@dataclass(frozen=True)
class CIDR:
    value: str

    def __post_init__(self) -> None:
        if type(self.value) is not str:
            raise TypeError("CIDR requires a string")
        object.__setattr__(self, "value", _native.normalize_network(self.value, True))

    def __str__(self) -> str:
        return self.value
