//! Replaceable, root-relative filesystem facade. Paths are borrowed UTF-8
//! slash-separated relative paths; every operation normalizes and validates them.
const std = @import("std");
const memory = @import("../memory/shared_buffer.zig");
const cancellation = @import("../async/cancellation.zig");
const future = @import("../async/future.zig");
const executor = @import("../executor/executor.zig");

pub const Error = error{ InvalidPath, NotFound, AccessDenied, ReadOnly, AlreadyExists, NotEmpty, NoSpaceLeft, TooLarge, Cancelled, Unsupported, Io };
pub const MmapError = error{ Unsupported, AccessDenied, Io };
pub const Durability = enum { none, data };
pub const OpenMode = enum { read, write, read_write };
pub const FileType = enum { file, directory, other };
pub const Metadata = struct { kind: FileType, size: u64 };
pub const WatchEventKind = enum { created, modified, removed, renamed, overflow, rescan_required };
/// Reserved for Task 15. `path` is borrowed for the callback duration.
pub const WatchEvent = struct { kind: WatchEventKind, path: []const u8, old_path: ?[]const u8 = null };

/// Handle-owned synchronous file. `read` and `write` may complete partially;
/// callers that require complete transfer use the filesystem `readAll` and
/// `writeAll` helpers. `deinit` closes once and is otherwise idempotent.
pub const FileVTable = struct {
    read: *const fn (?*anyopaque, []u8) Error!usize,
    write: *const fn (?*anyopaque, []const u8) Error!usize,
    seek: *const fn (?*anyopaque, u64) Error!u64,
    close: *const fn (?*anyopaque) void,
};
pub const File = struct {
    context: ?*anyopaque,
    vtable: *const FileVTable,
    pub fn read(self: File, destination: []u8) Error!usize {
        return self.vtable.read(self.context, destination);
    }
    pub fn write(self: File, source: []const u8) Error!usize {
        return self.vtable.write(self.context, source);
    }
    pub fn seek(self: File, offset: u64) Error!u64 {
        return self.vtable.seek(self.context, offset);
    }
    pub fn deinit(self: *File) void {
        if (self.context) |raw| self.vtable.close(raw);
        self.context = null;
    }
};

/// A validated path owns no memory. `normalize` writes the canonical relative
/// form into caller-owned storage. Empty paths denote the configured root.
pub fn normalizePath(out: *std.ArrayList(u8), input: []const u8) Error![]const u8 {
    out.clearRetainingCapacity();
    if (input.len == 0) return out.items;
    if (input[0] == '/' or input[0] == '\\' or (input.len >= 2 and std.ascii.isAlphabetic(input[0]) and input[1] == ':')) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, input, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '\\') != null or std.mem.indexOfScalar(u8, part, 0) != null) return error.InvalidPath;
        if (out.items.len != 0) out.append('/') catch return error.Io;
        out.appendSlice(part) catch return error.Io;
    }
    return out.items;
}

pub const VTable = struct {
    read_all: *const fn (?*anyopaque, std.mem.Allocator, []const u8, usize) Error!memory.SharedBuffer,
    write_all: *const fn (?*anyopaque, []const u8, []const u8) Error!void,
    metadata: *const fn (?*anyopaque, []const u8) Error!Metadata,
    make_dir: *const fn (?*anyopaque, []const u8) Error!void,
    delete: *const fn (?*anyopaque, []const u8) Error!void,
    atomic_write: *const fn (?*anyopaque, []const u8, []const u8, Durability) Error!void,
    mmap: *const fn (?*anyopaque, []const u8) MmapError!memory.SharedBuffer,
};

