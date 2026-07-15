const std = @import("std");
const ids = @import("../ids/ids.zig");
const cancellation = @import("cancellation.zig");

pub const State = enum { pending, completed, failed, cancelled };

/// Creates a handle-backed registry for long-lived work. Operation handles own
/// their cancellation source and are invalid immediately after `remove`.
/// Payload ownership remains with the backend until it calls `complete` or
/// `fail`; this registry deliberately does not implement a scheduler.
pub fn Registry(comptime Tag: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            state: State = .pending,
            cancellation_source: cancellation.CancellationSource,
        };
        const Table = ids.HandleTable(Entry, Tag);
        pub const Handle = Table.HandleType;

        allocator: std.mem.Allocator,
        table: Table,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .table = Table.init(allocator) };
        }
        pub fn deinit(self: *Self) void {
            var iterator = self.table.iterator();
            while (iterator.next()) |item| item.value.cancellation_source.deinit();
            self.table.deinit();
            self.* = undefined;
        }
        pub fn create(self: *Self) !Handle {
            var source = try cancellation.CancellationSource.init(self.allocator);
            errdefer source.deinit();
            return self.table.insert(.{ .cancellation_source = source });
        }
        pub fn state(self: *const Self, handle: Handle) ?State {
            return if (self.table.getConst(handle)) |entry| entry.state else null;
        }
        /// Returns a shared token. Call `Token.deinit` once finished observing.
        pub fn token(self: *Self, handle: Handle) ?cancellation.Token {
            const entry = self.table.get(handle) orelse return null;
            return entry.cancellation_source.token();
        }
        /// Requests cooperative cancellation and changes pending work to the
        /// cancelled terminal state. Physical backend cancellation is observed
        /// through the returned token, not promised by this call.
        pub fn requestCancel(self: *Self, handle: Handle, reason: cancellation.CancelReason) bool {
            const entry = self.table.get(handle) orelse return false;
            if (entry.state != .pending) return false;
            entry.state = .cancelled;
            _ = entry.cancellation_source.cancel(reason);
            return true;
        }
        pub fn complete(self: *Self, handle: Handle) bool {
            return terminal(self, handle, .completed);
        }
        pub fn fail(self: *Self, handle: Handle) bool {
            return terminal(self, handle, .failed);
        }
        pub fn remove(self: *Self, handle: Handle) bool {
            var entry = self.table.remove(handle) orelse return false;
            entry.cancellation_source.deinit();
            return true;
        }
        fn terminal(self: *Self, handle: Handle, target: State) bool {
            const entry = self.table.get(handle) orelse return false;
            if (entry.state != .pending) return false;
            entry.state = target;
            return true;
        }
    };
}

test "operations reject stale handles and bridge cancellation" {
    const R = Registry(struct {
        const name = "operation";
    });
    var registry = R.init(std.testing.allocator);
    defer registry.deinit();
    const handle = try registry.create();
    var token = registry.token(handle).?;
    defer token.deinit();
    try std.testing.expect(registry.requestCancel(handle, .requested));
    try std.testing.expect(token.isCancelled());
    try std.testing.expectEqual(State.cancelled, registry.state(handle).?);
    try std.testing.expect(registry.remove(handle));
    try std.testing.expect(registry.state(handle) == null);
    try std.testing.expect(!registry.complete(handle));
}

test "operation cleanup releases active cancellation sources" {
    const R = Registry(struct {
        const name = "operation_cleanup";
    });
    var registry = R.init(std.testing.allocator);
    const handle = try registry.create();
    var token = registry.token(handle).?;
    registry.deinit();
    try std.testing.expect(token.isCancelled());
    token.deinit();
}
