//! CEL syntax tree and bounded parser. Nodes and decoded literals live in the caller's arena.

const std = @import("std");
const value = @import("value.zig");
const regex = @import("regex.zig");
const proto = @import("proto.zig");
const types = @import("types.zig");
const Value = value.Value;

/// Failures when compiling source text.
pub const ParseError = error{
    /// Allocation failed.
    OutOfMemory,
    /// The expression does not match the CEL grammar.
    InvalidSyntax,
    /// A literal cannot be represented in its CEL type.
    InvalidLiteral,
    /// The source exceeds the configured byte limit.
    SourceLimitExceeded,
    /// Parsing or evaluation nesting exceeds the configured limit.
    DepthLimitExceeded,
    /// The syntax tree exceeds the configured node limit.
    NodeLimitExceeded,
};

/// Limits shared by compilation and evaluation of untrusted input.
pub const Limits = struct {
    max_source_bytes: usize = 1_048_576,
    max_depth: usize = 128,
    max_nodes: usize = 100_000,
    max_steps: usize = 1_000_000,
    max_check_steps: usize = 1_000_000,
    max_collection_size: usize = 100_000,
    regex: regex.Limits = .{},
    protobuf: proto.Limits = .{},
};

/// CEL operators and lexical tokens.
pub const Token = enum {
    eof,
    identifier,
    quoted_identifier,
    number,
    string,
    bytes,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    dot,
    colon,
    question,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    in_op,
};

/// Arena-owned syntax node. Source slices borrow the program's owned source.
pub const Node = union(enum) {
    literal: Value,
    ident: []const u8,
    local_ident: []const u8,
    block: struct { slots: []const *const Node, body: *const Node },
    block_index: usize,
    variable: []const u8,
    unary: struct { op: Token, operand: *const Node },
    binary: struct { op: Token, left: *const Node, right: *const Node },
    conditional: struct { condition: *const Node, yes: *const Node, no: *const Node },
    select: struct {
        target: *const Node,
        field: []const u8,
        /// An unquoted identifier chain can resolve to a qualified input name.
        qualified: bool,
        optional: bool = false,
    },
    index: struct { target: *const Node, key: *const Node, optional: bool = false },
    list: []const ListElement,
    map: []const MapEntry,
    call: Call,
    comprehension: Comprehension,
    optional_map: struct { target: *const Node, variable: []const u8, body: *const Node, flat: bool },
    sort_by: struct { target: *const Node, variable: []const u8, body: *const Node },
    local_bind: struct { name: []const u8, initializer: *const Node, body: *const Node },
    presence: struct { target: *const Node, field: []const u8 },
    message: struct { type_name: []const u8, fields: []const FieldInit },
};

/// One message field initializer.
pub const FieldInit = struct { name: []const u8, value: *const Node, optional: bool = false };

/// Unevaluated list element.
pub const ListElement = struct { value: *const Node, optional: bool = false };

/// Unevaluated map entry.
pub const MapEntry = struct { key: *const Node, value: *const Node, optional: bool = false };
/// Global or receiver-style function call.
pub const Call = struct {
    target: ?*const Node,
    name: []const u8,
    args: []const *const Node,
    /// Checked custom overloads, indexed into the program's owned environment.
    function_indices: ?[]const usize = null,
    /// Final inferred return contract for a checked custom call.
    function_result: ?types.Type = null,
    /// Checked built-ins do not need runtime custom-function namespace probing.
    checked: bool = false,
    /// Whether this call is the greatest (true) or least (false) namespace macro.
    math_extrema: ?bool = null,
};

/// A macro lowered to explicit iteration variables and expressions during compilation.
pub const Comprehension = struct {
    /// The result accumulated by a comprehension.
    pub const Kind = enum { all, exists, exists_one, list, map, map_entries };

    kind: Kind,
    target: *const Node,
    key_name: []const u8,
    value_name: ?[]const u8,
    predicate: ?*const Node,
    transform: ?*const Node,
};

