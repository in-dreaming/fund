const std = @import("std");
const builtin = @import("builtin");
const cabi = @import("../cabi/cabi.zig");

pub const LoadError = error{ UnsupportedPlatform, OpenFailed, MissingDescriptor, InvalidDescriptor, StartFailed, Busy, InvalidState };

/// Dynamic-plugin owner. Every acquired handle/callback lease must be released
/// before unload; callbacks are never invoked by this type.
pub const Plugin = struct {
    library: if (builtin.os.tag == .windows) void else std.DynLib,
    descriptor: *const cabi.PluginDescriptor,
    started: bool = false,
    leases: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn load(path: []const u8, required_features: u64) LoadError!Plugin {
        if (comptime builtin.os.tag == .windows) {
            return error.UnsupportedPlatform;
        } else {
            var library = std.DynLib.open(path) catch return error.OpenFailed;
            errdefer library.close();
            const entry = library.lookup(cabi.PluginGetDescriptor, "fd_plugin_get_descriptor") orelse return error.MissingDescriptor;
            const descriptor = entry();
            if (cabi.fd_plugin_descriptor_validate(descriptor, required_features) != .ok) return error.InvalidDescriptor;
            return .{ .library = library, .descriptor = descriptor.? };
        }
    }
    pub fn start(self: *Plugin) LoadError!void {
        if (self.started) return error.InvalidState;
        if (self.descriptor.start.?(null) != .ok) return error.StartFailed;
        self.started = true;
    }
    pub fn acquire(self: *Plugin) Lease {
        _ = self.leases.fetchAdd(1, .acq_rel);
        return .{ .plugin = self };
    }
    pub fn unload(self: *Plugin) LoadError!void {
        if (self.leases.load(.acquire) != 0) return error.Busy;
        if (self.started) self.descriptor.stop.?();
        if (comptime builtin.os.tag != .windows) self.library.close();
        self.started = false;
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
    plugin.leases = std.atomic.Value(u32).init(0);
    var lease = plugin.acquire();
    try std.testing.expectEqual(error.Busy, plugin.unload());
    lease.release();
}