/// Borrowed facade; its backend must outlive this value and all async reads.
pub const FileSystem = struct {
    context: ?*anyopaque,
    vtable: *const VTable,
    pub fn readAll(self: FileSystem, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error!memory.SharedBuffer {
        return self.vtable.read_all(self.context, allocator, path, limit);
    }
    pub fn writeAll(self: FileSystem, path: []const u8, bytes: []const u8) Error!void {
        return self.vtable.write_all(self.context, path, bytes);
    }
    pub fn metadata(self: FileSystem, path: []const u8) Error!Metadata {
        return self.vtable.metadata(self.context, path);
    }
    pub fn makeDir(self: FileSystem, path: []const u8) Error!void {
        return self.vtable.make_dir(self.context, path);
    }
    pub fn delete(self: FileSystem, path: []const u8) Error!void {
        return self.vtable.delete(self.context, path);
    }
    /// Replaces `path` using a temporary in the same directory. `data` flushes
    /// file contents before rename; directory metadata durability is OS-specific.
    pub fn atomicWrite(self: FileSystem, path: []const u8, bytes: []const u8, durability: Durability) Error!void {
        return self.vtable.atomic_write(self.context, path, bytes, durability);
    }
    pub fn mmap(self: FileSystem, path: []const u8) MmapError!memory.SharedBuffer {
        return self.vtable.mmap(self.context, path);
    }
};

pub const FaultHooks = struct {
    max_read: ?usize = null,
    max_write: ?usize = null,
    disk_full: bool = false,
    permission_denied: bool = false,
    disappear_before_read: bool = false,
};

/// Native filesystem rooted at an already-open directory. All paths are
/// normalized before use. Symlink traversal is rejected by policy only when
/// `reject_symlinks` is true; platforms without no-follow open support return
/// `Unsupported` for that policy rather than silently weakening it.
pub const NativeFileSystem = struct {
    allocator: std.mem.Allocator,
    root: std.fs.Dir,
    reject_symlinks: bool = false,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8, reject_symlinks: bool) !NativeFileSystem {
        return .{ .allocator = allocator, .root = try std.fs.cwd().openDir(root_path, .{}), .reject_symlinks = reject_symlinks };
    }
    pub fn deinit(self: *NativeFileSystem) void {
        self.root.close();
        self.* = undefined;
    }
    pub fn fileSystem(self: *NativeFileSystem) FileSystem {
        return .{ .context = self, .vtable = &vtable };
    }
    /// Opens a handle-owned native file beneath this filesystem root.
    pub fn open(self: *NativeFileSystem, path: []const u8, mode: OpenMode) Error!File {
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        const native_file = switch (mode) {
            .read => self.root.openFile(name, .{}) catch |err| return map(err),
            .write, .read_write => self.root.createFile(name, .{ .read = mode == .read_write }) catch |err| return map(err),
        };
        const state = self.allocator.create(NativeFile) catch {
            native_file.close();
            return error.Io;
        };
        state.* = .{ .allocator = self.allocator, .file = native_file };
        return .{ .context = state, .vtable = &NativeFile.vtable };
    }
    const NativeFile = struct {
        allocator: std.mem.Allocator,
        file: std.fs.File,
        fn fromRaw(raw: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(raw.?));
        }
        fn read(raw: ?*anyopaque, destination: []u8) Error!usize {
            return fromRaw(raw).file.read(destination) catch |err| return map(err);
        }
        fn write(raw: ?*anyopaque, source: []const u8) Error!usize {
            return fromRaw(raw).file.write(source) catch |err| return map(err);
        }
        fn seek(raw: ?*anyopaque, offset: u64) Error!u64 {
            return fromRaw(raw).file.seekTo(offset) catch |err| return map(err);
        }
        fn close(raw: ?*anyopaque) void {
            const self = fromRaw(raw);
            self.file.close();
            self.allocator.destroy(self);
        }
        const vtable = FileVTable{ .read = read, .write = write, .seek = seek, .close = close };
    };
    fn normalized(self: *NativeFileSystem, path: []const u8) Error![]u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();
        const result = try normalizePath(&list, path);
        if (result.len == 0) return error.InvalidPath;
        if (self.reject_symlinks) return error.Unsupported;
        return self.allocator.dupe(u8, result) catch error.Io;
    }
    fn map(err: anyerror) Error {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied => error.AccessDenied,
            error.DiskQuota, error.NoSpaceLeft => error.NoSpaceLeft,
            else => error.Io,
        };
    }
    fn readAll(raw: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error!memory.SharedBuffer {
        const self: *NativeFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        var file = self.root.openFile(name, .{}) catch |err| return map(err);
        defer file.close();
        const allocation_limit = if (limit == std.math.maxInt(usize)) limit else limit + 1;
        const bytes = file.readToEndAlloc(allocator, allocation_limit) catch |err| return map(err);
        defer allocator.free(bytes);
        if (bytes.len > limit) return error.TooLarge;
        return memory.SharedBuffer.initCopy(allocator, bytes, .io) catch error.Io;
    }
    fn writeAll(raw: ?*anyopaque, path: []const u8, bytes: []const u8) Error!void {
        const self: *NativeFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        var file = self.root.createFile(name, .{ .truncate = true }) catch |err| return map(err);
        defer file.close();
        file.writeAll(bytes) catch |err| return map(err);
    }
    fn metadata(raw: ?*anyopaque, path: []const u8) Error!Metadata {
        const self: *NativeFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        const stat = self.root.statFile(name) catch |err| return map(err);
        return .{ .kind = switch (stat.kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        }, .size = stat.size };
    }
    fn makeDir(raw: ?*anyopaque, path: []const u8) Error!void {
        const self: *NativeFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        self.root.makePath(name) catch |err| return map(err);
    }
    fn delete(raw: ?*anyopaque, path: []const u8) Error!void {
        const self: *NativeFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        self.root.deleteFile(name) catch |err| return map(err);
    }
    fn atomicWrite(raw: ?*anyopaque, path: []const u8, bytes: []const u8, durability: Durability) Error!void {
        const self: *NativeFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.normalized(path);
        defer self.allocator.free(name);
        const temporary = std.fmt.allocPrint(self.allocator, ".{s}.foundation-tmp", .{name}) catch return error.Io;
        defer self.allocator.free(temporary);
        var file = self.root.createFile(temporary, .{ .exclusive = true }) catch |err| return map(err);
        errdefer self.root.deleteFile(temporary) catch {};
        file.writeAll(bytes) catch |err| {
            file.close();
            return map(err);
        };
        if (durability == .data) file.sync() catch |err| {
            file.close();
            return map(err);
        };
        file.close();
        self.root.rename(temporary, name) catch |err| return map(err);
    }
    fn mmap(_: ?*anyopaque, _: []const u8) MmapError!memory.SharedBuffer {
        return error.Unsupported;
    }
    const vtable = VTable{ .read_all = readAll, .write_all = writeAll, .metadata = metadata, .make_dir = makeDir, .delete = delete, .atomic_write = atomicWrite, .mmap = mmap };
};

