from __future__ import annotations

from dataclasses import dataclass

from typing_extensions import Literal, TypeAlias

from cel.enums import EnumValue
from cel.maps import CELMap
from cel.network import CIDR, IPAddress
from cel.optional import OptionalValue
from cel.temporal import Duration, Timestamp


@dataclass(frozen=True)
class UInt:
    value: int

    def __post_init__(self) -> None:
        if type(self.value) is not int:
            raise TypeError("UInt requires an integer")
        if not 0 <= self.value < 2**64:
            raise ValueError("UInt must be between 0 and 2**64 - 1")


@dataclass(frozen=True)
class CELType:
    name: str
    parameters: tuple[CELType, ...] = ()
    kind: Literal["concrete", "parameter", "abstract"] = "concrete"

    def __post_init__(self) -> None:
        if type(self.name) is not str:
            raise TypeError("CELType requires a string name")
        if not self.name:
            raise ValueError("CELType name must not be empty")
        if type(self.parameters) is not tuple or any(type(parameter) is not CELType for parameter in self.parameters):
            raise TypeError("CELType parameters must be a tuple of CELType values")
        if type(self.kind) is not str:
            raise TypeError("CELType kind must be a string")
        if self.kind not in ("concrete", "parameter", "abstract"):
            raise ValueError("CELType kind must be concrete, parameter, or abstract")

    @classmethod
    def parameter(cls, name: str) -> CELType:
        return cls(name, kind="parameter")

    @classmethod
    def abstract(cls, name: str, parameters: tuple[CELType, ...] = ()) -> CELType:
        return cls(name, parameters, "abstract")


@dataclass(frozen=True)
class Message:
    type_name: str
    data: bytes = b""

    def __post_init__(self) -> None:
        if type(self.type_name) is not str or not self.type_name:
            raise TypeError("Message requires a nonempty protobuf type name")
        if type(self.data) is not bytes:
            raise TypeError("Message data must be bytes")


MapKey: TypeAlias = bool | int | str | UInt
Value: TypeAlias = (
    bool
    | int
    | float
    | str
    | bytes
    | UInt
    | CELType
    | CELMap
    | EnumValue
    | Message
    | Timestamp
    | Duration
    | OptionalValue
    | IPAddress
    | CIDR
    | None
    | list["Value"]
    | dict[MapKey, "Value"]
)
