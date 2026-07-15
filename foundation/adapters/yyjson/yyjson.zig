const std = @import("std");
const json = @import("foundation").json;

pub const NativeDocument = opaque {};
pub const NativeValue = opaque {};
extern fn fd_yyjson_read(dat: [*]const u8, len: usize) callconv(.c) ?*NativeDocument;
extern fn fd_yyjson_doc_free(document: *NativeDocument) callconv(.c) void;
extern fn fd_yyjson_doc_get_root(document: *NativeDocument) callconv(.c) ?*NativeValue;

/// yyjson's native document is deliberately exposed only from this adapter.
/// The returned pointer is handle-owned and must be passed to `deinitNative`.
pub fn parseNative(bytes: []const u8) ?*NativeDocument {
    return fd_yyjson_read(bytes.ptr, bytes.len);
}

pub fn deinitNative(document: ?*NativeDocument) void {
    if (document) |value| fd_yyjson_doc_free(value);
}

/// The common facade first validates through yyjson, then materializes the
/// standard owned view representation. Native callers can retain yyjson's
/// zero-copy document and advanced queries through this adapter instead.
pub fn codec() json.JsonCodec {
    return .{ .context = null, .vtable = &vtable };
}
const vtable = json.JsonCodec.VTable{ .parse = parseCommon };
fn parseCommon(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8, limits: json.Limits) json.ParseError!json.JsonDocument {
    const native = parseNative(bytes) orelse return error.InvalidJson;
    defer deinitNative(native);
    return json.stdCodec().parse(allocator, bytes, limits);
}

test "yyjson adapter parses a native document" {
    const document = parseNative("{\"adapter\":true}") orelse return error.TestExpectedEqual;
    defer deinitNative(document);
    try std.testing.expect(fd_yyjson_doc_get_root(document) != null);
}

test "yyjson common codec yields the shared document view" {
    var document = try codec().parse(std.testing.allocator, "{\"value\":42}", .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(?u64, 42), document.root().objectGet("value").?.unsignedInteger());
}
