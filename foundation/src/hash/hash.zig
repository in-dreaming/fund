//! Versioned content hashing facade. Content hashes are identifiers, not authentication.
const std = @import("std");
const filesystem = @import("../filesystem/filesystem.zig");

pub const Algorithm = enum(u8) { blake3 = 1 };
pub const digest_length = 32;
pub const Error = error{ InvalidFormat, UnsupportedAlgorithm, UnsupportedVersion, Finalized, OutOfMemory, Io };

/// A fixed-width, value-semantic content identifier. Binary serialization is 34 bytes:
/// algorithm, version, then the 32 digest bytes. Text is lowercase `blake3-1:<hex>`.
pub const ContentHash = struct {
    algorithm: Algorithm = .blake3,
    version: u8 = 1,
    digest: [digest_length]u8,
    pub fn eql(a: ContentHash, b: ContentHash) bool {
        return a.algorithm == b.algorithm and a.version == b.version and std.mem.eql(u8, &a.digest, &b.digest);
    }
    pub fn serialize(self: ContentHash) [digest_length + 2]u8 {
        var out: [digest_length + 2]u8 = undefined;
        out[0] = @intFromEnum(self.algorithm);
        out[1] = self.version;
        @memcpy(out[2..], &self.digest);
        return out;
    }
    pub fn deserialize(bytes: []const u8) Error!ContentHash {
        if (bytes.len != digest_length + 2) return error.InvalidFormat;
        const algorithm = std.meta.intToEnum(Algorithm, bytes[0]) catch return error.UnsupportedAlgorithm;
        if (bytes[1] != 1) return error.UnsupportedVersion;
        var digest: [digest_length]u8 = undefined;
        @memcpy(&digest, bytes[2..]);
        return .{ .algorithm = algorithm, .version = bytes[1], .digest = digest };
    }
    pub fn format(self: ContentHash, out: []u8) Error![]u8 {
        if (self.algorithm != .blake3) return error.UnsupportedAlgorithm;
        if (self.version != 1) return error.UnsupportedVersion;
        if (out.len < 9 + digest_length * 2) return error.InvalidFormat;
        @memcpy(out[0..9], "blake3-1:");
        _ = std.fmt.bufPrint(out[9 .. 9 + digest_length * 2], "{x}", .{self.digest}) catch return error.InvalidFormat;
        return out[0 .. 9 + digest_length * 2];
    }
    pub fn parse(text: []const u8) Error!ContentHash {
        if (text.len != 9 + digest_length * 2 or !std.mem.eql(u8, text[0..9], "blake3-1:")) return error.InvalidFormat;
        var digest: [digest_length]u8 = undefined;
        for (0..digest_length) |i| {
            const hi = std.fmt.charToDigit(text[9 + i * 2], 16) catch return error.InvalidFormat;
            const lo = std.fmt.charToDigit(text[10 + i * 2], 16) catch return error.InvalidFormat;
            if (std.ascii.isUpper(text[9 + i * 2]) or std.ascii.isUpper(text[10 + i * 2])) return error.InvalidFormat;
            digest[i] = @intCast(hi * 16 + lo);
        }
        return .{ .digest = digest };
    }
};

pub const HasherVTable = struct {
    update: *const fn (?*anyopaque, []const u8) Error!void,
    finalize: *const fn (?*anyopaque) Error!ContentHash,
    deinit: *const fn (?*anyopaque) void,
};
/// Handle-owned streaming state. `update` borrows data; `finalize` may be called once.
pub const Hasher = struct {
    context: ?*anyopaque,
    vtable: *const HasherVTable,
    pub fn update(self: Hasher, bytes: []const u8) Error!void {
        return self.vtable.update(self.context, bytes);
    }
    pub fn finalize(self: Hasher) Error!ContentHash {
        return self.vtable.finalize(self.context);
    }
    pub fn deinit(self: *Hasher) void {
        if (self.context != null) self.vtable.deinit(self.context);
        self.context = null;
    }
};
pub const Factory = struct { context: ?*anyopaque, new_hasher: *const fn (?*anyopaque, std.mem.Allocator) Error!Hasher };
pub fn hashBytes(factory: Factory, allocator: std.mem.Allocator, bytes: []const u8) Error!ContentHash {
    var hasher = try factory.new_hasher(factory.context, allocator);
    defer hasher.deinit();
    try hasher.update(bytes);
    return hasher.finalize();
}
/// Reads through the filesystem facade, so its buffer is allocator-owned and bounded by `limit`.
pub fn hashFile(factory: Factory, allocator: std.mem.Allocator, fs: filesystem.FileSystem, path: []const u8, limit: usize) Error!ContentHash {
    var buffer = fs.readAll(allocator, path, limit) catch return error.Io;
    defer buffer.release();
    return hashBytes(factory, allocator, buffer.bytes() catch return error.Io);
}

test "content hash binary and canonical text parsing" {
    var hash = ContentHash{ .digest = [_]u8{0xab} ** digest_length };
    var text: [73]u8 = undefined;
    const formatted = try hash.format(&text);
    try std.testing.expectEqualStrings("blake3-1:abababababababababababababababababababababababababababababababab", formatted);
    try std.testing.expect(hash.eql(try ContentHash.parse(formatted)));
    try std.testing.expectError(error.InvalidFormat, ContentHash.parse("blake3-1:AB"));
    try std.testing.expectError(error.UnsupportedVersion, ContentHash.deserialize(&[_]u8{ 1, 2 } ++ [_]u8{0} ** digest_length));
}

test "file and memory hashing use the same facade input" {
    const Toy = struct {
        const State = struct { allocator: std.mem.Allocator, sum: u8 = 0 };
        fn create(_: ?*anyopaque, allocator: std.mem.Allocator) Error!Hasher {
            const value = allocator.create(State) catch return error.OutOfMemory;
            value.* = .{ .allocator = allocator };
            return .{ .context = value, .vtable = &vtable };
        }
        fn state(raw: ?*anyopaque) *State {
            return @ptrCast(@alignCast(raw.?));
        }
        fn update(raw: ?*anyopaque, bytes: []const u8) Error!void {
            for (bytes) |byte| state(raw).sum +%= byte;
        }
        fn finalize(raw: ?*anyopaque) Error!ContentHash {
            return .{ .digest = [_]u8{state(raw).sum} ** digest_length };
        }
        fn deinit(raw: ?*anyopaque) void {
            const value = state(raw);
            value.allocator.destroy(value);
        }
        const vtable = HasherVTable{ .update = update, .finalize = finalize, .deinit = deinit };
    };
    var fs = filesystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const bytes = "filesystem facade content";
    try fs.fileSystem().writeAll("content", bytes);
    const factory = Factory{ .context = null, .new_hasher = Toy.create };
    try std.testing.expect((try hashBytes(factory, std.testing.allocator, bytes)).eql(try hashFile(factory, std.testing.allocator, fs.fileSystem(), "content", bytes.len)));
}
