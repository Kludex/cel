//! CPython FFI. Capsules own compiled programs; each call owns a conversion/evaluation arena.

const std = @import("std");
const cel = @import("root.zig");
const names = @import("names.zig");
const c = @cImport({
    @cDefine("Py_LIMITED_API", "0x030A0000");
    @cInclude("Python.h");
});
const Value = cel.Value;
const gpa = std.heap.c_allocator;

const capsule_name = "cel.Program";
const ConversionError = error{ PythonException, OutOfMemory };

fn failure(exception: [*c]c.PyObject, message: [*:0]const u8) ConversionError {
    c.PyErr_SetString(exception, message);
    return error.PythonException;
}

fn capsuleDestroy(capsule: ?*c.PyObject) callconv(.c) void {
    const ptr = c.PyCapsule_GetPointer(capsule, capsule_name) orelse return;
    const program: *cel.Program = @ptrCast(@alignCast(ptr));
    program.deinit();
    gpa.destroy(program);
}

fn compile(_: ?*c.PyObject, source: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return compileSource(source, .{}, false);
}

fn compileSource(source: ?*c.PyObject, config: cel.Environment, checked: bool) ?*c.PyObject {
    var len: c.Py_ssize_t = 0;
    const text = c.PyUnicode_AsUTF8AndSize(source, &len);
    if (text == null) return null;
    const program = gpa.create(cel.Program) catch return c.PyErr_NoMemory();
    const built = if (checked) config.compile(gpa, text[0..@intCast(len)], .{}) else config.parse(gpa, text[0..@intCast(len)], .{});
    program.* = built catch |err| {
        gpa.destroy(program);
        if (err == error.OutOfMemory) return c.PyErr_NoMemory();
        c.PyErr_SetString(c.PyExc_ValueError, @errorName(err));
        return null;
    };
    const capsule = c.PyCapsule_New(program, capsule_name, capsuleDestroy);
    if (capsule == null) {
        program.deinit();
        gpa.destroy(program);
    }
    return capsule;
}

const EnvironmentHandle = struct {
    arena: std.heap.ArenaAllocator,
    environment: cel.Environment,
};
const CallbackContext = struct { owner: *EnvironmentHandle, index: usize };
const CallbackFrame = struct { owner: ?*EnvironmentHandle, converter: *Converter, previous: ?*const CallbackFrame };
threadlocal var callback_frame: ?*const CallbackFrame = null;
const environment_name = "cel.Environment";

fn environmentDestroy(capsule: ?*c.PyObject) callconv(.c) void {
    const ptr = c.PyCapsule_GetPointer(capsule, environment_name) orelse return;
    const handle: *EnvironmentHandle = @ptrCast(@alignCast(ptr));
    handle.environment.deinit();
    handle.arena.deinit();
    gpa.destroy(handle);
}

fn environment(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyTuple_Size(args) != 16) {
        c.PyErr_SetString(c.PyExc_TypeError, "invalid environment arguments");
        return null;
    }
    const strong_enums = c.PyTuple_GetItem(args, 4);
    const true_object = @extern(*c.PyObject, .{ .name = "_Py_TrueStruct" });
    const false_object = @extern(*c.PyObject, .{ .name = "_Py_FalseStruct" });
    if (strong_enums != true_object and strong_enums != false_object) {
        c.PyErr_SetString(c.PyExc_TypeError, "strong_enums must be a bool");
        return null;
    }
    const handle = gpa.create(EnvironmentHandle) catch return c.PyErr_NoMemory();
    handle.arena = std.heap.ArenaAllocator.init(gpa);
    var converter = Converter{
        .arena = handle.arena.allocator(),
        .uint_type = c.PyTuple_GetItem(args, 6),
        .cel_type = c.PyTuple_GetItem(args, 7),
        .enum_type = c.PyTuple_GetItem(args, 8),
        .message_type = c.PyTuple_GetItem(args, 9),
        .duration_type = c.PyTuple_GetItem(args, 10),
        .timestamp_type = c.PyTuple_GetItem(args, 11),
        .map_type = c.PyTuple_GetItem(args, 12),
        .optional_type = c.PyTuple_GetItem(args, 13),
        .ip_type = c.PyTuple_GetItem(args, 14),
        .cidr_type = c.PyTuple_GetItem(args, 15),
        .strong_enums = strong_enums == true_object,
    };
    handle.environment = converter.environment(args, handle) catch |err| {
        handle.arena.deinit();
        gpa.destroy(handle);
        if (err == error.OutOfMemory) return c.PyErr_NoMemory();
        return null;
    };
    const capsule = c.PyCapsule_New(handle, environment_name, environmentDestroy);
    if (capsule == null) {
        handle.environment.deinit();
        handle.arena.deinit();
        gpa.destroy(handle);
    }
    return capsule;
}

fn compileIn(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyTuple_Size(args) != 3) {
        c.PyErr_SetString(c.PyExc_TypeError, "invalid compile arguments");
        return null;
    }
    const object = c.PyTuple_GetItem(args, 0);
    var config: cel.Environment = .{};
    if (object != c.Py_None()) {
        const pointer = c.PyCapsule_GetPointer(object, environment_name) orelse return null;
        config = @as(*const EnvironmentHandle, @ptrCast(@alignCast(pointer))).environment;
    }
    const checked = c.PyObject_IsTrue(c.PyTuple_GetItem(args, 2));
    if (checked < 0) return null;
    return compileSource(c.PyTuple_GetItem(args, 1), config, checked != 0);
}

