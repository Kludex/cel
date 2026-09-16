//! Shared public evaluation failures for the interpreter and trusted function implementations.

/// Failures produced by evaluating a compiled CEL program.
pub const EvalError = error{
    /// Allocation failed.
    OutOfMemory,
    /// No input or local variable has this name.
    UndeclaredReference,
    /// No overload accepts the supplied argument types or count.
    NoMatchingOverload,
    /// An integer operation is outside the type's range.
    Overflow,
    /// An integer divisor is zero.
    DivisionByZero,
    /// The requested map key is absent.
    NoSuchKey,
    /// A list index is outside the list.
    IndexOutOfBounds,
    /// A map literal contains equal keys.
    DuplicateKey,
    /// Execution exhausted its work budget.
    CostLimitExceeded,
    /// Evaluation nesting exceeds the limit.
    DepthLimitExceeded,
    /// A collection exceeds its size limit.
    CollectionLimitExceeded,
    /// A conversion cannot represent the input value.
    InvalidArgument,
    /// Regex compilation, caching, or program size exceeds the configured limit.
    RegexLimitExceeded,
    /// A type is not registered in the environment.
    UnsupportedType,
    /// Protobuf conversion exceeds its resource limits.
    ProtobufLimitExceeded,
    /// A declared function has no implementation.
    MissingFunction,
    /// Trusted host code raised an exception that must not be suppressed by CEL.
    HostFunctionError,
};
