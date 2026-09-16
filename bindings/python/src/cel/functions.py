from __future__ import annotations

from collections.abc import Callable
from dataclasses import KW_ONLY, dataclass

from cel.values import CELType, Value


@dataclass(frozen=True)
class Function:
    name: str
    parameters: tuple[CELType, ...]
    result: CELType
    implementation: Callable[..., Value] | None = None
    _: KW_ONLY
    overload_id: str = ""
    member: bool = False

    def __post_init__(self) -> None:
        if type(self.name) is not str:
            raise TypeError("Function name must be a string")
        if not self.name:
            raise ValueError("Function name must not be empty")
        if type(self.parameters) is not tuple or any(type(parameter) is not CELType for parameter in self.parameters):
            raise TypeError("Function parameters must be a tuple of CELType values")
        if type(self.result) is not CELType:
            raise TypeError("Function result must be a CELType")
        if self.implementation is not None and not callable(self.implementation):
            raise TypeError("Function implementation must be callable or None")
        if type(self.overload_id) is not str:
            raise TypeError("Function overload_id must be a string")
        if type(self.member) is not bool:
            raise TypeError("Function member must be a bool")