fn resultType(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyTuple_Size(args) != 2) {
        c.PyErr_SetString(c.PyExc_TypeError, "invalid result_type arguments");
        return null;
    }
    const pointer = c.PyCapsule_GetPointer(c.PyTuple_GetItem(args, 0), capsule_name) orelse return null;
    const program: *const cel.Program = @ptrCast(@alignCast(pointer));
    if (program.result_type) |t| return typeToPython(t, c.PyTuple_GetItem(args, 1));
    const none = c.Py_None();
    c.Py_IncRef(none);
    return none;
}

fn typeToPython(t: cel.Type, constructor: [*c]c.PyObject) ?*c.PyObject {
    const name = c.PyUnicode_DecodeUTF8(t.name.ptr, @intCast(t.name.len), "strict") orelse return null;
    defer c.Py_DecRef(name);
    const parameters = c.PyTuple_New(@intCast(t.parameters.len)) orelse return null;
    defer c.Py_DecRef(parameters);
    for (t.parameters, 0..) |parameter, i| {
        const item = typeToPython(parameter, constructor) orelse return null;
        if (c.PyTuple_SetItem(parameters, @intCast(i), item) < 0) return null;
    }
    const kind = c.PyUnicode_FromString(@tagName(t.kind)) orelse return null;
    defer c.Py_DecRef(kind);
    return c.PyObject_CallFunctionObjArgs(constructor, name, parameters, kind, @as(?*c.PyObject, null));
}

fn evaluate(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyTuple_Size(args) != 15) {
        c.PyErr_SetString(c.PyExc_TypeError, "evaluate requires a program, bindings, and conversion types");
        return null;
    }
    const ptr = c.PyCapsule_GetPointer(c.PyTuple_GetItem(args, 0), capsule_name) orelse return null;
    const program: *const cel.Program = @ptrCast(@alignCast(ptr));
    const input = c.PyTuple_GetItem(args, 1);
    const environment_object = c.PyTuple_GetItem(args, 2);
    const callbacks = c.PyTuple_GetItem(args, 3);
    if (!hasTypeFlag(input, c.Py_TPFLAGS_DICT_SUBCLASS)) {
        c.PyErr_SetString(c.PyExc_TypeError, "bindings must be a dict with string keys");
        return null;
    }
    if (!hasTypeFlag(callbacks, c.Py_TPFLAGS_TUPLE_SUBCLASS)) {
        c.PyErr_SetString(c.PyExc_TypeError, "callbacks must be a tuple");
        return null;
    }
    var owner: ?*EnvironmentHandle = null;
    if (environment_object != c.Py_None()) {
        const environment_pointer = c.PyCapsule_GetPointer(environment_object, environment_name) orelse return null;
        owner = @ptrCast(@alignCast(environment_pointer));
        if (c.PyTuple_Size(callbacks) != @as(c.Py_ssize_t, @intCast(owner.?.environment.functions.len))) {
            c.PyErr_SetString(c.PyExc_TypeError, "callback count does not match environment");
            return null;
        }
    } else if (c.PyTuple_Size(callbacks) != 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "callbacks require an environment");
        return null;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var stack = std.heap.stackFallback(4096, arena.allocator());
    const evaluation_allocator = stack.get();
    var borrowed: std.ArrayList(*c.PyObject) = .empty;
    // Borrowed inputs stay alive until every result has been converted, including after callback GIL releases.
    defer for (borrowed.items) |object| c.Py_DecRef(object);
    var converter = Converter{
        .arena = evaluation_allocator,
        .uint_type = c.PyTuple_GetItem(args, 4),
        .cel_type = c.PyTuple_GetItem(args, 5),
        .enum_type = c.PyTuple_GetItem(args, 6),
        .message_type = c.PyTuple_GetItem(args, 7),
        .duration_type = c.PyTuple_GetItem(args, 8),
        .timestamp_type = c.PyTuple_GetItem(args, 9),
        .map_type = c.PyTuple_GetItem(args, 10),
        .optional_type = c.PyTuple_GetItem(args, 12),
        .ip_type = c.PyTuple_GetItem(args, 13),
        .cidr_type = c.PyTuple_GetItem(args, 14),
        .callbacks = callbacks,
        .borrowed = &borrowed,
    };
    const has_callbacks = if (owner) |handle| handle.environment.functions.len != 0 else false;
    const frame = CallbackFrame{ .owner = owner, .converter = &converter, .previous = if (has_callbacks) callback_frame else null };
    if (has_callbacks) callback_frame = &frame;
    defer if (has_callbacks) {
        callback_frame = frame.previous;
    };
    const bindings = converter.bindings(input) catch |err| {
        if (err == error.OutOfMemory) return c.PyErr_NoMemory();
        return null;
    };
    const result = program.evaluate(evaluation_allocator, bindings) catch |err| {
        if (err == error.OutOfMemory) return c.PyErr_NoMemory();
        if (err == error.HostFunctionError and c.PyErr_Occurred() != null) return null;
        c.PyErr_SetString(c.PyTuple_GetItem(args, 11), @errorName(err));
        return null;
    };
    return converter.toPython(result);
}

