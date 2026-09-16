//! Node-API binding. External handles own compiled programs; each evaluation owns a conversion arena.

const std = @import("std");
const cel = @import("root.zig");
const names = @import("names.zig");
const c = @cImport({
    @cDefine("NAPI_VERSION", "8");
    @cInclude("node_api.h");
});
const Value = cel.Value;
const gpa = std.heap.c_allocator;

const max_depth: usize = 128;
const max_values: usize = 100_000;
const max_input_bytes: usize = 1_048_576;
const max_safe_integer: f64 = 9_007_199_254_740_991;
const program_tag = c.napi_type_tag{ .lower = 0x43454c5f50524f47, .upper = 0x52414d5f48414e44 };

const NapiError = error{ JavaScriptException, NapiFailure, OutOfMemory };

const plain_null: u8 = 0;
const plain_false: u8 = 1;
const plain_true: u8 = 2;
const plain_number: u8 = 3;
const plain_string: u8 = 4;
const plain_list: u8 = 5;
const plain_map: u8 = 6;
const plain_deferred: u8 = 7;
const plain_bigint: u8 = 8;

/// Borrowed view of the wrapper's flattened plain-data stream. The typed arrays outlive one evaluation.
const Plain = struct {
    env: c.napi_env,
    numbers: []const f64,
    length: usize,
    index: usize = 0,
    bytes: []const u8,
    byte_index: usize = 0,
    deferred: c.napi_value,

    fn init(env: c.napi_env, numbers_value: c.napi_value, length_value: c.napi_value, bytes_value: c.napi_value, deferred: c.napi_value) NapiError!Plain {
        var numbers_type: c.napi_typedarray_type = undefined;
        var numbers_len: usize = 0;
        var numbers_data: ?*anyopaque = null;
        try check(env, c.napi_get_typedarray_info(env, numbers_value, &numbers_type, &numbers_len, &numbers_data, null, null));
        if (numbers_type != c.napi_float64_array) return failType(env, "malformed plain-data stream");
        var bytes_type: c.napi_typedarray_type = undefined;
        var bytes_len: usize = 0;
        var bytes_data: ?*anyopaque = null;
        try check(env, c.napi_get_typedarray_info(env, bytes_value, &bytes_type, &bytes_len, &bytes_data, null, null));
        if (bytes_type != c.napi_uint8_array) return failType(env, "malformed plain-data stream");
        var length_double: f64 = 0;
        try check(env, c.napi_get_value_double(env, length_value, &length_double));
        if (!(length_double >= 0) or length_double > @as(f64, @floatFromInt(numbers_len)) or @trunc(length_double) != length_double)
            return failType(env, "malformed plain-data stream");
        const numbers: []const f64 = if (numbers_len == 0) &.{} else @as([*]const f64, @ptrCast(@alignCast(numbers_data orelse return error.NapiFailure)))[0..numbers_len];
        const bytes: []const u8 = if (bytes_len == 0) &.{} else @as([*]const u8, @ptrCast(bytes_data orelse return error.NapiFailure))[0..bytes_len];
        return .{ .env = env, .numbers = numbers, .length = @intFromFloat(length_double), .bytes = bytes, .deferred = deferred };
    }

    fn next(self: *Plain) NapiError!f64 {
        if (self.index >= self.length) return failType(self.env, "malformed plain-data stream");
        const value = self.numbers[self.index];
        self.index += 1;
        return value;
    }

    fn tag(self: *Plain) NapiError!u8 {
        const value = try self.next();
        if (!(value >= 0) or value > plain_bigint or @trunc(value) != value) return failType(self.env, "malformed plain-data stream");
        return @intFromFloat(value);
    }

    fn count(self: *Plain) NapiError!usize {
        const value = try self.next();
        if (!(value >= 0) or value > max_values * 16 or @trunc(value) != value) return failType(self.env, "malformed plain-data stream");
        return @intFromFloat(value);
    }
};
const environment_tag = c.napi_type_tag{ .lower = 0x43454c5f454e5652, .upper = 0x49524f4e4d454e54 };
const EnvHandle = struct {
    arena: std.heap.ArenaAllocator,
    environment: cel.Environment,
    active: ?*Converter = null,
};
const FnContext = struct { owner: *EnvHandle, index: usize };

const ProgramHandle = struct {
    program: cel.Program,
};

fn check(env: c.napi_env, status: c.napi_status) NapiError!void {
    if (status == c.napi_ok) return;
    if (status == c.napi_pending_exception) return error.JavaScriptException;
    var pending = false;
    if (c.napi_is_exception_pending(env, &pending) == c.napi_ok and pending) return error.JavaScriptException;
    return error.NapiFailure;
}

fn failType(env: c.napi_env, message: [*:0]const u8) NapiError {
    _ = c.napi_throw_type_error(env, null, message);
    return error.JavaScriptException;
}

fn failRange(env: c.napi_env, message: [*:0]const u8) NapiError {
    _ = c.napi_throw_range_error(env, null, message);
    return error.JavaScriptException;
}

fn setCoreError(env: c.napi_env, comptime prefix: []const u8, err: anyerror) void {
    const name = @errorName(err);
    var code_buffer: [64]u8 = undefined;
    const code = std.fmt.bufPrintZ(&code_buffer, "{s}{s}", .{ prefix, name }) catch return;
    _ = c.napi_throw_error(env, code.ptr, name.ptr);
}

fn finishFailure(env: c.napi_env, comptime prefix: []const u8, err: anyerror) c.napi_value {
    if (err == error.JavaScriptException) return null;
    if (err == error.OutOfMemory) {
        setCoreError(env, prefix, error.OutOfMemory);
        return null;
    }
    _ = c.napi_throw_error(env, "NodeAPIError", "Node-API call failed");
    return null;
}

fn finalizeProgram(_: c.node_api_basic_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const pointer = data orelse return;
    const handle: *ProgramHandle = @ptrCast(@alignCast(pointer));
    handle.program.deinit();
    gpa.destroy(handle);
}

fn compileCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return compileImpl(env, info) catch |err| finishTypedFailure(env, info, 1, err);
}

fn compileImpl(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var argc: usize = 3;
    var argv: [3]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &argc, &argv, null, null));
    if (argc != 2) return failType(env, "compile requires source and an error constructor");
    return compileSource(env, argv[0], .{}, false, argv[1]);
}

fn compileSource(env: c.napi_env, input: c.napi_value, config: cel.Environment, checked: bool, error_type: c.napi_value) NapiError!c.napi_value {
    var value_type: c.napi_valuetype = undefined;
    try check(env, c.napi_typeof(env, input, &value_type));
    if (value_type != c.napi_string) return failType(env, "source must be a string");

    var source_arena = std.heap.ArenaAllocator.init(gpa);
    defer source_arena.deinit();
    const source = readJavaScriptString(env, source_arena.allocator(), input, (cel.Limits{}).max_source_bytes) catch |err| switch (err) {
        error.StringLimitExceeded => {
            try throwTypedError(env, error_type, error.SourceLimitExceeded);
            return error.JavaScriptException;
        },
        else => |other| return other,
    };

    const handle = try gpa.create(ProgramHandle);
    const compiled = if (checked) config.compile(gpa, source, .{}) else config.parse(gpa, source, .{});
    handle.program = compiled catch |err| {
        gpa.destroy(handle);
        try throwTypedError(env, error_type, err);
        return error.JavaScriptException;
    };

    var external: c.napi_value = null;
    check(env, c.napi_create_external(env, handle, finalizeProgram, null, &external)) catch |err| {
        handle.program.deinit();
        gpa.destroy(handle);
        return err;
    };
    try check(env, c.napi_type_tag_object(env, external, &program_tag));
    return external;
}

