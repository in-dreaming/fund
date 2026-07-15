//! libuv is an optional, owner-pumped tooling adapter. It creates no threads.
const std = @import("std");
const foundation = @import("foundation");
const executor_api = foundation.executor;
const filesystem = foundation.filesystem;
const time = foundation.time;

const NativeLoop = opaque {};
const NativeTimer = opaque {};
const NativeWatch = opaque {};
const NativeListener = opaque {};
const NativeStream = opaque {};
const Call = *const fn (?*anyopaque) callconv(.c) void;
const WatchCall = *const fn (?*anyopaque, ?[*:0]const u8, c_int, c_int) callconv(.c) void;
const AcceptCall = *const fn (?*anyopaque, ?*NativeStream, c_int) callconv(.c) void;
const ConnectCall = *const fn (?*anyopaque, ?*NativeStream, c_int) callconv(.c) void;
const ReadCall = *const fn (?*anyopaque, ?[*]const u8, usize, c_int) callconv(.c) void;
const WriteCall = *const fn (?*anyopaque, c_int) callconv(.c) void;
extern fn fd_uv_loop_create(?*anyopaque, Call) ?*NativeLoop;
extern fn fd_uv_loop_destroy(*NativeLoop) void;
extern fn fd_uv_loop_pump(*NativeLoop) c_int;
extern fn fd_uv_loop_wakeup(*NativeLoop) void;
extern fn fd_uv_loop_stop(*NativeLoop) void;
extern fn fd_uv_timer_start(*NativeLoop, ?*anyopaque, Call, u64) ?*NativeTimer;
extern fn fd_uv_timer_cancel(*NativeTimer) void;
extern fn fd_uv_watch_start(*NativeLoop, ?*anyopaque, WatchCall, [*:0]const u8, c_uint) ?*NativeWatch;
extern fn fd_uv_watch_stop(*NativeWatch) void;
extern fn fd_uv_tcp_listen(*NativeLoop, ?*anyopaque, AcceptCall, *u16) ?*NativeListener;
extern fn fd_uv_tcp_listener_close(*NativeListener) void;
extern fn fd_uv_tcp_connect(*NativeLoop, ?*anyopaque, ConnectCall, u16) void;
extern fn fd_uv_tcp_stream_set_context(*NativeStream, ?*anyopaque) void;
extern fn fd_uv_tcp_stream_read(*NativeStream, ReadCall) c_int;
extern fn fd_uv_tcp_stream_close(*NativeStream) void;
extern fn fd_uv_tcp_stream_write(*NativeStream, [*]const u8, usize, ?*anyopaque, WriteCall) c_int;

pub const Error = error{ OutOfMemory, Shutdown, InvalidState, Io };

/// Process execution retains Task 09's synchronous explicit-argv contract.
/// libuv is used for loop-bound tooling I/O; the established native backend is
/// delegated to here rather than changing completion or ownership semantics.
pub const ProcessBackend = if (foundation.build_options.process) struct {
    native: foundation.process.NativeBackend = .{},
    pub fn backend(self: *@This()) foundation.process.Backend {
        return self.native.backend();
    }
} else struct {};

