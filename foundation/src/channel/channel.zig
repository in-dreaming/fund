const std = @import("std");
const cancellation = @import("../async/cancellation.zig");
const time = @import("../time/time.zig");

/// Overflow behavior when a bounded queue is full. `coalesce` requires a
/// caller-supplied coalescer; it is otherwise rejected explicitly.
pub const Overflow = enum { reject, block, drop_newest, drop_oldest, coalesce };
pub const SendError = error{ Closed, Full, Cancelled, DeadlineExceeded, UnsupportedPolicy };
const deadline_poll_interval_ns = std.time.ns_per_ms;

/// A fixed-capacity, mutex-backed FIFO. All methods are safe for MPSC use;
/// `Spsc` documents the narrower one-producer/one-consumer contract without
/// changing behavior. `destroy` receives every item rejected, dropped, left at
/// close/deinit, or displaced by a coalesced send.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Destroy = *const fn (*T) void;
        /// Return true when `incoming` has been incorporated into `existing`.
        /// The queue then destroys `incoming`; callers must not move resources
        /// out of it. This supplies caller-defined identity and merge semantics.
        pub const Coalescer = *const fn (existing: *T, incoming: *T) bool;

        allocator: std.mem.Allocator,
        items: []?T,
        destroy: Destroy,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},
        head: usize = 0,
        tail: usize = 0,
        count_: usize = 0,
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, requested_capacity: usize, destroy: Destroy) !Self {
            if (requested_capacity == 0) return error.InvalidCapacity;
            const items = try allocator.alloc(?T, requested_capacity);
            @memset(items, null);
            return .{ .allocator = allocator, .items = items, .destroy = destroy };
        }

        /// Wakes waiters, prohibits subsequent sends, and destroys queued
        /// values. It must not race with other queue methods.
        pub fn deinit(self: *Self) void {
            self.close();
            self.mutex.lock();
            self.destroyAllLocked();
            self.mutex.unlock();
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.items.len;
        }
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count_;
        }
        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        /// Closing is idempotent, wakes all blocked producers and consumers,
        /// and leaves already accepted values available for `receive`/`drain`.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            if (!self.closed) {
                self.closed = true;
                self.not_empty.broadcast();
                self.not_full.broadcast();
            }
            self.mutex.unlock();
        }

        /// On failure the caller retains ownership of `value`. On successful
        /// send, including a drop/coalesce result, the queue owns its cleanup.
        pub fn send(self: *Self, value: T, overflow: Overflow, coalescer: ?Coalescer) SendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            if (self.count_ < self.items.len) return self.pushLocked(value);
            switch (overflow) {
                .reject => return error.Full,
                .block => return error.Full,
                .drop_newest => {
                    var discarded = value;
                    self.destroy(&discarded);
                },
                .drop_oldest => {
                    self.dropOldestLocked();
                    self.pushLocked(value);
                },
                .coalesce => {
                    const hook = coalescer orelse return error.UnsupportedPolicy;
                    var incoming = value;
                    for (0..self.count_) |offset| {
                        const index = (self.head + offset) % self.items.len;
                        if (self.items[index]) |*existing| if (hook(existing, &incoming)) {
                            self.destroy(&incoming);
                            return;
                        };
                    }
                    return error.Full;
                },
            }
        }

        /// A blocking send. It is forbidden for executor/non-blocking threads
        /// by contract. Zig 0.16's thread condition has no timed wait, so this
        /// releases the mutex and polls at most every millisecond; deadlines,
        /// close, and cancellation are therefore observed without queue work.
        pub fn sendBlocking(self: *Self, value: T, token: ?cancellation.Token, clock: time.Clock, deadline: time.MonotonicInstant) SendError!void {
            var registration: ?cancellation.Registration = null;
            if (token) |cancel_token| registration = cancel_token.register(Waker.wake, self) catch return error.Cancelled;
            defer if (registration) |*r| r.deinit();
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count_ == self.items.len and !self.closed) {
                if (token) |cancel_token| if (cancel_token.isCancelled()) return error.Cancelled;
                if (clock.monotonicNow().nanoseconds >= deadline.nanoseconds) return error.DeadlineExceeded;
                self.pollWaitLocked();
            }
            if (self.closed) return error.Closed;
            self.pushLocked(value);
        }

        /// Returns null when empty or closed-and-drained. A returned value is
        /// caller-owned and must be destroyed by the caller when appropriate.
        pub fn receive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.popLocked();
        }

        pub fn receiveBlocking(self: *Self, token: ?cancellation.Token, clock: time.Clock, deadline: time.MonotonicInstant) SendError!?T {
            var registration: ?cancellation.Registration = null;
            if (token) |cancel_token| registration = cancel_token.register(Waker.wake, self) catch return error.Cancelled;
            defer if (registration) |*r| r.deinit();
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count_ == 0 and !self.closed) {
                if (token) |cancel_token| if (cancel_token.isCancelled()) return error.Cancelled;
                if (clock.monotonicNow().nanoseconds >= deadline.nanoseconds) return error.DeadlineExceeded;
                self.pollWaitLocked();
            }
            return self.popLocked();
        }

        /// Transfers each accepted item to `callback` in FIFO order. Values are
        /// callback-owned after invocation.
        pub fn drain(self: *Self, context: ?*anyopaque, callback: *const fn (?*anyopaque, T) void) usize {
            var count: usize = 0;
            while (self.receive()) |value| {
                callback(context, value);
                count += 1;
            }
            return count;
        }

        const Waker = struct {
            fn wake(raw: ?*anyopaque, _: cancellation.CancelReason) void {
                const self: *Self = @ptrCast(@alignCast(raw.?));
                self.mutex.lock();
                self.not_empty.broadcast();
                self.not_full.broadcast();
                self.mutex.unlock();
            }
        };
        fn pushLocked(self: *Self, value: T) void {
            self.items[self.tail] = value;
            self.tail = (self.tail + 1) % self.items.len;
            self.count_ += 1;
            self.not_empty.signal();
        }
        fn popLocked(self: *Self) ?T {
            if (self.count_ == 0) return null;
            const value = self.items[self.head].?;
            self.items[self.head] = null;
            self.head = (self.head + 1) % self.items.len;
            self.count_ -= 1;
            self.not_full.signal();
            return value;
        }
        fn dropOldestLocked(self: *Self) void {
            var value = self.popLocked().?;
            self.destroy(&value);
        }
        fn destroyAllLocked(self: *Self) void {
            while (self.popLocked()) |item| {
                var value = item;
                self.destroy(&value);
            }
        }
        fn pollWaitLocked(self: *Self) void {
            self.mutex.unlock();
            std.Thread.sleep(deadline_poll_interval_ns);
            self.mutex.lock();
        }
    };
}