const Converter = struct {
    arena: std.mem.Allocator,
    uint_type: [*c]c.PyObject,
    cel_type: [*c]c.PyObject,
    enum_type: [*c]c.PyObject,
    message_type: [*c]c.PyObject,
    duration_type: [*c]c.PyObject,
    timestamp_type: [*c]c.PyObject,
    map_type: [*c]c.PyObject,
    optional_type: [*c]c.PyObject,
    ip_type: [*c]c.PyObject,
    cidr_type: [*c]c.PyObject,
    callbacks: [*c]c.PyObject = null,
    strong_enums: bool = false,
    remaining: usize = 100_000,
    remaining_bytes: usize = 1_048_576,
    /// When present, string and bytes inputs borrow the Python object's buffer and this list keeps the objects alive.
    borrowed: ?*std.ArrayList(*c.PyObject) = null,

    fn copyBytes(self: *Converter, bytes: []const u8) ConversionError![]const u8 {
        if (bytes.len > self.remaining_bytes) return failure(c.PyExc_ValueError, "input exceeds byte limit");
        self.remaining_bytes -= bytes.len;
        return self.arena.dupe(u8, bytes);
    }

    /// Borrow an immutable Python buffer for the rest of the call, or copy it when no borrow list is active.
    fn borrowBytes(self: *Converter, owner: [*c]c.PyObject, bytes: []const u8) ConversionError![]const u8 {
        const list = self.borrowed orelse return self.copyBytes(bytes);
        if (bytes.len > self.remaining_bytes) return failure(c.PyExc_ValueError, "input exceeds byte limit");
        self.remaining_bytes -= bytes.len;
        try list.append(self.arena, owner);
        c.Py_IncRef(owner);
        return bytes;
    }

    fn environment(self: *Converter, args: ?*c.PyObject, owner: *EnvironmentHandle) ConversionError!cel.Environment {
        const declarations = c.PyTuple_GetItem(args, 0);
        const constants = c.PyTuple_GetItem(args, 1);
        if (!hasTypeFlag(declarations, c.Py_TPFLAGS_DICT_SUBCLASS) or !hasTypeFlag(constants, c.Py_TPFLAGS_DICT_SUBCLASS)) {
            return failure(c.PyExc_TypeError, "variables and constants must be dicts");
        }
        const len: usize = @intCast(c.PyDict_Size(declarations));
        if (len > self.remaining) return failure(c.PyExc_ValueError, "too many declarations");
        const variables = try self.arena.alloc(cel.Declaration, len);
        var position: c.Py_ssize_t = 0;
        var key: [*c]c.PyObject = null;
        var val: [*c]c.PyObject = null;
        var index: usize = 0;
        while (c.PyDict_Next(declarations, &position, &key, &val) != 0) : (index += 1) {
            var size: c.Py_ssize_t = 0;
            const name = c.PyUnicode_AsUTF8AndSize(key, &size);
            if (name == null) return error.PythonException;
            variables[index] = .{ .name = try self.copyBytes(name[0..@intCast(size)]), .type = try self.fromType(val, 0) };
        }
        var size: c.Py_ssize_t = 0;
        const container = c.PyUnicode_AsUTF8AndSize(c.PyTuple_GetItem(args, 2), &size);
        if (container == null) return error.PythonException;
        const descriptors = c.PyTuple_GetItem(args, 3);
        if (!hasTypeFlag(descriptors, c.Py_TPFLAGS_BYTES_SUBCLASS)) return failure(c.PyExc_TypeError, "descriptors must be bytes");
        const descriptor_len: usize = @intCast(c.PyBytes_Size(descriptors));
        if (descriptor_len > 1_048_576) return failure(c.PyExc_ValueError, "descriptor byte limit exceeded");
        const config = cel.Environment{
            .variables = variables,
            .constants = try self.bindings(constants),
            .container = try self.copyBytes(container[0..@intCast(size)]),
            .descriptors = c.PyBytes_AsString(descriptors)[0..descriptor_len],
            .functions = try self.decodeFunctions(c.PyTuple_GetItem(args, 5), owner),
            .strong_enums = self.strong_enums,
        };
        return config.clone(self.arena, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return failure(c.PyExc_ValueError, @errorName(err));
        };
    }

    fn decodeFunctions(
        self: *Converter,
        input: [*c]c.PyObject,
        owner: *EnvironmentHandle,
    ) ConversionError![]const cel.Function {
        if (!hasTypeFlag(input, c.Py_TPFLAGS_TUPLE_SUBCLASS)) return failure(c.PyExc_TypeError, "functions must be a tuple");
        const length: usize = @intCast(c.PyTuple_Size(input));
        if (length > self.remaining) return failure(c.PyExc_ValueError, "function declaration limit exceeded");
        const functions = try self.arena.alloc(cel.Function, length);
        const contexts = try self.arena.alloc(CallbackContext, length);
        const true_object = @extern(*c.PyObject, .{ .name = "_Py_TrueStruct" });
        const false_object = @extern(*c.PyObject, .{ .name = "_Py_FalseStruct" });
        for (functions, contexts, 0..) |*function, *context, index| {
            const specification = c.PyTuple_GetItem(input, @intCast(index));
            if (!hasTypeFlag(specification, c.Py_TPFLAGS_TUPLE_SUBCLASS) or c.PyTuple_Size(specification) != 6) {
                return failure(c.PyExc_TypeError, "invalid function specification");
            }
            const name_object = c.PyTuple_GetItem(specification, 0);
            const id_object = c.PyTuple_GetItem(specification, 1);
            const parameters_object = c.PyTuple_GetItem(specification, 2);
            const member_object = c.PyTuple_GetItem(specification, 4);
            const implementation_object = c.PyTuple_GetItem(specification, 5);
            if (!hasTypeFlag(name_object, c.Py_TPFLAGS_UNICODE_SUBCLASS) or !hasTypeFlag(id_object, c.Py_TPFLAGS_UNICODE_SUBCLASS)) {
                return failure(c.PyExc_TypeError, "function names and overload IDs must be strings");
            }
            if (!hasTypeFlag(parameters_object, c.Py_TPFLAGS_TUPLE_SUBCLASS)) {
                return failure(c.PyExc_TypeError, "function parameters must be a tuple");
            }
            if ((member_object != true_object and member_object != false_object) or
                (implementation_object != true_object and implementation_object != false_object))
            {
                return failure(c.PyExc_TypeError, "function flags must be bools");
            }
            var name_length: c.Py_ssize_t = 0;
            const name = c.PyUnicode_AsUTF8AndSize(name_object, &name_length);
            if (name == null) return error.PythonException;
            var id_length: c.Py_ssize_t = 0;
            const id = c.PyUnicode_AsUTF8AndSize(id_object, &id_length);
            if (id == null) return error.PythonException;
            const parameter_count: usize = @intCast(c.PyTuple_Size(parameters_object));
            if (parameter_count > self.remaining) {
                return failure(c.PyExc_ValueError, "function declaration limit exceeded");
            }
            const parameters = try self.arena.alloc(cel.Type, parameter_count);
            for (parameters, 0..) |*parameter, parameter_index| {
                parameter.* = try self.fromType(c.PyTuple_GetItem(parameters_object, @intCast(parameter_index)), 0);
            }
            context.* = .{ .owner = owner, .index = index };
            function.* = .{
                .name = try self.copyBytes(name[0..@intCast(name_length)]),
                .overload_id = try self.copyBytes(id[0..@intCast(id_length)]),
                .parameters = parameters,
                .result = try self.fromType(c.PyTuple_GetItem(specification, 3), 0),
                .member = member_object == true_object,
                .implementation = if (implementation_object == true_object) invokeCallback else null,
                .context = context,
            };
        }
        return functions;
    }

    fn fromType(self: *Converter, input: [*c]c.PyObject, depth: usize) ConversionError!cel.Type {
        if (depth >= 128 or self.remaining == 0) return failure(c.PyExc_ValueError, "declaration limit exceeded");
        self.remaining -= 1;
        if (c.Py_IS_TYPE(input, @ptrCast(self.cel_type)) == 0) return failure(c.PyExc_TypeError, "expected CELType");
        const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
        defer c.Py_DecRef(fields);
        const name_object = c.PyDict_GetItemString(fields, "name") orelse return failure(c.PyExc_TypeError, "missing type name");
        var size: c.Py_ssize_t = 0;
        const name = c.PyUnicode_AsUTF8AndSize(name_object, &size);
        if (name == null) return error.PythonException;
        const parameters = c.PyDict_GetItemString(fields, "parameters") orelse
            return failure(c.PyExc_TypeError, "missing type parameters");
        const kind_object = c.PyDict_GetItemString(fields, "kind") orelse
            return failure(c.PyExc_TypeError, "missing type kind");
        if (!hasTypeFlag(parameters, c.Py_TPFLAGS_TUPLE_SUBCLASS))
            return failure(c.PyExc_TypeError, "type parameters must be a tuple");
        var kind_length: c.Py_ssize_t = 0;
        const kind_text = c.PyUnicode_AsUTF8AndSize(kind_object, &kind_length);
        if (kind_text == null) return error.PythonException;
        const kind = std.meta.stringToEnum(cel.Type.Kind, kind_text[0..@intCast(kind_length)]) orelse
            return failure(c.PyExc_ValueError, "invalid CELType kind");
        const length: usize = @intCast(c.PyTuple_Size(parameters));
        if (length > self.remaining) return failure(c.PyExc_ValueError, "declaration limit exceeded");
        const nested = try self.arena.alloc(cel.Type, length);
        for (nested, 0..) |*item, i| item.* = try self.fromType(c.PyTuple_GetItem(parameters, @intCast(i)), depth + 1);
        return .{ .name = try self.copyBytes(name[0..@intCast(size)]), .parameters = nested, .kind = kind };
    }

    fn bindings(self: *Converter, input: [*c]c.PyObject) ConversionError![]const cel.Binding {
        const len: usize = @intCast(c.PyDict_Size(input));
        if (len > self.remaining) return failure(c.PyExc_ValueError, "input exceeds collection limit");
        const out = try self.arena.alloc(cel.Binding, len);
        var pos: c.Py_ssize_t = 0;
        var key: [*c]c.PyObject = null;
        var val: [*c]c.PyObject = null;
        var index: usize = 0;
        while (c.PyDict_Next(input, &pos, &key, &val) != 0) {
            var size: c.Py_ssize_t = 0;
            const name = c.PyUnicode_AsUTF8AndSize(key, &size);
            if (name == null) return error.PythonException;
            out[index] = .{ .name = try self.borrowBytes(key, name[0..@intCast(size)]), .value = try self.fromPython(val, 0) };
            index += 1;
        }
        return out;
    }

    fn fromPython(self: *Converter, input: [*c]c.PyObject, depth: usize) ConversionError!Value {
        if (depth >= 128) return failure(c.PyExc_ValueError, "input exceeds depth limit or contains a cycle");
        if (self.remaining == 0) return failure(c.PyExc_ValueError, "input exceeds collection limit");
        self.remaining -= 1;
        if (input == c.Py_None()) return .null;
        const true_object = @extern(*c.PyObject, .{ .name = "_Py_TrueStruct" });
        const false_object = @extern(*c.PyObject, .{ .name = "_Py_FalseStruct" });
        if (input == true_object or input == false_object) return .{ .bool = input == true_object };
        if (hasTypeFlag(input, c.Py_TPFLAGS_LONG_SUBCLASS)) {
            const n = c.PyLong_AsLongLong(input);
            if (c.PyErr_Occurred() != null) return error.PythonException;
            return .{ .int = n };
        }
        // translate-c cannot declare an extern variable with the limited API's opaque type.
        const float_type = @extern(*c.PyTypeObject, .{ .name = "PyFloat_Type" });
        if (c.PyObject_TypeCheck(input, float_type) != 0) return .{ .double = c.PyFloat_AsDouble(input) };
        if (hasTypeFlag(input, c.Py_TPFLAGS_UNICODE_SUBCLASS)) {
            var len: c.Py_ssize_t = 0;
            const text = c.PyUnicode_AsUTF8AndSize(input, &len);
            if (text == null) return error.PythonException;
            return .{ .string = try self.borrowBytes(input, text[0..@intCast(len)]) };
        }
        if (hasTypeFlag(input, c.Py_TPFLAGS_BYTES_SUBCLASS)) {
            const len: usize = @intCast(c.PyBytes_Size(input));
            return .{ .bytes = try self.borrowBytes(input, c.PyBytes_AsString(input)[0..len]) };
        }
        if (hasTypeFlag(input, c.Py_TPFLAGS_LIST_SUBCLASS)) {
            const len: usize = @intCast(c.PyList_Size(input));
            if (len > self.remaining) return failure(c.PyExc_ValueError, "input exceeds collection limit");
            const out = try self.arena.alloc(Value, len);
            for (out, 0..) |*slot, i| slot.* = try self.fromPython(c.PyList_GetItem(input, @intCast(i)), depth + 1);
            return .{ .list = out };
        }
        if (hasTypeFlag(input, c.Py_TPFLAGS_DICT_SUBCLASS)) {
            const len: usize = @intCast(c.PyDict_Size(input));
            if (len > self.remaining / 2) return failure(c.PyExc_ValueError, "input exceeds collection limit");
            const out = try self.arena.alloc(cel.Entry, len);
            var pos: c.Py_ssize_t = 0;
            var key: [*c]c.PyObject = null;
            var val: [*c]c.PyObject = null;
            var index: usize = 0;
            var needs_validation = false;
            const string_type = @extern(*c.PyTypeObject, .{ .name = "PyUnicode_Type" });
            const integer_type = @extern(*c.PyTypeObject, .{ .name = "PyLong_Type" });
            while (c.PyDict_Next(input, &pos, &key, &val) != 0) {
                if (c.Py_IS_TYPE(key, string_type) == 0 and c.Py_IS_TYPE(key, integer_type) == 0 and
                    key != true_object and key != false_object) needs_validation = true;
                const k = try self.fromPython(key, depth + 1);
                switch (k) {
                    .bool, .int, .uint, .string => {},
                    else => return failure(c.PyExc_TypeError, "CEL map keys must be bool, int, UInt, or str"),
                }
                out[index] = .{ .key = k, .value = try self.fromPython(val, depth + 1) };
                index += 1;
            }
            if (needs_validation) try self.validateMap(out);
            return .{ .map = out };
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.map_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const entries = c.PyDict_GetItemString(fields, "entries") orelse
                return failure(c.PyExc_TypeError, "CELMap entries are missing");
            if (!hasTypeFlag(entries, c.Py_TPFLAGS_TUPLE_SUBCLASS))
                return failure(c.PyExc_TypeError, "CELMap entries must be a tuple");
            c.Py_IncRef(entries);
            defer c.Py_DecRef(entries);
            const length: usize = @intCast(c.PyTuple_Size(entries));
            if (length > self.remaining / 2) return failure(c.PyExc_ValueError, "input exceeds collection limit");
            const out = try self.arena.alloc(cel.Entry, length);
            for (out, 0..) |*entry, i| {
                const pair = c.PyTuple_GetItem(entries, @intCast(i));
                if (!hasTypeFlag(pair, c.Py_TPFLAGS_TUPLE_SUBCLASS) or c.PyTuple_Size(pair) != 2)
                    return failure(c.PyExc_TypeError, "CELMap entries must be key-value tuples");
                const key = c.PyTuple_GetItem(pair, 0);
                if (!hasTypeFlag(key, c.Py_TPFLAGS_LONG_SUBCLASS) and !hasTypeFlag(key, c.Py_TPFLAGS_UNICODE_SUBCLASS) and
                    c.Py_IS_TYPE(key, @ptrCast(self.uint_type)) == 0)
                    return failure(c.PyExc_TypeError, "CEL map keys must be bool, int, UInt, or str");
                entry.* = .{
                    .key = try self.fromPython(key, depth + 1),
                    .value = try self.fromPython(c.PyTuple_GetItem(pair, 1), depth + 1),
                };
            }
            try self.validateMap(out);
            return .{ .map = out };
        }
        const is_ip = c.Py_IS_TYPE(input, @ptrCast(self.ip_type)) != 0;
        if (is_ip or c.Py_IS_TYPE(input, @ptrCast(self.cidr_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const object = c.PyDict_GetItemString(fields, "value") orelse return failure(c.PyExc_TypeError, "missing network value");
            var length: c.Py_ssize_t = 0;
            const bytes = c.PyUnicode_AsUTF8AndSize(object, &length);
            if (bytes == null) return error.PythonException;
            if (length > 128) return failure(c.PyExc_ValueError, "network value is too long");
            const text = try self.copyBytes(bytes[0..@intCast(length)]);
            return if (is_ip) Value.fromIP(self.arena, cel.IP.parse(text) catch return failure(c.PyExc_ValueError, "invalid IP address")) else Value.fromCIDR(self.arena, cel.CIDR.parse(text) catch return failure(c.PyExc_ValueError, "invalid CIDR prefix"));
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.optional_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const has_value = c.PyDict_GetItemString(fields, "has_value") orelse
                return failure(c.PyExc_TypeError, "OptionalValue has_value is missing");
            const value = c.PyDict_GetItemString(fields, "value") orelse
                return failure(c.PyExc_TypeError, "OptionalValue value is missing");
            if (has_value != true_object and has_value != false_object) {
                return failure(c.PyExc_TypeError, "OptionalValue has_value must be a bool");
            }
            if (has_value == false_object) {
                if (value != c.Py_None()) return failure(c.PyExc_ValueError, "an absent OptionalValue must have a None value");
                return .{ .optional = null };
            }
            c.Py_IncRef(value);
            defer c.Py_DecRef(value);
            return Value.fromOptional(self.arena, try self.fromPython(value, depth + 1));
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.uint_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const object = c.PyDict_GetItemString(fields, "value") orelse
                return failure(c.PyExc_TypeError, "UInt requires an integer value");
            if (!hasTypeFlag(object, c.Py_TPFLAGS_LONG_SUBCLASS))
                return failure(c.PyExc_TypeError, "UInt requires an integer value");
            const n = c.PyLong_AsUnsignedLongLong(object);
            if (c.PyErr_Occurred() != null) return error.PythonException;
            return .{ .uint = n };
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.cel_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const object = c.PyDict_GetItemString(fields, "name") orelse
                return failure(c.PyExc_TypeError, "CELType requires a string name");
            var len: c.Py_ssize_t = 0;
            const name = c.PyUnicode_AsUTF8AndSize(object, &len);
            if (name == null) return error.PythonException;
            if (len == 0) return failure(c.PyExc_ValueError, "CELType name must not be empty");
            const parameters = c.PyDict_GetItemString(fields, "parameters") orelse
                return failure(c.PyExc_TypeError, "CELType parameters are missing");
            const kind = c.PyDict_GetItemString(fields, "kind") orelse
                return failure(c.PyExc_TypeError, "CELType kind is missing");
            if (c.PyUnicode_CompareWithASCIIString(kind, "concrete") != 0 or
                !hasTypeFlag(parameters, c.Py_TPFLAGS_TUPLE_SUBCLASS) or c.PyTuple_Size(parameters) != 0)
            {
                return failure(c.PyExc_TypeError, "non-concrete CELType is a declaration, not a runtime value");
            }
            return .{ .type_value = try self.copyBytes(name[0..@intCast(len)]) };
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.enum_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const name_object = c.PyDict_GetItemString(fields, "type_name") orelse
                return failure(c.PyExc_TypeError, "EnumValue type_name is missing");
            const number_object = c.PyDict_GetItemString(fields, "number") orelse
                return failure(c.PyExc_TypeError, "EnumValue number is missing");
            var length: c.Py_ssize_t = 0;
            const name = c.PyUnicode_AsUTF8AndSize(name_object, &length);
            if (name == null) return error.PythonException;
            const type_name = name[0..@intCast(length)];
            if (type_name.len > self.remaining_bytes) return failure(c.PyExc_ValueError, "input exceeds byte limit");
            if (!names.valid(type_name, false)) {
                return failure(c.PyExc_ValueError, "EnumValue type name must be qualified");
            }
            if (std.mem.count(u8, type_name, ".") >= 128) {
                return failure(c.PyExc_ValueError, "EnumValue type name exceeds depth limit");
            }
            if (!hasTypeFlag(number_object, c.Py_TPFLAGS_LONG_SUBCLASS) or
                number_object == true_object or number_object == false_object)
            {
                return failure(c.PyExc_TypeError, "EnumValue number must be an integer");
            }
            const number = c.PyLong_AsLongLong(number_object);
            if (c.PyErr_Occurred() != null) return error.PythonException;
            if (number < std.math.minInt(i32) or number > std.math.maxInt(i32)) {
                return failure(c.PyExc_ValueError, "EnumValue number must fit a signed 32-bit integer");
            }
            return Value.fromEnum(self.arena, .{
                .type_name = try self.copyBytes(type_name),
                .number = @intCast(number),
            });
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.message_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const name_object = c.PyDict_GetItemString(fields, "type_name") orelse
                return failure(c.PyExc_TypeError, "Message type_name is missing");
            const data_object = c.PyDict_GetItemString(fields, "data") orelse
                return failure(c.PyExc_TypeError, "Message data is missing");
            var length: c.Py_ssize_t = 0;
            const name = c.PyUnicode_AsUTF8AndSize(name_object, &length);
            if (name == null) return error.PythonException;
            if (!hasTypeFlag(data_object, c.Py_TPFLAGS_BYTES_SUBCLASS))
                return failure(c.PyExc_TypeError, "Message data must be bytes");
            const data_length: usize = @intCast(c.PyBytes_Size(data_object));
            return Value.fromMessage(self.arena, .{ .type_name = try self.copyBytes(name[0..@intCast(length)]), .data = try self.copyBytes(c.PyBytes_AsString(data_object)[0..data_length]) });
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.duration_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const object = c.PyDict_GetItemString(fields, "nanoseconds") orelse return failure(c.PyExc_TypeError, "missing duration nanoseconds");
            if (!hasTypeFlag(object, c.Py_TPFLAGS_LONG_SUBCLASS))
                return failure(c.PyExc_TypeError, "duration nanoseconds must be an integer");
            const nanoseconds = c.PyLong_AsLongLong(object);
            if (c.PyErr_Occurred() != null) return error.PythonException;
            return .{ .duration = .{ .nanoseconds = nanoseconds } };
        }
        if (c.Py_IS_TYPE(input, @ptrCast(self.timestamp_type)) != 0) {
            const fields = c.PyObject_GenericGetDict(input, null) orelse return error.PythonException;
            defer c.Py_DecRef(fields);
            const seconds_object = c.PyDict_GetItemString(fields, "seconds") orelse return failure(c.PyExc_TypeError, "missing timestamp seconds");
            const nanos_object = c.PyDict_GetItemString(fields, "nanos") orelse return failure(c.PyExc_TypeError, "missing timestamp nanos");
            if (!hasTypeFlag(seconds_object, c.Py_TPFLAGS_LONG_SUBCLASS) or
                !hasTypeFlag(nanos_object, c.Py_TPFLAGS_LONG_SUBCLASS))
                return failure(c.PyExc_TypeError, "timestamp fields must be integers");
            const seconds = c.PyLong_AsLongLong(seconds_object);
            const nanos = c.PyLong_AsUnsignedLongLong(nanos_object);
            if (c.PyErr_Occurred() != null) return error.PythonException;
            if (nanos >= 1_000_000_000) return failure(c.PyExc_ValueError, "timestamp nanos out of range");
            const time = cel.Timestamp{ .seconds = seconds, .nanos = @intCast(nanos) };
            time.validate() catch return failure(c.PyExc_ValueError, "timestamp seconds out of range");
            return .{ .timestamp = time };
        }
        return failure(c.PyExc_TypeError, "unsupported CEL input type");
    }

    fn validateMap(self: *Converter, entries: []const cel.Entry) ConversionError!void {
        cel.value.validateMapKeys(self.arena, entries) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidMapKey => failure(c.PyExc_TypeError, "CEL map keys must be bool, int, UInt, or str"),
            error.DuplicateKey => failure(c.PyExc_ValueError, "duplicate CEL map key"),
        };
    }

    fn toPython(self: *Converter, input: Value) ?*c.PyObject {
        return switch (input) {
            .null => blk: {
                const none = c.Py_None();
                c.Py_IncRef(none);
                break :blk none;
            },
            .bool => |v| c.PyBool_FromLong(@intFromBool(v)),
            .int => |v| c.PyLong_FromLongLong(v),
            .uint => |v| blk: {
                const n = c.PyLong_FromUnsignedLongLong(v) orelse return null;
                defer c.Py_DecRef(n);
                break :blk c.PyObject_CallFunctionObjArgs(self.uint_type, n, @as(?*c.PyObject, null));
            },
            .double => |v| c.PyFloat_FromDouble(v),
            .string => |v| c.PyUnicode_DecodeUTF8(v.ptr, @intCast(v.len), "strict"),
            .bytes => |v| c.PyBytes_FromStringAndSize(v.ptr, @intCast(v.len)),
            .ip, .cidr => blk: {
                const text = if (input == .ip) input.ip.format(self.arena) catch return c.PyErr_NoMemory() else input.cidr.format(self.arena) catch return c.PyErr_NoMemory();
                const string = c.PyUnicode_DecodeUTF8(text.ptr, @intCast(text.len), "strict") orelse return null;
                defer c.Py_DecRef(string);
                break :blk c.PyObject_CallFunctionObjArgs(if (input == .ip) self.ip_type else self.cidr_type, string, @as(?*c.PyObject, null));
            },
            .optional => |value| blk: {
                const has_value = c.PyBool_FromLong(@intFromBool(value != null)) orelse return null;
                defer c.Py_DecRef(has_value);
                const payload = if (value) |present| self.toPython(present.*) orelse return null else none: {
                    const none = c.Py_None();
                    c.Py_IncRef(none);
                    break :none none;
                };
                defer c.Py_DecRef(payload);
                break :blk c.PyObject_CallFunctionObjArgs(
                    self.optional_type,
                    has_value,
                    payload,
                    @as(?*c.PyObject, null),
                );
            },
            .type_value => |v| blk: {
                const name = c.PyUnicode_DecodeUTF8(v.ptr, @intCast(v.len), "strict") orelse return null;
                defer c.Py_DecRef(name);
                break :blk c.PyObject_CallFunctionObjArgs(self.cel_type, name, @as(?*c.PyObject, null));
            },
            .duration => |duration| blk: {
                const nanos = c.PyLong_FromLongLong(duration.nanoseconds) orelse return null;
                defer c.Py_DecRef(nanos);
                break :blk c.PyObject_CallFunctionObjArgs(self.duration_type, nanos, @as(?*c.PyObject, null));
            },
            .timestamp => |time| blk: {
                const seconds = c.PyLong_FromLongLong(time.seconds) orelse return null;
                defer c.Py_DecRef(seconds);
                const nanos = c.PyLong_FromUnsignedLong(time.nanos) orelse return null;
                defer c.Py_DecRef(nanos);
                break :blk c.PyObject_CallFunctionObjArgs(self.timestamp_type, seconds, nanos, @as(?*c.PyObject, null));
            },
            .enum_value => |item| blk: {
                const name = c.PyUnicode_DecodeUTF8(item.type_name.ptr, @intCast(item.type_name.len), "strict") orelse return null;
                defer c.Py_DecRef(name);
                const number = c.PyLong_FromLong(item.number) orelse return null;
                defer c.Py_DecRef(number);
                break :blk c.PyObject_CallFunctionObjArgs(self.enum_type, name, number, @as(?*c.PyObject, null));
            },
            .message => |m| blk: {
                const name = c.PyUnicode_DecodeUTF8(m.type_name.ptr, @intCast(m.type_name.len), "strict") orelse return null;
                defer c.Py_DecRef(name);
                const data = c.PyBytes_FromStringAndSize(m.data.ptr, @intCast(m.data.len)) orelse return null;
                defer c.Py_DecRef(data);
                break :blk c.PyObject_CallFunctionObjArgs(self.message_type, name, data, @as(?*c.PyObject, null));
            },
            .list => |items| blk: {
                const out = c.PyList_New(@intCast(items.len)) orelse return null;
                for (items, 0..) |item, i| {
                    const v = self.toPython(item) orelse {
                        c.Py_DecRef(out);
                        return null;
                    };
                    if (c.PyList_SetItem(out, @intCast(i), v) < 0) {
                        c.Py_DecRef(out);
                        return null;
                    }
                }
                break :blk out;
            },
            .map => |items| blk: {
                var booleans = [_]bool{ false, false };
                var integers = [_]bool{ false, false };
                for (items) |item| switch (item.key) {
                    .bool => |v| booleans[@intFromBool(v)] = true,
                    .int => |v| if (v == 0 or v == 1) {
                        integers[@intCast(v)] = true;
                    },
                    else => {},
                };
                if ((booleans[0] and integers[0]) or (booleans[1] and integers[1])) {
                    const entries = c.PyTuple_New(@intCast(items.len)) orelse return null;
                    defer c.Py_DecRef(entries);
                    for (items, 0..) |item, i| {
                        const key = self.toPython(item.key) orelse return null;
                        defer c.Py_DecRef(key);
                        const val = self.toPython(item.value) orelse return null;
                        defer c.Py_DecRef(val);
                        const pair = c.PyTuple_Pack(2, key, val) orelse return null;
                        if (c.PyTuple_SetItem(entries, @intCast(i), pair) < 0) return null;
                    }
                    break :blk c.PyObject_CallFunctionObjArgs(self.map_type, entries, @as(?*c.PyObject, null));
                }
                const out = c.PyDict_New() orelse return null;
                for (items) |item| {
                    const key = self.toPython(item.key) orelse {
                        c.Py_DecRef(out);
                        return null;
                    };
                    defer c.Py_DecRef(key);
                    const v = self.toPython(item.value) orelse {
                        c.Py_DecRef(out);
                        return null;
                    };
                    defer c.Py_DecRef(v);
                    if (c.PyDict_SetItem(out, key, v) < 0) {
                        c.Py_DecRef(out);
                        return null;
                    }
                }
                break :blk out;
            },
        };
    }
};

fn hasTypeFlag(object: [*c]c.PyObject, flag: c_ulong) bool {
    // ob_type is stable ABI; translated Py_TYPE calls may bind the Python 3.14 symbol.
    return c.PyType_HasFeature(object.*.ob_type, flag) != 0;
}

fn invokeCallback(context: ?*anyopaque, _: std.mem.Allocator, arguments: []const Value) cel.EvalError!Value {
    const record: *const CallbackContext = @ptrCast(@alignCast(context orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "function callback context is unavailable");
        return error.HostFunctionError;
    }));
    var active = callback_frame;
    const converter = while (active) |frame| : (active = frame.previous) {
        if (frame.owner == record.owner) break frame.converter;
    } else {
        c.PyErr_SetString(c.PyExc_RuntimeError, "function callback environment is inactive");
        return error.HostFunctionError;
    };
    const callback = c.PyTuple_GetItem(converter.callbacks, @intCast(record.index));
    if (callback == null) return error.HostFunctionError;
    const positional = c.PyTuple_New(@intCast(arguments.len)) orelse return error.HostFunctionError;
    defer c.Py_DecRef(positional);
    for (arguments, 0..) |argument, index| {
        const object = converter.toPython(argument) orelse return error.HostFunctionError;
        if (c.PyTuple_SetItem(positional, @intCast(index), object) < 0) return error.HostFunctionError;
    }
    const result = c.PyObject_CallObject(callback, positional) orelse return error.HostFunctionError;
    defer c.Py_DecRef(result);
    return converter.fromPython(result, 0) catch |err| {
        if (err == error.OutOfMemory) _ = c.PyErr_NoMemory();
        return error.HostFunctionError;
    };
}

