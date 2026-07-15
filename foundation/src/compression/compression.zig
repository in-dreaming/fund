//! Compression facade. Input slices are borrowed; returned SharedBuffers are owned.
const std = @import("std");
const memory = @import("../memory/shared_buffer.zig");
const cancellation = @import("../async/cancellation.zig");

pub const Algorithm = enum { zstd, lz4, passthrough };
pub const Format = enum { zstd_frame, lz4_block, raw };
pub const ChecksumPolicy = enum { default, required, disabled };
pub const Error = error{ InvalidArgument, Cancelled, OutputLimitExceeded, CorruptedData, Unsupported, OutOfMemory, Internal };

/// Options are value types; dictionary bytes are borrowed for the duration of a call.
pub const Options = struct {
    level: i32 = 0,
    dictionary: ?[]const u8 = null,
    checksum: ChecksumPolicy = .default,
    max_output_bytes: usize = std.math.maxInt(usize),
    cancellation: ?*const cancellation.Token = null,
};

pub const VTable = struct {
    bound: *const fn (?*anyopaque, usize) Error!usize,
    compress: *const fn (?*anyopaque, std.mem.Allocator, []const u8, Options) Error!memory.SharedBuffer,
    decompress: *const fn (?*anyopaque, std.mem.Allocator, []const u8, Options) Error!memory.SharedBuffer,
};

/// Borrowed compressor facade. The backend must outlive this value. Calls are synchronous;
/// a cancellation token is checked before allocation and must be checked by backends at work checkpoints.
pub const Compressor = struct {
    context: ?*anyopaque,
    vtable: *const VTable,
    algorithm: Algorithm,
    format: Format,
    pub fn compressBound(self: Compressor, input_len: usize) Error!usize {
        return self.vtable.bound(self.context, input_len);
    }
    pub fn compress(self: Compressor, allocator: std.mem.Allocator, input: []const u8, options: Options) Error!memory.SharedBuffer {
        if (options.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        return self.vtable.compress(self.context, allocator, input, options);
    }
    pub fn decompress(self: Compressor, allocator: std.mem.Allocator, input: []const u8, options: Options) Error!memory.SharedBuffer {
        if (options.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        return self.vtable.decompress(self.context, allocator, input, options);
    }
};

/// Deterministic conformance-only backend. It is raw copying, never compression.
pub fn passThrough() Compressor {
    return .{ .context = null, .vtable = &pass_vtable, .algorithm = .passthrough, .format = .raw };
}
fn passBound(_: ?*anyopaque, len: usize) Error!usize {
    return len;
}
fn copy(_: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, options: Options) Error!memory.SharedBuffer {
    if (input.len > options.max_output_bytes) return error.OutputLimitExceeded;
    return memory.SharedBuffer.initCopy(allocator, input, .general) catch error.OutOfMemory;
}
const pass_vtable = VTable{ .bound = passBound, .compress = copy, .decompress = copy };

test "pass-through has bounded ownership and cancellation" {
    var output = try passThrough().compress(std.testing.allocator, "abc", .{ .max_output_bytes = 3 });
    defer output.release();
    try std.testing.expectEqualStrings("abc", try output.bytes());
    try std.testing.expectError(error.OutputLimitExceeded, passThrough().decompress(std.testing.allocator, "abcd", .{ .max_output_bytes = 3 }));
    var source = try cancellation.CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    _ = source.cancel(.requested);
    try std.testing.expectError(error.Cancelled, passThrough().compress(std.testing.allocator, "", .{ .cancellation = &token }));
}
