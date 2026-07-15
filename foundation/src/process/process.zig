//! Explicit-argv process execution. This module is only present with `-Dprocess`.
const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../error/error.zig");
const memory = @import("../memory/shared_buffer.zig");
const time = @import("../time/time.zig");
const cancellation = @import("../async/cancellation.zig");
const executor = @import("../executor/executor.zig");

pub const Error = error{ InvalidArgument, Unsupported, SpawnFailed, OutputLimit, Timeout, Cancelled, Io, Unavailable, OutOfMemory };
pub const StdioMode = enum { inherit, ignore, capture };
pub const OverflowBehavior = enum { fail, spill_to_file };
pub const GroupMode = enum { none, new_group };
pub const TerminationPolicy = struct {
    graceful_timeout: time.Duration = .milliseconds(250),
    kill_after: time.Duration = .milliseconds(250),
};

/// Borrowed execution inputs. `argv[0]` is the executable; no shell is ever
/// involved. `environment`, when supplied, replaces rather than augments the
/// child environment and must outlive `run`.
pub const Request = struct {
    argv: []const []const u8,
    working_directory: ?[]const u8 = null,
    environment: ?*const std.process.Environ.Map = null,
    stdin_bytes: ?[]const u8 = null,
    stdout: StdioMode = .capture,
    stderr: StdioMode = .capture,
    stdout_limit: usize = 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
    overflow: OverflowBehavior = .fail,
    group: GroupMode = .none,
    timeout: ?time.Duration = null,
    /// A shared observer, borrowed for `run`. This synchronous native backend
    /// checks it before spawning; cancellable host work uses the mock boundary.
    cancellation_token: ?cancellation.Token = null,
    cancellation_requested: bool = false,
    termination: TerminationPolicy = .{},
};

pub const ExitStatus = union(enum) {
    exited: u8,
    signaled: i32,
    unknown: u32,
};

/// Shared output buffers are owned by the result and released with `deinit`.
/// Their byte views are borrowed until then. Native codes are preserved where
/// Zig exposes them; `category` is the stable Foundation classification.
pub const Result = struct {
    status: ExitStatus,
    stdout: ?memory.SharedBuffer = null,
    stderr: ?memory.SharedBuffer = null,
    category: ?errors.ErrorCategory = null,
    native_code: i64 = 0,
    pub fn deinit(self: *Result) void {
        if (self.stdout) |*value| value.release();
        if (self.stderr) |*value| value.release();
        self.* = undefined;
    }
};

/// A borrowed backend facade. Backends must not invoke business callbacks;
/// callers select their callback executor through the existing future API.
pub const Backend = struct {
    context: ?*anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { run: *const fn (?*anyopaque, std.mem.Allocator, Request) Error!Result };
    pub fn run(self: Backend, allocator: std.mem.Allocator, request: Request) Error!Result {
        return self.vtable.run(self.context, allocator, request);
    }
};

pub const StreamCallback = *const fn (?*anyopaque, []const u8) void;
pub const Completion = *const fn (?*anyopaque, OperationResult) void;
pub const OperationResult = union(enum) {
    success: Result,
    failure: Error,
    cancelled,
    pub fn deinit(self: *OperationResult) void {
        if (self.* == .success) self.success.deinit();
        self.* = undefined;
    }
};
pub const OperationOptions = struct {
    work_executor: executor.Executor,
    completion_executor: executor.Executor,
    stdout_callback: ?StreamCallback = null,
    stderr_callback: ?StreamCallback = null,
};

