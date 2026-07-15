const std = @import("std");

pub const Duration = struct {
    nanoseconds: i64,
    pub fn fromNanoseconds(value: i64) Duration {
        return .{ .nanoseconds = value };
    }
    pub fn milliseconds(value: i64) Duration {
        return .{ .nanoseconds = std.math.mul(i64, value, std.time.ns_per_ms) catch if (value < 0) std.math.minInt(i64) else std.math.maxInt(i64) };
    }
    pub fn compare(a: Duration, b: Duration) std.math.Order {
        return std.math.order(a.nanoseconds, b.nanoseconds);
    }
    pub fn saturatingAdd(a: Duration, b: Duration) Duration {
        return .fromNanoseconds(a.nanoseconds +| b.nanoseconds);
    }
};

pub const MonotonicInstant = struct {
    nanoseconds: i64,
    pub fn after(self: MonotonicInstant, duration: Duration) MonotonicInstant {
        return .{ .nanoseconds = self.nanoseconds +| duration.nanoseconds };
    }
    pub fn remaining(deadline: MonotonicInstant, now: MonotonicInstant) Duration {
        return .fromNanoseconds(@max(0, deadline.nanoseconds -| now.nanoseconds));
    }
};
pub const WallTimestamp = struct { nanoseconds: i64 };

pub const Clock = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { monotonic_now: *const fn (*anyopaque) MonotonicInstant, wall_now: *const fn (*anyopaque) WallTimestamp };
    pub fn monotonicNow(self: Clock) MonotonicInstant {
        return self.vtable.monotonic_now(self.context);
    }
    /// Wall time is informational. Use `monotonicNow` for every deadline and timeout.
    pub fn wallNow(self: Clock) WallTimestamp {
        return self.vtable.wall_now(self.context);
    }
};

pub const SystemClock = struct {
    pub fn clock(self: *SystemClock) Clock {
        return .{ .context = self, .vtable = &vtable };
    }
    fn monotonic(context: *anyopaque) MonotonicInstant {
        _ = context;
        return .{ .nanoseconds = @intCast(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds) };
    }
    fn wall(context: *anyopaque) WallTimestamp {
        _ = context;
        return .{ .nanoseconds = @intCast(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds) };
    }
    const vtable = Clock.VTable{ .monotonic_now = monotonic, .wall_now = wall };
};

pub const ManualClock = struct {
    monotonic: MonotonicInstant = .{ .nanoseconds = 0 },
    wall: WallTimestamp = .{ .nanoseconds = 0 },
    pub fn clock(self: *ManualClock) Clock {
        return .{ .context = self, .vtable = &vtable };
    }
    pub fn advance(self: *ManualClock, duration: Duration) void {
        self.monotonic = self.monotonic.after(duration);
        self.wall.nanoseconds +|= duration.nanoseconds;
    }
    pub fn setWall(self: *ManualClock, value: WallTimestamp) void {
        self.wall = value;
    }
    fn monotonicNow(context: *anyopaque) MonotonicInstant {
        return @as(*ManualClock, @ptrCast(@alignCast(context))).monotonic;
    }
    fn wallNow(context: *anyopaque) WallTimestamp {
        return @as(*ManualClock, @ptrCast(@alignCast(context))).wall;
    }
    const vtable = Clock.VTable{ .monotonic_now = monotonicNow, .wall_now = wallNow };
};
pub const GameClock = ManualClock;

test "duration boundaries and deadline" {
    try std.testing.expectEqual(@as(i64, 0), Duration.milliseconds(0).nanoseconds);
    try std.testing.expectEqual(@as(i64, -1_000_000), Duration.milliseconds(-1).nanoseconds);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), Duration.milliseconds(std.math.maxInt(i64)).nanoseconds);
    const now = MonotonicInstant{ .nanoseconds = 4 };
    try std.testing.expectEqual(@as(i64, 0), MonotonicInstant.remaining(now, now.after(.nanoseconds(-1))).nanoseconds);
}
test "wall jumps never affect timeouts" {
    var clock = ManualClock{};
    const deadline = clock.clock().monotonicNow().after(.milliseconds(10));
    clock.setWall(.{ .nanoseconds = -99 });
    clock.advance(.milliseconds(10));
    try std.testing.expectEqual(@as(i64, 0), MonotonicInstant.remaining(deadline, clock.clock().monotonicNow()).nanoseconds);
}
test "system monotonic does not decrease" {
    var clock = SystemClock{};
    const facade = clock.clock();
    try std.testing.expect(facade.monotonicNow().nanoseconds <= facade.monotonicNow().nanoseconds);
}