/// An explicitly owned libuv loop. The owner calls `pump`; all libuv callbacks
/// run there. `submit` is thread-safe but only becomes observable after pumping.
pub const Loop = struct {
    allocator: std.mem.Allocator,
    native: *NativeLoop,
    tasks: std.ArrayListUnmanaged(executor_api.Task) = .empty,
    mutex: std.Io.Mutex = .init,
    accepting: bool = true,

    pub fn init(allocator: std.mem.Allocator) Error!*Loop {
        const result = allocator.create(Loop) catch return error.OutOfMemory;
        result.* = .{ .allocator = allocator, .native = undefined };
        result.native = fd_uv_loop_create(result, onWake) orelse {
            allocator.destroy(result);
            return error.OutOfMemory;
        };
        return result;
    }
    /// Stops accepting work, discards queued tasks, and closes native handles.
    /// Call only after cancelling handle-owned timers and watches.
    pub fn deinit(self: *Loop) void {
        self.close();
        self.lock();
        const pending = self.tasks;
        self.tasks = .empty;
        self.unlock();
        for (pending.items) |task| task.discard(task.context);
        var owned = pending;
        owned.deinit(self.allocator);
        fd_uv_loop_destroy(self.native);
        self.allocator.destroy(self);
    }
    pub fn executor(self: *Loop) executor_api.Executor {
        return .{ .context = self, .vtable = &executor_vtable };
    }
    /// Runs currently-ready libuv callbacks without blocking. Returns whether
    /// libuv still has referenced work; construction itself does not do work.
    pub fn pump(self: *Loop) bool {
        return fd_uv_loop_pump(self.native) != 0;
    }
    pub fn close(self: *Loop) void {
        self.lock();
        self.accepting = false;
        self.unlock();
        fd_uv_loop_stop(self.native);
    }
    fn submit(raw: ?*anyopaque, task: executor_api.Task) executor_api.SubmitError!void {
        const self: *Loop = @ptrCast(@alignCast(raw.?));
        self.lock();
        defer self.unlock();
        if (!self.accepting) return error.Shutdown;
        self.tasks.append(self.allocator, task) catch return error.OutOfMemory;
        fd_uv_loop_wakeup(self.native);
    }
    fn cancel(raw: ?*anyopaque) void {
        @as(*Loop, @ptrCast(@alignCast(raw.?))).close();
    }
    const executor_vtable = executor_api.VTable{ .submit = submit, .cancel = cancel };
    fn onWake(raw: ?*anyopaque) callconv(.c) void {
        const self: *Loop = @ptrCast(@alignCast(raw.?));
        self.lock();
        const pending = self.tasks;
        self.tasks = .empty;
        self.unlock();
        for (pending.items) |task| task.run(task.context);
        var owned = pending;
        owned.deinit(self.allocator);
    }
    fn lock(self: *Loop) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }
    fn unlock(self: *Loop) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }
};

/// Handle-owned one-shot timer. Its task crosses to `completion`, never runs
/// on an incidental backend thread, and is discarded when cancelled.
pub const Timer = struct {
    allocator: std.mem.Allocator,
    completion: executor_api.Executor,
    task: executor_api.Task,
    native: ?*NativeTimer = null,
    fired: bool = false,
    pub fn schedule(allocator: std.mem.Allocator, loop: *Loop, delay: time.Duration, completion: executor_api.Executor, task: executor_api.Task) Error!*Timer {
        const result = allocator.create(Timer) catch return error.OutOfMemory;
        result.* = .{ .allocator = allocator, .completion = completion, .task = task };
        const milliseconds: u64 = @intCast(@max(0, @divFloor(delay.nanoseconds, std.time.ns_per_ms)));
        result.native = fd_uv_timer_start(loop.native, result, onTimer, milliseconds) orelse {
            allocator.destroy(result);
            return error.Io;
        };
        return result;
    }
    /// May be called once by the loop owner before the timer fires.
    pub fn cancel(self: *Timer) void {
        if (self.native) |native| fd_uv_timer_cancel(native) else return;
        self.native = null;
        self.task.discard(self.task.context);
        self.allocator.destroy(self);
    }
    fn onTimer(raw: ?*anyopaque) callconv(.c) void {
        const self: *Timer = @ptrCast(@alignCast(raw.?));
        self.native = null;
        self.fired = true;
        self.completion.submit(self.task) catch self.task.discard(self.task.context);
        self.allocator.destroy(self);
    }
};

pub const WatchCallback = *const fn (?*anyopaque, filesystem.WatchEvent) void;
/// Handle-owned recursive/nonrecursive native watch. Events can be coalesced
/// and rename pairs are platform-dependent. Callback paths are allocator-owned
/// only until the scheduled callback returns; callbacks must not block.
pub const Watch = struct {
    allocator: std.mem.Allocator,
    completion: executor_api.Executor,
    callback: WatchCallback,
    userdata: ?*anyopaque,
    native: ?*NativeWatch,
    pub fn start(allocator: std.mem.Allocator, loop: *Loop, path: [*:0]const u8, recursive: bool, completion: executor_api.Executor, callback: WatchCallback, userdata: ?*anyopaque) Error!*Watch {
        const self = allocator.create(Watch) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .completion = completion, .callback = callback, .userdata = userdata, .native = null };
        self.native = fd_uv_watch_start(loop.native, self, onWatch, path, if (recursive) 1 else 0) orelse {
            allocator.destroy(self);
            return error.Io;
        };
        return self;
    }
    pub fn deinit(self: *Watch) void {
        if (self.native) |native| fd_uv_watch_stop(native);
        self.native = null;
        self.allocator.destroy(self);
    }
    const Delivery = struct {
        allocator: std.mem.Allocator,
        callback: WatchCallback,
        userdata: ?*anyopaque,
        path: []u8,
        event: filesystem.WatchEventKind,
        fn run(raw: ?*anyopaque) void {
            const self: *Delivery = @ptrCast(@alignCast(raw.?));
            defer self.allocator.free(self.path);
            defer self.allocator.destroy(self);
            self.callback(self.userdata, .{ .kind = self.event, .path = self.path });
        }
        fn discard(raw: ?*anyopaque) void {
            const self: *Delivery = @ptrCast(@alignCast(raw.?));
            self.allocator.free(self.path);
            self.allocator.destroy(self);
        }
    };
    fn onWatch(raw: ?*anyopaque, name: ?[*:0]const u8, events: c_int, status: c_int) callconv(.c) void {
        const self: *Watch = @ptrCast(@alignCast(raw.?));
        const path = self.allocator.dupe(u8, if (name) |value| std.mem.span(value) else "") catch return;
        const delivery = self.allocator.create(Delivery) catch {
            self.allocator.free(path);
            return;
        };
        const event: filesystem.WatchEventKind = if (status < 0) .rescan_required else if ((events & 1) != 0) .renamed else .modified;
        delivery.* = .{ .allocator = self.allocator, .callback = self.callback, .userdata = self.userdata, .path = path, .event = event };
        self.completion.submit(.{ .run = Delivery.run, .discard = Delivery.discard, .context = delivery }) catch Delivery.discard(delivery);
    }
};

