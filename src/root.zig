//! CEL compiler and evaluator. Programs own syntax; evaluation values borrow input or caller arena storage.

/// Runtime values and input bindings.
pub const value = @import("value.zig");
/// Compilation and evaluation APIs.
pub const program = @import("program.zig");
/// Reusable compiled expression.
pub const Program = program.Program;
/// Namespaces, declarations, constants, and checked compilation.
pub const Environment = program.Environment;
/// Static CEL type description.
pub const Type = program.Type;
/// A named variable and its static type.
pub const Declaration = program.Declaration;
/// A typed custom function overload and its optional trusted implementation.
pub const Function = program.Function;
/// Discriminated evaluation and callback failures.
pub const EvalError = program.EvalError;
/// Resource limits for untrusted expressions.
pub const Limits = program.Limits;
/// Typed CEL value.
pub const Value = value.Value;
/// Named evaluation input.
pub const Binding = value.Binding;
/// CEL map entry.
pub const Entry = value.Entry;
/// A protobuf message's fully qualified type name and wire bytes.
pub const Message = value.Message;
/// A protobuf enum's fully qualified type name and signed 32-bit number.
pub const EnumValue = value.EnumValue;
/// Nanosecond temporal value representations.
pub const temporal = @import("temporal.zig");
/// Normalized UTC instant.
pub const Timestamp = temporal.Timestamp;
/// Signed nanosecond duration.
pub const Duration = temporal.Duration;
/// Pure network address and prefix values.
pub const network = @import("network.zig");
/// An IPv4 or IPv6 address without a zone or port.
pub const IP = network.IP;
/// An IP prefix that preserves unmasked host bits.
pub const CIDR = network.CIDR;

test {
    _ = value;
    _ = program;
    _ = temporal;
    _ = network;
}
