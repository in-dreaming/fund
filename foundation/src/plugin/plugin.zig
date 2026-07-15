const std = @import("std");
const builtin = @import("builtin");
const cabi = @import("../cabi/cabi.zig");

pub const LoadError = error{ UnsupportedPlatform, OpenFailed, MissingDescriptor, InvalidDescriptor, StartFailed, Busy, InvalidState };

const WindowsLibrary = if (builtin.os.tag == .windows) struct {
    const Handle = *anyopaque;
    const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: u32 = 0x00000100;
    const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: u32 = 0x00001000;
    extern "kernel32" fn LoadLibraryExW(path: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?Handle;
    extern "kernel32" fn GetProcAddress(module: Handle, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(module: Handle) callconv(.winapi) i32;

    handle: Handle,

    fn open(path: []const u8) !@This() {
        const io = std.Io.Threaded.global_single_threaded.io();
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(io, path, std.heap.page_allocator) catch return error.OpenFailed;
        defer std.heap.page_allocator.free(absolute);
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, absolute) catch return error.OpenFailed;
        defer std.heap.page_allocator.free(path_w);
        const handle = LoadLibraryExW(path_w.ptr, null, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) orelse return error.OpenFailed;
        return .{ .handle = handle };
    }
    fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.handle, name.ptr) orelse return null);
    }
    fn close(self: *@This()) void {
        _ = FreeLibrary(self.handle);
    }
} else struct {};

const DynamicLibrary = if (builtin.os.tag == .windows) WindowsLibrary else std.DynLib;

/// Dynamic-plugin owner. Acquired callback leases prevent unloading. The host
/// context is borrowed by the plugin only for the duration of `start`.
pub const Plugin = struct {
    pub const State = enum { loaded, started, unloaded };

    library: DynamicLibrary,
    descriptor: *const cabi.PluginDescriptor,
    state: State = .loaded,
    leases: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn load(path: []const u8, required_features: u64) LoadError!Plugin {
        var library = DynamicLibrary.open(path) catch return error.OpenFailed;
        errdefer library.close();
        const entry = library.lookup(cabi.PluginGetDescriptor, "fd_plugin_get_descriptor") orelse return error.MissingDescriptor;
        const descriptor = entry();
        if (cabi.fd_plugin_descriptor_validate(descriptor, required_features) != .ok) return error.InvalidDescriptor;
        return .{ .library = library, .descriptor = descriptor.? };
    }

    pub fn start(self: *Plugin, host_context: ?*const anyopaque) LoadError!void {
        if (self.state != .loaded) return error.InvalidState;
        if (self.descriptor.start.?(host_context) != .ok) return error.StartFailed;
        self.state = .started;
    }

    pub fn acquire(self: *Plugin) LoadError!Lease {
        if (self.state == .unloaded) return error.InvalidState;
        _ = self.leases.fetchAdd(1, .acq_rel);
        if (self.state == .unloaded) {
            _ = self.leases.fetchSub(1, .acq_rel);
            return error.InvalidState;
        }
        return .{ .plugin = self };
    }

    pub fn stop(self: *Plugin) LoadError!void {
        if (self.state != .started) return error.InvalidState;
        self.descriptor.stop.?();
        self.state = .loaded;
    }

    pub fn unload(self: *Plugin) LoadError!void {
        if (self.state == .unloaded) return error.InvalidState;
        if (self.leases.load(.acquire) != 0) return error.Busy;
        if (self.state == .started) self.descriptor.stop.?();
        self.library.close();
        self.state = .unloaded;
    }

    pub const Lease = struct {
        plugin: ?*Plugin,
        pub fn release(self: *Lease) void {
            const plugin = self.plugin orelse return;
            _ = plugin.leases.fetchSub(1, .acq_rel);
            self.plugin = null;
        }
    };
};

test "unload guard refuses live leases" {
    var plugin: Plugin = undefined;
    plugin.state = .loaded;
    plugin.leases = std.atomic.Value(u32).init(0);
    var lease = try plugin.acquire();
    try std.testing.expectEqual(error.Busy, plugin.unload());
    lease.release();
}