pub const LocalEndpoint = struct { port: u16 };
pub const StreamError = error{ Closed, ResourceExhausted, Io };
pub const ReadCallback = *const fn (?*anyopaque, []const u8, ?errors.ErrorCategory) void;
pub const AcceptCallback = *const fn (?*anyopaque, *Stream) void;
pub const ConnectCallback = *const fn (?*anyopaque, ?*Stream, ?errors.ErrorCategory) void;
const errors = foundation.errors;

/// Handle-owned local TCP byte stream. Reads and write completions are always
/// scheduled on `completion`; received byte slices are borrowed for one call.
/// `max_write_bytes` bounds each accepted write, providing caller-visible
/// backpressure without adding message framing.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    native: *NativeStream,
    completion: executor_api.Executor,
    read_callback: ReadCallback,
    read_userdata: ?*anyopaque,
    max_write_bytes: usize,
    closed: bool = false,

    fn init(allocator: std.mem.Allocator, native: *NativeStream, completion: executor_api.Executor, read_callback: ReadCallback, userdata: ?*anyopaque, max_write_bytes: usize) Error!*Stream {
        const self = allocator.create(Stream) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .native = native, .completion = completion, .read_callback = read_callback, .read_userdata = userdata, .max_write_bytes = max_write_bytes };
        fd_uv_tcp_stream_set_context(native, self);
        if (fd_uv_tcp_stream_read(native, onRead) != 0) {
            allocator.destroy(self);
            return error.Io;
        }
        return self;
    }
    pub fn write(self: *Stream, bytes: []const u8, completion: executor_api.Executor, task: executor_api.Task) StreamError!void {
        if (self.closed) return error.Closed;
        if (bytes.len > self.max_write_bytes) return error.ResourceExhausted;
        const state = self.allocator.create(Write) catch return error.ResourceExhausted;
        state.* = .{ .allocator = self.allocator, .completion = completion, .task = task };
        if (fd_uv_tcp_stream_write(self.native, bytes.ptr, bytes.len, state, Write.done) != 0) {
            self.allocator.destroy(state);
            return error.Io;
        }
    }
    pub fn deinit(self: *Stream) void {
        if (!self.closed) fd_uv_tcp_stream_close(self.native);
        self.closed = true;
        self.allocator.destroy(self);
    }
    const Write = struct {
        allocator: std.mem.Allocator,
        completion: executor_api.Executor,
        task: executor_api.Task,
        fn done(raw: ?*anyopaque, status: c_int) callconv(.c) void {
            const self: *Write = @ptrCast(@alignCast(raw.?));
            _ = status;
            self.completion.submit(self.task) catch self.task.discard(self.task.context);
            self.allocator.destroy(self);
        }
    };
    const Read = struct {
        allocator: std.mem.Allocator,
        callback: ReadCallback,
        userdata: ?*anyopaque,
        bytes: []u8,
        category: ?errors.ErrorCategory,
        fn run(raw: ?*anyopaque) void {
            const self: *Read = @ptrCast(@alignCast(raw.?));
            defer self.allocator.free(self.bytes);
            defer self.allocator.destroy(self);
            self.callback(self.userdata, self.bytes, self.category);
        }
        fn discard(raw: ?*anyopaque) void {
            const self: *Read = @ptrCast(@alignCast(raw.?));
            self.allocator.free(self.bytes);
            self.allocator.destroy(self);
        }
    };
    fn onRead(raw: ?*anyopaque, bytes: ?[*]const u8, length: usize, status: c_int) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(raw.?));
        const copy = self.allocator.dupe(u8, if (bytes) |value| value[0..length] else "") catch return;
        const delivery = self.allocator.create(Read) catch {
            self.allocator.free(copy);
            return;
        };
        delivery.* = .{ .allocator = self.allocator, .callback = self.read_callback, .userdata = self.read_userdata, .bytes = copy, .category = if (status < 0) .io else null };
        self.completion.submit(.{ .run = Read.run, .discard = Read.discard, .context = delivery }) catch Read.discard(delivery);
    }
};

