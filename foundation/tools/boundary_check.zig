const std = @import("std");

const Vendor = struct { name: []const u8, adapter: []const u8, markers: []const []const u8 };
const vendors = [_]Vendor{
    .{ .name = "curl", .adapter = "curl", .markers = &.{ "curl/curl.h", "curl_" } },
    .{ .name = "libuv", .adapter = "libuv", .markers = &.{ "uv.h", "uv_" } },
    .{ .name = "yyjson", .adapter = "yyjson", .markers = &.{ "yyjson.h", "yyjson_" } },
    .{ .name = "sqlite", .adapter = "sqlite", .markers = &.{ "sqlite3.h", "sqlite3_" } },
    .{ .name = "zstd", .adapter = "zstd", .markers = &.{ "zstd.h", "ZSTD_" } },
    .{ .name = "lz4", .adapter = "lz4", .markers = &.{ "lz4.h", "LZ4_" } },
    .{ .name = "blake3", .adapter = "blake3", .markers = &.{ "blake3.h", "blake3_" } },
    .{ .name = "tracy", .adapter = "tracy", .markers = &.{ "Tracy.hpp", "TracyC.h", "Tracy" } },
    .{ .name = "mimalloc", .adapter = "mimalloc", .markers = &.{ "mimalloc.h", "mi_" } },
    .{ .name = "mbedtls", .adapter = "mbedtls", .markers = &.{ "mbedtls/", "mbedtls_" } },
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return usage();
    var found_path = false;
    while (args.next()) |path| {
        found_path = true;
        try scanPath(init.io, init.gpa, path);
    }
    if (!found_path) return usage();
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: boundary_check <source-path>...\n", .{});
    return error.InvalidArguments;
}

fn scanPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isSourceFile(entry.path)) continue;
        const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
        defer allocator.free(full_path);
        try scanFile(io, allocator, full_path);
    }
}

fn isSourceFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".h") or std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".cc") or std.mem.endsWith(u8, path, ".cpp");
}

fn scanFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    for (vendors) |vendor| {
        if (isAdapterPath(path, vendor.adapter)) continue;
        for (vendor.markers) |marker| {
            if (std.mem.indexOf(u8, bytes, marker) != null) return forbidden(path, vendor.name, marker);
        }
    }
}

fn isAdapterPath(path: []const u8, adapter: []const u8) bool {
    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (!std.mem.eql(u8, part, "adapters")) continue;
        const name = parts.next() orelse return false;
        return std.mem.eql(u8, name, adapter);
    }
    return false;
}

fn forbidden(path: []const u8, vendor: []const u8, marker: []const u8) error{ForbiddenVendorImport} {
    std.debug.print("forbidden {s} vendor import in {s}: {s}; use adapters/{s}/\n", .{ vendor, path, marker, vendor });
    return error.ForbiddenVendorImport;
}

test "adapter fixture passes boundary check" {
    try scanPath(std.Io.Threaded.global_single_threaded.io(), std.testing.allocator, "tests/fixtures/boundary/allowed");
}

test "forbidden vendor import is detected" {
    try std.testing.expectError(error.ForbiddenVendorImport, scanPath(std.Io.Threaded.global_single_threaded.io(), std.testing.allocator, "tests/fixtures/boundary"));
}