/// Parse a complete expression into arena storage.
pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    limits: Limits,
    regex_patterns: *std.ArrayList([]const u8),
) ParseError!*const Node {
    if (source.len > limits.max_source_bytes) return error.SourceLimitExceeded;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidSyntax;
    var parser = Parser{ .arena = arena, .source = source, .limits = limits, .regex_patterns = regex_patterns };
    try parser.advance();
    const root = try parser.expression(0);
    if (parser.token != .eof) return error.InvalidSyntax;
    return root;
}

const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    limits: Limits,
    regex_patterns: *std.ArrayList([]const u8),
    pos: usize = 0,
    start: usize = 0,
    token: Token = .eof,
    text: []const u8 = "",
    depth: usize = 0,
    nodes: usize = 0,

    fn node(self: *Parser, item: Node) ParseError!*const Node {
        if (self.nodes >= self.limits.max_nodes) return error.NodeLimitExceeded;
        self.nodes += 1;
        const result = try self.arena.create(Node);
        result.* = item;
        return result;
    }

    fn advance(self: *Parser) ParseError!void {
        const s = self.source;
        while (self.pos < s.len) {
            if (std.ascii.isWhitespace(s[self.pos])) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, s[self.pos..], "//")) {
                while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            } else break;
        }
        self.start = self.pos;
        if (self.pos == s.len) {
            self.token = .eof;
            self.text = "";
            return;
        }
        var quote_pos = self.pos;
        var is_bytes = false;
        var raw = false;
        if (s[quote_pos] == 'b' or s[quote_pos] == 'B') {
            is_bytes = true;
            quote_pos += 1;
        }
        if (quote_pos < s.len and (s[quote_pos] == 'r' or s[quote_pos] == 'R')) {
            raw = true;
            quote_pos += 1;
        }
        if (quote_pos < s.len and (s[quote_pos] == '\'' or s[quote_pos] == '"')) {
            const quote = s[quote_pos];
            const triple = quote_pos + 2 < s.len and s[quote_pos + 1] == quote and s[quote_pos + 2] == quote;
            const width: usize = if (triple) 3 else 1;
            self.pos = quote_pos + width;
            while (self.pos < s.len) {
                const c = s[self.pos];
                if (c == quote and (!triple or (self.pos + 2 < s.len and
                    s[self.pos + 1] == quote and s[self.pos + 2] == quote)))
                {
                    self.pos += width;
                    self.token = if (is_bytes) .bytes else .string;
                    self.text = s[self.start..self.pos];
                    return;
                }
                if (!triple and (c == '\n' or c == '\r')) return error.InvalidSyntax;
                if (c == '\\' and !raw) self.pos += 1;
                self.pos += 1;
            }
            return error.InvalidSyntax;
        }
        const c = s[self.pos];
        self.pos += 1;
        if (c == '`') {
            while (self.pos < s.len and s[self.pos] != '`') : (self.pos += 1) {
                if (!std.ascii.isAlphanumeric(s[self.pos]) and
                    std.mem.indexOfScalar(u8, "_./- ", s[self.pos]) == null) return error.InvalidSyntax;
            }
            if (self.pos == s.len or self.pos == self.start + 1) return error.InvalidSyntax;
            self.text = s[self.start + 1 .. self.pos];
            self.pos += 1;
            self.token = .quoted_identifier;
            return;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < s.len and (std.ascii.isAlphanumeric(s[self.pos]) or s[self.pos] == '_')) self.pos += 1;
            self.text = s[self.start..self.pos];
            self.token = if (std.mem.eql(u8, self.text, "in")) .in_op else .identifier;
            return;
        }
        if (std.ascii.isDigit(c) or (c == '.' and self.pos < s.len and std.ascii.isDigit(s[self.pos]))) {
            if (c == '0' and self.pos < s.len and (s[self.pos] == 'x' or s[self.pos] == 'X')) {
                self.pos += 1;
                while (self.pos < s.len and std.ascii.isHex(s[self.pos])) self.pos += 1;
            } else {
                while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
                if (c != '.' and self.pos + 1 < s.len and s[self.pos] == '.' and std.ascii.isDigit(s[self.pos + 1])) {
                    self.pos += 1;
                    while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
                }
                if (self.pos < s.len and (s[self.pos] == 'e' or s[self.pos] == 'E')) {
                    self.pos += 1;
                    if (self.pos < s.len and (s[self.pos] == '+' or s[self.pos] == '-')) self.pos += 1;
                    while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
                }
            }
            if (self.pos < s.len and (s[self.pos] == 'u' or s[self.pos] == 'U')) self.pos += 1;
            self.token = .number;
        } else {
            self.token = switch (c) {
                '(' => .lparen,
                ')' => .rparen,
                '[' => .lbracket,
                ']' => .rbracket,
                '{' => .lbrace,
                '}' => .rbrace,
                ',' => .comma,
                '.' => .dot,
                ':' => .colon,
                '?' => .question,
                '+' => .plus,
                '-' => .minus,
                '*' => .star,
                '/' => .slash,
                '%' => .percent,
                '!', '=', '<', '>' => blk: {
                    const equal = self.pos < s.len and s[self.pos] == '=';
                    if (equal) self.pos += 1;
                    break :blk switch (c) {
                        '!' => if (equal) .ne else .bang,
                        '=' => if (equal) .eq else return error.InvalidSyntax,
                        '<' => if (equal) .le else .lt,
                        '>' => if (equal) .ge else .gt,
                        else => unreachable,
                    };
                },
                '&', '|' => blk: {
                    if (self.pos == s.len or s[self.pos] != c) return error.InvalidSyntax;
                    self.pos += 1;
                    break :blk if (c == '&') .and_op else .or_op;
                },
                else => return error.InvalidSyntax,
            };
        }
        self.text = s[self.start..self.pos];
    }

    fn consume(self: *Parser, token: Token) ParseError!void {
        if (self.token != token) return error.InvalidSyntax;
        try self.advance();
    }

    fn expression(self: *Parser, min_precedence: u8) ParseError!*const Node {
        if (self.depth >= self.limits.max_depth) return error.DepthLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        var left = try self.prefix();
        while (true) {
            if (self.token == .lbrace) {
                const type_name = try qualifiedName(self.arena, left);
                try self.advance();
                var fields: std.ArrayList(FieldInit) = .empty;
                while (self.token != .rbrace) {
                    const optional = self.token == .question;
                    if (optional) try self.advance();
                    if (self.token != .identifier and self.token != .quoted_identifier) return error.InvalidSyntax;
                    const field_name = self.text;
                    try self.advance();
                    try self.consume(.colon);
                    try fields.append(self.arena, .{
                        .name = field_name,
                        .value = try self.expression(0),
                        .optional = optional,
                    });
                    if (self.token != .comma) break;
                    try self.advance();
                }
                try self.consume(.rbrace);
                left = try self.node(.{ .message = .{ .type_name = type_name, .fields = try fields.toOwnedSlice(self.arena) } });
                continue;
            }
            if (self.token == .dot) {
                try self.advance();
                const optional = self.token == .question;
                if (optional) try self.advance();
                const quoted = self.token == .quoted_identifier;
                if (!quoted and (self.token != .identifier or std.mem.eql(u8, self.text, "true") or
                    std.mem.eql(u8, self.text, "false") or std.mem.eql(u8, self.text, "null")))
                {
                    return error.InvalidSyntax;
                }
                const name = self.text;
                try self.advance();
                if ((quoted or optional) and self.token == .lparen) return error.InvalidSyntax;
                left = if (self.token == .lparen)
                    try self.call(left, name)
                else
                    try self.node(.{ .select = .{
                        .target = left,
                        .field = name,
                        .qualified = !optional and !quoted and
                            (left.* == .ident or (left.* == .select and left.select.qualified)),
                        .optional = optional,
                    } });
                continue;
            }
            if (self.token == .lbracket) {
                try self.advance();
                const optional = self.token == .question;
                if (optional) try self.advance();
                const key = try self.expression(0);
                try self.consume(.rbracket);
                left = try self.node(.{ .index = .{ .target = left, .key = key, .optional = optional } });
                continue;
            }
            const precedence: u8 = switch (self.token) {
                .question => 1,
                .or_op => 2,
                .and_op => 3,
                .eq, .ne, .lt, .le, .gt, .ge, .in_op => 4,
                .plus, .minus => 5,
                .star, .slash, .percent => 6,
                else => break,
            };
            if (precedence < min_precedence) break;
            const op = self.token;
            try self.advance();
            if (op == .question) {
                const yes = try self.expression(0);
                try self.consume(.colon);
                const no = try self.expression(1);
                left = try self.node(.{ .conditional = .{ .condition = left, .yes = yes, .no = no } });
            } else {
                const right = try self.expression(precedence + 1);
                left = try self.node(.{ .binary = .{ .op = op, .left = left, .right = right } });
            }
        }
        return left;
    }

    fn prefix(self: *Parser) ParseError!*const Node {
        const token = self.token;
        const text = self.text;
        try self.advance();
        switch (token) {
            .number => return self.node(.{ .literal = try number(text) }),
            .string, .bytes => {
                const decoded = try decode(self.arena, text, token == .bytes);
                return self.node(.{ .literal = if (token == .bytes) .{ .bytes = decoded } else .{ .string = decoded } });
            },
            .identifier => {
                if (std.mem.eql(u8, text, "true")) return self.node(.{ .literal = .{ .bool = true } });
                if (std.mem.eql(u8, text, "false")) return self.node(.{ .literal = .{ .bool = false } });
                if (std.mem.eql(u8, text, "null")) return self.node(.{ .literal = .null });
                if (reserved(text)) return error.InvalidSyntax;
                if (self.token == .lparen) return self.call(null, text);
                return self.node(.{ .ident = text });
            },
            .dot => {
                if (self.token != .identifier or reserved(self.text)) return error.InvalidSyntax;
                const name = try std.mem.concat(self.arena, u8, &.{ ".", self.text });
                try self.advance();
                if (self.token == .lparen) return self.call(null, name);
                return self.node(.{ .ident = name });
            },
            .minus, .bang => {
                if (token == .minus and self.token == .number and
                    (std.mem.eql(u8, self.text, "9223372036854775808") or
                        std.ascii.eqlIgnoreCase(self.text, "0x8000000000000000")))
                {
                    try self.advance();
                    return self.node(.{ .literal = .{ .int = std.math.minInt(i64) } });
                }
                return self.node(.{ .unary = .{ .op = token, .operand = try self.expression(7) } });
            },
            .lparen => {
                const result = try self.expression(0);
                try self.consume(.rparen);
                return result;
            },
            .lbracket => {
                var items: std.ArrayList(ListElement) = .empty;
                while (self.token != .rbracket) {
                    const optional = self.token == .question;
                    if (optional) try self.advance();
                    try items.append(self.arena, .{ .value = try self.expression(0), .optional = optional });
                    if (self.token != .comma) break;
                    try self.advance();
                }
                try self.consume(.rbracket);
                return self.node(.{ .list = try items.toOwnedSlice(self.arena) });
            },
            .lbrace => {
                var items: std.ArrayList(MapEntry) = .empty;
                while (self.token != .rbrace) {
                    const optional = self.token == .question;
                    if (optional) try self.advance();
                    const key = try self.expression(0);
                    try self.consume(.colon);
                    const item = try self.expression(0);
                    try items.append(self.arena, .{ .key = key, .value = item, .optional = optional });
                    if (self.token != .comma) break;
                    try self.advance();
                }
                try self.consume(.rbrace);
                return self.node(.{ .map = try items.toOwnedSlice(self.arena) });
            },
            else => return error.InvalidSyntax,
        }
    }

    fn call(self: *Parser, target: ?*const Node, name: []const u8) ParseError!*const Node {
        try self.consume(.lparen);
        var args: std.ArrayList(*const Node) = .empty;
        if (self.token != .rparen) while (true) {
            try args.append(self.arena, try self.expression(0));
            if (self.token != .comma) break;
            try self.advance();
        };
        try self.consume(.rparen);
        if (target == null and std.mem.eql(u8, name, "has") and args.items.len == 1) {
            if (args.items[0].* != .select) return error.InvalidSyntax;
            const select = args.items[0].select;
            return self.node(.{ .presence = .{ .target = select.target, .field = select.field } });
        }
        if (target) |receiver| if (receiver.* == .ident and std.mem.eql(u8, receiver.ident, "proto") and
            (std.mem.eql(u8, name, "hasExt") or std.mem.eql(u8, name, "getExt")) and args.items.len == 2)
        {
            if (args.items[1].* != .select) return error.InvalidSyntax;
            var pieces: std.ArrayList([]const u8) = .empty;
            var current = args.items[1];
            while (current.* == .select) {
                if (current.select.optional) return error.InvalidSyntax;
                try pieces.append(self.arena, current.select.field);
                current = current.select.target;
            }
            if (current.* != .ident) return error.InvalidSyntax;
            try pieces.append(self.arena, current.ident);
            std.mem.reverse([]const u8, pieces.items);
            const extension = try std.mem.join(self.arena, ".", pieces.items);
            if (std.mem.eql(u8, name, "hasExt"))
                return self.node(.{ .presence = .{ .target = args.items[0], .field = extension } });
            return self.node(.{ .select = .{ .target = args.items[0], .field = extension, .qualified = false } });
        };
        if (target) |receiver| if (receiver.* == .ident and std.mem.eql(u8, receiver.ident, "cel")) {
            if (std.mem.eql(u8, name, "block")) {
                if (args.items.len != 2 or args.items[0].* != .list) return error.InvalidSyntax;
                const elements = args.items[0].list;
                const slots = try self.arena.alloc(*const Node, elements.len);
                for (elements, slots) |element, *slot| slot.* = element.value;
                return self.node(.{ .block = .{ .slots = slots, .body = args.items[1] } });
            }
            if (std.mem.eql(u8, name, "index")) {
                if (args.items.len != 1) return error.InvalidSyntax;
                const index = try indexLiteral(args.items[0]);
                return self.node(.{ .block_index = index });
            }
            if (std.mem.eql(u8, name, "iterVar") or std.mem.eql(u8, name, "accuVar")) {
                if (args.items.len != 2) return error.InvalidSyntax;
                const depth = try indexLiteral(args.items[0]);
                const slot = try indexLiteral(args.items[1]);
                const alias_prefix = if (std.mem.eql(u8, name, "iterVar")) "@it" else "@ac";
                return self.node(.{ .local_ident = try std.fmt.allocPrint(self.arena, "{s}:{d}:{d}", .{ alias_prefix, depth, slot }) });
            }
        };
        if (target) |receiver| if (receiver.* == .ident and std.mem.eql(u8, receiver.ident, "cel") and
            std.mem.eql(u8, name, "bind") and args.items.len == 3)
        {
            const variable = bindingName(args.items[0]) orelse return error.InvalidSyntax;
            return self.node(.{ .local_bind = .{
                .name = variable,
                .initializer = args.items[1],
                .body = args.items[2],
            } });
        };
        if (target) |optional_target| {
            if (std.mem.eql(u8, name, "optMap") or std.mem.eql(u8, name, "optFlatMap")) {
                if (args.items.len != 2) return error.InvalidSyntax;
                const variable = bindingName(args.items[0]) orelse return error.InvalidSyntax;
                if (std.mem.startsWith(u8, variable, ".")) return error.InvalidSyntax;
                return self.node(.{ .optional_map = .{
                    .target = optional_target,
                    .variable = variable,
                    .body = args.items[1],
                    .flat = std.mem.eql(u8, name, "optFlatMap"),
                } });
            }
        }
        if (target) |sort_target| if (std.mem.eql(u8, name, "sortBy") and args.items.len == 2) {
            switch (sort_target.*) {
                .literal, .map, .message => return error.InvalidSyntax,
                else => {},
            }
            const variable = bindingName(args.items[0]) orelse return error.InvalidSyntax;
            if (std.mem.startsWith(u8, variable, ".")) return error.InvalidSyntax;
            return self.node(.{ .sort_by = .{
                .target = sort_target,
                .variable = variable,
                .body = args.items[1],
            } });
        };
        const macros = std.StaticStringMap(Comprehension.Kind).initComptime(.{
            .{ "all", .all },              .{ "exists", .exists },    .{ "exists_one", .exists_one },
            .{ "existsOne", .exists_one }, .{ "map", .list },         .{ "filter", .list },
            .{ "transformList", .list },   .{ "transformMap", .map }, .{ "transformMapEntry", .map_entries },
        });
        if (target) |range| if (macros.get(name)) |kind| macro: {
            const quantifier = kind == .all or kind == .exists or kind == .exists_one;
            const filter = std.mem.eql(u8, name, "filter");
            const two_vars = std.mem.startsWith(u8, name, "transform") or (quantifier and args.items.len == 3);
            const variables: usize = if (two_vars) 2 else 1;
            const minimum: usize = variables + 1;
            const maximum: usize = minimum + @intFromBool(!quantifier and !filter);
            if (args.items.len < minimum or args.items.len > maximum or
                (std.mem.eql(u8, name, "existsOne") and !two_vars)) break :macro;
            for (args.items[0..variables]) |arg| {
                const variable = bindingName(arg) orelse return error.InvalidSyntax;
                if (std.mem.startsWith(u8, variable, ".")) return error.InvalidSyntax;
            }
            const first = bindingName(args.items[0]).?;
            const second = if (two_vars) bindingName(args.items[1]).? else null;
            if (second) |name_of_second| if (std.mem.eql(u8, first, name_of_second)) return error.InvalidSyntax;
            const predicate = if (quantifier or filter or args.items.len == variables + 2)
                args.items[variables]
            else
                null;
            const transform = if (quantifier or filter) null else args.items[args.items.len - 1];
            return self.node(.{ .comprehension = .{
                .kind = kind,
                .target = range,
                .key_name = first,
                .value_name = second,
                .predicate = predicate,
                .transform = transform,
            } });
        };
        if (target) |namespace| {
            if (namespace.* == .ident and
                (std.mem.eql(u8, namespace.ident, "math") or std.mem.eql(u8, namespace.ident, ".math")))
            {
                const greatest = std.mem.eql(u8, name, "greatest");
                if (greatest or std.mem.eql(u8, name, "least")) {
                    if (args.items.len == 0 or
                        (args.items.len == 1 and !validMathExtremaSingleArg(args.items[0])))
                    {
                        return error.InvalidSyntax;
                    }
                    if (args.items.len > 1) for (args.items) |arg| {
                        if (!validMathExtremaArg(arg)) return error.InvalidSyntax;
                    };
                    return self.node(.{ .call = .{
                        .target = null,
                        .name = if (greatest) "math.greatest" else "math.least",
                        .args = try args.toOwnedSlice(self.arena),
                        .math_extrema = greatest,
                    } });
                }
            }
        }
        const function_name = if (target == null and std.mem.startsWith(u8, name, ".")) name[1..] else name;
        const match_args: usize = if (target == null) 2 else 1;
        if (std.mem.eql(u8, function_name, "matches") and args.items.len == match_args) {
            const pattern = args.items[match_args - 1];
            if (pattern.* == .literal and pattern.literal == .string) {
                try self.regex_patterns.append(self.arena, pattern.literal.string);
            }
        }
        return self.node(.{ .call = .{ .target = target, .name = name, .args = try args.toOwnedSlice(self.arena) } });
    }
};

