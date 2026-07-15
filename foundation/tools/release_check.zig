const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.InvalidArguments;
    const manifests_path = args.next() orelse return error.InvalidArguments;
    const notices_path = args.next() orelse return error.InvalidArguments;
    if (args.next() != null) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    const notices = try cwd.readFileAlloc(init.io, notices_path, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(notices);
    var dir = try cwd.openDir(init.io, manifests_path, .{ .iterate = true });
    defer dir.close(init.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const manifest_path = try std.fs.path.join(init.gpa, &.{ manifests_path, entry.name });
        defer init.gpa.free(manifest_path);
        const bytes = try cwd.readFileAlloc(init.io, manifest_path, init.gpa, .limited(1024 * 1024));
        defer init.gpa.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, bytes, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const name = object.get("name") orelse return error.InvalidManifest;
        const license = object.get("license") orelse return error.InvalidManifest;
        if (name != .string or license != .object) return error.InvalidManifest;
        const license_file = license.object.get("file") orelse return error.InvalidManifest;
        if (license_file != .string) return error.InvalidManifest;
        const path = try std.fs.path.join(init.gpa, &.{ "third_party", license_file.string });
        defer init.gpa.free(path);
        cwd.access(init.io, path, .{}) catch return error.MissingLicense;
        if (std.mem.indexOf(u8, notices, name.string) == null) return error.MissingNotice;
        count += 1;
    }
    if (count == 0) return error.EmptyManifestSet;
}
