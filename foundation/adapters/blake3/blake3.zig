const std = @import("std");
const foundation = @import("foundation");
const hash = foundation.hash;
extern fn fd_blake3_new() ?*anyopaque;
extern fn fd_blake3_update(?*anyopaque, [*]const u8, usize) void;
extern fn fd_blake3_finalize(?*anyopaque, *[32]u8) void;
extern fn fd_blake3_delete(?*anyopaque) void;
const State = struct { allocator: std.mem.Allocator, raw: ?*anyopaque, finalized: bool = false };
pub fn factory() hash.Factory {
    return .{ .context = null, .new_hasher = newHasher };
}
fn newHasher(_: ?*anyopaque, allocator: std.mem.Allocator) hash.Error!hash.Hasher {
    const value = fd_blake3_new() orelse return error.OutOfMemory;
    const allocated = allocator.create(State) catch {
        fd_blake3_delete(value);
        return error.OutOfMemory;
    };
    allocated.* = .{ .allocator = allocator, .raw = value };
    return .{ .context = allocated, .vtable = &vtable };
}
fn state(raw: ?*anyopaque) *State {
    return @ptrCast(@alignCast(raw.?));
}
fn update(raw: ?*anyopaque, bytes: []const u8) hash.Error!void {
    const value = state(raw);
    if (value.finalized) return error.Finalized;
    fd_blake3_update(value.raw, bytes.ptr, bytes.len);
}
fn finalize(raw: ?*anyopaque) hash.Error!hash.ContentHash {
    const value = state(raw);
    if (value.finalized) return error.Finalized;
    value.finalized = true;
    var digest: [32]u8 = undefined;
    fd_blake3_finalize(value.raw, &digest);
    return .{ .digest = digest };
}
fn deinit(raw: ?*anyopaque) void {
    const value = state(raw);
    const allocator = value.allocator;
    fd_blake3_delete(value.raw);
    allocator.destroy(value);
}
const vtable = hash.HasherVTable{ .update = update, .finalize = finalize, .deinit = deinit };
test "blake3 official empty vector and split updates" {
    const expected = try hash.ContentHash.parse("blake3-1:af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");
    try std.testing.expect(expected.eql(try hash.hashBytes(factory(), std.testing.allocator, "")));
    var h = try factory().new_hasher(null, std.testing.allocator);
    defer h.deinit();
    try h.update("a");
    try h.update("bc");
    try std.testing.expect((try h.finalize()).eql(try hash.hashBytes(factory(), std.testing.allocator, "abc")));
}