fn bindingName(node: *const Node) ?[]const u8 {
    return switch (node.*) {
        .ident, .local_ident => |name| name,
        else => null,
    };
}

fn indexLiteral(node: *const Node) ParseError!usize {
    if (node.* != .literal or node.literal != .int) return error.InvalidSyntax;
    return std.math.cast(usize, node.literal.int) orelse error.InvalidSyntax;
}

fn validMathExtremaSingleArg(arg: *const Node) bool {
    if (arg.* != .list) return validMathExtremaArg(arg);
    if (arg.list.len == 0) return false;
    for (arg.list) |item| if (!validMathExtremaArg(item.value)) return false;
    return true;
}

fn validMathExtremaArg(arg: *const Node) bool {
    return switch (arg.*) {
        .literal => |literal| literal.numeric(),
        .list, .map, .message => false,
        else => true,
    };
}

/// Materialize a qualified identifier without repeatedly copying its prefixes.
pub fn qualifiedName(arena: std.mem.Allocator, node: *const Node) ParseError![]const u8 {
    var pieces: std.ArrayList([]const u8) = .empty;
    var current = node;
    while (current.* == .select) {
        if (!current.select.qualified) return error.InvalidSyntax;
        try pieces.append(arena, current.select.field);
        current = current.select.target;
    }
    if (current.* != .ident) return error.InvalidSyntax;
    try pieces.append(arena, current.ident);
    std.mem.reverse([]const u8, pieces.items);
    return std.mem.join(arena, ".", pieces.items);
}