fn finalizeEnvironment(_: c.node_api_basic_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const handle: *EnvHandle = @ptrCast(@alignCast(data orelse return));
    handle.environment.deinit();
    handle.arena.deinit();
    gpa.destroy(handle);
}

fn environmentCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return environmentImpl(env, info) catch |err| finishTypedFailure(env, info, 17, err);
}

fn environmentImpl(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var argc: usize = 23;
    var argv: [23]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &argc, &argv, null, null));
    if (argc != 22) return failType(env, "invalid environment arguments");
    var strong_kind: c.napi_valuetype = undefined;
    try check(env, c.napi_typeof(env, argv[4], &strong_kind));
    if (strong_kind != c.napi_boolean) return failType(env, "strongEnums must be a boolean");
    var strong_enums = false;
    try check(env, c.napi_get_value_bool(env, argv[4], &strong_enums));
    const handle = try gpa.create(EnvHandle);
    handle.arena = std.heap.ArenaAllocator.init(gpa);
    handle.environment = .{};
    handle.active = null;
    var transferred = false;
    errdefer if (!transferred) {
        handle.environment.deinit();
        handle.arena.deinit();
        gpa.destroy(handle);
    };
    var converter = Converter{
        .env = env,
        .arena = handle.arena.allocator(),
        .uint_type = argv[6],
        .double_type = argv[7],
        .cel_type = argv[8],
        .enum_type = argv[9],
        .message_type = argv[10],
        .duration_type = argv[11],
        .timestamp_type = argv[12],
        .object_prototype = argv[13],
        .map_constructor = argv[14],
        .map_snapshot = argv[15],
        .map_set = argv[16],
        .optional_type = argv[18],
        .property_names = argv[19],
        .ip_type = argv[20],
        .cidr_type = argv[21],
    };
    const variables = try converter.declarations(argv[0]);
    const descriptors = try converter.fromJavaScript(argv[3], 0);
    if (descriptors != .bytes) return failType(env, "descriptors must be a Uint8Array");
    const config = cel.Environment{
        .variables = variables,
        .constants = try converter.bindings(argv[1]),
        .functions = try converter.functions(argv[5], handle),
        .container = try converter.readString(argv[2]),
        .descriptors = descriptors.bytes,
        .strong_enums = strong_enums,
    };
    handle.environment = config.clone(handle.arena.allocator(), .{}) catch |err| {
        try throwTypedError(env, argv[17], err);
        return error.JavaScriptException;
    };
    var result: c.napi_value = null;
    try check(env, c.napi_create_external(env, handle, finalizeEnvironment, null, &result));
    transferred = true;
    try check(env, c.napi_type_tag_object(env, result, &environment_tag));
    return result;
}

fn compileInCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return compileInImpl(env, info) catch |err| finishTypedFailure(env, info, 3, err);
}

fn compileInImpl(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var argc: usize = 5;
    var argv: [5]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &argc, &argv, null, null));
    if (argc != 4) return failType(env, "invalid compile arguments");
    var kind: c.napi_valuetype = undefined;
    try check(env, c.napi_typeof(env, argv[0], &kind));
    var config: cel.Environment = .{};
    if (kind != c.napi_null) {
        var tagged = false;
        try check(env, c.napi_check_object_type_tag(env, argv[0], &environment_tag, &tagged));
        if (!tagged) return failType(env, "invalid Environment handle");
        var pointer: ?*anyopaque = null;
        try check(env, c.napi_get_value_external(env, argv[0], &pointer));
        config = @as(*const EnvHandle, @ptrCast(@alignCast(pointer orelse return error.NapiFailure))).environment;
    }
    var checked: bool = false;
    try check(env, c.napi_get_value_bool(env, argv[2], &checked));
    return compileSource(env, argv[1], config, checked, argv[3]);
}

fn resultTypeCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return resultTypeImpl(env, info) catch |err| finishTypedFailure(env, info, 2, err);
}

fn resultTypeImpl(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var argc: usize = 4;
    var argv: [4]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &argc, &argv, null, null));
    if (argc != 3) return failType(env, "invalid resultType arguments");
    var tagged = false;
    try check(env, c.napi_check_object_type_tag(env, argv[0], &program_tag, &tagged));
    if (!tagged) return failType(env, "invalid Program handle");
    var pointer: ?*anyopaque = null;
    try check(env, c.napi_get_value_external(env, argv[0], &pointer));
    const program: *const ProgramHandle = @ptrCast(@alignCast(pointer orelse return error.NapiFailure));
    if (program.program.result_type) |t| return typeToJavaScript(env, argv[1], t);
    var result: c.napi_value = null;
    try check(env, c.napi_get_null(env, &result));
    return result;
}

fn fastPlanCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return fastPlanImpl(env, info) catch |err| finishFailure(env, "CEL_PLAN_", err);
}

/// Return the program's plain-data subset as a JSON string, or null when it has none.
fn fastPlanImpl(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &argc, &argv, null, null));
    if (argc != 1) return failType(env, "fastPlan requires a Program handle");
    var tagged = false;
    try check(env, c.napi_check_object_type_tag(env, argv[0], &program_tag, &tagged));
    if (!tagged) return failType(env, "invalid Program handle");
    var pointer: ?*anyopaque = null;
    try check(env, c.napi_get_value_external(env, argv[0], &pointer));
    const program: *const ProgramHandle = @ptrCast(@alignCast(pointer orelse return error.NapiFailure));
    var result: c.napi_value = null;
    const plan = try program.program.fastPlan(gpa) orelse {
        try check(env, c.napi_get_null(env, &result));
        return result;
    };
    defer gpa.free(plan);
    try check(env, c.napi_create_string_utf8(env, plan.ptr, plan.len, &result));
    return result;
}

fn typeToJavaScript(env: c.napi_env, constructor: c.napi_value, t: cel.Type) NapiError!c.napi_value {
    var name: c.napi_value = null;
    try check(env, c.napi_create_string_utf8(env, t.name.ptr, t.name.len, &name));
    var parameters: c.napi_value = null;
    try check(env, c.napi_create_array_with_length(env, t.parameters.len, &parameters));
    for (t.parameters, 0..) |parameter, i| {
        try check(env, c.napi_set_element(env, parameters, @intCast(i), try typeToJavaScript(env, constructor, parameter)));
    }
    var kind: c.napi_value = null;
    const kind_name = @tagName(t.kind);
    try check(env, c.napi_create_string_utf8(env, kind_name.ptr, kind_name.len, &kind));
    const args = [_]c.napi_value{ name, parameters, kind };
    var result: c.napi_value = null;
    try check(env, c.napi_new_instance(env, constructor, args.len, &args, &result));
    return result;
}

fn evaluateCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return evaluateImpl(env, info) catch |err| finishTypedFailure(env, info, 15, err);
}

fn finishTypedFailure(env: c.napi_env, info: c.napi_callback_info, constructor_index: usize, err: NapiError) c.napi_value {
    if (err == error.OutOfMemory) {
        var argc: usize = 18;
        var argv: [18]c.napi_value = @splat(null);
        if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) == c.napi_ok and argc > constructor_index) {
            throwTypedError(env, argv[constructor_index], err) catch |failure|
                return finishFailure(env, "CEL_NATIVE_", failure);
            return null;
        }
    }
    return finishFailure(env, "CEL_NATIVE_", err);
}

