const std = @import("std");
const time = @import("../time/time.zig");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

/// The first cancellation request permanently selects the reason.
pub const CancelReason = enum { requested, timeout, owner_destroyed, shutdown };

pub const CancelCallback = *const fn (?*anyopaque, CancelReason) void;

const Callback = struct { id: u64, function: CancelCallback, userdata: ?*anyopaque };

const State = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    mutex: Mutex = .{},
    cancelled: bool = false,
    reason: ?CancelReason = null,
    next_callback_id: u64 = 1,
    callbacks: std.ArrayListUnmanaged(Callback) = .empty,

    fn retain(self: *State) void {
        const previous = self.references.fetchAdd(1, .acq_rel);
        std.debug.assert(previous != std.math.maxInt(u32));
    }

    fn release(self: *State) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        self.callbacks.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// An owned cancellation state. `deinit` cancels with `owner_destroyed`; tokens
/// and registrations retain the state, so callbacks can never observe freed
/// source storage. This type is not thread-safe to deinitialize concurrently
/// with its own methods.
pub const CancellationSource = struct {
    state: ?*State,
    parent_registration: ?Registration = null,
    parent_child_state: ?*State = null,

    pub fn init(allocator: std.mem.Allocator) !CancellationSource {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator };
        return .{ .state = state };
    }

    /// Creates a child whose cancellation follows `parent`. The parent link is
    /// removed during child deinitialization; no global child registry exists.
    pub fn initChild(allocator: std.mem.Allocator, parent: Token) !CancellationSource {
        var child = try init(allocator);
        errdefer child.deinit();
        const ChildLink = struct {
            state: *State,
            fn propagate(userdata: ?*anyopaque, reason: CancelReason) void {
                const state: *State = @ptrCast(@alignCast(userdata.?));
                cancelState(state, reason);
            }
        };
        const child_state = child.state.?;
        child_state.retain(); // Held while the parent callback may reference this state.
        child.parent_registration = try parent.register(ChildLink.propagate, child_state);
        child.parent_child_state = child_state;
        if (parent.isCancelled()) child.cancel(parent.reason().?);
        return child;
    }

    pub fn deinit(self: *CancellationSource) void {
        const state = self.state orelse return;
        _ = self.cancel(.owner_destroyed);
        if (self.parent_registration) |*registration| registration.deinit();
        self.parent_registration = null;
        if (self.parent_child_state) |child_state| child_state.release();
        self.parent_child_state = null;
        self.state = null;
        state.release();
    }

    /// Requests cancellation. It returns true only for the request that chose
    /// the final reason. Callbacks execute synchronously on the requesting
    /// thread after the state lock has been released.
    pub fn cancel(self: *CancellationSource, reason: CancelReason) bool {
        return cancelState(self.state orelse return false, reason);
    }

    /// A token is a shared owner and must be released with `deinit`.
    pub fn token(self: *const CancellationSource) Token {
        const state = self.state orelse @panic("token requested after source deinit");
        state.retain();
        return .{ .state = state };
    }

    /// Host-driven deadline support. Call `pollDeadline` from an executor or
    /// event loop; this module never creates a timer thread.
    pub fn pollDeadline(self: *CancellationSource, clock: time.Clock, deadline: time.MonotonicInstant) bool {
        if (clock.monotonicNow().nanoseconds < deadline.nanoseconds) return false;
        return self.cancel(.timeout);
    }
};

fn cancelState(state: *State, reason: CancelReason) bool {
    var callbacks: std.ArrayListUnmanaged(Callback) = .empty;
    state.mutex.lock();
    if (state.cancelled) {
        state.mutex.unlock();
        return false;
    }
    state.cancelled = true;
    state.reason = reason;
    callbacks = state.callbacks;
    state.callbacks = .empty;
    state.mutex.unlock();
    defer callbacks.deinit(state.allocator);
    for (callbacks.items) |callback| callback.function(callback.userdata, reason);
    return true;
}

