const std = @import("std");

pub const Utf8Policy = enum { reject, replace };
pub const Event = struct { event: []const u8, data: []const u8, id: []const u8, retry_ms: ?u64 };
pub const Limits = struct { max_field_bytes: usize = 64 * 1024, max_event_bytes: usize = 1024 * 1024 };
/// Incremental SSE parser. `feed` accepts arbitrary byte boundaries. Event
/// slices are borrowed until the next `feed`, `finish`, or `deinit` call.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    utf8: Utf8Policy,
    line: std.ArrayListUnmanaged(u8) = .empty,
    data: std.ArrayListUnmanaged(u8) = .empty,
    event_name: std.ArrayListUnmanaged(u8) = .empty,
    last_id: std.ArrayListUnmanaged(u8) = .empty,
    retry: ?u64 = null,
    saw_cr: bool = false,
    pub fn init(allocator: std.mem.Allocator, limits: Limits, utf8: Utf8Policy) Parser {
        return .{ .allocator = allocator, .limits = limits, .utf8 = utf8 };
    }
    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.event_name.deinit(self.allocator);
        self.last_id.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn feed(self: *Parser, bytes: []const u8, callback: *const fn (?*anyopaque, Event) void, userdata: ?*anyopaque) !void {
        for (bytes) |byte| {
            if (self.saw_cr) {
                self.saw_cr = false;
                if (byte == '\n') continue;
            }
            if (byte == '\r') {
                try self.finishLine(callback, userdata);
                self.saw_cr = true;
            } else if (byte == '\n') try self.finishLine(callback, userdata) else {
                if (self.line.items.len >= self.limits.max_field_bytes) return error.FieldTooLarge;
                try self.line.append(self.allocator, byte);
            }
        }
    }
    pub fn finish(self: *Parser, callback: *const fn (?*anyopaque, Event) void, userdata: ?*anyopaque) !void {
        if (self.line.items.len != 0) try self.finishLine(callback, userdata);
        try self.dispatch(callback, userdata);
    }
    fn finishLine(self: *Parser, callback: *const fn (?*anyopaque, Event) void, userdata: ?*anyopaque) !void {
        defer self.line.clearRetainingCapacity();
        if (self.line.items.len == 0) return self.dispatch(callback, userdata);
        const line = self.line.items;
        if (line[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |p| line[0..p] else line;
        var value = if (colon) |p| line[p + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];
        if (!std.unicode.utf8ValidateSlice(value)) {
            if (self.utf8 == .reject) return error.InvalidUtf8;
            return;
        }
        if (std.mem.eql(u8, field, "data")) {
            if (self.data.items.len + value.len + 1 > self.limits.max_event_bytes) return error.EventTooLarge;
            try self.data.appendSlice(self.allocator, value);
            try self.data.append(self.allocator, '\n');
        } else if (std.mem.eql(u8, field, "event")) {
            self.event_name.clearRetainingCapacity();
            try self.event_name.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                self.last_id.clearRetainingCapacity();
                try self.last_id.appendSlice(self.allocator, value);
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry = std.fmt.parseInt(u64, value, 10) catch self.retry;
        }
    }
    fn dispatch(self: *Parser, callback: *const fn (?*anyopaque, Event) void, userdata: ?*anyopaque) !void {
        if (self.data.items.len == 0) {
            self.event_name.clearRetainingCapacity();
            return;
        }
        self.data.items.len -= 1;
        callback(userdata, .{ .event = if (self.event_name.items.len == 0) "message" else self.event_name.items, .data = self.data.items, .id = self.last_id.items, .retry_ms = self.retry });
        self.data.clearRetainingCapacity();
        self.event_name.clearRetainingCapacity();
    }
};
test "SSE handles all CR LF boundaries and fields" {
    const Probe = struct {
        calls: usize = 0,
        data: [16]u8 = undefined,
        len: usize = 0,
        fn event(raw: ?*anyopaque, value: Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.len = value.data.len;
            @memcpy(self.data[0..value.data.len], value.data);
        }
    };
    const fixture = "id: 9\r\nevent: update\ndata: one\rdata: two\nretry: 12\n\n";
    for (0..fixture.len + 1) |split| {
        var parser = Parser.init(std.testing.allocator, .{}, .reject);
        defer parser.deinit();
        var probe = Probe{};
        try parser.feed(fixture[0..split], Probe.event, &probe);
        try parser.feed(fixture[split..], Probe.event, &probe);
        try parser.finish(Probe.event, &probe);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqualStrings("one\ntwo", probe.data[0..probe.len]);
    }
}
test "SSE rejects invalid utf8 and bounded events" {
    var parser = Parser.init(std.testing.allocator, .{ .max_event_bytes = 3 }, .reject);
    defer parser.deinit();
    const noop = struct {
        fn call(_: ?*anyopaque, _: Event) void {}
    }.call;
    try std.testing.expectError(error.InvalidUtf8, parser.feed("data: \xff\n", noop, null));
}
