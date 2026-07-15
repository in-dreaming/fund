const std = @import("std");

pub const ErrorCategory = enum(u16) {
    invalid_argument = 1,
    invalid_state,
    not_found,
    permission_denied,
    cancelled,
    timeout,
    unavailable,
    resource_exhausted,
    io,
    network,
    protocol,
    corrupted_data,
    unsupported,
    internal,
};

/// C error codes 1..14 are permanently assigned to the enum values below;
/// 0 and values from 15 onward are reserved for future Foundation releases.
pub const SourceContext = struct { file: []const u8 = "", line: u32 = 0, operation: []const u8 = "", parent_operation: []const u8 = "" };
pub const ErrorInfo = struct {
    category: ErrorCategory,
    native_code: i64 = 0,
    message: []const u8 = "",
    context: SourceContext = .{},
    // `message` is borrowed; callers retain it for the lifetime of this value.
};
/// Allocator-owned error message. Call `deinit` exactly once.
pub const OwnedErrorInfo = struct {
    info: ErrorInfo,
    allocator: std.mem.Allocator,
    pub fn initCopy(allocator: std.mem.Allocator, info: ErrorInfo) !OwnedErrorInfo {
        var result = OwnedErrorInfo{ .info = info, .allocator = allocator };
        result.info.message = try allocator.dupe(u8, info.message);
        return result;
    }
    pub fn deinit(self: *OwnedErrorInfo) void {
        self.allocator.free(@constCast(self.info.message));
        self.info.message = "";
    }
};
pub fn toCCode(category: ErrorCategory) u32 {
    return @intFromEnum(category);
}
pub fn fromCCode(code: u32) ?ErrorCategory {
    return std.meta.intToEnum(ErrorCategory, @intCast(code)) catch null;
}
pub fn withContext(info: ErrorInfo, context: SourceContext) ErrorInfo {
    var result = info;
    result.context.parent_operation = info.context.operation;
    result.context = context;
    return result;
}
pub fn redact(message: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, message, "token") != null or std.mem.indexOf(u8, message, "password") != null) "[redacted]" else message;
}

test "categories round trip" {
    inline for (@typeInfo(ErrorCategory).@"enum".fields) |field| try std.testing.expectEqual(@as(?ErrorCategory, @enumFromInt(field.value)), fromCCode(field.value));
}
test "redaction and native preservation" {
    const info = withContext(.{ .category = .network, .native_code = -7, .message = redact("token=x") }, .{ .operation = "send" });
    try std.testing.expectEqual(@as(i64, -7), info.native_code);
    try std.testing.expectEqualStrings("[redacted]", info.message);
}
test "owned message and invalid C code" {
    var value = try OwnedErrorInfo.initCopy(std.testing.allocator, .{ .category = .io, .message = "safe" });
    defer value.deinit();
    try std.testing.expectEqualStrings("safe", value.info.message);
    try std.testing.expect(fromCCode(0) == null);
    try std.testing.expect(fromCCode(99) == null);
}