/// Prefixes all requests beneath a validated virtual directory. The wrapped
/// backend owns actual root/symlink policy; this wrapper prevents `..` and
/// absolute paths from escaping its virtual prefix.
pub const SandboxFileSystem = struct {
    allocator: std.mem.Allocator,
    inner: FileSystem,
    prefix: []u8,
    pub fn init(allocator: std.mem.Allocator, inner: FileSystem, prefix: []const u8) Error!SandboxFileSystem {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();
        const normalized = try normalizePath(&list, prefix);
        if (normalized.len == 0) return error.InvalidPath;
        return .{ .allocator = allocator, .inner = inner, .prefix = allocator.dupe(u8, normalized) catch return error.Io };
    }
    pub fn deinit(self: *SandboxFileSystem) void {
        self.allocator.free(self.prefix);
        self.* = undefined;
    }
    pub fn fileSystem(self: *SandboxFileSystem) FileSystem {
        return .{ .context = self, .vtable = &vtable };
    }
    fn joined(self: *SandboxFileSystem, path: []const u8) Error![]u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();
        const normalized = try normalizePath(&list, path);
        if (normalized.len == 0) return error.InvalidPath;
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.prefix, normalized }) catch error.Io;
    }
    fn readAll(raw: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error!memory.SharedBuffer {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.joined(path);
        defer self.allocator.free(name);
        return self.inner.readAll(allocator, name, limit);
    }
    fn writeAll(raw: ?*anyopaque, path: []const u8, bytes: []const u8) Error!void {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.joined(path);
        defer self.allocator.free(name);
        return self.inner.writeAll(name, bytes);
    }
    fn metadata(raw: ?*anyopaque, path: []const u8) Error!Metadata {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.joined(path);
        defer self.allocator.free(name);
        return self.inner.metadata(name);
    }
    fn makeDir(raw: ?*anyopaque, path: []const u8) Error!void {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.joined(path);
        defer self.allocator.free(name);
        return self.inner.makeDir(name);
    }
    fn delete(raw: ?*anyopaque, path: []const u8) Error!void {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.joined(path);
        defer self.allocator.free(name);
        return self.inner.delete(name);
    }
    fn atomicWrite(raw: ?*anyopaque, path: []const u8, bytes: []const u8, durability: Durability) Error!void {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.joined(path);
        defer self.allocator.free(name);
        return self.inner.atomicWrite(name, bytes, durability);
    }
    fn mmap(raw: ?*anyopaque, path: []const u8) MmapError!memory.SharedBuffer {
        const self: *SandboxFileSystem = @ptrCast(@alignCast(raw.?));
        const name = self.joined(path) catch return error.Io;
        defer self.allocator.free(name);
        return self.inner.mmap(name);
    }
    const vtable = VTable{ .read_all = readAll, .write_all = writeAll, .metadata = metadata, .make_dir = makeDir, .delete = delete, .atomic_write = atomicWrite, .mmap = mmap };
};

