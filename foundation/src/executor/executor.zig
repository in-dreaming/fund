const std = @import("std");

/// A submitted task owns `context` until either `run` or `discard` is called.
/// Executors invoke a task at most once. Tasks must not block the executor.
pub const Task = struct {
    run: *const fn (?*anyopaque) void,
    discard: *const fn (?*anyopaque) void,
    context: ?*anyopaque,
};

pub const SubmitError = error{ Rejected, OutOfMemory, Shutdown };
pub const VTable = struct {
    submit: *const fn (?*anyopaque, Task) SubmitError!void,
    cancel: *const fn (?*anyopaque) void,
};

/// A borrowed executor facade. The concrete executor must outlive submitted
/// tasks. Rejected submissions leave task ownership with the caller, which must
/// call `Task.discard`; this makes completion-payload reclamation explicit.
pub const Executor = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub fn submit(self: Executor, task: Task) SubmitError!void {
        return self.vtable.submit(self.context, task);
    }
    pub fn cancel(self: Executor) void {
        self.vtable.cancel(self.context);
    }
};

/// Runs submitted work synchronously on the caller's thread. This is the only
/// executor that permits reentrancy; its callback contract otherwise matches
/// queued executors.
pub const ImmediateExecutor = struct {
    pub fn executor(self: *ImmediateExecutor) Executor {
        return .{ .context = self, .vtable = &vtable };
    }
    fn submit(_: ?*anyopaque, task: Task) SubmitError!void {
        task.run(task.context);
    }
    fn cancel(_: ?*anyopaque) void {}
    const vtable = VTable{ .submit = submit, .cancel = cancel };
};

/// A single-threaded, host-pumped queue. `pump` must always be called from its
/// designated host thread. `deinit` discards unrun tasks; no callbacks run then.
pub const MainThreadQueue = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    accepting: bool = true,

    pub fn init(allocator: std.mem.Allocator) MainThreadQueue {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MainThreadQueue) void {
        for (self.tasks.items) |task| task.discard(task.context);
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn executor(self: *MainThreadQueue) Executor {
        return .{ .context = self, .vtable = &vtable };
    }
    pub fn pump(self: *MainThreadQueue) usize {
        var count: usize = 0;
        while (self.tasks.items.len != 0) {
            const task = self.tasks.orderedRemove(0);
            task.run(task.context);
            count += 1;
        }
        return count;
    }
    pub fn close(self: *MainThreadQueue) void {
        self.accepting = false;
    }
    fn submit(context: ?*anyopaque, task: Task) SubmitError!void {
        const self: *MainThreadQueue = @ptrCast(@alignCast(context.?));
        if (!self.accepting) return error.Shutdown;
        try self.tasks.append(self.allocator, task);
    }
    fn cancel(context: ?*anyopaque) void {
        const self: *MainThreadQueue = @ptrCast(@alignCast(context.?));
        self.close();
    }
    const vtable = VTable{ .submit = submit, .cancel = cancel };
};

/// Deterministic test executor. It is deliberately equivalent to the host
/// queue, but named separately so tests make execution ownership explicit.
pub const TestExecutor = MainThreadQueue;

test "queued executor defers inline submission until pumped" {
    const Probe = struct {
        calls: usize = 0,
        fn run(context: ?*anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).calls += 1;
        }
        fn discard(_: ?*anyopaque) void {}
    };
    var queue = MainThreadQueue.init(std.testing.allocator);
    defer queue.deinit();
    var probe = Probe{};
    try queue.executor().submit(.{ .run = Probe.run, .discard = Probe.discard, .context = &probe });
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), queue.pump());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "rejected task remains caller owned" {
    const Probe = struct {
        discarded: usize = 0,
        fn run(_: ?*anyopaque) void {}
        fn discard(context: ?*anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).discarded += 1;
        }
    };
    var queue = MainThreadQueue.init(std.testing.allocator);
    defer queue.deinit();
    queue.close();
    var probe = Probe{};
    const task = Task{ .run = Probe.run, .discard = Probe.discard, .context = &probe };
    try std.testing.expectError(error.Shutdown, queue.executor().submit(task));
    task.discard(task.context);
    try std.testing.expectEqual(@as(usize, 1), probe.discarded);
}