const OwnedRequest = struct {
    allocator: std.mem.Allocator,
    argv: [][]u8,
    cwd: ?[]u8,
    environment: ?std.process.Environ.Map,
    stdin_bytes: ?[]u8,
    request: Request,

    fn init(allocator: std.mem.Allocator, input: Request) !OwnedRequest {
        const argv = try allocator.alloc([]u8, input.argv.len);
        errdefer allocator.free(argv);
        var argv_count: usize = 0;
        errdefer for (argv[0..argv_count]) |arg| allocator.free(arg);
        for (input.argv, 0..) |arg, index| {
            argv[index] = try allocator.dupe(u8, arg);
            argv_count += 1;
        }
        const cwd = if (input.working_directory) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| allocator.free(value);
        const stdin_bytes = if (input.stdin_bytes) |value| try allocator.dupe(u8, value) else null;
        errdefer if (stdin_bytes) |value| allocator.free(value);
        var environment: ?std.process.Environ.Map = null;
        if (input.environment) |source| {
            var copy = std.process.Environ.Map.init(allocator);
            errdefer copy.deinit();
            for (source.keys(), source.values()) |key, value| try copy.put(key, value);
            environment = copy;
        }
        var request = input;
        request.argv = argv;
        request.working_directory = cwd;
        request.stdin_bytes = stdin_bytes;
        request.environment = if (environment) |*value| value else null;
        request.cancellation_token = null;
        return .{ .allocator = allocator, .argv = argv, .cwd = cwd, .environment = environment, .stdin_bytes = stdin_bytes, .request = request };
    }
    fn view(self: *OwnedRequest, token: cancellation.Token) Request {
        self.request.environment = if (self.environment) |*value| value else null;
        self.request.cancellation_token = token;
        return self.request;
    }
    fn deinit(self: *OwnedRequest) void {
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        if (self.cwd) |value| self.allocator.free(value);
        if (self.stdin_bytes) |value| self.allocator.free(value);
        if (self.environment) |*value| value.deinit();
    }
};

/// Handle-owned asynchronous process operation. The completion callback owns a
/// successful result and must call `OperationResult.deinit` exactly once.
pub const ProcessOperation = struct {
    const State = enum(u8) { open, working, queued, closing, terminal };
    allocator: std.mem.Allocator,
    backend: Backend,
    request: OwnedRequest,
    options: OperationOptions,
    completion: Completion,
    userdata: ?*anyopaque,
    source: cancellation.CancellationSource,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.open)),
    references: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),

    pub fn start(allocator: std.mem.Allocator, backend: Backend, request: Request, options: OperationOptions, completion: Completion, userdata: ?*anyopaque) Error!*ProcessOperation {
        if (request.argv.len == 0 or request.argv[0].len == 0) return error.InvalidArgument;
        const self = allocator.create(ProcessOperation) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        var owned = OwnedRequest.init(allocator, request) catch return error.OutOfMemory;
        errdefer owned.deinit();
        const source = if (request.cancellation_token) |token|
            cancellation.CancellationSource.initChild(allocator, token) catch return error.OutOfMemory
        else
            cancellation.CancellationSource.init(allocator) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .backend = backend, .request = owned, .options = options, .completion = completion, .userdata = userdata, .source = source };
        options.work_executor.submit(.{ .run = runWork, .discard = discardWork, .context = self }) catch {
            self.source.deinit();
            self.request.deinit();
            allocator.destroy(self);
            return error.Unavailable;
        };
        return self;
    }
    pub fn cancel(self: *ProcessOperation) void {
        _ = self.source.cancel(.requested);
    }
    pub fn deinit(self: *ProcessOperation) void {
        var current = self.state.load(.acquire);
        while (current != @intFromEnum(State.closing) and current != @intFromEnum(State.terminal)) {
            if (self.state.cmpxchgWeak(current, @intFromEnum(State.closing), .acq_rel, .acquire) == null) break;
            current = self.state.load(.acquire);
        }
        _ = self.source.cancel(.owner_destroyed);
        self.release();
    }
    fn release(self: *ProcessOperation) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.source.deinit();
        self.request.deinit();
        self.allocator.destroy(self);
    }
    fn runWork(raw: ?*anyopaque) void {
        const self: *ProcessOperation = @ptrCast(@alignCast(raw.?));
        if (self.state.cmpxchgStrong(@intFromEnum(State.open), @intFromEnum(State.working), .acq_rel, .acquire) != null) {
            self.release();
            return;
        }
        var token = self.source.token();
        defer token.deinit();
        const result: OperationResult = if (token.isCancelled()) .cancelled else if (self.backend.run(self.allocator, self.request.view(token))) |value| .{ .success = value } else |err| switch (err) {
            error.Cancelled => .cancelled,
            else => .{ .failure = err },
        };
        if (self.state.cmpxchgStrong(@intFromEnum(State.working), @intFromEnum(State.queued), .acq_rel, .acquire) != null) {
            var discarded = result;
            discarded.deinit();
            self.release();
            return;
        }
        const delivery = self.allocator.create(Delivery) catch {
            var discarded = result;
            discarded.deinit();
            self.state.store(@intFromEnum(State.terminal), .release);
            self.release();
            return;
        };
        delivery.* = .{ .operation = self, .result = result };
        self.options.completion_executor.submit(.{ .run = Delivery.run, .discard = Delivery.discard, .context = delivery }) catch Delivery.discard(delivery);
    }
    fn discardWork(raw: ?*anyopaque) void {
        const self: *ProcessOperation = @ptrCast(@alignCast(raw.?));
        self.state.store(@intFromEnum(State.terminal), .release);
        self.release();
    }
    const Delivery = struct {
        operation: *ProcessOperation,
        result: OperationResult,
        fn run(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const allocator = self.operation.allocator;
            defer allocator.destroy(self);
            defer self.operation.release();
            if (self.operation.state.cmpxchgStrong(@intFromEnum(State.queued), @intFromEnum(State.terminal), .acq_rel, .acquire) != null) {
                self.result.deinit();
                return;
            }
            if (self.result == .success) {
                if (self.operation.options.stdout_callback) |callback| if (self.result.success.stdout) |buffer| callback(self.operation.userdata, buffer.bytes() catch "");
                if (self.operation.options.stderr_callback) |callback| if (self.result.success.stderr) |buffer| callback(self.operation.userdata, buffer.bytes() catch "");
            }
            self.operation.completion(self.operation.userdata, self.result);
        }
        fn discard(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const allocator = self.operation.allocator;
            self.result.deinit();
            self.operation.state.store(@intFromEnum(State.terminal), .release);
            self.operation.release();
            allocator.destroy(self);
        }
    };
};