/// Bounded SPSC FIFO. Exactly one producer and one consumer should call it;
/// the implementation additionally serializes accidental concurrent access.
pub fn Spsc(comptime T: type) type {
    return Queue(T);
}
/// Bounded MPSC FIFO. Many producers may send concurrently; one consumer calls
/// receive/drain. The mutex establishes FIFO order at successful acquisition.
pub fn Mpsc(comptime T: type) type {
    return Queue(T);
}
/// A host-pumped MPSC mailbox. The designated host thread consumes with pump.
pub fn Mailbox(comptime T: type) type {
    return struct {
        queue: Mpsc(T),
        pub fn init(allocator: std.mem.Allocator, capacity: usize, destroy: Mpsc(T).Destroy) !@This() {
            return .{ .queue = try Mpsc(T).init(allocator, capacity, destroy) };
        }
        pub fn deinit(self: *@This()) void {
            self.queue.deinit();
        }
        pub fn post(self: *@This(), value: T, overflow: Overflow, coalescer: ?Mpsc(T).Coalescer) SendError!void {
            return self.queue.send(value, overflow, coalescer);
        }
        pub fn pump(self: *@This(), context: ?*anyopaque, callback: *const fn (?*anyopaque, T) void) usize {
            return self.queue.drain(context, callback);
        }
        pub fn close(self: *@This()) void {
            self.queue.close();
        }
        pub fn len(self: *@This()) usize {
            return self.queue.len();
        }
    };
}

test "capacity one FIFO and overflow destruction" {
    const D = struct {
        var count: usize = 0;
        fn destroy(_: *u8) void {
            count += 1;
        }
    };
    D.count = 0;
    var queue = try Spsc(u8).init(std.testing.allocator, 1, D.destroy);
    defer queue.deinit();
    try queue.send(1, .reject, null);
    try std.testing.expectError(error.Full, queue.send(2, .reject, null));
    try queue.send(2, .drop_newest, null);
    try std.testing.expectEqual(@as(usize, 1), D.count);
    try queue.send(3, .drop_oldest, null);
    try std.testing.expectEqual(@as(u8, 3), queue.receive().?);
    try std.testing.expectEqual(@as(usize, 2), D.count);
}