fn reserved(name: []const u8) bool {
    const names = std.StaticStringMap(void).initComptime(.{
        .{"true"},   .{"false"},    .{"null"}, .{"as"},     .{"break"}, .{"const"}, .{"continue"}, .{"else"},
        .{"for"},    .{"function"}, .{"if"},   .{"import"}, .{"let"},   .{"loop"},  .{"package"},  .{"namespace"},
        .{"return"}, .{"var"},      .{"void"}, .{"while"},
    });
    return names.has(name);
}

fn number(text: []const u8) ParseError!Value {
    if (std.ascii.toLower(text[text.len - 1]) == 'u') {
        const digits = text[0 .. text.len - 1];
        const hex = std.ascii.startsWithIgnoreCase(digits, "0x");
        return .{ .uint = std.fmt.parseInt(u64, if (hex) digits[2..] else digits, if (hex) 16 else 10) catch return error.InvalidLiteral };
    }
    const hex = std.ascii.startsWithIgnoreCase(text, "0x");
    if (!hex and std.mem.indexOfAny(u8, text, ".eE") != null) {
        const v = std.fmt.parseFloat(f64, text) catch return error.InvalidLiteral;
        if (!std.math.isFinite(v)) return error.InvalidLiteral;
        return .{ .double = v };
    }
    return .{ .int = std.fmt.parseInt(i64, if (hex) text[2..] else text, if (hex) 16 else 10) catch return error.InvalidLiteral };
}

