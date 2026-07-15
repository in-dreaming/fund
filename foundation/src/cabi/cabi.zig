const std = @import("std");
const memory = @import("../memory/shared_buffer.zig");

pub const abi_version: u32 = 1;
pub const ErrorCode = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    invalid_state = 2,
    not_found = 3,
    permission_denied = 4,
    cancelled = 5,
    timeout = 6,
    unavailable = 7,
    resource_exhausted = 8,
    io = 9,
    network = 10,
    protocol = 11,
    corrupted_data = 12,
    unsupported = 13,
    internal = 14,
};

pub const StringView = extern struct { data: ?[*]const u8, length: usize };
pub const Buffer = extern struct {
    data: ?[*]u8,
    length: usize,
    release: ?*const fn (?*anyopaque, ?[*]u8, usize) callconv(.c) void,
    release_userdata: ?*anyopaque,
};
pub const Callback = *const fn (?*anyopaque) callconv(.c) void;
pub const Executor = extern struct {
    struct_size: u32,
    struct_version: u32,
    userdata: ?*anyopaque,
    schedule: ?*const fn (?*anyopaque, Callback, ?*anyopaque) callconv(.c) ErrorCode,
};
pub const PluginDescriptor = extern struct {
    struct_size: u32,
    struct_version: u32,
    abi_version_: u32,
    feature_bits: u64,
    build_id: StringView,
    start: ?*const fn (?*const anyopaque) callconv(.c) ErrorCode,
    stop: ?*const fn () callconv(.c) void,
};
pub const PluginGetDescriptor = *const fn () callconv(.c) ?*const PluginDescriptor;

const BufferBridge = struct {
    allocator: std.mem.Allocator,
    buffer: memory.SharedBuffer,
    fn release(context: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.buffer.release();
        self.allocator.destroy(self);
    }
};

/// Transfers the C buffer's release obligation into a SharedBuffer. The input
/// buffer is cleared only after allocation succeeds.
pub fn sharedBufferFromC(allocator: std.mem.Allocator, buffer: *Buffer, tag: memory.MemoryTag) !memory.SharedBuffer {
    _ = buffer.release orelse return error.InvalidArgument;
    const data = buffer.data orelse return error.InvalidArgument;
    const context = try allocator.create(CBufferBridge);
    context.* = .{ .allocator = allocator, .buffer = buffer.* };
    const result = memory.SharedBuffer.adopt(allocator, data[0..buffer.length], .mutable, tag, CBufferBridge.release, context, null, .{}) catch |err| {
        return err;
    };
    buffer.* = .{ .data = null, .length = 0, .release = null, .release_userdata = null };
    return result;
}
const CBufferBridge = struct {
    allocator: std.mem.Allocator,
    buffer: Buffer,
    fn release(context: ?*anyopaque, _: []u8) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        defer self.allocator.destroy(self);
        self.buffer.release.?(self.buffer.release_userdata, self.buffer.data, self.buffer.length);
    }
};
/// Returns a C-owned clone. `fd_buffer_release` releases the clone exactly once.
pub fn sharedBufferToC(allocator: std.mem.Allocator, buffer: memory.SharedBuffer) !Buffer {
    const bridge = try allocator.create(BufferBridge);
    errdefer allocator.destroy(bridge);
    bridge.* = .{ .allocator = allocator, .buffer = try buffer.clone() };
    errdefer bridge.buffer.release();
    const bytes = bridge.buffer.mutableBytes() catch |err| switch (err) {
        error.ReadOnly => blk: {
            const source = try bridge.buffer.bytes();
            const mutable_copy = try memory.SharedBuffer.initCopy(allocator, source, .c_abi);
            bridge.buffer.release();
            bridge.buffer = mutable_copy;
            break :blk try bridge.buffer.mutableBytes();
        },
        else => return err,
    };
    return .{ .data = bytes.ptr, .length = bytes.len, .release = BufferBridge.release, .release_userdata = bridge };
}
fn hasField(comptime T: type, supplied: u32, comptime field: []const u8) bool {
    return supplied >= @offsetOf(T, field) + @sizeOf(@FieldType(T, field));
}