fn throwTypedError(env: c.napi_env, constructor: c.napi_value, err: anyerror) NapiError!void {
    const name = @errorName(err);
    var code: c.napi_value = null;
    var exception: c.napi_value = null;
    try check(env, c.napi_create_string_utf8(env, name.ptr, name.len, &code));
    try check(env, c.napi_new_instance(env, constructor, 1, &code, &exception));
    try check(env, c.napi_throw(env, exception));
}

fn evaluateImpl(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var argc: usize = 25;
    var argv: [25]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &argc, &argv, null, null));
    if (argc != 24) return failType(env, "evaluate requires a program, bindings, and conversion types");

    var tagged = false;
    try check(env, c.napi_check_object_type_tag(env, argv[0], &program_tag, &tagged));
    if (!tagged) return failType(env, "invalid Program handle");
    var pointer: ?*anyopaque = null;
    try check(env, c.napi_get_value_external(env, argv[0], &pointer));
    const handle: *const ProgramHandle = @ptrCast(@alignCast(pointer orelse return failType(env, "invalid Program handle")));

    var owner: ?*EnvHandle = null;
    var environment_kind: c.napi_valuetype = undefined;
    try check(env, c.napi_typeof(env, argv[2], &environment_kind));
    if (environment_kind != c.napi_undefined) {
        try check(env, c.napi_check_object_type_tag(env, argv[2], &environment_tag, &tagged));
        if (!tagged) return failType(env, "invalid Environment handle");
        try check(env, c.napi_get_value_external(env, argv[2], &pointer));
        owner = @ptrCast(@alignCast(pointer orelse return failType(env, "invalid Environment handle")));
    }
    var callbacks_are_array = false;
    try check(env, c.napi_is_array(env, argv[3], &callbacks_are_array));
    if (!callbacks_are_array) return failType(env, "callbacks must be an array");
    var callback_count: u32 = 0;
    try check(env, c.napi_get_array_length(env, argv[3], &callback_count));
    if (@as(usize, callback_count) != if (owner) |handle_owner| handle_owner.environment.functions.len else 0) {
        return failType(env, "callback count does not match environment");
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var stack = std.heap.stackFallback(4096, arena_state.allocator());
    const arena = stack.get();
    var converter = Converter{
        .env = env,
        .arena = arena,
        .uint_type = argv[4],
        .double_type = argv[5],
        .cel_type = argv[6],
        .enum_type = argv[7],
        .object_prototype = argv[8],
        .message_type = argv[9],
        .duration_type = argv[10],
        .timestamp_type = argv[11],
        .map_constructor = argv[12],
        .map_snapshot = argv[13],
        .map_set = argv[14],
        .optional_type = argv[16],
        .property_names = argv[17],
        .ip_type = argv[18],
        .cidr_type = argv[19],
        .callbacks = argv[3],
    };
    const previous = if (owner) |handle_owner| handle_owner.active else null;
    if (owner) |handle_owner| handle_owner.active = &converter;
    defer if (owner) |handle_owner| {
        handle_owner.active = previous;
    };
    const bindings = try converter.plainBindings(argv[20], argv[21], argv[22], argv[23]);
    const result = handle.program.evaluate(arena, bindings) catch |err| {
        if (err == error.HostFunctionError) {
            var pending = false;
            try check(env, c.napi_is_exception_pending(env, &pending));
            if (pending) return error.JavaScriptException;
        }
        try throwTypedError(env, argv[15], err);
        return error.JavaScriptException;
    };
    return converter.toJavaScript(result, 0);
}

fn readJavaScriptString(env: c.napi_env, arena: std.mem.Allocator, input: c.napi_value, max_bytes: usize) (NapiError || error{StringLimitExceeded})![]const u8 {
    var buffer: [64]u8 = undefined;
    var written: usize = 0;
    const status = c.napi_get_value_string_utf8(env, input, &buffer, buffer.len, &written);
    if (status == c.napi_string_expected) return failType(env, "expected a string");
    try check(env, status);
    // UTF-8 truncation may leave up to three spare bytes before the terminator.
    const result = if (written < buffer.len - 4) blk: {
        if (written > max_bytes) return error.StringLimitExceeded;
        break :blk try arena.dupe(u8, buffer[0..written]);
    } else blk: {
        var length: usize = 0;
        try check(env, c.napi_get_value_string_utf16(env, input, null, 0, &length));
        if (length > max_bytes) return error.StringLimitExceeded;
        try check(env, c.napi_get_value_string_utf8(env, input, null, 0, &length));
        if (length > max_bytes) return error.StringLimitExceeded;
        const bytes = try arena.alloc(u8, length + 1);
        try check(env, c.napi_get_value_string_utf8(env, input, bytes.ptr, bytes.len, &written));
        break :blk bytes[0..written];
    };
    // Node replaces lone surrogates with U+FFFD, so those outputs need a lossless check.
    if (std.mem.indexOf(u8, result, "\xef\xbf\xbd") != null) {
        var inline_units: [64]u16 = undefined;
        const units = if (result.len < inline_units.len) &inline_units else try arena.alloc(u16, result.len + 1);
        try check(env, c.napi_get_value_string_utf16(env, input, units.ptr, units.len, &written));
        for (units[0..written]) |*unit| unit.* = std.mem.nativeToLittle(u16, unit.*);
        var iterator = std.unicode.Utf16LeIterator.init(units[0..written]);
        while (iterator.nextCodepoint() catch return failType(env, "strings must not contain unpaired UTF-16 surrogates")) |_| {}
    }
    return result;
}