fn normalizeNetwork(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyTuple_Size(args) != 2) {
        c.PyErr_SetString(c.PyExc_TypeError, "network normalization requires text and kind");
        return null;
    }
    var length: c.Py_ssize_t = 0;
    const bytes = c.PyUnicode_AsUTF8AndSize(c.PyTuple_GetItem(args, 0), &length);
    if (bytes == null) return null;
    const kind = c.PyObject_IsTrue(c.PyTuple_GetItem(args, 1));
    if (kind < 0) return null;
    if (length > 128) {
        c.PyErr_SetString(c.PyExc_ValueError, "network value is too long");
        return null;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = bytes[0..@intCast(length)];
    const normalized = if (kind != 0) blk: {
        const parsed = cel.CIDR.parse(text) catch {
            c.PyErr_SetString(c.PyExc_ValueError, "invalid CIDR prefix");
            return null;
        };
        break :blk parsed.format(arena.allocator()) catch return c.PyErr_NoMemory();
    } else blk: {
        const parsed = cel.IP.parse(text) catch {
            c.PyErr_SetString(c.PyExc_ValueError, "invalid IP address");
            return null;
        };
        break :blk parsed.format(arena.allocator()) catch return c.PyErr_NoMemory();
    };
    return c.PyUnicode_DecodeUTF8(normalized.ptr, @intCast(normalized.len), "strict");
}