pub const NativeBackend = struct {
    pub fn backend(self: *NativeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }
    fn run(_: ?*anyopaque, allocator: std.mem.Allocator, request: Request) Error!Result {
        if (request.argv.len == 0 or request.argv[0].len == 0) return error.InvalidArgument;
        if (request.overflow == .spill_to_file) return error.Unsupported;
        if (request.cancellation_requested or (request.cancellation_token != null and request.cancellation_token.?.isCancelled())) return error.Cancelled;
        const io = std.Io.Threaded.global_single_threaded.io();
        const timeout: std.Io.Timeout = if (request.timeout) |value| .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(@max(0, value.nanoseconds)) }, .clock = .awake } } else .none;
        const native = runConfigured(allocator, io, request, timeout) catch |err| return mapError(err);
        defer allocator.free(native.stdout);
        defer allocator.free(native.stderr);
        var result = Result{ .status = mapTerm(native.term) };
        switch (request.stdout) {
            .capture => result.stdout = memory.SharedBuffer.initCopy(allocator, native.stdout, .io) catch return error.Io,
            .inherit => std.Io.File.stdout().writeStreamingAll(io, native.stdout) catch return error.Io,
            .ignore => {},
        }
        errdefer if (result.stdout) |*value| value.release();
        switch (request.stderr) {
            .capture => result.stderr = memory.SharedBuffer.initCopy(allocator, native.stderr, .io) catch return error.Io,
            .inherit => std.Io.File.stderr().writeStreamingAll(io, native.stderr) catch return error.Io,
            .ignore => {},
        }
        return result;
    }
    const vtable = Backend.VTable{ .run = run };
};

