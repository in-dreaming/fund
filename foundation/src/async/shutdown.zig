const std = @import("std");
const time = @import("../time/time.zig");

pub const ShutdownMode = enum { graceful, immediate };
pub const ShutdownPhase = enum(u8) { stop_accepting, cancel_operations, drain_critical, flush_observability, stop_loops, join_threads, destroy_adapters, report_leaks };
pub const ParticipantResult = enum { complete, pending, failed };
pub const ShutdownCallback = *const fn (?*anyopaque, ShutdownMode, ?time.MonotonicInstant) ParticipantResult;

pub const Participant = struct { phase: ShutdownPhase, order: u32 = 0, callback: ShutdownCallback, userdata: ?*anyopaque = null };

/// A host-driven teardown coordinator. Participants are borrowed callbacks and
/// must remain valid until `deinit`. Graceful mode requires a monotonic deadline;
/// `run` invokes each participant at most once and returns when all complete or
/// the deadline has elapsed. Immediate mode skips `drain_critical`.
pub const ShutdownCoordinator = struct {
    allocator: std.mem.Allocator,
    participants: std.ArrayListUnmanaged(Participant) = .empty,
    state: State = .idle,
    mode: ?ShutdownMode = null,
    deadline: ?time.MonotonicInstant = null,
    cursor: usize = 0,
    failures: usize = 0,
    mutex: std.Thread.Mutex = .{},

    const State = enum { idle, running, complete };
    pub const RunResult = enum { complete, pending, deadline_exceeded };

    pub fn init(allocator: std.mem.Allocator) ShutdownCoordinator {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *ShutdownCoordinator) void {
        self.participants.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *ShutdownCoordinator, participant: Participant) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .idle) return error.ShutdownStarted;
        try self.participants.append(self.allocator, participant);
    }
    pub fn failureCount(self: *ShutdownCoordinator) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failures;
    }
    pub fn run(self: *ShutdownCoordinator, clock: time.Clock, mode: ShutdownMode, graceful_deadline: ?time.MonotonicInstant) error{ InvalidDeadline, ShutdownModeMismatch }!RunResult {
        self.mutex.lock();
        if (self.state == .idle) {
            if (mode == .graceful and graceful_deadline == null) {
                self.mutex.unlock();
                return error.InvalidDeadline;
            }
            self.state = .running;
            self.mode = mode;
            self.deadline = graceful_deadline;
            std.mem.sort(Participant, self.participants.items, {}, lessThan);
        } else if (self.mode.? != mode) {
            self.mutex.unlock();
            return error.ShutdownModeMismatch;
        }
        if (self.state == .complete) {
            self.mutex.unlock();
            return .complete;
        }
        const deadline = self.deadline;
        self.mutex.unlock();
        while (self.cursor < self.participants.items.len) {
            if (mode == .graceful and clock.monotonicNow().nanoseconds >= deadline.?.nanoseconds) return .deadline_exceeded;
            const participant = self.participants.items[self.cursor];
            if (mode == .immediate and participant.phase == .drain_critical) {
                self.cursor += 1;
                continue;
            }
            switch (participant.callback(participant.userdata, mode, deadline)) {
                .complete => self.cursor += 1,
                .failed => {
                    self.failures += 1;
                    self.cursor += 1;
                },
                .pending => return .pending,
            }
        }
        self.mutex.lock();
        self.state = .complete;
        self.mutex.unlock();
        return .complete;
    }
    fn lessThan(_: void, a: Participant, b: Participant) bool {
        return @intFromEnum(a.phase) < @intFromEnum(b.phase) or (@intFromEnum(a.phase) == @intFromEnum(b.phase) and a.order < b.order);
    }
};

test "shutdown phases are ordered and immediate skips draining" {
    const Probe = struct {
        calls: [3]u8 = .{ 0, 0, 0 },
        count: usize = 0,
        fn call(p: ?*anyopaque, _: ShutdownMode, _: ?time.MonotonicInstant) ParticipantResult {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.calls[self.count] = @intCast(self.count);
            self.count += 1;
            return .complete;
        }
    };
    var coordinator = ShutdownCoordinator.init(std.testing.allocator);
    defer coordinator.deinit();
    var probe = Probe{};
    try coordinator.register(.{ .phase = .destroy_adapters, .callback = Probe.call, .userdata = &probe });
    try coordinator.register(.{ .phase = .drain_critical, .callback = Probe.call, .userdata = &probe });
    try coordinator.register(.{ .phase = .stop_accepting, .callback = Probe.call, .userdata = &probe });
    var clock = time.ManualClock{};
    try std.testing.expectEqual(ShutdownCoordinator.RunResult.complete, try coordinator.run(clock.clock(), .immediate, null));
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(ShutdownCoordinator.RunResult.complete, try coordinator.run(clock.clock(), .immediate, null));
}

test "graceful requires deadline and stops at deadline" {
    const Pending = struct {
        fn call(_: ?*anyopaque, _: ShutdownMode, _: ?time.MonotonicInstant) ParticipantResult {
            return .pending;
        }
    };
    var coordinator = ShutdownCoordinator.init(std.testing.allocator);
    defer coordinator.deinit();
    try coordinator.register(.{ .phase = .drain_critical, .callback = Pending.call });
    var clock = time.ManualClock{};
    try std.testing.expectError(error.InvalidDeadline, coordinator.run(clock.clock(), .graceful, null));
    const deadline = clock.clock().monotonicNow().after(.milliseconds(1));
    try std.testing.expectEqual(ShutdownCoordinator.RunResult.pending, try coordinator.run(clock.clock(), .graceful, deadline));
    clock.advance(.milliseconds(1));
    try std.testing.expectEqual(ShutdownCoordinator.RunResult.deadline_exceeded, try coordinator.run(clock.clock(), .graceful, deadline));
}
