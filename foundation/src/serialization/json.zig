const std = @import("std");
const errors = @import("../error/error.zig");

pub const Limits = struct {
    max_bytes: usize = 4 * 1024 * 1024,
    max_depth: usize = 64,
    max_nodes: usize = 100_000,
    max_string_bytes: usize = 1024 * 1024,
};

pub const ParseError = error{ InvalidJson, LimitExceeded, OutOfMemory };

/// A parsed JSON document. It owns all parsed storage; every `JsonValueView`
/// obtained from it is borrowed and becomes invalid after `deinit`.
pub const JsonDocument = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *JsonDocument) void {
        self.parsed.deinit();
    }

    pub fn root(self: *const JsonDocument) JsonValueView {
        return .{ .value = &self.parsed.value };
    }
};

/// Read-only borrowed view of a value in a `JsonDocument`. Strings and object
/// keys are decoded UTF-8 bytes; JSON escape spelling is not retained.
pub const JsonValueView = struct {
    value: *const std.json.Value,

    pub const Kind = enum { null, bool, signed_integer, unsigned_integer, float, string, array, object, number_string };

    pub fn kind(self: JsonValueView) Kind {
        return switch (self.value.*) {
            .null => .null,
            .bool => .bool,
            .integer => |number| if (number < 0) .signed_integer else .unsigned_integer,
            .float => .float,
            .string => .string,
            .array => .array,
            .object => .object,
            .number_string => .number_string,
        };
    }
    pub fn boolean(self: JsonValueView) ?bool {
        return if (self.value.* == .bool) self.value.bool else null;
    }
    pub fn signedInteger(self: JsonValueView) ?i64 {
        return if (self.value.* == .integer) self.value.integer else null;
    }
    pub fn unsignedInteger(self: JsonValueView) ?u64 {
        return if (self.value.* == .integer and self.value.integer >= 0) @intCast(self.value.integer) else null;
    }
    pub fn float(self: JsonValueView) ?f64 {
        return if (self.value.* == .float) self.value.float else null;
    }
    pub fn string(self: JsonValueView) ?[]const u8 {
        return switch (self.value.*) {
            .string => |text| text,
            .number_string => |text| text,
            else => null,
        };
    }
    pub fn arrayLen(self: JsonValueView) ?usize {
        return if (self.value.* == .array) self.value.array.items.len else null;
    }
    pub fn arrayAt(self: JsonValueView, index: usize) ?JsonValueView {
        if (self.value.* != .array or index >= self.value.array.items.len) return null;
        return .{ .value = &self.value.array.items[index] };
    }
    pub fn objectGet(self: JsonValueView, key: []const u8) ?JsonValueView {
        if (self.value.* != .object) return null;
        const found = self.value.object.getPtr(key) orelse return null;
        return .{ .value = found };
    }
    pub fn objectLen(self: JsonValueView) ?usize {
        return if (self.value.* == .object) self.value.object.count() else null;
    }
    pub fn objectFieldAt(self: JsonValueView, index: usize) ?Field {
        if (self.value.* != .object or index >= self.value.object.count()) return null;
        const entry = self.value.object.entries.get(index);
        return .{ .key = entry.key, .value = .{ .value = &entry.value } };
    }
    pub const Field = struct { key: []const u8, value: JsonValueView };
};

pub const JsonCodec = struct {
    context: ?*anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { parse: *const fn (?*anyopaque, std.mem.Allocator, []const u8, Limits) ParseError!JsonDocument };
    pub fn parse(self: JsonCodec, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) ParseError!JsonDocument {
        return self.vtable.parse(self.context, allocator, bytes, limits);
    }
};

pub fn stdCodec() JsonCodec {
    return .{ .context = null, .vtable = &std_vtable };
}
const std_vtable = JsonCodec.VTable{ .parse = parseStd };

fn parseStd(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) ParseError!JsonDocument {
    if (bytes.len > limits.max_bytes) return error.LimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always, .max_value_len = limits.max_string_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValueTooLong => return error.LimitExceeded,
        else => return error.InvalidJson,
    };
    errdefer parsed.deinit();
    var counter = Counter{ .limits = limits };
    try inspect(&parsed.value, &counter, 0);
    return .{ .parsed = parsed };
}

const Counter = struct { limits: Limits, nodes: usize = 0 };
fn inspect(value: *const std.json.Value, counter: *Counter, depth: usize) ParseError!void {
    if (depth > counter.limits.max_depth or counter.nodes == counter.limits.max_nodes) return error.LimitExceeded;
    counter.nodes += 1;
    switch (value.*) {
        .string, .number_string => |text| if (text.len > counter.limits.max_string_bytes) return error.LimitExceeded,
        .array => |items| for (items.items) |*item| try inspect(item, counter, depth + 1),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.*.len > counter.limits.max_string_bytes) return error.LimitExceeded;
                try inspect(entry.value_ptr, counter, depth + 1);
            }
        },
        else => {},
    }
}