const Converter = struct {
    env: c.napi_env,
    arena: std.mem.Allocator,
    uint_type: c.napi_value,
    double_type: c.napi_value,
    cel_type: c.napi_value,
    enum_type: c.napi_value,
    message_type: c.napi_value,
    duration_type: c.napi_value,
    timestamp_type: c.napi_value,
    object_prototype: c.napi_value,
    map_constructor: c.napi_value,
    map_snapshot: c.napi_value,
    map_set: c.napi_value,
    optional_type: c.napi_value,
    property_names: c.napi_value,
    ip_type: c.napi_value,
    cidr_type: c.napi_value,
    callbacks: c.napi_value = null,
    remaining: usize = max_values,
    input_bytes: usize = 0,
    ancestors: [max_depth]c.napi_value = [_]c.napi_value{null} ** max_depth,
    ancestor_count: usize = 0,

    fn declarations(self: *Converter, input: c.napi_value) NapiError![]const cel.Declaration {
        var kind: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, input, &kind));
        if (kind != c.napi_object or !try self.plainObject(input)) return failType(self.env, "variables must be a plain object");
        const keys = try self.propertyNames(input);
        var count: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, keys, &count));
        if (count > self.remaining) return failRange(self.env, "declaration limit exceeded");
        const declarations_list = try self.arena.alloc(cel.Declaration, count);
        for (declarations_list, 0..) |*declaration, i| {
            var key: c.napi_value = null;
            var type_value: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, keys, @intCast(i), &key));
            try check(self.env, c.napi_get_property(self.env, input, key, &type_value));
            declaration.* = .{ .name = try self.readString(key), .type = try self.fromType(type_value, 0) };
        }
        return declarations_list;
    }

    fn functions(self: *Converter, input: c.napi_value, owner: *EnvHandle) NapiError![]const cel.Function {
        var is_array = false;
        try check(self.env, c.napi_is_array(self.env, input, &is_array));
        if (!is_array) return failType(self.env, "functions must be an array");
        var length: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, input, &length));
        if (length > self.remaining) return failRange(self.env, "function declaration limit exceeded");
        const output = try self.arena.alloc(cel.Function, length);
        const contexts = try self.arena.alloc(FnContext, length);
        for (output, contexts, 0..) |*function, *context, index| {
            var specification: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, input, @intCast(index), &specification));
            try check(self.env, c.napi_is_array(self.env, specification, &is_array));
            var field_count: u32 = 0;
            if (is_array) try check(self.env, c.napi_get_array_length(self.env, specification, &field_count));
            if (!is_array or field_count != 6) return failType(self.env, "invalid function specification");
            var fields: [6]c.napi_value = @splat(null);
            for (&fields, 0..) |*field, field_index| {
                try check(self.env, c.napi_get_element(self.env, specification, @intCast(field_index), field));
            }
            var value_kind: c.napi_valuetype = undefined;
            try check(self.env, c.napi_typeof(self.env, fields[4], &value_kind));
            if (value_kind != c.napi_boolean) return failType(self.env, "member must be a boolean");
            var member = false;
            try check(self.env, c.napi_get_value_bool(self.env, fields[4], &member));
            try check(self.env, c.napi_typeof(self.env, fields[5], &value_kind));
            if (value_kind != c.napi_boolean) return failType(self.env, "hasImplementation must be a boolean");
            var has_implementation = false;
            try check(self.env, c.napi_get_value_bool(self.env, fields[5], &has_implementation));
            try check(self.env, c.napi_is_array(self.env, fields[2], &is_array));
            if (!is_array) return failType(self.env, "function parameters must be an array");
            var parameter_count: u32 = 0;
            try check(self.env, c.napi_get_array_length(self.env, fields[2], &parameter_count));
            if (parameter_count > self.remaining) return failRange(self.env, "function declaration limit exceeded");
            const parameters = try self.arena.alloc(cel.Type, parameter_count);
            for (parameters, 0..) |*parameter, parameter_index| {
                var item: c.napi_value = null;
                try check(self.env, c.napi_get_element(self.env, fields[2], @intCast(parameter_index), &item));
                parameter.* = try self.fromType(item, 0);
            }
            context.* = .{ .owner = owner, .index = index };
            function.* = .{
                .name = try self.readString(fields[0]),
                .overload_id = try self.readString(fields[1]),
                .parameters = parameters,
                .result = try self.fromType(fields[3], 0),
                .member = member,
                .implementation = if (has_implementation) invokeFunction else null,
                .context = context,
            };
        }
        return output;
    }

    fn fromType(self: *Converter, input: c.napi_value, depth: usize) NapiError!cel.Type {
        if (depth >= max_depth or self.remaining == 0) return failRange(self.env, "declaration limit exceeded");
        self.remaining -= 1;
        var matches = false;
        try check(self.env, c.napi_instanceof(self.env, input, self.cel_type, &matches));
        if (!matches) return failType(self.env, "expected CELType");
        var name: c.napi_value = null;
        var parameters: c.napi_value = null;
        var kind_value: c.napi_value = null;
        try check(self.env, c.napi_get_named_property(self.env, input, "name", &name));
        const text = try self.readString(name);
        try check(self.env, c.napi_get_named_property(self.env, input, "parameters", &parameters));
        try check(self.env, c.napi_get_named_property(self.env, input, "kind", &kind_value));
        const kind_text = try self.readString(kind_value);
        const type_kind = std.meta.stringToEnum(cel.Type.Kind, kind_text) orelse
            return failRange(self.env, "invalid CELType kind");
        var is_array = false;
        try check(self.env, c.napi_is_array(self.env, parameters, &is_array));
        if (!is_array) return failType(self.env, "type parameters must be an array");
        var length: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, parameters, &length));
        if (length > self.remaining) return failRange(self.env, "declaration limit exceeded");
        const nested = try self.arena.alloc(cel.Type, length);
        for (nested, 0..) |*parameter, i| {
            var item: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, parameters, @intCast(i), &item));
            parameter.* = try self.fromType(item, depth + 1);
        }
        return .{ .name = text, .parameters = nested, .kind = type_kind };
    }

    fn bindings(self: *Converter, input: c.napi_value) NapiError![]const cel.Binding {
        var value_type: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, input, &value_type));
        if (value_type != c.napi_object or !try self.plainObject(input)) {
            return failType(self.env, "bindings must be a plain object");
        }
        const keys = try self.propertyNames(input);
        var len: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, keys, &len));
        if (len > self.remaining) return failRange(self.env, "input exceeds collection limit");
        const out = try self.arena.alloc(cel.Binding, len);
        try self.pushAncestor(input);
        defer self.popAncestor();
        for (out, 0..) |*slot, index| {
            var key: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, keys, @intCast(index), &key));
            const name = try self.readString(key);
            var item: c.napi_value = null;
            try check(self.env, c.napi_get_property(self.env, input, key, &item));
            slot.* = .{ .name = name, .value = try self.fromJavaScript(item, 0) };
        }
        return out;
    }

    fn fromJavaScript(self: *Converter, input: c.napi_value, depth: usize) NapiError!Value {
        if (depth >= max_depth) return failRange(self.env, "input exceeds depth limit");
        if (self.remaining == 0) return failRange(self.env, "input exceeds collection limit");
        self.remaining -= 1;

        var value_type: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, input, &value_type));
        return switch (value_type) {
            c.napi_null => .null,
            c.napi_boolean => blk: {
                var value = false;
                try check(self.env, c.napi_get_value_bool(self.env, input, &value));
                break :blk .{ .bool = value };
            },
            c.napi_number => try self.number(input, false),
            c.napi_bigint => blk: {
                var value: i64 = 0;
                var lossless = false;
                try check(self.env, c.napi_get_value_bigint_int64(self.env, input, &value, &lossless));
                if (!lossless) return failRange(self.env, "bigint must fit signed 64-bit CEL int");
                break :blk .{ .int = value };
            },
            c.napi_string => .{ .string = try self.readString(input) },
            c.napi_object => try self.object(input, depth),
            c.napi_undefined => failType(self.env, "undefined is not a CEL value"),
            else => failType(self.env, "unsupported CEL input type"),
        };
    }

    fn number(self: *Converter, input: c.napi_value, force_double: bool) NapiError!Value {
        var value: f64 = 0;
        try check(self.env, c.napi_get_value_double(self.env, input, &value));
        if (force_double or !std.math.isFinite(value) or @trunc(value) != value or
            (value == 0 and std.math.signbit(value))) return .{ .double = value };
        if (value < -max_safe_integer or value > max_safe_integer) {
            return failRange(self.env, "integer numbers must be safe; use bigint or Double");
        }
        return .{ .int = @intFromFloat(value) };
    }

    fn object(self: *Converter, input: c.napi_value, depth: usize) NapiError!Value {
        var is_array = false;
        try check(self.env, c.napi_is_array(self.env, input, &is_array));
        if (is_array) return self.list(input, depth);

        var is_typed_array = false;
        try check(self.env, c.napi_is_typedarray(self.env, input, &is_typed_array));
        if (is_typed_array) {
            var array_type: c.napi_typedarray_type = undefined;
            var len: usize = 0;
            var data: ?*anyopaque = null;
            try check(self.env, c.napi_get_typedarray_info(self.env, input, &array_type, &len, &data, null, null));
            if (array_type != c.napi_uint8_array) return failType(self.env, "bytes must be a Uint8Array or Buffer");
            try self.chargeBytes(len);
            if (len == 0) return .{ .bytes = &.{} };
            const bytes = @as([*]const u8, @ptrCast(data orelse return error.NapiFailure))[0..len];
            // A later property getter may detach or mutate this ArrayBuffer.
            return .{ .bytes = try self.arena.dupe(u8, bytes) };
        }

        switch (try self.snapshotMap(input)) {
            .entries => |entries| return self.nativeMap(input, entries, depth),
            .plain => return self.map(input, depth),
            .other => {},
        }

        var is_ip = false;
        var is_cidr = false;
        try check(self.env, c.napi_instanceof(self.env, input, self.ip_type, &is_ip));
        if (!is_ip) try check(self.env, c.napi_instanceof(self.env, input, self.cidr_type, &is_cidr));
        if (is_ip or is_cidr) {
            var raw: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "value", &raw));
            const text = try self.readString(raw);
            return if (is_ip) Value.fromIP(self.arena, cel.IP.parse(text) catch return failRange(self.env, "invalid IP address")) else Value.fromCIDR(self.arena, cel.CIDR.parse(text) catch return failRange(self.env, "invalid CIDR prefix"));
        }
        var matches = false;
        try check(self.env, c.napi_instanceof(self.env, input, self.optional_type, &matches));
        if (matches) {
            var has_value: c.napi_value = null;
            var value: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "hasValue", &has_value));
            try check(self.env, c.napi_get_named_property(self.env, input, "value", &value));
            var kind: c.napi_valuetype = undefined;
            try check(self.env, c.napi_typeof(self.env, has_value, &kind));
            if (kind != c.napi_boolean) return failType(self.env, "OptionalValue hasValue must be a boolean");
            var present = false;
            try check(self.env, c.napi_get_value_bool(self.env, has_value, &present));
            if (!present) {
                try check(self.env, c.napi_typeof(self.env, value, &kind));
                if (kind != c.napi_null) return failType(self.env, "an absent OptionalValue must have a null value");
                return .{ .optional = null };
            }
            try self.pushAncestor(input);
            defer self.popAncestor();
            return Value.fromOptional(self.arena, try self.fromJavaScript(value, depth + 1));
        }

        matches = false;
        try check(self.env, c.napi_instanceof(self.env, input, self.uint_type, &matches));
        if (matches) return self.uint(input);
        try check(self.env, c.napi_instanceof(self.env, input, self.double_type, &matches));
        if (matches) {
            var value: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "value", &value));
            var value_type: c.napi_valuetype = undefined;
            try check(self.env, c.napi_typeof(self.env, value, &value_type));
            if (value_type != c.napi_number) return failType(self.env, "Double.value must be a number");
            return self.number(value, true);
        }

        try check(self.env, c.napi_instanceof(self.env, input, self.cel_type, &matches));
        if (matches) {
            var name: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "name", &name));
            const text = try self.readString(name);
            if (text.len == 0) return failRange(self.env, "CELType name must not be empty");
            var parameters: c.napi_value = null;
            var kind_value: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "parameters", &parameters));
            try check(self.env, c.napi_get_named_property(self.env, input, "kind", &kind_value));
            const kind_text = try self.readString(kind_value);
            var length: u32 = 0;
            try check(self.env, c.napi_get_array_length(self.env, parameters, &length));
            if (length != 0 or !std.mem.eql(u8, kind_text, "concrete")) {
                return failType(self.env, "non-concrete CELType is a declaration, not a runtime value");
            }
            return .{ .type_value = text };
        }

        try check(self.env, c.napi_instanceof(self.env, input, self.enum_type, &matches));
        if (matches) {
            var name: c.napi_value = null;
            var number_value: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "typeName", &name));
            const type_name = try self.readString(name);
            if (!names.valid(type_name, false)) {
                return failRange(self.env, "EnumValue typeName must be a qualified name");
            }
            if (std.mem.count(u8, type_name, ".") >= max_depth) {
                return failRange(self.env, "EnumValue typeName exceeds depth limit");
            }
            try check(self.env, c.napi_get_named_property(self.env, input, "number", &number_value));
            var kind: c.napi_valuetype = undefined;
            try check(self.env, c.napi_typeof(self.env, number_value, &kind));
            if (kind != c.napi_number) return failType(self.env, "EnumValue number must be an integer number");
            var integer: f64 = 0;
            try check(self.env, c.napi_get_value_double(self.env, number_value, &integer));
            if (!std.math.isFinite(integer) or @trunc(integer) != integer) {
                return failType(self.env, "EnumValue number must be an integer number");
            }
            if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32)) {
                return failRange(self.env, "EnumValue number must fit a signed 32-bit integer");
            }
            return Value.fromEnum(self.arena, .{ .type_name = type_name, .number = @intFromFloat(integer) });
        }

        try check(self.env, c.napi_instanceof(self.env, input, self.message_type, &matches));
        if (matches) {
            var name: c.napi_value = null;
            var data: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "typeName", &name));
            const type_name = try self.readString(name);
            try check(self.env, c.napi_get_named_property(self.env, input, "data", &data));
            const bytes = try self.fromJavaScript(data, depth + 1);
            if (bytes != .bytes) return failType(self.env, "Message data must be a Uint8Array");
            return Value.fromMessage(self.arena, .{ .type_name = type_name, .data = bytes.bytes });
        }
        try check(self.env, c.napi_instanceof(self.env, input, self.duration_type, &matches));
        if (matches) {
            var nanoseconds: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "nanoseconds", &nanoseconds));
            var value: i64 = 0;
            var lossless = false;
            try check(self.env, c.napi_get_value_bigint_int64(self.env, nanoseconds, &value, &lossless));
            if (!lossless) return failRange(self.env, "Duration must fit signed 64-bit nanoseconds");
            return .{ .duration = .{ .nanoseconds = value } };
        }
        try check(self.env, c.napi_instanceof(self.env, input, self.timestamp_type, &matches));
        if (matches) {
            var seconds: c.napi_value = null;
            var nanos: c.napi_value = null;
            try check(self.env, c.napi_get_named_property(self.env, input, "seconds", &seconds));
            try check(self.env, c.napi_get_named_property(self.env, input, "nanos", &nanos));
            var sec: i64 = 0;
            var lossless = false;
            var fraction: f64 = 0;
            try check(self.env, c.napi_get_value_bigint_int64(self.env, seconds, &sec, &lossless));
            try check(self.env, c.napi_get_value_double(self.env, nanos, &fraction));
            if (!lossless or !std.math.isFinite(fraction) or @trunc(fraction) != fraction or fraction < 0 or fraction >= 1_000_000_000) {
                return failRange(self.env, "Timestamp is not normalized");
            }
            const time = cel.Timestamp{ .seconds = sec, .nanos = @intFromFloat(fraction) };
            time.validate() catch return failRange(self.env, "Timestamp seconds out of range");
            return .{ .timestamp = time };
        }
        return failType(self.env, "CEL maps must be plain objects");
    }

    fn uint(self: *Converter, input: c.napi_value) NapiError!Value {
        var wrapped: c.napi_value = null;
        try check(self.env, c.napi_get_named_property(self.env, input, "value", &wrapped));
        var value_type: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, wrapped, &value_type));
        if (value_type != c.napi_bigint) return failType(self.env, "UInt.value must be a bigint");
        var value: u64 = 0;
        var lossless = false;
        try check(self.env, c.napi_get_value_bigint_uint64(self.env, wrapped, &value, &lossless));
        if (!lossless) return failRange(self.env, "UInt must fit unsigned 64-bit CEL uint");
        return .{ .uint = value };
    }

    fn list(self: *Converter, input: c.napi_value, depth: usize) NapiError!Value {
        var len: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, input, &len));
        if (len > self.remaining) return failRange(self.env, "input exceeds collection limit");
        try self.pushAncestor(input);
        defer self.popAncestor();
        const out = try self.arena.alloc(Value, len);
        for (out, 0..) |*slot, index| {
            var item: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, input, @intCast(index), &item));
            slot.* = try self.fromJavaScript(item, depth + 1);
        }
        return .{ .list = out };
    }

    fn map(self: *Converter, input: c.napi_value, depth: usize) NapiError!Value {
        const keys = try self.propertyNames(input);
        var len: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, keys, &len));
        if (len > self.remaining / 2) return failRange(self.env, "input exceeds collection limit");
        self.remaining -= len;
        try self.pushAncestor(input);
        defer self.popAncestor();
        const out = try self.arena.alloc(cel.Entry, len);
        for (out, 0..) |*slot, index| {
            var key: c.napi_value = null;
            var item: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, keys, @intCast(index), &key));
            const name = try self.readString(key);
            try check(self.env, c.napi_get_property(self.env, input, key, &item));
            slot.* = .{ .key = .{ .string = name }, .value = try self.fromJavaScript(item, depth + 1) };
        }
        return .{ .map = out };
    }

    fn snapshotMap(self: *Converter, input: c.napi_value) NapiError!union(enum) { plain, other, entries: c.napi_value } {
        var budget: c.napi_value = null;
        try check(self.env, c.napi_create_uint32(self.env, @intCast(self.remaining / 2), &budget));
        const args = [_]c.napi_value{ input, budget };
        var snapshot: c.napi_value = null;
        try check(self.env, c.napi_call_function(self.env, input, self.map_snapshot, args.len, &args, &snapshot));
        var kind: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, snapshot, &kind));
        if (kind == c.napi_boolean) {
            var plain = false;
            try check(self.env, c.napi_get_value_bool(self.env, snapshot, &plain));
            return if (plain) .plain else .other;
        }
        return .{ .entries = snapshot };
    }

    fn nativeMap(self: *Converter, input: c.napi_value, snapshot: c.napi_value, depth: usize) NapiError!Value {
        var len: u32 = 0;
        try check(self.env, c.napi_get_array_length(self.env, snapshot, &len));
        if (len > self.remaining / 2) return failRange(self.env, "input exceeds collection limit");
        self.remaining -= len;
        try self.pushAncestor(input);
        defer self.popAncestor();
        const out = try self.arena.alloc(cel.Entry, len);
        var numeric_keys = false;
        for (out, 0..) |*slot, index| {
            var pair: c.napi_value = null;
            var key: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, snapshot, @intCast(index), &pair));
            try check(self.env, c.napi_get_element(self.env, pair, 0, &key));
            slot.* = .{ .key = try self.mapKey(key), .value = .null };
            numeric_keys = numeric_keys or slot.key == .int or slot.key == .uint;
        }
        if (numeric_keys) try self.validateMapKeys(out);
        for (out, 0..) |*slot, index| {
            var pair: c.napi_value = null;
            var item: c.napi_value = null;
            try check(self.env, c.napi_get_element(self.env, snapshot, @intCast(index), &pair));
            try check(self.env, c.napi_get_element(self.env, pair, 1, &item));
            slot.value = try self.fromJavaScript(item, depth + 1);
        }
        return .{ .map = out };
    }

    fn mapKey(self: *Converter, input: c.napi_value) NapiError!Value {
        var kind: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, input, &kind));
        return switch (kind) {
            c.napi_boolean => blk: {
                var value = false;
                try check(self.env, c.napi_get_value_bool(self.env, input, &value));
                break :blk .{ .bool = value };
            },
            c.napi_number => blk: {
                const value = try self.number(input, false);
                if (value != .int) return failType(self.env, "CEL map number keys must be integers");
                break :blk value;
            },
            c.napi_bigint => blk: {
                var value: i64 = 0;
                var lossless = false;
                try check(self.env, c.napi_get_value_bigint_int64(self.env, input, &value, &lossless));
                if (!lossless) return failRange(self.env, "bigint map key must fit signed 64-bit CEL int");
                break :blk .{ .int = value };
            },
            c.napi_string => .{ .string = try self.readString(input) },
            c.napi_object => blk: {
                var matches = false;
                try check(self.env, c.napi_instanceof(self.env, input, self.uint_type, &matches));
                if (!matches) return failType(self.env, "CEL map keys must be bool, int, uint, or string");
                break :blk try self.uint(input);
            },
            else => failType(self.env, "CEL map keys must be bool, int, uint, or string"),
        };
    }

    fn validateMapKeys(self: *Converter, entries: []const cel.Entry) NapiError!void {
        cel.value.validateMapKeys(self.arena, entries) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMapKey => return failType(self.env, "CEL map keys must be bool, int, uint, or string"),
            error.DuplicateKey => return failType(self.env, "CEL map keys must be unique"),
        };
    }

    fn plainObject(self: *Converter, input: c.napi_value) NapiError!bool {
        var prototype: c.napi_value = null;
        try check(self.env, c.napi_get_prototype(self.env, input, &prototype));
        var same = false;
        try check(self.env, c.napi_strict_equals(self.env, prototype, self.object_prototype, &same));
        if (same) return true;
        var value_type: c.napi_valuetype = undefined;
        try check(self.env, c.napi_typeof(self.env, prototype, &value_type));
        return value_type == c.napi_null;
    }

    fn propertyNames(self: *Converter, input: c.napi_value) NapiError!c.napi_value {
        var keys: c.napi_value = null;
        const args = [_]c.napi_value{input};
        try check(self.env, c.napi_call_function(self.env, input, self.property_names, args.len, &args, &keys));
        return keys;
    }

    fn readString(self: *Converter, input: c.napi_value) NapiError![]const u8 {
        const result = readJavaScriptString(self.env, self.arena, input, max_input_bytes - self.input_bytes) catch |err| switch (err) {
            error.StringLimitExceeded => return failRange(self.env, "input exceeds byte limit"),
            else => |other| return other,
        };
        try self.chargeBytes(result.len);
        return result;
    }

    fn chargeBytes(self: *Converter, len: usize) NapiError!void {
        if (len > max_input_bytes - self.input_bytes) return failRange(self.env, "input exceeds byte limit");
        self.input_bytes += len;
    }

    fn pushAncestor(self: *Converter, input: c.napi_value) NapiError!void {
        for (self.ancestors[0..self.ancestor_count]) |ancestor| {
            var same = false;
            try check(self.env, c.napi_strict_equals(self.env, input, ancestor, &same));
            if (same) return failRange(self.env, "input contains a cycle");
        }
        if (self.ancestor_count == self.ancestors.len) return failRange(self.env, "input exceeds depth limit");
        self.ancestors[self.ancestor_count] = input;
        self.ancestor_count += 1;
    }

    /// Decode the wrapper's flattened plain-data stream. Deferred entries reuse the per-value converter.
    fn plainBindings(self: *Converter, numbers_value: c.napi_value, length_value: c.napi_value, bytes_value: c.napi_value, deferred: c.napi_value) NapiError![]const cel.Binding {
        var plain = try Plain.init(self.env, numbers_value, length_value, bytes_value, deferred);
        if (try plain.tag() != plain_map) return failType(self.env, "bindings must be a plain object");
        const len = try plain.count();
        if (len > self.remaining) return failRange(self.env, "input exceeds collection limit");
        const out = try self.arena.alloc(cel.Binding, len);
        for (out) |*slot| {
            if (try plain.tag() != plain_string) return failType(self.env, "expected a string");
            const name = try self.plainString(&plain);
            slot.* = .{ .name = name, .value = try self.plainValue(&plain, 0) };
        }
        if (plain.index != plain.length) return failType(self.env, "malformed plain-data stream");
        return out;
    }

    fn plainString(self: *Converter, plain: *Plain) NapiError![]const u8 {
        const len = try plain.count();
        if (len > plain.bytes.len - plain.byte_index) return failType(self.env, "malformed plain-data stream");
        try self.chargeBytes(len);
        // The wrapper keeps the byte buffer alive for the whole call, so results borrow it like other inputs.
        const text = plain.bytes[plain.byte_index .. plain.byte_index + len];
        plain.byte_index += len;
        return text;
    }

    fn plainValue(self: *Converter, plain: *Plain, depth: usize) NapiError!Value {
        if (depth >= max_depth) return failRange(self.env, "input exceeds depth limit");
        if (self.remaining == 0) return failRange(self.env, "input exceeds collection limit");
        self.remaining -= 1;
        return switch (try plain.tag()) {
            plain_null => .null,
            plain_false => .{ .bool = false },
            plain_true => .{ .bool = true },
            plain_number => blk: {
                const value = try plain.next();
                if (!std.math.isFinite(value) or @trunc(value) != value or (value == 0 and std.math.signbit(value)))
                    break :blk .{ .double = value };
                if (value < -max_safe_integer or value > max_safe_integer)
                    return failRange(self.env, "integer numbers must be safe; use bigint or Double");
                break :blk .{ .int = @intFromFloat(value) };
            },
            plain_bigint => blk: {
                const high = try plain.next();
                const low = try plain.next();
                if (@trunc(high) != high or @trunc(low) != low or high < -0x80000000 or high > 0x7fffffff or low < 0 or low > 0xffffffff)
                    return failType(self.env, "malformed plain-data stream");
                const upper: i64 = @intFromFloat(high);
                const lower: i64 = @intFromFloat(low);
                break :blk .{ .int = (upper << 32) | lower };
            },
            plain_string => .{ .string = try self.plainString(plain) },
            plain_list => blk: {
                const len = try plain.count();
                if (len > self.remaining) return failRange(self.env, "input exceeds collection limit");
                const out = try self.arena.alloc(Value, len);
                for (out) |*item| item.* = try self.plainValue(plain, depth + 1);
                break :blk .{ .list = out };
            },
            plain_map => blk: {
                const len = try plain.count();
                if (len > self.remaining / 2) return failRange(self.env, "input exceeds collection limit");
                self.remaining -= len;
                const out = try self.arena.alloc(cel.Entry, len);
                for (out) |*slot| {
                    if (try plain.tag() != plain_string) return failType(self.env, "expected a string");
                    slot.* = .{ .key = .{ .string = try self.plainString(plain) }, .value = try self.plainValue(plain, depth + 1) };
                }
                break :blk .{ .map = out };
            },
            plain_deferred => blk: {
                const index = try plain.count();
                var item: c.napi_value = null;
                var ancestors: c.napi_value = null;
                var snapshot: c.napi_value = null;
                try check(self.env, c.napi_get_element(self.env, plain.deferred, @intCast(index), &item));
                try check(self.env, c.napi_get_element(self.env, plain.deferred, @intCast(index + 1), &ancestors));
                try check(self.env, c.napi_get_element(self.env, plain.deferred, @intCast(index + 2), &snapshot));
                var count: u32 = 0;
                try check(self.env, c.napi_get_array_length(self.env, ancestors, &count));
                if (count > self.ancestors.len - self.ancestor_count) return failRange(self.env, "input exceeds depth limit");
                const base = self.ancestor_count;
                for (0..count) |offset| {
                    try check(self.env, c.napi_get_element(self.env, ancestors, @intCast(offset), &self.ancestors[base + offset]));
                }
                self.ancestor_count = base + count;
                defer {
                    for (self.ancestors[base..self.ancestor_count]) |*slot| slot.* = null;
                    self.ancestor_count = base;
                }
                var snapshot_kind: c.napi_valuetype = undefined;
                try check(self.env, c.napi_typeof(self.env, snapshot, &snapshot_kind));
                // Map entries were captured by the wrapper in traversal order, before later getters ran.
                if (snapshot_kind == c.napi_object) break :blk try self.nativeMap(item, snapshot, depth);
                // The stream already counted this value; the per-value converter charges it again.
                self.remaining += 1;
                break :blk try self.fromJavaScript(item, depth);
            },
            else => failType(self.env, "malformed plain-data stream"),
        };
    }

    fn popAncestor(self: *Converter) void {
        self.ancestor_count -= 1;
        self.ancestors[self.ancestor_count] = null;
    }

    fn toJavaScript(self: *Converter, input: Value, depth: usize) NapiError!c.napi_value {
        if (depth >= max_depth) return failRange(self.env, "result exceeds depth limit");
        var out: c.napi_value = null;
        switch (input) {
            .null => try check(self.env, c.napi_get_null(self.env, &out)),
            .bool => |value| try check(self.env, c.napi_get_boolean(self.env, value, &out)),
            .int => |value| try check(self.env, c.napi_create_bigint_int64(self.env, value, &out)),
            .uint => |value| {
                var integer: c.napi_value = null;
                try check(self.env, c.napi_create_bigint_uint64(self.env, value, &integer));
                const args = [_]c.napi_value{integer};
                try check(self.env, c.napi_new_instance(self.env, self.uint_type, args.len, &args, &out));
            },
            .double => |value| try check(self.env, c.napi_create_double(self.env, value, &out)),
            .string => |value| try check(self.env, c.napi_create_string_utf8(self.env, value.ptr, value.len, &out)),
            .bytes => |value| try check(self.env, c.napi_create_buffer_copy(self.env, value.len, value.ptr, null, &out)),
            .ip, .cidr => {
                const text = if (input == .ip) input.ip.format(self.arena) catch return error.OutOfMemory else input.cidr.format(self.arena) catch return error.OutOfMemory;
                var string: c.napi_value = null;
                try check(self.env, c.napi_create_string_utf8(self.env, text.ptr, text.len, &string));
                const arguments = [_]c.napi_value{string};
                try check(self.env, c.napi_new_instance(self.env, if (input == .ip) self.ip_type else self.cidr_type, arguments.len, &arguments, &out));
            },
            .optional => |value| {
                var has_value: c.napi_value = null;
                try check(self.env, c.napi_get_boolean(self.env, value != null, &has_value));
                var payload: c.napi_value = null;
                if (value) |present| {
                    payload = try self.toJavaScript(present.*, depth + 1);
                } else {
                    try check(self.env, c.napi_get_null(self.env, &payload));
                }
                const args = [_]c.napi_value{ has_value, payload };
                try check(self.env, c.napi_new_instance(self.env, self.optional_type, args.len, &args, &out));
            },
            .type_value => |value| {
                var name: c.napi_value = null;
                try check(self.env, c.napi_create_string_utf8(self.env, value.ptr, value.len, &name));
                const args = [_]c.napi_value{name};
                try check(self.env, c.napi_new_instance(self.env, self.cel_type, args.len, &args, &out));
            },
            .duration => |span| {
                var nanos: c.napi_value = null;
                try check(self.env, c.napi_create_bigint_int64(self.env, span.nanoseconds, &nanos));
                const args = [_]c.napi_value{nanos};
                try check(self.env, c.napi_new_instance(self.env, self.duration_type, args.len, &args, &out));
            },
            .timestamp => |time| {
                var seconds: c.napi_value = null;
                var nanos: c.napi_value = null;
                try check(self.env, c.napi_create_bigint_int64(self.env, time.seconds, &seconds));
                try check(self.env, c.napi_create_uint32(self.env, time.nanos, &nanos));
                const args = [_]c.napi_value{ seconds, nanos };
                try check(self.env, c.napi_new_instance(self.env, self.timestamp_type, args.len, &args, &out));
            },
            .enum_value => |item| {
                var name: c.napi_value = null;
                var number_value: c.napi_value = null;
                try check(self.env, c.napi_create_string_utf8(self.env, item.type_name.ptr, item.type_name.len, &name));
                try check(self.env, c.napi_create_int32(self.env, item.number, &number_value));
                const args = [_]c.napi_value{ name, number_value };
                try check(self.env, c.napi_new_instance(self.env, self.enum_type, args.len, &args, &out));
            },
            .message => |m| {
                var name: c.napi_value = null;
                var data: c.napi_value = null;
                try check(self.env, c.napi_create_string_utf8(self.env, m.type_name.ptr, m.type_name.len, &name));
                try check(self.env, c.napi_create_buffer_copy(self.env, m.data.len, m.data.ptr, null, &data));
                const args = [_]c.napi_value{ name, data };
                try check(self.env, c.napi_new_instance(self.env, self.message_type, args.len, &args, &out));
            },
            .list => |items| {
                try check(self.env, c.napi_create_array_with_length(self.env, items.len, &out));
                for (items, 0..) |item, index| {
                    const value = try self.toJavaScript(item, depth + 1);
                    try check(self.env, c.napi_set_element(self.env, out, @intCast(index), value));
                }
            },
            .map => |items| return self.mapToJavaScript(items, depth),
        }
        return out;
    }

    fn mapToJavaScript(self: *Converter, items: []const cel.Entry, depth: usize) NapiError!c.napi_value {
        const string_keys = for (items) |item| {
            if (item.key != .string) break false;
        } else true;
        if (string_keys) {
            var out: c.napi_value = null;
            try check(self.env, c.napi_create_object(self.env, &out));
            const properties = try self.arena.alloc(c.napi_property_descriptor, items.len);
            for (items, properties) |item, *property| {
                var name: c.napi_value = null;
                try check(self.env, c.napi_create_string_utf8(self.env, item.key.string.ptr, item.key.string.len, &name));
                property.* = std.mem.zeroes(c.napi_property_descriptor);
                property.name = name;
                property.value = try self.toJavaScript(item.value, depth + 1);
                property.attributes = c.napi_default_jsproperty;
            }
            try check(self.env, c.napi_define_properties(self.env, out, properties.len, properties.ptr));
            return out;
        }

        var out: c.napi_value = null;
        try check(self.env, c.napi_new_instance(self.env, self.map_constructor, 0, null, &out));
        for (items) |item| {
            const args = [_]c.napi_value{
                try self.toJavaScript(item.key, depth + 1),
                try self.toJavaScript(item.value, depth + 1),
            };
            var ignored: c.napi_value = null;
            try check(self.env, c.napi_call_function(self.env, out, self.map_set, args.len, &args, &ignored));
        }
        return out;
    }
};

