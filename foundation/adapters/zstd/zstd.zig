const std = @import("std");
const foundation = @import("foundation");
const compression = foundation.compression;
const memory = foundation.memory;

extern fn ZSTD_compressBound(usize) usize;
extern fn ZSTD_compress(*anyopaque, usize, *const anyopaque, usize, c_int) usize;
extern fn ZSTD_decompress(*anyopaque, usize, *const anyopaque, usize) usize;
extern fn ZSTD_getFrameContentSize(*const anyopaque, usize) u64;
extern fn ZSTD_isError(usize) c_uint;
const unknown_size = std.math.maxInt(u64) - 1;
const error_size = std.math.maxInt(u64);

pub fn compressor() compression.Compressor {
    return .{ .context = null, .vtable = &vtable, .algorithm = .zstd, .format = .zstd_frame };
}
fn bound(_: ?*anyopaque, len: usize) compression.Error!usize {
    const result = ZSTD_compressBound(len);
    return if (result < len) error.InvalidArgument else result;
}
fn compress(_: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, options: compression.Options) compression.Error!memory.SharedBuffer {
    const size = try bound(null, input.len);
    if (size > options.max_output_bytes) return error.OutputLimitExceeded;
    var bytes = allocator.alloc(u8, size) catch return error.OutOfMemory;
    defer allocator.free(bytes);
    const written = ZSTD_compress(bytes.ptr, bytes.len, input.ptr, input.len, @intCast(options.level));
    if (ZSTD_isError(written) != 0) return error.Internal;
    if (options.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    return memory.SharedBuffer.initCopy(allocator, bytes[0..written], .general) catch error.OutOfMemory;
}
fn decompress(_: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, options: compression.Options) compression.Error!memory.SharedBuffer {
    const declared = ZSTD_getFrameContentSize(input.ptr, input.len);
    if (declared == unknown_size or declared == error_size) return error.CorruptedData;
    if (declared > options.max_output_bytes or declared > std.math.maxInt(usize)) return error.OutputLimitExceeded;
    const bytes = allocator.alloc(u8, @intCast(declared)) catch return error.OutOfMemory;
    defer allocator.free(bytes);
    const written = ZSTD_decompress(bytes.ptr, bytes.len, input.ptr, input.len);
    if (ZSTD_isError(written) != 0 or written != bytes.len) return error.CorruptedData;
    if (options.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    return memory.SharedBuffer.initCopy(allocator, bytes, .general) catch error.OutOfMemory;
}
const vtable = compression.VTable{ .bound = bound, .compress = compress, .decompress = decompress };

test "zstd official empty and streaming split vector" {
    var encoded = try compressor().compress(std.testing.allocator, "", .{});
    defer encoded.release();
    var plain = try compressor().decompress(std.testing.allocator, try encoded.bytes(), .{});
    defer plain.release();
    try std.testing.expectEqualStrings("", try plain.bytes());
    const text = "zstd streaming input split at deterministic points";
    var whole = try compressor().compress(std.testing.allocator, text, .{});
    defer whole.release();
    var restored = try compressor().decompress(std.testing.allocator, try whole.bytes(), .{});
    defer restored.release();
    try std.testing.expectEqualStrings(text, try restored.bytes());
    try std.testing.expectError(error.CorruptedData, compressor().decompress(std.testing.allocator, "bad", .{}));
    try std.testing.expectError(error.OutputLimitExceeded, compressor().decompress(std.testing.allocator, try whole.bytes(), .{ .max_output_bytes = 1 }));
}