/// Caller owns the returned serialized byte slice and releases it with the
/// same allocator. Serialization never retains the supplied borrowed view.
pub fn serialize(allocator: std.mem.Allocator, view: JsonValueView) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(view.value.*, .{}, &output.writer().interface);
    return output.toOwnedSlice();
}

pub const SchemaLimits = struct { max_depth: usize = 64, max_nodes: usize = 10_000, max_string_bytes: usize = 64 * 1024 };
pub const CompileError = error{ InvalidSchema, LimitsExceeded, OutOfMemory };
pub const SchemaType = enum { null, boolean, integer, number, string, array, object };

pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    root_node: *Node,
    pub fn deinit(self: *Schema) void {
        self.arena.deinit();
    }
    pub fn validate(self: *const Schema, allocator: std.mem.Allocator, value: JsonValueView) !?ValidationFailure {
        var path = std.ArrayList(u8).init(allocator);
        defer path.deinit();
        return validateNode(self.root_node, allocator, value.value, &path, 0);
    }
};
const Node = struct {
    types: []const SchemaType = &.{},
    required: std.StringHashMapUnmanaged(void) = .empty,
    properties: std.StringHashMapUnmanaged(*Node) = .empty,
    items: ?*Node = null,
    enums: []const std.json.Value = &.{},
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    additional_properties: bool = true,
};
pub const ValidationFailure = struct {
    category: errors.ErrorCategory = .invalid_argument,
    path: []u8,
    /// Allocator-owned path. Call `deinit` exactly once with its creating allocator.
    pub fn deinit(self: *ValidationFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.path = &.{};
    }
};

pub fn compile(allocator: std.mem.Allocator, definition: JsonValueView, limits: SchemaLimits) CompileError!Schema {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var counter = CompileCounter{ .limits = limits };
    const root = try compileNode(arena.allocator(), definition.value, &counter, 0);
    return .{ .arena = arena, .root_node = root };
}
const CompileCounter = struct { limits: SchemaLimits, nodes: usize = 0 };
fn compileNode(allocator: std.mem.Allocator, value: *const std.json.Value, counter: *CompileCounter, depth: usize) CompileError!*Node {
    if (depth > counter.limits.max_depth or counter.nodes == counter.limits.max_nodes) return error.LimitsExceeded;
    if (value.* != .object) return error.InvalidSchema;
    counter.nodes += 1;
    const node = try allocator.create(Node);
    node.* = .{};
    const object = value.object;
    if (object.get("type")) |kind| node.types = try compileTypes(allocator, kind);
    if (object.get("required")) |required| try compileRequired(allocator, &node.required, required, counter);
    if (object.get("properties")) |properties| try compileProperties(allocator, &node.properties, properties, counter, depth);
    if (object.get("items")) |items| node.items = try compileNode(allocator, &items, counter, depth + 1);
    if (object.get("enum")) |values| node.enums = try cloneEnum(allocator, values, counter, depth);
    if (object.get("minimum")) |number| node.minimum = numberAsFloat(number) orelse return error.InvalidSchema;
    if (object.get("maximum")) |number| node.maximum = numberAsFloat(number) orelse return error.InvalidSchema;
    if (object.get("minLength")) |number| node.min_length = nonnegative(number) orelse return error.InvalidSchema;
    if (object.get("maxLength")) |number| node.max_length = nonnegative(number) orelse return error.InvalidSchema;
    if (object.get("additionalProperties")) |allowed| node.additional_properties = if (allowed == .bool) allowed.bool else return error.InvalidSchema;
    return node;
}
fn compileTypes(allocator: std.mem.Allocator, value: *const std.json.Value) CompileError![]const SchemaType {
    if (value.* == .string) return &.{try parseType(value.string)};
    if (value.* != .array or value.array.items.len == 0) return error.InvalidSchema;
    const types = try allocator.alloc(SchemaType, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidSchema;
        types[index] = try parseType(item.string);
    }
    return types;
}
fn parseType(text: []const u8) CompileError!SchemaType {
    inline for (@typeInfo(SchemaType).@"enum".fields) |field| if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    return error.InvalidSchema;
}
fn compileRequired(allocator: std.mem.Allocator, out: *std.StringHashMapUnmanaged(void), value: *const std.json.Value, counter: *CompileCounter) CompileError!void {
    if (value.* != .array) return error.InvalidSchema;
    for (value.array.items) |item| {
        if (item != .string or item.string.len > counter.limits.max_string_bytes) return error.InvalidSchema;
        try out.put(allocator, item.string, {});
    }
}
fn compileProperties(allocator: std.mem.Allocator, out: *std.StringHashMapUnmanaged(*Node), value: *const std.json.Value, counter: *CompileCounter, depth: usize) CompileError!void {
    if (value.* != .object) return error.InvalidSchema;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len > counter.limits.max_string_bytes) return error.LimitsExceeded;
        try out.put(allocator, entry.key_ptr.*, try compileNode(allocator, entry.value_ptr, counter, depth + 1));
    }
}
fn cloneEnum(allocator: std.mem.Allocator, value: *const std.json.Value, counter: *CompileCounter, depth: usize) CompileError![]const std.json.Value {
    if (value.* != .array) return error.InvalidSchema;
    const result = try allocator.alloc(std.json.Value, value.array.items.len);
    for (value.array.items, 0..) |*item, index| result[index] = try cloneValue(allocator, item, counter, depth + 1);
    return result;
}
fn cloneValue(allocator: std.mem.Allocator, value: *const std.json.Value, counter: *CompileCounter, depth: usize) CompileError!std.json.Value {
    if (depth > counter.limits.max_depth or counter.nodes == counter.limits.max_nodes) return error.LimitsExceeded;
    counter.nodes += 1;
    return switch (value.*) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        .array => |items| blk: {
            var list = std.json.Array.init(allocator);
            for (items.items) |*item| try list.append(try cloneValue(allocator, item, counter, depth + 1));
            break :blk .{ .array = list };
        },
        .object => return error.InvalidSchema,
        else => value.*,
    };
}
fn numberAsFloat(value: *const std.json.Value) ?f64 {
    return switch (value.*) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => null,
    };
}
fn nonnegative(value: *const std.json.Value) ?usize {
    const number = value.integer;
    return if (value.* == .integer and number >= 0) @intCast(number) else null;
}

