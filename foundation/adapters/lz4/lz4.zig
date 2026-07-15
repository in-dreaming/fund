const std = @import("std");
const foundation = @import("foundation");
const compression = foundation.compression;
const memory = foundation.memory;
extern fn LZ4_compressBound(c_int) c_int;
extern fn LZ4_compress_default([*]const u8, [*]u8, c_int, c_int) c_int;
extern fn LZ4_decompress_safe([*]const u8, [*]u8, c_int, c_int) c_int;
pub fn compressor() compression.Compressor {
    return .{ .context = null, .vtable = &vtable, .algorithm = .lz4, .format = .lz4_block };
}
fn bound(_: ?*anyopaque, len: usize) compression.Error!usize {
    if (len > std.math.maxInt(c_int)) return error.InvalidArgument;
    const result = LZ4_compressBound(@intCast(len));
    return if (result <= 0) error.InvalidArgument else @intCast(result);
}
fn compress(_: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, options: compression.Options) compression.Error!memory.SharedBuffer {
    const size = try bound(null, input.len);
    if (size > options.max_output_bytes) return error.OutputLimitExceeded;
    var bytes = allocator.alloc(u8, size) catch return error.OutOfMemory;
    defer allocator.free(bytes);
    const written = LZ4_compress_default(input.ptr, bytes.ptr, @intCast(input.len), @intCast(bytes.len));
    if (written <= 0) return error.Internal;
    return memory.SharedBuffer.initCopy(allocator, bytes[0..@intCast(written)], .general) catch error.OutOfMemory;
}
/// LZ4 blocks have no embedded output size; callers must set `max_output_bytes` to the stored original size.
fn decompress(_: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, options: compression.Options) compression.Error!memory.SharedBuffer {
    if (options.max_output_bytes == std.math.maxInt(usize) or options.max_output_bytes > std.math.maxInt(c_int)) return error.InvalidArgument;
    var bytes = allocator.alloc(u8, options.max_output_bytes) catch return error.OutOfMemory;
    defer allocator.free(bytes);
    const written = LZ4_decompress_safe(input.ptr, bytes.ptr, @intCast(input.len), @intCast(bytes.len));
    if (written < 0) return error.CorruptedData;
    return memory.SharedBuffer.initCopy(allocator, bytes[0..@intCast(written)], .general) catch error.OutOfMemory;
}
const vtable = compression.VTable{ .bound = bound, .compress = compress, .decompress = decompress };
test "lz4 empty round trip and corruption" {
    var encoded = try compressor().compress(std.testing.allocator, "", .{});
    defer encoded.release();
    var plain = try compressor().decompress(std.testing.allocator, try encoded.bytes(), .{ .max_output_bytes = 0 });
    defer plain.release();
    try std.testing.expectEqualStrings("", try plain.bytes());
    try std.testing.expectError(error.CorruptedData, compressor().decompress(std.testing.allocator, "bad", .{ .max_output_bytes = 4 }));
}