fn runConfigured(allocator: std.mem.Allocator, io: std.Io, request: Request, timeout: std.Io.Timeout) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = if (request.working_directory) |path| .{ .path = path } else .inherit,
        .environ_map = request.environment,
        .stdin = if (request.stdin_bytes != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag != .windows and request.group == .new_group) 0 else null,
        .create_no_window = builtin.os.tag == .windows,
    });
    defer child.kill(io);
    var job: ?WindowsJob = if (builtin.os.tag == .windows and request.group == .new_group) try WindowsJob.init(child.id.?) else null;
    defer if (job) |*value| value.deinit();
    if (request.stdin_bytes) |input| {
        try child.stdin.?.writeStreamingAll(io, input);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const stdout_reader = reader.reader(0);
    const stderr_reader = reader.reader(1);
    const poll_timeout: std.Io.Timeout = if (request.timeout != null) timeout else .{ .duration = .{ .raw = .{ .nanoseconds = 25 * std.time.ns_per_ms }, .clock = .awake } };
    while (true) {
        reader.fill(64, poll_timeout) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (request.cancellation_token != null and request.cancellation_token.?.isCancelled()) return error.Cancelled;
                if (request.timeout != null) return error.Timeout;
                continue;
            },
            else => |value| return value,
        };
        if (stdout_reader.buffered().len > request.stdout_limit or stderr_reader.buffered().len > request.stderr_limit) return error.StreamTooLong;
        if (request.cancellation_token != null and request.cancellation_token.?.isCancelled()) return error.Cancelled;
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

const WindowsJob = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const BasicLimits = extern struct {
        per_process_user_time: i64 = 0,
        per_job_user_time: i64 = 0,
        limit_flags: u32 = 0,
        minimum_working_set_size: usize = 0,
        maximum_working_set_size: usize = 0,
        active_process_limit: u32 = 0,
        affinity: usize = 0,
        priority_class: u32 = 0,
        scheduling_class: u32 = 0,
    };
    const IoCounters = extern struct { read_ops: u64 = 0, write_ops: u64 = 0, other_ops: u64 = 0, read_bytes: u64 = 0, write_bytes: u64 = 0, other_bytes: u64 = 0 };
    const ExtendedLimits = extern struct {
        basic: BasicLimits = .{},
        io: IoCounters = .{},
        process_memory_limit: usize = 0,
        job_memory_limit: usize = 0,
        peak_process_memory_used: usize = 0,
        peak_job_memory_used: usize = 0,
    };
    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: u32, info: *const anyopaque, length: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;

    handle: windows.HANDLE,
    fn init(process: windows.HANDLE) !@This() {
        const handle = CreateJobObjectW(null, null) orelse return error.Unsupported;
        errdefer _ = CloseHandle(handle);
        var limits = ExtendedLimits{};
        limits.basic.limit_flags = 0x00002000;
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return error.Unsupported;
        if (AssignProcessToJobObject(handle, process) == 0) return error.Unsupported;
        return .{ .handle = handle };
    }
    fn deinit(self: *@This()) void {
        _ = CloseHandle(self.handle);
    }
} else struct {
    fn init(_: void) !@This() {
        return .{};
    }
    fn deinit(_: *@This()) void {}
};

/// Deterministic test backend contract for Task 16. It returns a copied result
/// and records the last borrowed request without executing a child process.
pub const MockBackend = struct {
    result: Result = .{ .status = .{ .exited = 0 } },
    calls: usize = 0,
    last_argv: ?[]const []const u8 = null,
    pub fn backend(self: *MockBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }
    fn run(raw: ?*anyopaque, allocator: std.mem.Allocator, request: Request) Error!Result {
        const self: *MockBackend = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.last_argv = request.argv;
        var copy = Result{ .status = self.result.status, .category = self.result.category, .native_code = self.result.native_code };
        if (self.result.stdout) |value| copy.stdout = value.clone() catch return error.Io;
        errdefer if (copy.stdout) |*value| value.release();
        if (self.result.stderr) |value| copy.stderr = value.clone() catch return error.Io;
        _ = allocator;
        return copy;
    }
    const vtable = Backend.VTable{ .run = run };
};