fn validateNode(node: *const Node, allocator: std.mem.Allocator, value: *const std.json.Value, path: *std.ArrayList(u8), depth: usize) !?ValidationFailure {
    if (depth > 256) return makeFailure(allocator, path);
    if (node.types.len > 0) {
        var found = false;
        for (node.types) |kind| {
            if (matches(kind, value)) found = true;
        }
        if (!found) return makeFailure(allocator, path);
    }
    if (node.enums.len > 0) {
        var found = false;
        for (node.enums) |item| {
            if (equalValues(&item, value)) found = true;
        }
        if (!found) return makeFailure(allocator, path);
    }
    if (numberAsFloat(value)) |number| {
        if (node.minimum) |minimum| if (number < minimum) return makeFailure(allocator, path);
        if (node.maximum) |maximum| if (number > maximum) return makeFailure(allocator, path);
    }
    if (value.* == .string) {
        const length = std.unicode.utf8CountCodepoints(value.string) catch return makeFailure(allocator, path);
        if (node.min_length) |min| if (length < min) return makeFailure(allocator, path);
        if (node.max_length) |max| if (length > max) return makeFailure(allocator, path);
    }
    if (value.* == .array) {
        if (node.items) |items| {
            for (value.array.items, 0..) |*item, index| {
                const saved = path.items.len;
                defer path.shrinkRetainingCapacity(saved);
                try appendIndex(path, index);
                if (try validateNode(items, allocator, item, path, depth + 1)) |failure| return failure;
            }
        }
    }
    if (value.* == .object) {
        var required = node.required.iterator();
        while (required.next()) |entry| if (!value.object.contains(entry.key_ptr.*)) {
            const saved = path.items.len;
            defer path.shrinkRetainingCapacity(saved);
            try appendKey(path, entry.key_ptr.*);
            return makeFailure(allocator, path);
        };
        var fields = value.object.iterator();
        while (fields.next()) |entry| {
            const child = node.properties.get(entry.key_ptr.*);
            if (child == null and !node.additional_properties) {
                const saved = path.items.len;
                defer path.shrinkRetainingCapacity(saved);
                try appendKey(path, entry.key_ptr.*);
                return makeFailure(allocator, path);
            }
            if (child) |schema| {
                const saved = path.items.len;
                defer path.shrinkRetainingCapacity(saved);
                try appendKey(path, entry.key_ptr.*);
                if (try validateNode(schema, allocator, entry.value_ptr, path, depth + 1)) |failure| return failure;
            }
        }
    }
    return null;
}
fn matches(kind: SchemaType, value: *const std.json.Value) bool {
    return switch (kind) {
        .null => value.* == .null,
        .boolean => value.* == .bool,
        .integer => value.* == .integer,
        .number => value.* == .integer or value.* == .float,
        .string => value.* == .string,
        .array => value.* == .array,
        .object => value.* == .object,
    };
}
fn equalValues(a: *const std.json.Value, b: *const std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a.*) != @as(std.meta.Tag(std.json.Value), b.*)) return false;
    return switch (a.*) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => if (a.array.items.len != b.array.items.len) false else for (a.array.items, b.array.items) |*left, *right| if (!equalValues(left, right)) return false else true,
        .object => false,
    };
}
fn makeFailure(allocator: std.mem.Allocator, path: *const std.ArrayList(u8)) !ValidationFailure {
    return .{ .path = try allocator.dupe(u8, if (path.items.len == 0) "$" else path.items) };
}
fn appendKey(path: *std.ArrayList(u8), key: []const u8) !void {
    try path.append('.');
    try path.appendSlice(key);
}
fn appendIndex(path: *std.ArrayList(u8), index: usize) !void {
    try path.print("[{d}]", .{index});
}