fn invokeFunction(context: ?*anyopaque, _: std.mem.Allocator, arguments: []const Value) cel.EvalError!Value {
    const record: *const FnContext = @ptrCast(@alignCast(context orelse {
        return error.HostFunctionError;
    }));
    const converter = record.owner.active orelse return error.HostFunctionError;
    var callback: c.napi_value = null;
    check(converter.env, c.napi_get_element(converter.env, converter.callbacks, @intCast(record.index), &callback)) catch {
        return error.HostFunctionError;
    };
    var callback_kind: c.napi_valuetype = undefined;
    check(converter.env, c.napi_typeof(converter.env, callback, &callback_kind)) catch {
        return error.HostFunctionError;
    };
    if (callback_kind != c.napi_function) return error.HostFunctionError;
    const argv = converter.arena.alloc(c.napi_value, arguments.len) catch return error.OutOfMemory;
    for (arguments, argv) |argument, *output| {
        output.* = converter.toJavaScript(argument, 0) catch |err| return if (err == error.OutOfMemory)
            error.OutOfMemory
        else
            error.HostFunctionError;
    }
    var receiver: c.napi_value = null;
    check(converter.env, c.napi_get_undefined(converter.env, &receiver)) catch return error.HostFunctionError;
    var result: c.napi_value = null;
    check(converter.env, c.napi_call_function(converter.env, receiver, callback, argv.len, argv.ptr, &result)) catch {
        return error.HostFunctionError;
    };
    return converter.fromJavaScript(result, 0) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        error.HostFunctionError;
}

