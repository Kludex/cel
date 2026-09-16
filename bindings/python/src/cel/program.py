from __future__ import annotations

from cel import _native
from cel.enums import EnumValue
from cel.functions import Function as Function
from cel.maps import CELMap
from cel.network import CIDR, IPAddress
from cel.optional import OptionalValue
from cel.temporal import Duration, Timestamp
from cel.values import CELType as CELType, MapKey as MapKey, Message as Message, UInt as UInt, Value as Value


class CompileError(ValueError):
    """The expression cannot be compiled."""


class EvaluationError(RuntimeError):
    """The expression cannot be evaluated with these bindings."""


class Program:
    __slots__ = ("_environment", "_handle")

    def __init__(self, source: str, *, environment: Environment | None = None, check: bool = False) -> None:
        if type(check) is not bool:
            raise TypeError("check must be a bool")
        self._environment = environment
        try:
            if environment is None and not check:
                self._handle = _native.compile(source)
            else:
                self._handle = _native.compile_in(None if environment is None else environment._handle, source, check)
        except ValueError as exc:
            raise CompileError(str(exc)) from None

    def evaluate(self, bindings: dict[str, Value]) -> Value:
        environment = self._environment
        return _native.evaluate(
            self._handle,
            bindings,
            None if environment is None else environment._handle,
            () if environment is None else environment._callbacks,
            UInt,
            CELType,
            EnumValue,
            Message,
            Duration,
            Timestamp,
            CELMap,
            EvaluationError,
            OptionalValue,
            IPAddress,
            CIDR,
        )

    def __call__(self, bindings: dict[str, Value]) -> Value:
        return self.evaluate(bindings)

    @property
    def result_type(self) -> CELType | None:
        return _native.result_type(self._handle, CELType)


class Environment:
    __slots__ = ("_callbacks", "_handle")

    def __init__(
        self,
        *,
        variables: dict[str, CELType] | None = None,
        constants: dict[str, Value] | None = None,
        container: str = "",
        descriptors: bytes = b"",
        strong_enums: bool = False,
        functions: tuple[Function, ...] = (),
    ) -> None:
        if type(strong_enums) is not bool:
            raise TypeError("strong_enums must be a bool")
        if type(functions) is not tuple or any(type(function) is not Function for function in functions):
            raise TypeError("functions must be a tuple of Function values")
        self._callbacks = tuple(function.implementation for function in functions)
        specifications = tuple(
            (
                function.name,
                function.overload_id,
                function.parameters,
                function.result,
                function.member,
                function.implementation is not None,
            )
            for function in functions
        )
        try:
            self._handle = _native.environment(
                variables or {},
                constants or {},
                container,
                descriptors,
                strong_enums,
                specifications,
                UInt,
                CELType,
                EnumValue,
                Message,
                Duration,
                Timestamp,
                CELMap,
                OptionalValue,
                IPAddress,
                CIDR,
            )
        except ValueError as exc:
            raise CompileError(str(exc)) from None

    def compile(self, source: str, *, check: bool = True) -> Program:
        return Program(source, environment=self, check=check)