test "coalesce and close preserve ownership" {
    const Item = struct { key: u8, value: u8 };
    const D = struct {
        var count: usize = 0;
        fn destroy(_: *Item) void {
            count += 1;
        }
    };
    const C = struct {
        fn merge(a: *Item, b: *Item) bool {
            if (a.key != b.key) return false;
            a.value = b.value;
            return true;
        }
    };
    D.count = 0;
    var queue = try Mpsc(Item).init(std.testing.allocator, 1, D.destroy);
    defer queue.deinit();
    try queue.send(.{ .key = 1, .value = 2 }, .reject, null);
    try queue.send(.{ .key = 1, .value = 4 }, .coalesce, C.merge);
    try std.testing.expectEqual(@as(usize, 1), D.count);
    const item = queue.receive().?;
    try std.testing.expectEqual(@as(u8, 4), item.value);
    queue.close();
    try std.testing.expectError(error.Closed, queue.send(.{ .key = 2, .value = 1 }, .reject, null));
}

test "blocking methods observe cancellation and deadline" {
    const D = struct {
        fn destroy(_: *u8) void {}
    };
    var queue = try Mpsc(u8).init(std.testing.allocator, 1, D.destroy);
    defer queue.deinit();
    var clock = time.ManualClock{};
    const deadline = clock.clock().monotonicNow();
    try std.testing.expectError(error.DeadlineExceeded, queue.receiveBlocking(null, clock.clock(), deadline));
    var source = try cancellation.CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    _ = source.cancel(.requested);
    try std.testing.expectError(error.Cancelled, queue.receiveBlocking(token, clock.clock(), deadline.after(.milliseconds(1))));
}

test "a blocking waiter observes a manually advanced deadline without queue activity" {
    const D = struct {
        fn destroy(_: *u8) void {}
    };
    const Waiter = struct {
        queue: *Mpsc(u8),
        clock: time.Clock,
        deadline: time.MonotonicInstant,
        started: *std.atomic.Value(bool),
        result: *std.atomic.Value(bool),
        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.queue.receiveBlocking(null, self.clock, self.deadline) catch |err| {
                self.result.store(err == error.DeadlineExceeded, .release);
                return;
            };
        }
    };
    var queue = try Mpsc(u8).init(std.testing.allocator, 1, D.destroy);
    defer queue.deinit();
    var clock = time.ManualClock{};
    const deadline = clock.clock().monotonicNow().after(.milliseconds(1));
    var started = std.atomic.Value(bool).init(false);
    var observed_deadline = std.atomic.Value(bool).init(false);
    var waiter = Waiter{ .queue = &queue, .clock = clock.clock(), .deadline = deadline, .started = &started, .result = &observed_deadline };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    while (!started.load(.acquire)) std.Thread.yield() catch {};
    clock.advance(.milliseconds(1));
    thread.join();
    try std.testing.expect(observed_deadline.load(.acquire));
}

test "init reports allocation failure" {
    const D = struct {
        fn destroy(_: *u8) void {}
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Mpsc(u8).init(failing.allocator(), 1, D.destroy));
}

test "MPSC stress has no lost or duplicate accepted items" {
    const producers = 4;
    const per_producer = 250;
    const D = struct {
        fn destroy(_: *u32) void {}
    };
    const Producer = struct {
        queue: *Mpsc(u32),
        base: u32,
        fn run(self: *@This()) void {
            for (0..per_producer) |offset| {
                const value = self.base + @as(u32, @intCast(offset));
                while (true) {
                    self.queue.send(value, .reject, null) catch |err| switch (err) {
                        error.Full => {
                            std.Thread.yield() catch {};
                            continue;
                        },
                        else => @panic("unexpected queue send error"),
                    };
                    break;
                }
            }
        }
    };
    var queue = try Mpsc(u32).init(std.testing.allocator, 31, D.destroy);
    defer queue.deinit();
    var producer_state: [producers]Producer = undefined;
    var threads: [producers]std.Thread = undefined;
    for (&producer_state, 0..) |*state, index| {
        state.* = .{ .queue = &queue, .base = @as(u32, @intCast(index * per_producer)) };
        threads[index] = try std.Thread.spawn(.{}, Producer.run, .{state});
    }
    var seen = [_]bool{false} ** (producers * per_producer);
    var received: usize = 0;
    while (received < seen.len) {
        if (queue.receive()) |value| {
            try std.testing.expect(value < seen.len);
            try std.testing.expect(!seen[value]);
            seen[value] = true;
            received += 1;
        } else std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();
    for (seen) |was_seen| try std.testing.expect(was_seen);
}
