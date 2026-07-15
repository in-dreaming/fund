//! Explicit-argv process execution. This module is only present with `-Dprocess`.
const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../error/error.zig");
const memory = @import("../memory/shared_buffer.zig");
const time = @import("../time/time.zig");
const cancellation = @import("../async/cancellation.zig");

pub const Error = error{ InvalidArgument, Unsupported, SpawnFailed, OutputLimit, Timeout, Cancelled, Io };
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

pub const NativeBackend = struct {
    pub fn backend(self: *NativeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }
    fn run(_: ?*anyopaque, allocator: std.mem.Allocator, request: Request) Error!Result {
        if (request.argv.len == 0 or request.argv[0].len == 0) return error.InvalidArgument;
        if (request.stdin_bytes != null or request.group != .none or request.overflow == .spill_to_file) return error.Unsupported;
        if (request.stdout != .capture or request.stderr != .capture) return error.Unsupported;
        if (request.cancellation_requested or (request.cancellation_token != null and request.cancellation_token.?.isCancelled())) return error.Cancelled;
        const io = std.Io.Threaded.global_single_threaded.io();
        const timeout: std.Io.Timeout = if (request.timeout) |value| .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(@max(0, value.nanoseconds)) }, .clock = .awake } } else .none;
        const native = std.process.run(allocator, io, .{
            .argv = request.argv,
            .cwd = if (request.working_directory) |path| .{ .path = path } else .inherit,
            .environ_map = request.environment,
            .stdout_limit = std.Io.Limit.limited(request.stdout_limit),
            .stderr_limit = std.Io.Limit.limited(request.stderr_limit),
            .timeout = timeout,
        }) catch |err| return mapError(err);
        defer allocator.free(native.stdout);
        defer allocator.free(native.stderr);
        var result = Result{ .status = mapTerm(native.term) };
        result.stdout = memory.SharedBuffer.initCopy(allocator, native.stdout, .io) catch return error.Io;
        errdefer result.stdout.?.release();
        result.stderr = memory.SharedBuffer.initCopy(allocator, native.stderr, .io) catch return error.Io;
        return result;
    }
    const vtable = Backend.VTable{ .run = run };
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
    try std.testing.expectError(error.Unsupported, native.backend().run(std.testing.allocator, .{ .argv = &.{"x"}, .stdin_bytes = "x" }));
    try std.testing.expectError(error.Cancelled, native.backend().run(std.testing.allocator, .{ .argv = &.{"x"}, .cancellation_requested = true }));
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