pub const MemoryFileSystem = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]u8) = .empty,
    faults: FaultHooks = .{},
    pub fn init(allocator: std.mem.Allocator) MemoryFileSystem {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MemoryFileSystem) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn fileSystem(self: *MemoryFileSystem) FileSystem {
        return .{ .context = self, .vtable = &vtable };
    }
    fn pathKey(self: *MemoryFileSystem, path: []const u8) Error![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const normalized = try normalizePath(&result, path);
        if (normalized.len == 0) return error.InvalidPath;
        return self.allocator.dupe(u8, normalized) catch error.Io;
    }
    fn readAll(raw: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error!memory.SharedBuffer {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(raw.?));
        if (self.faults.permission_denied) return error.AccessDenied;
        const name = try self.pathKey(path);
        defer self.allocator.free(name);
        if (self.faults.disappear_before_read) return error.NotFound;
        const bytes = self.files.get(name) orelse return error.NotFound;
        if (bytes.len > limit) return error.TooLarge;
        const amount = @min(bytes.len, self.faults.max_read orelse bytes.len);
        return memory.SharedBuffer.initCopy(allocator, bytes[0..amount], .io) catch error.Io;
    }
    fn writeAll(raw: ?*anyopaque, path: []const u8, bytes: []const u8) Error!void {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(raw.?));
        if (self.faults.permission_denied) return error.AccessDenied;
        if (self.faults.disk_full) return error.NoSpaceLeft;
        const name = try self.pathKey(path);
        errdefer self.allocator.free(name);
        const amount = @min(bytes.len, self.faults.max_write orelse bytes.len);
        const copy = self.allocator.dupe(u8, bytes[0..amount]) catch return error.Io;
        errdefer self.allocator.free(copy);
        if (self.files.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        self.files.put(self.allocator, name, copy) catch return error.Io;
    }
    fn metadata(raw: ?*anyopaque, path: []const u8) Error!Metadata {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.pathKey(path);
        defer self.allocator.free(name);
        const bytes = self.files.get(name) orelse return error.NotFound;
        return .{ .kind = .file, .size = bytes.len };
    }
    fn makeDir(raw: ?*anyopaque, path: []const u8) Error!void {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.pathKey(path);
        self.allocator.free(name);
    }
    fn delete(raw: ?*anyopaque, path: []const u8) Error!void {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(raw.?));
        const name = try self.pathKey(path);
        defer self.allocator.free(name);
        const old = self.files.fetchRemove(name) orelse return error.NotFound;
        self.allocator.free(old.key);
        self.allocator.free(old.value);
    }
    fn atomicWrite(raw: ?*anyopaque, path: []const u8, bytes: []const u8, _: Durability) Error!void {
        return writeAll(raw, path, bytes);
    }
    fn mmap(_: ?*anyopaque, _: []const u8) MmapError!memory.SharedBuffer {
        return error.Unsupported;
    }
    const vtable = VTable{ .read_all = readAll, .write_all = writeAll, .metadata = metadata, .make_dir = makeDir, .delete = delete, .atomic_write = atomicWrite, .mmap = mmap };
};

