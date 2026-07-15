const std = @import("std");

const required_fields = [_][]const u8{ "name", "version", "purpose", "platforms", "linkage", "source_modifications", "security_update_policy", "replacement_removal_path", "replacement_cost", "owner" };

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return usage();
    const path = args.next() orelse return usage();
    if (args.next() != null) return usage();
    try validatePath(init.io, init.gpa, path);
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: dependency_check <manifest-file-or-directory>\n", .{});
    return error.InvalidArguments;
}

fn validatePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    if (stat.kind == .directory) {
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            {
                const child = try std.fs.path.join(allocator, &.{ path, entry.name });
                defer allocator.free(child);
                try validateManifest(io, allocator, child);
            }
        }
        return;
    }
    try validateManifest(io, allocator, path);
}

fn validateManifest(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return invalid(path, "root must be an object");
    const object = parsed.value.object;
    inline for (required_fields) |field| {
        const value = object.get(field) orelse return invalid(path, "missing required field");
        if (!hasValue(value)) return invalid(path, "required field is empty");
    }
    const source = object.get("source") orelse return invalid(path, "missing source");
    const license = object.get("license") orelse return invalid(path, "missing license");
    if (source != .object or license != .object) return invalid(path, "source and license must be objects");
    const ref = source.object.get("ref") orelse return invalid(path, "missing source.ref");
    if (ref != .string or !isPinned(ref.string)) return invalid(path, "source.ref must be an immutable hash");
    const license_file = license.object.get("file") orelse return invalid(path, "missing license.file");
    if (license_file != .string or license_file.string.len == 0) return invalid(path, "missing license.file");
    const license_path = try std.fs.path.join(allocator, &.{ "third_party", license_file.string });
    defer allocator.free(license_path);
    cwd.access(io, license_path, .{}) catch return invalid(path, "referenced license file does not exist");
    const linkage = object.get("linkage").?;
    if (linkage != .string or (!std.mem.eql(u8, linkage.string, "static") and !std.mem.eql(u8, linkage.string, "dynamic") and !std.mem.eql(u8, linkage.string, "none"))) return invalid(path, "invalid linkage");
    const patches = object.get("patches") orelse return invalid(path, "missing patches");
    if (patches != .array) return invalid(path, "patches must be an array");
    for (patches.array.items) |patch| {
        if (patch != .string or patch.string.len == 0) return invalid(path, "patch must be a non-empty path");
        const patch_path = try std.fs.path.join(allocator, &.{ "third_party/patches", patch.string });
        defer allocator.free(patch_path);
        cwd.access(io, patch_path, .{}) catch return invalid(path, "referenced patch does not exist");
    }
}

fn hasValue(value: std.json.Value) bool {
    return switch (value) {
        .string => |text| text.len != 0,
        .array => |items| items.items.len != 0,
        .bool, .integer, .float => true,
        else => false,
    };
}

fn isPinned(ref: []const u8) bool {
    if (ref.len < 16) return false;
    for (ref) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn invalid(path: []const u8, reason: []const u8) error{InvalidManifest} {
    std.debug.print("invalid manifest {s}: {s}\n", .{ path, reason });
    return error.InvalidManifest;
}

test "invalid manifest fixture is rejected" {
    try std.testing.expectError(error.InvalidManifest, validatePath(std.Io.Threaded.global_single_threaded.io(), std.testing.allocator, "tests/fixtures/invalid-manifest.json"));
}