fn normalizeNetworkCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return normalizeNetwork(env, info) catch |err| finishFailure(env, "CEL_NETWORK_", err);
}

fn normalizeNetwork(env: c.napi_env, info: c.napi_callback_info) NapiError!c.napi_value {
    var count: usize = 3;
    var args: [3]c.napi_value = @splat(null);
    try check(env, c.napi_get_cb_info(env, info, &count, &args, null, null));
    if (count != 2) return failType(env, "network normalization requires text and kind");
    var is_cidr = false;
    try check(env, c.napi_get_value_bool(env, args[1], &is_cidr));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = readJavaScriptString(env, arena.allocator(), args[0], 128) catch |err| switch (err) {
        error.StringLimitExceeded => return failRange(env, "network value is too long"),
        else => |other| return other,
    };
    const result = if (is_cidr) blk: {
        const prefix = cel.CIDR.parse(text) catch return failRange(env, "invalid CIDR prefix");
        break :blk prefix.format(arena.allocator()) catch return error.OutOfMemory;
    } else blk: {
        const address = cel.IP.parse(text) catch return failRange(env, "invalid IP address");
        break :blk address.format(arena.allocator()) catch return error.OutOfMemory;
    };
    var output: c.napi_value = null;
    try check(env, c.napi_create_string_utf8(env, result.ptr, result.len, &output));
    return output;
}

