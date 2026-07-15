const std = @import("std");
const errors = @import("../error/error.zig");
const executor = @import("../executor/executor.zig");

pub const Terminal = enum { pending, completed, failed, cancelled };

/// Creates a single-producer future. `destroy_value` owns cleanup of an
/// unclaimed successful value; values returned by `take` become caller-owned.
pub fn Pair(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = struct {
            allocator: std.mem.Allocator,
            references: usize = 2,
            mutex: std.Thread.Mutex = .{},
            terminal: Terminal = .pending,
            value: ?T = null,
            failure: ?errors.OwnedErrorInfo = null,
            destroy_value: *const fn (*T, std.mem.Allocator) void,
            next_continuation_id: u64 = 1,
            continuations: std.ArrayListUnmanaged(Continuation) = .empty,
        };

        pub const Continuation = struct {
            id: u64,
            executor: executor.Executor,
            callback: *const fn (?*anyopaque, Terminal) void,
            context: ?*anyopaque,
        };

        pub const Future = struct {
            state: ?*State,
            pub fn deinit(self: *Future) void {
                release(self.state);
                self.state = null;
            }
            pub fn status(self: Future) Terminal {
                const state = self.state orelse return .cancelled;
                state.mutex.lock();
                defer state.mutex.unlock();
                return state.terminal;
            }
            /// Transfers a completed value to the caller. It returns null for
            /// pending, failed, cancelled, and already-taken futures.
            pub fn take(self: *Future) ?T {
                const state = self.state orelse return null;
                state.mutex.lock();
                defer state.mutex.unlock();
                if (state.terminal != .completed) return null;
                const value = state.value orelse return null;
                state.value = null;
                return value;
            }
            /// The returned error is borrowed until `deinit`; failures retain
            /// their copied message even after producer teardown.
            pub fn errorInfo(self: Future) ?errors.ErrorInfo {
                const state = self.state orelse return null;
                state.mutex.lock();
                defer state.mutex.unlock();
                return if (state.failure) |failure| failure.info else null;
            }
            /// Calls `callback` once on `target`. Queued executors defer even
            /// already-completed futures until pumped. Deregistration only
            /// affects callbacks not already claimed by resolution.
            pub fn register(self: *Future, target: executor.Executor, callback: *const fn (?*anyopaque, Terminal) void, context: ?*anyopaque) !Registration {
                const state = self.state orelse return error.InvalidState;
                state.mutex.lock();
                if (state.terminal != .pending) {
                    const terminal = state.terminal;
                    state.mutex.unlock();
                    schedule(state.allocator, .{ .id = 0, .executor = target, .callback = callback, .context = context }, terminal);
                    return .{ .state = null, .id = 0 };
                }
                const id = state.next_continuation_id;
                state.next_continuation_id +%= 1;
                if (state.next_continuation_id == 0) state.next_continuation_id = 1;
                state.continuations.append(state.allocator, .{ .id = id, .executor = target, .callback = callback, .context = context }) catch |err| {
                    state.mutex.unlock();
                    return err;
                };
                state.references += 1;
                state.mutex.unlock();
                return .{ .state = state, .id = id };
            }
        };
        pub const Registration = struct {
            state: ?*State,
            id: u64,
            pub fn deregister(self: *Registration) bool {
                const state = self.state orelse return false;
                state.mutex.lock();
                for (state.continuations.items, 0..) |continuation, index| {
                    if (continuation.id != self.id) continue;
                    _ = state.continuations.swapRemove(index);
                    state.mutex.unlock();
                    self.id = 0;
                    release(state);
                    return true;
                }
                state.mutex.unlock();
                return false;
            }
            pub fn deinit(self: *Registration) void {
                const state = self.state orelse return;
                if (!self.deregister()) release(state);
                self.state = null;
            }
        };
        pub const Promise = struct {
            state: ?*State,
            pub fn deinit(self: *Promise) void {
                release(self.state);
                self.state = null;
            }
            pub fn complete(self: *Promise, value: T) bool {
                return transition(self.state, .completed, value, null);
            }
            pub fn fail(self: *Promise, info: errors.ErrorInfo) !bool {
                const state = self.state orelse return false;
                const owned = try errors.OwnedErrorInfo.initCopy(state.allocator, info);
                if (transition(state, .failed, null, owned)) return true;
                var discarded = owned;
                discarded.deinit();
                return false;
            }
            pub fn cancel(self: *Promise) bool {
                return transition(self.state, .cancelled, null, null);
            }
        };
        pub fn init(allocator: std.mem.Allocator, destroy_value: *const fn (*T, std.mem.Allocator) void) !struct { future: Future, promise: Promise } {
            const state = try allocator.create(State);
            state.* = .{ .allocator = allocator, .destroy_value = destroy_value };
            return .{ .future = .{ .state = state }, .promise = .{ .state = state } };
        }
        fn transition(state_: ?*State, terminal: Terminal, value: ?T, failure: ?errors.OwnedErrorInfo) bool {
            const state = state_ orelse return false;
            var continuations: std.ArrayListUnmanaged(Continuation) = .empty;
            state.mutex.lock();
            if (state.terminal != .pending) {
                state.mutex.unlock();
                return false;
            }
            state.terminal = terminal;
            state.value = value;
            state.failure = failure;
            continuations = state.continuations;
            state.continuations = .empty;
            state.mutex.unlock();
            for (continuations.items) |continuation| {
                schedule(state.allocator, continuation, terminal);
            }
            continuations.deinit(state.allocator);
            return true;
        }
        const Dispatch = struct {
            allocator: std.mem.Allocator,
            callback: *const fn (?*anyopaque, Terminal) void,
            context: ?*anyopaque,
            terminal: Terminal,
            fn run(raw: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                defer self.allocator.destroy(self);
                self.callback(self.context, self.terminal);
            }
            fn discard(raw: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.allocator.destroy(self);
            }
        };
        fn schedule(allocator: std.mem.Allocator, continuation: Continuation, terminal: Terminal) void {
            const dispatch = allocator.create(Dispatch) catch return;
            dispatch.* = .{ .allocator = allocator, .callback = continuation.callback, .context = continuation.context, .terminal = terminal };
            const task: executor.Task = .{ .run = Dispatch.run, .discard = Dispatch.discard, .context = dispatch };
            continuation.executor.submit(task) catch task.discard(task.context);
        }
        fn release(state_: ?*State) void {
            const state = state_ orelse return;
            state.mutex.lock();
            std.debug.assert(state.references > 0);
            state.references -= 1;
            const destroy = state.references == 0;
            state.mutex.unlock();
            if (!destroy) return;
            state.continuations.deinit(state.allocator);
            if (state.value) |*value| state.destroy_value(value, state.allocator);
            if (state.failure) |*failure| failure.deinit();
            state.allocator.destroy(state);
        }
    };
}