fn mapTerm(term: std.process.Child.Term) ExitStatus {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signaled = @intFromEnum(signal) },
        .stopped => |signal| .{ .signaled = @intFromEnum(signal) },
        .unknown => |code| .{ .unknown = code },
    };
}
fn mapError(err: anyerror) Error {
    return switch (err) {
        error.StreamTooLong => error.OutputLimit,
        error.Timeout => error.Timeout,
        error.Cancelled => error.Cancelled,
        error.FileNotFound, error.AccessDenied, error.InvalidExe, error.NotDir => error.SpawnFailed,
        else => error.Io,
    };
}

test "native process passes argv literally and captures bounded output" {
    var native = NativeBackend{};
    const result = try native.backend().run(std.testing.allocator, .{
        .argv = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c", "echo", "a b&c" } else &.{ "/bin/echo", "a b&c" },
    });
    var owned = result;
    defer owned.deinit();
    try std.testing.expectEqual(@as(u8, 0), switch (owned.status) {
        .exited => |code| code,
        else => 255,
    });
    try std.testing.expect(std.mem.indexOf(u8, try owned.stdout.?.bytes(), "a b&c") != null);
}

test "native process maps spawn, output, and unsupported requests" {
    var native = NativeBackend{};
    try std.testing.expectError(error.SpawnFailed, native.backend().run(std.testing.allocator, .{ .argv = &.{"definitely-not-a-foundation-process"} }));
    try std.testing.expectError(error.Cancelled, native.backend().run(std.testing.allocator, .{ .argv = &.{"x"}, .cancellation_requested = true }));
}

test "native process writes stdin and asynchronous completion owns result" {
    if (builtin.os.tag != .windows) return;
    var native = NativeBackend{};
    var work = executor.TestExecutor.init(std.testing.allocator);
    defer work.deinit();
    var completion_queue = executor.TestExecutor.init(std.testing.allocator);
    defer completion_queue.deinit();
    const Probe = struct {
        calls: usize = 0,
        output: bool = false,
        fn stream(raw: ?*anyopaque, bytes: []const u8) void {
            @as(*@This(), @ptrCast(@alignCast(raw.?))).output = std.mem.eql(u8, bytes, "input-data");
        }
        fn done(raw: ?*anyopaque, result: OperationResult) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            var owned = result;
            owned.deinit();
        }
    };
    var probe = Probe{};
    const operation = try ProcessOperation.start(std.testing.allocator, native.backend(), .{ .argv = &.{ "cmd.exe", "/d", "/c", "set /p line= & <nul set /p =%line%" }, .stdin_bytes = "input-data\n", .group = .new_group }, .{ .work_executor = work.executor(), .completion_executor = completion_queue.executor(), .stdout_callback = Probe.stream }, Probe.done, &probe);
    defer operation.deinit();
    _ = work.pump();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    _ = completion_queue.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.output);
}

test "native process supports environment cwd, exit code, output limit, and timeout" {
    if (builtin.os.tag != .windows) return;
    var native = NativeBackend{};
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("FOUNDATION_PROCESS_TEST", "present");
    var details = try native.backend().run(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/c", "echo %FOUNDATION_PROCESS_TEST% & cd & exit 7" },
        .working_directory = "src",
        .environment = &environment,
    });
    defer details.deinit();
    try std.testing.expectEqual(@as(u8, 7), switch (details.status) {
        .exited => |code| code,
        else => 255,
    });
    const output = try details.stdout.?.bytes();
    try std.testing.expect(std.mem.indexOf(u8, output, "present") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\foundation\\src") != null);
    try std.testing.expectError(error.OutputLimit, native.backend().run(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/c", "echo excess" },
        .stdout_limit = 1,
    }));
    try std.testing.expectError(error.Timeout, native.backend().run(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/c", "ping 127.0.0.1 -n 4 > nul" },
        .timeout = .milliseconds(20),
    }));
}