pub const ReadOnlyFileSystem = struct {
    inner: FileSystem,
    pub fn fileSystem(self: *ReadOnlyFileSystem) FileSystem {
        return .{ .context = self, .vtable = &vtable };
    }
    fn fromRaw(raw: ?*anyopaque) *ReadOnlyFileSystem {
        return @ptrCast(@alignCast(raw.?));
    }
    fn readAll(raw: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error!memory.SharedBuffer {
        return fromRaw(raw).inner.readAll(allocator, path, limit);
    }
    fn metadata(raw: ?*anyopaque, path: []const u8) Error!Metadata {
        return fromRaw(raw).inner.metadata(path);
    }
    fn denied(_: ?*anyopaque, _: []const u8, _: []const u8) Error!void {
        return error.ReadOnly;
    }
    fn deniedDir(_: ?*anyopaque, _: []const u8) Error!void {
        return error.ReadOnly;
    }
    fn deniedAtomic(_: ?*anyopaque, _: []const u8, _: []const u8, _: Durability) Error!void {
        return error.ReadOnly;
    }
    fn mmap(raw: ?*anyopaque, path: []const u8) MmapError!memory.SharedBuffer {
        return fromRaw(raw).inner.mmap(path);
    }
    const vtable = VTable{ .read_all = readAll, .write_all = denied, .metadata = metadata, .make_dir = deniedDir, .delete = deniedDir, .atomic_write = deniedAtomic, .mmap = mmap };
};

pub const OverlayFileSystem = struct {
    upper: FileSystem,
    lower: FileSystem,
    pub fn fileSystem(self: *OverlayFileSystem) FileSystem {
        return .{ .context = self, .vtable = &vtable };
    }
    fn fromRaw(raw: ?*anyopaque) *OverlayFileSystem {
        return @ptrCast(@alignCast(raw.?));
    }
    fn readAll(raw: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error!memory.SharedBuffer {
        return fromRaw(raw).upper.readAll(allocator, path, limit) catch |err| if (err == error.NotFound) fromRaw(raw).lower.readAll(allocator, path, limit) else err;
    }
    fn metadata(raw: ?*anyopaque, path: []const u8) Error!Metadata {
        return fromRaw(raw).upper.metadata(path) catch |err| if (err == error.NotFound) fromRaw(raw).lower.metadata(path) else err;
    }
    fn writeAll(raw: ?*anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return fromRaw(raw).upper.writeAll(path, bytes);
    }
    fn makeDir(raw: ?*anyopaque, path: []const u8) Error!void {
        return fromRaw(raw).upper.makeDir(path);
    }
    fn delete(raw: ?*anyopaque, path: []const u8) Error!void {
        return fromRaw(raw).upper.delete(path);
    }
    fn atomicWrite(raw: ?*anyopaque, path: []const u8, bytes: []const u8, durability: Durability) Error!void {
        return fromRaw(raw).upper.atomicWrite(path, bytes, durability);
    }
    fn mmap(raw: ?*anyopaque, path: []const u8) MmapError!memory.SharedBuffer {
        return fromRaw(raw).upper.mmap(path) catch |err| if (err == error.Unsupported) fromRaw(raw).lower.mmap(path) else err;
    }
    const vtable = VTable{ .read_all = readAll, .write_all = writeAll, .metadata = metadata, .make_dir = makeDir, .delete = delete, .atomic_write = atomicWrite, .mmap = mmap };
};

/// Async reads run as a task on `work_executor`; no thread or queue is created.
/// The returned future owns its SharedBuffer until `take` transfers it.
pub const AsyncRead = struct { future: future.Pair(memory.SharedBuffer).Future };
pub fn readAsync(allocator: std.mem.Allocator, fs: FileSystem, path: []const u8, limit: usize, token: ?cancellation.Token, work_executor: executor.Executor) Error!AsyncRead {
    const Pair = future.Pair(memory.SharedBuffer);
    const Work = struct {
        allocator: std.mem.Allocator,
        fs: FileSystem,
        path: []u8,
        limit: usize,
        token: ?cancellation.Token,
        promise: Pair.Promise,
        fn cleanup(value: *memory.SharedBuffer, _: std.mem.Allocator) void {
            value.release();
        }
        fn run(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            defer {
                self.promise.deinit();
                if (self.token) |*cancel_token| cancel_token.deinit();
                self.allocator.free(self.path);
                self.allocator.destroy(self);
            }
            if (self.token) |cancel_token| if (cancel_token.isCancelled()) {
                _ = self.promise.cancel();
                return;
            };
            var buffer = self.fs.readAll(self.allocator, self.path, self.limit) catch |err| {
                _ = self.promise.fail(.{ .category = switch (err) {
                    error.Cancelled => .cancelled,
                    error.NotFound => .not_found,
                    error.AccessDenied => .permission_denied,
                    error.TooLarge => .resource_exhausted,
                    else => .io,
                }, .message = @errorName(err) }) catch {};
                return;
            };
            if (self.token) |cancel_token| if (cancel_token.isCancelled()) {
                buffer.release();
                _ = self.promise.cancel();
                return;
            };
            if (!self.promise.complete(buffer)) buffer.release();
        }
        fn discard(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.promise.fail(future.executorRejected()) catch {};
            self.promise.deinit();
            if (self.token) |*cancel_token| cancel_token.deinit();
            self.allocator.free(self.path);
            self.allocator.destroy(self);
        }
    };
    var pair = Pair.init(allocator, Work.cleanup) catch return error.Io;
    const work = allocator.create(Work) catch {
        pair.future.deinit();
        pair.promise.deinit();
        return error.Io;
    };
    const copy = allocator.dupe(u8, path) catch {
        allocator.destroy(work);
        pair.future.deinit();
        pair.promise.deinit();
        return error.Io;
    };
    work.* = .{ .allocator = allocator, .fs = fs, .path = copy, .limit = limit, .token = if (token) |value| value.clone() else null, .promise = pair.promise };
    const task: executor.Task = .{ .run = Work.run, .discard = Work.discard, .context = work };
    work_executor.submit(task) catch {
        task.discard(task.context);
    };
    return .{ .future = pair.future };
}

test "paths reject traversal and normalize" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqualStrings("a/b", try normalizePath(&out, "a/./b"));
    try std.testing.expectError(error.InvalidPath, normalizePath(&out, "../x"));
    try std.testing.expectError(error.InvalidPath, normalizePath(&out, "/x"));
}
test "memory, readonly, overlay, faults, and async executor" {
    var lower = MemoryFileSystem.init(std.testing.allocator);
    defer lower.deinit();
    var upper = MemoryFileSystem.init(std.testing.allocator);
    defer upper.deinit();
    try lower.fileSystem().writeAll("x", "lower");
    var overlay = OverlayFileSystem{ .upper = upper.fileSystem(), .lower = lower.fileSystem() };
    var first = try overlay.fileSystem().readAll(std.testing.allocator, "x", 10);
    defer first.release();
    try std.testing.expectEqualStrings("lower", try first.bytes());
    try upper.fileSystem().atomicWrite("x", "upper", .data);
    var second = try overlay.fileSystem().readAll(std.testing.allocator, "x", 10);
    defer second.release();
    try std.testing.expectEqualStrings("upper", try second.bytes());
    var ro = ReadOnlyFileSystem{ .inner = upper.fileSystem() };
    try std.testing.expectError(error.ReadOnly, ro.fileSystem().writeAll("x", "no"));
    upper.faults.disk_full = true;
    try std.testing.expectError(error.NoSpaceLeft, upper.fileSystem().writeAll("new", "x"));
    upper.faults.disk_full = false;
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var async = try readAsync(std.testing.allocator, upper.fileSystem(), "x", 10, null, queue.executor());
    defer async.future.deinit();
    try std.testing.expectEqual(future.Terminal.pending, async.future.status());
    _ = queue.pump();
    var result = async.future.take().?;
    defer result.release();
    try std.testing.expectEqualStrings("upper", try result.bytes());
}
test "async cancellation and limits" {
    var fs = MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.fileSystem().writeAll("x", "four");
    var source = try cancellation.CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var pending = try readAsync(std.testing.allocator, fs.fileSystem(), "x", 3, token, queue.executor());
    defer pending.future.deinit();
    _ = source.cancel(.requested);
    _ = queue.pump();
    try std.testing.expectEqual(future.Terminal.cancelled, pending.future.status());
}

test "sandbox contains requests and native atomic replacement conforms" {
    var memory_fs = MemoryFileSystem.init(std.testing.allocator);
    defer memory_fs.deinit();
    try memory_fs.fileSystem().writeAll("safe/value", "ok");
    var sandbox = try SandboxFileSystem.init(std.testing.allocator, memory_fs.fileSystem(), "safe");
    defer sandbox.deinit();
    var value = try sandbox.fileSystem().readAll(std.testing.allocator, "value", 8);
    defer value.release();
    try std.testing.expectEqualStrings("ok", try value.bytes());
    try std.testing.expectError(error.InvalidPath, sandbox.fileSystem().readAll(std.testing.allocator, "../value", 8));

    var native = try NativeFileSystem.init(std.testing.allocator, ".", false);
    defer native.deinit();
    try native.fileSystem().makeDir(".zig-cache/foundation-task-08");
    defer native.fileSystem().delete(".zig-cache/foundation-task-08/value") catch {};
    try native.fileSystem().atomicWrite(".zig-cache/foundation-task-08/value", "first", .data);
    try native.fileSystem().atomicWrite(".zig-cache/foundation-task-08/value", "second", .none);
    var handle = try native.open(".zig-cache/foundation-task-08/value", .read);
    defer handle.deinit();
    var handle_bytes: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try handle.read(&handle_bytes));
    try std.testing.expectEqual(@as(u64, 0), try handle.seek(0));
    var replaced = try native.fileSystem().readAll(std.testing.allocator, ".zig-cache/foundation-task-08/value", 16);
    defer replaced.release();
    try std.testing.expectEqualStrings("second", try replaced.bytes());
}

test "async completion callback uses its selected executor" {
    const Probe = struct {
        calls: usize = 0,
        fn call(raw: ?*anyopaque, _: future.Terminal) void {
            @as(*@This(), @ptrCast(@alignCast(raw.?))).calls += 1;
        }
    };
    var fs = MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.fileSystem().writeAll("x", "data");
    var work = executor.TestExecutor.init(std.testing.allocator);
    defer work.deinit();
    var callback = executor.TestExecutor.init(std.testing.allocator);
    defer callback.deinit();
    var read = try readAsync(std.testing.allocator, fs.fileSystem(), "x", 8, null, work.executor());
    defer read.future.deinit();
    var probe = Probe{};
    var registration = try read.future.register(callback.executor(), Probe.call, &probe);
    defer registration.deinit();
    _ = work.pump();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    _ = callback.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}