var methods = [_]c.PyMethodDef{
    .{ .ml_name = "normalize_network", .ml_meth = normalizeNetwork, .ml_flags = c.METH_VARARGS, .ml_doc = "Normalize a network value." },
    .{ .ml_name = "environment", .ml_meth = environment, .ml_flags = c.METH_VARARGS, .ml_doc = "Create an environment." },
    .{ .ml_name = "compile_in", .ml_meth = compileIn, .ml_flags = c.METH_VARARGS, .ml_doc = "Compile in an environment." },
    .{ .ml_name = "result_type", .ml_meth = resultType, .ml_flags = c.METH_VARARGS, .ml_doc = "Get the static result type." },
    .{ .ml_name = "compile", .ml_meth = compile, .ml_flags = c.METH_O, .ml_doc = "Compile a CEL expression." },
    .{ .ml_name = "evaluate", .ml_meth = evaluate, .ml_flags = c.METH_VARARGS, .ml_doc = "Evaluate a compiled CEL expression." },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};
var module = c.PyModuleDef{
    .m_base = std.mem.zeroes(c.PyModuleDef_Base),
    .m_name = "_native",
    .m_doc = "Native Zig CEL engine.",
    .m_size = 0,
    .m_methods = &methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

/// CPython extension entry point.
pub export fn PyInit__native() ?*c.PyObject {
    return c.PyModule_Create2(&module, c.PYTHON_API_VERSION);
}
