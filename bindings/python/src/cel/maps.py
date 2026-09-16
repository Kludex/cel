from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from cel.values import MapKey, Value


@dataclass(frozen=True)
class CELMap:
    entries: tuple[tuple[MapKey, Value], ...]

    def __post_init__(self) -> None:
        from cel.values import UInt

        if type(self.entries) is not tuple:
            raise TypeError("CELMap entries must be a tuple of key-value tuples")
        seen: set[tuple[bool, int | str]] = set()
        for entry in self.entries:
            if type(entry) is not tuple or len(entry) != 2:
                raise TypeError("CELMap entries must be key-value tuples")
            key = entry[0]
            if type(key) not in (bool, int, str, UInt):
                raise TypeError("CEL map keys must be bool, int, UInt, or str")
            canonical = (type(key) is bool, key.value if isinstance(key, UInt) else key)
            if canonical in seen:
                raise ValueError("duplicate CEL map key")
            seen.add(canonical)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, CELMap):
            return NotImplemented
        return len(self.entries) == len(other.entries) and all(
            type(left[0]) is type(right[0]) and left == right for left, right in zip(self.entries, other.entries)
        )
