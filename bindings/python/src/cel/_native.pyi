from cel.enums import EnumValue
from cel.maps import CELMap
from cel.network import CIDR, IPAddress
from cel.optional import OptionalValue
from cel.program import CELType, EvaluationError, Message, UInt, Value
from cel.temporal import Duration, Timestamp

def normalize_network(value: str, is_cidr: bool) -> str: ...
def compile(source: str) -> object: ...
def fast_plan(handle: object) -> str | None: ...
def matches_literal(handle: object, pattern: str, text: str, error_type: type[EvaluationError]) -> bool: ...
def compile_in(environment: object | None, source: str, check: bool) -> object: ...
def result_type(handle: object, cel_type: type[CELType]) -> CELType | None: ...
def environment(
    variables: dict[str, CELType],
    constants: dict[str, Value],
    container: str,
    descriptors: bytes,
    strong_enums: bool,
    functions: tuple[tuple[str, str, tuple[CELType, ...], CELType, bool, bool], ...],
    uint_type: type[UInt],
    cel_type: type[CELType],
    enum_type: type[EnumValue],
    message_type: type[Message],
    duration_type: type[Duration],
    timestamp_type: type[Timestamp],
    map_type: type[CELMap],
    optional_type: type[OptionalValue],
    ip_type: type[IPAddress],
    cidr_type: type[CIDR],
) -> object: ...
def evaluate(
    handle: object,
    bindings: dict[str, Value],
    environment: object | None,
    callbacks: tuple[object, ...],
    uint_type: type[UInt],
    cel_type: type[CELType],
    enum_type: type[EnumValue],
    message_type: type[Message],
    duration_type: type[Duration],
    timestamp_type: type[Timestamp],
    map_type: type[CELMap],
    evaluation_error_type: type[EvaluationError],
    optional_type: type[OptionalValue],
    ip_type: type[IPAddress],
    cidr_type: type[CIDR],
) -> Value: ...