/// Maps executor rejection into a stable terminal error. Callers reclaim the
/// payload themselves before invoking this helper when a queued completion was
/// not accepted.
pub fn executorRejected() errors.ErrorInfo {
    return .{ .category = .unavailable, .message = "executor rejected completion" };
}

/// Posts a producer completion to `target`. Even an inline backend therefore
/// cannot invoke consumer logic until the chosen executor accepts and runs it.
/// On rejection the payload is reclaimed and the promise fails as unavailable.
pub fn postComplete(comptime T: type, promise: *Pair(T).Promise, target: executor.Executor, value: T, destroy_value: *const fn (*T, std.mem.Allocator) void) void {
    const Completion = struct {
        promise: *Pair(T).Promise,
        value: T,
        destroy_value: *const fn (*T, std.mem.Allocator) void,
        fn run(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const allocator = self.promise.state.?.allocator;
            defer allocator.destroy(self);
            if (!self.promise.complete(self.value)) self.destroy_value(&self.value, allocator);
        }
        fn discard(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const allocator = self.promise.state.?.allocator;
            self.destroy_value(&self.value, allocator);
            _ = self.promise.fail(executorRejected()) catch {};
            allocator.destroy(self);
        }
    };
    const allocator = promise.state orelse {
        var discarded = value;
        destroy_value(&discarded, std.heap.page_allocator);
        return;
    };
    const completion = allocator.allocator.create(Completion) catch {
        var discarded = value;
        destroy_value(&discarded, allocator.allocator);
        _ = promise.fail(executorRejected()) catch {};
        return;
    };
    completion.* = .{ .promise = promise, .value = value, .destroy_value = destroy_value };
    const task: executor.Task = .{ .run = Completion.run, .discard = Completion.discard, .context = completion };
    target.submit(task) catch task.discard(task.context);
}