fn register(env: c.napi_env, exports: c.napi_value) NapiError!c.napi_value {
    var plan_function: c.napi_value = null;
    try check(env, c.napi_create_function(env, "fastPlan", c.NAPI_AUTO_LENGTH, fastPlanCallback, null, &plan_function));
    try check(env, c.napi_set_named_property(env, exports, "fastPlan", plan_function));
    var network_function: c.napi_value = null;
    try check(env, c.napi_create_function(env, "normalizeNetwork", c.NAPI_AUTO_LENGTH, normalizeNetworkCallback, null, &network_function));
    try check(env, c.napi_set_named_property(env, exports, "normalizeNetwork", network_function));
    var environment_function: c.napi_value = null;
    var compile_in_function: c.napi_value = null;
    var result_type_function: c.napi_value = null;
    try check(env, c.napi_create_function(env, "environment", c.NAPI_AUTO_LENGTH, environmentCallback, null, &environment_function));
    try check(env, c.napi_create_function(env, "compileIn", c.NAPI_AUTO_LENGTH, compileInCallback, null, &compile_in_function));
    try check(env, c.napi_create_function(env, "resultType", c.NAPI_AUTO_LENGTH, resultTypeCallback, null, &result_type_function));
    try check(env, c.napi_set_named_property(env, exports, "environment", environment_function));
    try check(env, c.napi_set_named_property(env, exports, "compileIn", compile_in_function));
    try check(env, c.napi_set_named_property(env, exports, "resultType", result_type_function));
    var compile_function: c.napi_value = null;
    var evaluate_function: c.napi_value = null;
    try check(env, c.napi_create_function(env, "compile", c.NAPI_AUTO_LENGTH, compileCallback, null, &compile_function));
    try check(env, c.napi_create_function(env, "evaluate", c.NAPI_AUTO_LENGTH, evaluateCallback, null, &evaluate_function));
    try check(env, c.napi_set_named_property(env, exports, "compile", compile_function));
    try check(env, c.napi_set_named_property(env, exports, "evaluate", evaluate_function));
    return exports;
}

/// Node-API module entry point.
pub export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    return register(env, exports) catch |err| finishFailure(env, "CEL_MODULE_", err);
}