/// Handle-owned loopback TCP listener. Its accept callback runs on the chosen
/// executor at most once per accepted stream; it transfers stream ownership.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    native: *NativeListener,
    completion: executor_api.Executor,
    accept_callback: AcceptCallback,
    userdata: ?*anyopaque,
    read_callback: ReadCallback,
    max_write_bytes: usize,
    port: u16 = 0,
    pub fn listen(allocator: std.mem.Allocator, loop: *Loop, completion: executor_api.Executor, accept_callback: AcceptCallback, userdata: ?*anyopaque, read_callback: ReadCallback, max_write_bytes: usize) Error!*Listener {
        const self = allocator.create(Listener) catch return error.OutOfMemory;
        var port: u16 = 0;
        self.* = .{ .allocator = allocator, .native = undefined, .completion = completion, .accept_callback = accept_callback, .userdata = userdata, .read_callback = read_callback, .max_write_bytes = max_write_bytes };
        self.native = fd_uv_tcp_listen(loop.native, self, onAccept, &port) orelse {
            allocator.destroy(self);
            return error.Io;
        };
        self.port = port;
        return self;
    }
    pub fn endpoint(self: *const Listener) LocalEndpoint {
        return .{ .port = self.port };
    }
    pub fn deinit(self: *Listener) void {
        fd_uv_tcp_listener_close(self.native);
        self.allocator.destroy(self);
    }
    const Accept = struct {
        listener: *Listener,
        native: *NativeStream,
        fn run(raw: ?*anyopaque) void {
            const self: *Accept = @ptrCast(@alignCast(raw.?));
            defer self.listener.allocator.destroy(self);
            const stream = Stream.init(self.listener.allocator, self.native, self.listener.completion, self.listener.read_callback, self.listener.userdata, self.listener.max_write_bytes) catch {
                fd_uv_tcp_stream_close(self.native);
                return;
            };
            self.listener.accept_callback(self.listener.userdata, stream);
        }
        fn discard(raw: ?*anyopaque) void {
            const self: *Accept = @ptrCast(@alignCast(raw.?));
            fd_uv_tcp_stream_close(self.native);
            self.listener.allocator.destroy(self);
        }
    };
    fn onAccept(raw: ?*anyopaque, native: ?*NativeStream, status: c_int) callconv(.c) void {
        const self: *Listener = @ptrCast(@alignCast(raw.?));
        if (status != 0 or native == null) return;
        const delivery = self.allocator.create(Accept) catch {
            fd_uv_tcp_stream_close(native.?);
            return;
        };
        delivery.* = .{ .listener = self, .native = native.? };
        self.completion.submit(.{ .run = Accept.run, .discard = Accept.discard, .context = delivery }) catch Accept.discard(delivery);
    }
};