test "standard codec views, ownership, limits, and duplicate keys" {
    var document = try stdCodec().parse(std.testing.allocator, "{\"text\":\"\\u4e16\\u754c\",\"n\":-1,\"a\":[true]}", .{});
    defer document.deinit();
    try std.testing.expectEqualStrings("\xE4\xB8\x96\xE7\x95\x8C", document.root().objectGet("text").?.string().?);
    try std.testing.expectEqual(@as(?i64, -1), document.root().objectGet("n").?.signedInteger());
    try std.testing.expect(document.root().objectGet("a").?.arrayAt(0).?.boolean().?);
    try std.testing.expectError(error.InvalidJson, stdCodec().parse(std.testing.allocator, "{\"x\":1,\"x\":2}", .{}));
    try std.testing.expectError(error.LimitExceeded, stdCodec().parse(std.testing.allocator, "[[]]", .{ .max_depth = 1 }));
}
test "schema supported keywords and paths" {
    var definition = try stdCodec().parse(std.testing.allocator, "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":3},\"scores\":{\"type\":\"array\",\"items\":{\"type\":\"number\",\"minimum\":0}}},\"additionalProperties\":false}", .{});
    defer definition.deinit();
    var schema = try compile(std.testing.allocator, definition.root(), .{});
    defer schema.deinit();
    var input = try stdCodec().parse(std.testing.allocator, "{\"name\":\"ok\",\"scores\":[1]}", .{});
    defer input.deinit();
    var failure = (try schema.validate(std.testing.allocator, input.root())).?;
    defer failure.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("$.name", failure.path);
}
test "schema enum, ranges, unknown properties, and compilation failures" {
    var definition = try stdCodec().parse(std.testing.allocator, "{\"type\":\"object\",\"properties\":{\"v\":{\"enum\":[1,2],\"maximum\":2}},\"additionalProperties\":false}", .{});
    defer definition.deinit();
    var schema = try compile(std.testing.allocator, definition.root(), .{});
    defer schema.deinit();
    var input = try stdCodec().parse(std.testing.allocator, "{\"other\":true}", .{});
    defer input.deinit();
    var failure = (try schema.validate(std.testing.allocator, input.root())).?;
    defer failure.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("$.other", failure.path);
    var invalid = try stdCodec().parse(std.testing.allocator, "{\"type\":\"not-a-type\"}", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidSchema, compile(std.testing.allocator, invalid.root(), .{}));
}

test "schema type lists, unicode length, allocation failure, and depth limits" {
    var definition = try stdCodec().parse(std.testing.allocator, "{\"type\":[\"null\",\"boolean\",\"integer\",\"string\"],\"maxLength\":1}", .{});
    defer definition.deinit();
    var schema = try compile(std.testing.allocator, definition.root(), .{});
    defer schema.deinit();
    var valid = try stdCodec().parse(std.testing.allocator, "\"\\u4e16\"", .{});
    defer valid.deinit();
    try std.testing.expect((try schema.validate(std.testing.allocator, valid.root())) == null);
    var too_long = try stdCodec().parse(std.testing.allocator, "\"ab\"", .{});
    defer too_long.deinit();
    var length_failure = (try schema.validate(std.testing.allocator, too_long.root())).?;
    defer length_failure.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("$", length_failure.path);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, compile(failing.allocator(), definition.root(), .{}));
    var nested = try stdCodec().parse(std.testing.allocator, "{\"items\":{\"items\":{\"type\":\"string\"}}}", .{});
    defer nested.deinit();
    try std.testing.expectError(error.LimitsExceeded, compile(std.testing.allocator, nested.root(), .{ .max_depth = 1 }));
}