pub export fn fd_abi_version() callconv(.c) u32 {
    return abi_version;
}
pub export fn fd_string_view_validate(value: StringView) callconv(.c) ErrorCode {
    return if (value.data == null and value.length != 0) .invalid_argument else .ok;
}
pub export fn fd_handle_validate(handle: u64) callconv(.c) ErrorCode {
    return if ((handle >> 32) == 0) .invalid_argument else .ok;
}
pub export fn fd_cancel_reason_validate(reason: u32) callconv(.c) ErrorCode {
    return if (reason >= 1 and reason <= 4) .ok else .invalid_argument;
}
pub export fn fd_operation_state_validate(state: u32) callconv(.c) ErrorCode {
    return if (state <= 3) .ok else .invalid_argument;
}
pub export fn fd_buffer_release(buffer: ?*Buffer) callconv(.c) ErrorCode {
    const value = buffer orelse return .invalid_argument;
    const release = value.release orelse return .invalid_state;
    if (value.data == null and value.length != 0) return .invalid_argument;
    const data = value.data;
    value.release = null;
    value.data = null;
    const length = value.length;
    value.length = 0;
    release(value.release_userdata, data, length);
    return .ok;
}
pub export fn fd_executor_schedule(executor: ?*const Executor, callback: ?Callback, userdata: ?*anyopaque) callconv(.c) ErrorCode {
    const value = executor orelse return .invalid_argument;
    const schedule = value.schedule orelse return .invalid_argument;
    if (callback == null or value.struct_version != 1 or !hasField(Executor, value.struct_size, "schedule")) return .invalid_argument;
    return schedule(value.userdata, callback.?, userdata);
}
pub export fn fd_plugin_descriptor_validate(descriptor: ?*const PluginDescriptor, required_features: u64) callconv(.c) ErrorCode {
    const value = descriptor orelse return .invalid_argument;
    if (value.struct_version != 1 or value.abi_version_ != abi_version or !hasField(PluginDescriptor, value.struct_size, "stop")) return .unsupported;
    if ((value.feature_bits & required_features) != required_features) return .unsupported;
    if (fd_string_view_validate(value.build_id) != .ok or value.start == null or value.stop == null) return .invalid_argument;
    return .ok;
}

test "C ABI validates extensible input and clears buffer ownership" {
    try std.testing.expectEqual(ErrorCode.invalid_argument, fd_string_view_validate(.{ .data = null, .length = 1 }));
    try std.testing.expectEqual(ErrorCode.invalid_argument, fd_handle_validate(3));
    const Probe = struct {
        calls: usize = 0,
        fn release(userdata: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) void {
            @as(*@This(), @ptrCast(@alignCast(userdata.?))).calls += 1;
        }
    };
    var probe = Probe{};
    var buffer = Buffer{ .data = null, .length = 0, .release = Probe.release, .release_userdata = &probe };
    try std.testing.expectEqual(ErrorCode.ok, fd_buffer_release(&buffer));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(ErrorCode.invalid_state, fd_buffer_release(&buffer));
}

test "extensible structs accept known prefixes and ignore future tails" {
    const Probe = struct {
        calls: usize = 0,
        fn call(context: ?*anyopaque) callconv(.c) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).calls += 1;
        }
        fn schedule(_: ?*anyopaque, callback: Callback, context: ?*anyopaque) callconv(.c) ErrorCode {
            callback(context);
            return .ok;
        }
    };
    var probe = Probe{};
    var executor = Executor{
        .struct_size = @offsetOf(Executor, "schedule") + @sizeOf(@FieldType(Executor, "schedule")),
        .struct_version = 1,
        .userdata = null,
        .schedule = Probe.schedule,
    };
    try std.testing.expectEqual(ErrorCode.ok, fd_executor_schedule(&executor, Probe.call, &probe));
    executor.struct_size += 64; // Unknown future tail is ignored.
    try std.testing.expectEqual(ErrorCode.ok, fd_executor_schedule(&executor, Probe.call, &probe));
    executor.struct_version = 2;
    try std.testing.expectEqual(ErrorCode.invalid_argument, fd_executor_schedule(&executor, Probe.call, &probe));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}

test "C buffer conversion handles read-only storage and every allocation failure" {
    const Probe = struct {
        fn release(_: ?*anyopaque, bytes: []u8) void {
            std.testing.allocator.free(bytes);
        }
        fn convert(allocator: std.mem.Allocator, source: memory.SharedBuffer) !void {
            var output = try sharedBufferToC(allocator, source);
            try std.testing.expectEqualStrings("readonly", output.data.?[0..output.length]);
            try std.testing.expectEqual(ErrorCode.ok, fd_buffer_release(&output));
        }
    };
    const bytes = try std.testing.allocator.dupe(u8, "readonly");
    var source = try memory.SharedBuffer.adopt(std.testing.allocator, bytes, .read_only, .c_abi, Probe.release, null, null, .{});
    defer source.release();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.convert, .{source});
}