/// Starts a loopback connection. `callback` is invoked once on `completion`;
/// a non-null stream transfers handle ownership to the callback.
pub fn connect(allocator: std.mem.Allocator, loop: *Loop, endpoint: LocalEndpoint, completion: executor_api.Executor, callback: ConnectCallback, userdata: ?*anyopaque, read_callback: ReadCallback, max_write_bytes: usize) Error!void {
    const state = allocator.create(Connect) catch return error.OutOfMemory;
    state.* = .{ .allocator = allocator, .completion = completion, .callback = callback, .userdata = userdata, .read_callback = read_callback, .max_write_bytes = max_write_bytes };
    fd_uv_tcp_connect(loop.native, state, Connect.done, endpoint.port);
}
const Connect = struct {
    allocator: std.mem.Allocator,
    completion: executor_api.Executor,
    callback: ConnectCallback,
    userdata: ?*anyopaque,
    read_callback: ReadCallback,
    max_write_bytes: usize,
    native: ?*NativeStream = null,
    status: c_int = 0,
    fn done(raw: ?*anyopaque, native: ?*NativeStream, status: c_int) callconv(.c) void {
        const self: *Connect = @ptrCast(@alignCast(raw.?));
        self.native = native;
        self.status = status;
        self.completion.submit(.{ .run = run, .discard = discard, .context = self }) catch discard(self);
    }
    fn run(raw: ?*anyopaque) void {
        const self: *Connect = @ptrCast(@alignCast(raw.?));
        defer self.allocator.destroy(self);
        if (self.status != 0 or self.native == null) {
            self.callback(self.userdata, null, .network);
            return;
        }
        const stream = Stream.init(self.allocator, self.native.?, self.completion, self.read_callback, self.userdata, self.max_write_bytes) catch {
            fd_uv_tcp_stream_close(self.native.?);
            self.callback(self.userdata, null, .io);
            return;
        };
        self.callback(self.userdata, stream, null);
    }
    fn discard(raw: ?*anyopaque) void {
        const self: *Connect = @ptrCast(@alignCast(raw.?));
        if (self.native) |native| fd_uv_tcp_stream_close(native);
        self.allocator.destroy(self);
    }
};

test "loop construction is inert and pumping controls executor progress" {
    const Probe = struct {
        calls: usize = 0,
        fn run(raw: ?*anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(raw.?))).calls += 1;
        }
        fn discard(_: ?*anyopaque) void {}
    };
    var loop = try Loop.init(std.testing.allocator);
    defer loop.deinit();
    var probe = Probe{};
    try loop.executor().submit(.{ .run = Probe.run, .discard = Probe.discard, .context = &probe });
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    _ = loop.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "timer cancellation discards work" {
    const Probe = struct {
        discarded: usize = 0,
        fn run(_: ?*anyopaque) void {}
        fn discard(raw: ?*anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(raw.?))).discarded += 1;
        }
    };
    var loop = try Loop.init(std.testing.allocator);
    defer loop.deinit();
    var completion = executor_api.TestExecutor.init(std.testing.allocator);
    defer completion.deinit();
    var probe = Probe{};
    const timer = try Timer.schedule(std.testing.allocator, loop, .milliseconds(1000), completion.executor(), .{ .run = Probe.run, .discard = Probe.discard, .context = &probe });
    timer.cancel();
    _ = loop.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.discarded);
}

test "loopback TCP transfers bytes through selected executor" {
    const Probe = struct {
        server: ?*Stream = null,
        client: ?*Stream = null,
        reads: usize = 0,
        writes: usize = 0,
        fn accepted(raw: ?*anyopaque, stream: *Stream) void {
            @as(*@This(), @ptrCast(@alignCast(raw.?))).server = stream;
        }
        fn connected(raw: ?*anyopaque, stream: ?*Stream, category: ?errors.ErrorCategory) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (category == null) self.client = stream;
        }
        fn read(raw: ?*anyopaque, bytes: []const u8, category: ?errors.ErrorCategory) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (category == null and std.mem.eql(u8, bytes, "ping")) self.reads += 1;
        }
        fn wrote(raw: ?*anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(raw.?))).writes += 1;
        }
        fn discarded(_: ?*anyopaque) void {}
    };
    var loop = try Loop.init(std.testing.allocator);
    var probe = Probe{};
    var immediate = executor_api.ImmediateExecutor{};
    const listener = try Listener.listen(std.testing.allocator, loop, immediate.executor(), Probe.accepted, &probe, Probe.read, 64);
    try connect(std.testing.allocator, loop, listener.endpoint(), immediate.executor(), Probe.connected, &probe, Probe.read, 64);
    var attempts: usize = 0;
    while (probe.client == null and attempts < 32) : (attempts += 1) _ = loop.pump();
    try std.testing.expect(probe.client != null);
    try std.testing.expect(probe.server != null);
    try probe.client.?.write("ping", immediate.executor(), .{ .run = Probe.wrote, .discard = Probe.discarded, .context = &probe });
    attempts = 0;
    while (probe.reads == 0 and attempts < 32) : (attempts += 1) _ = loop.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.reads);
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    probe.client.?.deinit();
    probe.server.?.deinit();
    listener.deinit();
    _ = loop.pump();
    loop.deinit();
}