/// A copyable shared cancellation observer. `clone` returns another owner and
/// every owner must call `deinit`. Queries take a bounded mutex acquisition.
pub const Token = struct {
    state: *State,

    pub fn clone(self: Token) Token {
        self.state.retain();
        return self;
    }
    pub fn deinit(self: *Token) void {
        self.state.release();
        self.* = undefined;
    }
    pub fn isCancelled(self: Token) bool {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        return self.state.cancelled;
    }
    pub fn reason(self: Token) ?CancelReason {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        return self.state.reason;
    }
    /// `callback` runs at most once, either synchronously during registration
    /// if already cancelled, or on the thread that first cancels. It must not
    /// block. The returned registration must be deinitialized to release its
    /// retained state; `deregister` prevents a callback not already claimed by
    /// cancellation from running.
    pub fn register(self: Token, callback: CancelCallback, userdata: ?*anyopaque) !Registration {
        self.state.retain();
        errdefer self.state.release();
        self.state.mutex.lock();
        if (self.state.cancelled) {
            const cancelled_reason = self.state.reason.?;
            self.state.mutex.unlock();
            callback(userdata, cancelled_reason);
            return .{ .state = self.state, .id = 0 };
        }
        const id = self.state.next_callback_id;
        self.state.next_callback_id +%= 1;
        if (self.state.next_callback_id == 0) self.state.next_callback_id = 1;
        errdefer self.state.mutex.unlock();
        try self.state.callbacks.append(self.state.allocator, .{ .id = id, .function = callback, .userdata = userdata });
        self.state.mutex.unlock();
        return .{ .state = self.state, .id = id };
    }
};

/// Owns a retained registration state. `deinit` is idempotent. Calling it while
/// a cancellation callback is executing cannot retract that in-flight call.
pub const Registration = struct {
    state: ?*State,
    id: u64,

    pub fn deregister(self: *Registration) bool {
        const state = self.state orelse return false;
        if (self.id == 0) return false;
        state.mutex.lock();
        defer state.mutex.unlock();
        for (state.callbacks.items, 0..) |callback, index| {
            if (callback.id != self.id) continue;
            _ = state.callbacks.swapRemove(index);
            self.id = 0;
            return true;
        }
        self.id = 0;
        return false;
    }
    pub fn deinit(self: *Registration) void {
        const state = self.state orelse return;
        _ = self.deregister();
        self.state = null;
        state.release();
    }
};

test "cancel before register selects first reason and calls once" {
    const Probe = struct {
        calls: usize = 0,
        reason: ?CancelReason = null,
        fn call(p: ?*anyopaque, reason: CancelReason) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.calls += 1;
            self.reason = reason;
        }
    };
    var source = try CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    try std.testing.expect(source.cancel(.requested));
    try std.testing.expect(!source.cancel(.timeout));
    var token = source.token();
    defer token.deinit();
    var probe = Probe{};
    var registration = try token.register(Probe.call, &probe);
    defer registration.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(CancelReason.requested, probe.reason.?);
}

test "deregister prevents a later callback" {
    const Probe = struct {
        calls: usize = 0,
        fn call(p: ?*anyopaque, _: CancelReason) void {
            @as(*@This(), @ptrCast(@alignCast(p.?))).calls += 1;
        }
    };
    var source = try CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    var probe = Probe{};
    var registration = try token.register(Probe.call, &probe);
    try std.testing.expect(registration.deregister());
    registration.deinit();
    _ = source.cancel(.requested);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "parent cancellation propagates and child destruction unregisters" {
    var parent = try CancellationSource.init(std.testing.allocator);
    defer parent.deinit();
    var parent_token = parent.token();
    defer parent_token.deinit();
    var child = try CancellationSource.initChild(std.testing.allocator, parent_token);
    var child_token = child.token();
    defer child_token.deinit();
    _ = parent.cancel(.shutdown);
    try std.testing.expectEqual(CancelReason.shutdown, child_token.reason().?);
    child.deinit();
}

test "deadline polling is driven by a manual clock" {
    var clock = time.ManualClock{};
    var source = try CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    const deadline = clock.clock().monotonicNow().after(.milliseconds(5));
    try std.testing.expect(!source.pollDeadline(clock.clock(), deadline));
    clock.advance(.milliseconds(5));
    try std.testing.expect(source.pollDeadline(clock.clock(), deadline));
}

test "source destruction cancels retained tokens" {
    const Probe = struct {
        calls: usize = 0,
        reason: ?CancelReason = null,
        fn call(context: ?*anyopaque, reason: CancelReason) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.reason = reason;
        }
    };
    var source = try CancellationSource.init(std.testing.allocator);
    var token = source.token();
    defer token.deinit();
    var probe = Probe{};
    var registration = try token.register(Probe.call, &probe);
    defer registration.deinit();
    source.deinit();
    try std.testing.expect(token.isCancelled());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(CancelReason.owner_destroyed, probe.reason.?);
}
