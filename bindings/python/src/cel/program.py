from __future__ import annotations

from typing import cast

from cel import _native
from cel.enums import EnumValue
from cel.functions import Function as Function
from cel.maps import CELMap
from cel.network import CIDR, IPAddress
from cel.optional import OptionalValue
from cel.plain import BAIL, FastFunction, compile_plain
from cel.temporal import Duration, Timestamp
from cel.values import CELType as CELType, MapKey as MapKey, Message as Message, UInt as UInt, Value as Value


class _Unset:
    """Marker for a fast path that has not been compiled yet."""


_UNSET = _Unset()


class CompileError(ValueError):
    """The expression cannot be compiled."""


class EvaluationError(RuntimeError):
    """The expression cannot be evaluated with these bindings."""


class Program:
    __slots__ = ("_environment", "_fast", "_handle")

    def __init__(self, source: str, *, environment: Environment | None = None, check: bool = False) -> None:
        if type(check) is not bool:
            raise TypeError("check must be a bool")
        self._environment = environment
        self._fast: FastFunction | None | _Unset = _UNSET
        try:
            if environment is None and not check:
                self._handle = _native.compile(source)
            else:
                self._handle = _native.compile_in(None if environment is None else environment._handle, source, check)
        except ValueError as exc:
            raise CompileError(str(exc)) from None

    @property
    def has_fast_path(self) -> bool:
        """Whether `evaluate(bindings, plain_data=True)` can bypass the engine for this program."""
        return self._fast_path() is not None

    def _fast_path(self) -> FastFunction | None:
        if isinstance(self._fast, _Unset):
            self._fast = compile_plain(_native.fast_plan(self._handle))
        return self._fast

    def evaluate(self, bindings: dict[str, Value], *, plain_data: bool = False) -> Value:
        """Evaluate with `bindings`.

        `plain_data=True` runs a Python function compiled from the program when it uses only string,
        boolean, and integer literals, unquoted field selection, string-keyed indexing, `==`, `!=`, `&&`,
        `||`, `!`, `?:`, and the `startsWith`/`endsWith`/`contains` predicates. Bindings must be dictionaries
        of dictionaries, `str`, `bool`, and int64 `int` values; any other value sends the call to the engine
        so the result is unchanged. Unused keys are never read in this mode.
        """
        if type(plain_data) is not bool:
            raise TypeError("plain_data must be a bool")
        if plain_data:
            fast = self._fast if not isinstance(self._fast, _Unset) else self._fast_path()
            if fast is not None:
                result = fast(bindings)
                if result is not BAIL:
                    return cast(Value, result)
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