fn decode(arena: std.mem.Allocator, text: []const u8, is_bytes: bool) ParseError![]const u8 {
    var start: usize = if (is_bytes) 1 else 0;
    const raw = text[start] == 'r' or text[start] == 'R';
    if (raw) start += 1;
    const quote = text[start];
    const width: usize = if (start + 2 < text.len and text[start + 1] == quote and text[start + 2] == quote) 3 else 1;
    const source = text[start + width .. text.len - width];
    if (raw) return source;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < source.len) : (pos += 1) {
        if (source[pos] != '\\') {
            try out.append(arena, source[pos]);
            continue;
        }
        pos += 1;
        if (pos == source.len) return error.InvalidLiteral;
        const c = source[pos];
        const escaped: ?u8 = switch (c) {
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'n' => 10,
            'r' => 13,
            't' => 9,
            'v' => 11,
            '\\', '\'', '"', '?', '`' => c,
            else => null,
        };
        if (escaped) |v| {
            try out.append(arena, v);
        } else {
            const code: u21 = if (c == 'x' or c == 'X' or c == 'u' or c == 'U') blk: {
                const count: usize = switch (c) {
                    'u' => 4,
                    'U' => 8,
                    else => 2,
                };
                if (is_bytes and count != 2) return error.InvalidLiteral;
                if (pos + 1 + count > source.len) return error.InvalidLiteral;
                const result = std.fmt.parseInt(u21, source[pos + 1 .. pos + 1 + count], 16) catch return error.InvalidLiteral;
                pos += count;
                break :blk result;
            } else if (c >= '0' and c <= '3') blk: {
                if (pos + 3 > source.len) return error.InvalidLiteral;
                const result = std.fmt.parseInt(u8, source[pos .. pos + 3], 8) catch return error.InvalidLiteral;
                pos += 2;
                break :blk result;
            } else return error.InvalidLiteral;
            if (is_bytes) {
                try out.append(arena, @intCast(code));
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code, &buf) catch return error.InvalidLiteral;
                try out.appendSlice(arena, buf[0..len]);
            }
        }
    }
    if (!is_bytes and !std.unicode.utf8ValidateSlice(out.items)) return error.InvalidLiteral;
    return out.toOwnedSlice(arena);
}