test "future resolves once and releases abandoned payload" {
    const P = Pair([]u8);
    const Cleanup = struct {
        fn run(value: *[]u8, allocator: std.mem.Allocator) void {
            allocator.free(value.*);
        }
    };
    var pair = try P.init(std.testing.allocator, Cleanup.run);
    defer pair.future.deinit();
    defer pair.promise.deinit();
    const value = try std.testing.allocator.dupe(u8, "ok");
    try std.testing.expect(pair.promise.complete(value));
    try std.testing.expect(!pair.promise.cancel());
    const taken = pair.future.take().?;
    defer std.testing.allocator.free(taken);
    try std.testing.expectEqualStrings("ok", taken);
}

test "failure owns copied error through producer teardown" {
    const P = Pair(u8);
    const Cleanup = struct {
        fn run(_: *u8, _: std.mem.Allocator) void {}
    };
    var pair = try P.init(std.testing.allocator, Cleanup.run);
    defer pair.future.deinit();
    try std.testing.expect(try pair.promise.fail(.{ .category = .io, .message = "disk" }));
    pair.promise.deinit();
    try std.testing.expectEqualStrings("disk", pair.future.errorInfo().?.message);
}

test "future allocation failure leaves no state" {
    const P = Pair(u8);
    const Cleanup = struct {
        fn run(_: *u8, _: std.mem.Allocator) void {}
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, P.init(failing.allocator(), Cleanup.run));
}

test "continuations are queued and may be deregistered" {
    const P = Pair(u8);
    const Cleanup = struct {
        fn run(_: *u8, _: std.mem.Allocator) void {}
    };
    const Probe = struct {
        calls: usize = 0,
        terminal: ?Terminal = null,
        fn call(context: ?*anyopaque, terminal: Terminal) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.terminal = terminal;
        }
    };
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var pair = try P.init(std.testing.allocator, Cleanup.run);
    defer pair.future.deinit();
    defer pair.promise.deinit();
    var first = Probe{};
    var second = Probe{};
    var retained = try pair.future.register(queue.executor(), Probe.call, &first);
    defer retained.deinit();
    var removed = try pair.future.register(queue.executor(), Probe.call, &second);
    try std.testing.expect(removed.deregister());
    try std.testing.expect(pair.promise.complete(7));
    try std.testing.expectEqual(@as(usize, 0), first.calls);
    try std.testing.expectEqual(@as(usize, 1), queue.pump());
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(Terminal.completed, first.terminal.?);
    try std.testing.expectEqual(@as(usize, 0), second.calls);
}

test "posted completion from inline backend waits for queue pump" {
    const P = Pair(u8);
    const Cleanup = struct {
        fn run(_: *u8, _: std.mem.Allocator) void {}
    };
    var queue = executor.MainThreadQueue.init(std.testing.allocator);
    defer queue.deinit();
    var pair = try P.init(std.testing.allocator, Cleanup.run);
    defer pair.future.deinit();
    defer pair.promise.deinit();
    postComplete(u8, &pair.promise, queue.executor(), 9, Cleanup.run);
    try std.testing.expectEqual(Terminal.pending, pair.future.status());
    _ = queue.pump();
    try std.testing.expectEqual(@as(u8, 9), pair.future.take().?);
}
