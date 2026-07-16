const std = @import("std");
const errors = @import("../error/error.zig");
const memory = @import("../memory/shared_buffer.zig");
const cancellation = @import("../async/cancellation.zig");
const executor = @import("../executor/executor.zig");

/// Borrowed request header. Header ordering is preserved and both slices must
/// remain valid only until `HttpClient.start` returns; implementations copy them.
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Method = enum { get, head, post, put, patch, delete, options };
pub const RedirectPolicy = union(enum) { deny, follow: u8 };
pub const ProxyPolicy = union(enum) { system, disabled, url: []const u8 };
pub const TlsConfig = struct {
    /// System trust is the production default. `allow_invalid_certificates` is
    /// intentionally absent: test trust must name an explicit CA bundle.
    ca_bundle_path: ?[]const u8 = null,
    client_certificate_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
};
pub const Options = struct {
    connect_timeout_ms: u64 = 10_000,
    first_byte_timeout_ms: u64 = 10_000,
    timeout_ms: u64 = 30_000,
    response_body_limit: usize = 16 * 1024 * 1024,
    redirects: RedirectPolicy = .deny,
    proxy: ProxyPolicy = .system,
    tls: TlsConfig = .{},
    executor: executor.Executor,
    cancellation_token: ?cancellation.Token = null,
};
pub const StreamError = error{ Backpressure, InvalidData, ResourceExhausted };
pub const ResponseHead = struct { status: u16 };
pub const HeadCallback = *const fn (?*anyopaque, ResponseHead) StreamError!void;
/// Receives response-body chunks while the transport is active. The bytes are
/// borrowed only for the callback. Returning an error aborts the transfer.
pub const StreamCallback = *const fn (?*anyopaque, []const u8) StreamError!void;
pub const Stream = struct {
    callback: StreamCallback,
    context: ?*anyopaque = null,
    /// Delivered exactly once before the first body chunk, including for
    /// responses with an empty body.
    head: ?HeadCallback = null,
};
pub const Request = struct {
    url: []const u8,
    method: Method = .get,
    headers: []const Header = &.{},
    /// Borrowed request bytes, valid only through `start`; stream uploads are
    /// represented by backends through the same bounded copy contract for now.
    body: []const u8 = &.{},
};
pub const Response = struct {
    status: u16,
    /// Allocator-owned header storage. Call `deinit` exactly once.
    headers: []Header = &.{},
    /// Shared response bytes. `deinit` releases this ownership.
    body: memory.SharedBuffer,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Response) void {
        for (self.headers) |header| {
            self.allocator.free(@constCast(header.name));
            self.allocator.free(@constCast(header.value));
        }
        if (self.headers.len != 0) self.allocator.free(self.headers);
        self.body.release();
        self.* = undefined;
    }
};
pub const Completion = *const fn (?*anyopaque, Result) void;
pub const Failure = struct {
    category: errors.ErrorCategory,
    native_code: i64 = 0,
    message: []const u8 = "",
    message_storage: ?memory.SharedBuffer = null,

    fn initCopy(allocator: std.mem.Allocator, info: errors.ErrorInfo) !Failure {
        var storage = try memory.SharedBuffer.initCopy(allocator, info.message, .network);
        errdefer storage.release();
        return .{ .category = info.category, .native_code = info.native_code, .message = try storage.bytes(), .message_storage = storage };
    }
    fn deinit(self: *Failure) void {
        if (self.message_storage) |*storage| storage.release();
        self.* = undefined;
    }
};
pub const Result = union(enum) {
    response: Response,
    failure: Failure,
    cancelled,

    pub fn deinit(self: *Result) void {
        switch (self.*) {
            .response => |*response| response.deinit(),
            .failure => |*failure_value| failure_value.deinit(),
            .cancelled => {},
        }
        self.* = undefined;
    }
};

pub fn failureResult(allocator: std.mem.Allocator, info: errors.ErrorInfo) Result {
    return .{ .failure = Failure.initCopy(allocator, info) catch .{ .category = .resource_exhausted } };
}

/// Handle-owned operation. Completion is delivered at most once on the chosen
/// executor; `deinit` requests cancellation and releases the operation.
pub const HttpOperation = struct {
    allocator: std.mem.Allocator,
    source: cancellation.CancellationSource,
    completion: Completion,
    userdata: ?*anyopaque,
    target: executor.Executor,
    response_body_limit: usize,
    references: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.open)),
    const State = enum(u8) { open, queued, closing, terminal };
    pub fn deinit(self: *HttpOperation) void {
        var current = self.state.load(.acquire);
        while (current != @intFromEnum(State.closing) and current != @intFromEnum(State.terminal)) {
            if (self.state.cmpxchgWeak(current, @intFromEnum(State.closing), .acq_rel, .acquire) == null) break;
            current = self.state.load(.acquire);
        }
        _ = self.source.cancel(.owner_destroyed);
        self.release();
    }
    pub fn cancel(self: *HttpOperation) void {
        _ = self.source.cancel(.requested);
    }
    pub fn token(self: *HttpOperation) cancellation.Token {
        return self.source.token();
    }
    fn release(self: *HttpOperation) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.source.deinit();
        self.allocator.destroy(self);
    }
};

/// Creates the handle-owned operation state shared by HTTP adapters. The
/// adapter owns the second reference and must call `finish` exactly once.
pub fn createOperation(allocator: std.mem.Allocator, options: Options, completion: Completion, userdata: ?*anyopaque) !*HttpOperation {
    const operation = try allocator.create(HttpOperation);
    errdefer allocator.destroy(operation);
    const source = if (options.cancellation_token) |token|
        try cancellation.CancellationSource.initChild(allocator, token)
    else
        try cancellation.CancellationSource.init(allocator);
    operation.* = .{
        .allocator = allocator,
        .source = source,
        .completion = completion,
        .userdata = userdata,
        .target = options.executor,
        .response_body_limit = options.response_body_limit,
    };
    return operation;
}

/// Abandons an operation when a backend cannot publish the returned handle.
pub fn abandon(operation: *HttpOperation) void {
    operation.state.store(@intFromEnum(HttpOperation.State.closing), .release);
    _ = operation.source.cancel(.owner_destroyed);
    operation.release();
    operation.release();
}

pub const StartError = error{ InvalidArgument, OutOfMemory, Unavailable };
pub const VTable = struct {
    start: *const fn (?*anyopaque, std.mem.Allocator, Request, Options, ?Stream, Completion, ?*anyopaque) StartError!*HttpOperation,
};
/// Borrowed backend facade. The backend outlives all operations it returns.
pub const HttpClient = struct {
    context: ?*anyopaque,
    vtable: *const VTable,
    pub fn start(self: HttpClient, allocator: std.mem.Allocator, request: Request, options: Options, completion: Completion, userdata: ?*anyopaque) StartError!*HttpOperation {
        if (request.url.len == 0 or options.response_body_limit == 0) return error.InvalidArgument;
        return self.vtable.start(self.context, allocator, request, options, null, completion, userdata);
    }
    /// Starts a bounded streaming response. The terminal completion contains
    /// status and headers with an empty body after all chunks were delivered.
    pub fn startStream(self: HttpClient, allocator: std.mem.Allocator, request: Request, options: Options, stream: Stream, completion: Completion, userdata: ?*anyopaque) StartError!*HttpOperation {
        if (request.url.len == 0 or options.response_body_limit == 0) return error.InvalidArgument;
        return self.vtable.start(self.context, allocator, request, options, stream, completion, userdata);
    }
};

const Dispatch = struct {
    operation: *HttpOperation,
    allocator: std.mem.Allocator,
    result: Result,
    fn run(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        defer self.allocator.destroy(self);
        defer self.operation.release();
        if (self.operation.state.cmpxchgStrong(@intFromEnum(HttpOperation.State.queued), @intFromEnum(HttpOperation.State.terminal), .acq_rel, .acquire) != null) {
            self.result.deinit();
            return;
        }
        self.operation.completion(self.operation.userdata, self.result);
    }
    fn discard(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.result.deinit();
        _ = self.operation.state.cmpxchgStrong(@intFromEnum(HttpOperation.State.queued), @intFromEnum(HttpOperation.State.terminal), .acq_rel, .acquire);
        self.operation.release();
        self.allocator.destroy(self);
    }
};
/// Transfers the adapter's ownership to an executor-bound terminal result.
/// After calling this, the adapter must not access `operation` again.
pub fn finish(operation: *HttpOperation, result: Result) void {
    if (operation.state.cmpxchgStrong(@intFromEnum(HttpOperation.State.open), @intFromEnum(HttpOperation.State.queued), .acq_rel, .acquire) != null) {
        var discarded = result;
        discarded.deinit();
        operation.release();
        return;
    }
    const dispatch = operation.allocator.create(Dispatch) catch {
        var discarded = result;
        discarded.deinit();
        operation.state.store(@intFromEnum(HttpOperation.State.terminal), .release);
        operation.release();
        return;
    };
    dispatch.* = .{ .operation = operation, .allocator = operation.allocator, .result = result };
    const task = executor.Task{ .run = Dispatch.run, .discard = Dispatch.discard, .context = dispatch };
    operation.target.submit(task) catch task.discard(task.context);
}

/// Deterministic host-pumped HTTP backend. `pump` emits one scripted outcome
/// per call, never directly invoking the business completion callback.
pub const MockClient = struct {
    pub const Script = union(enum) { response: struct { status: u16 = 200, body: []const u8, native_code: i64 = 0 }, chunk: []const u8, failure: errors.ErrorInfo, pending };
    const Pending = struct { operation: *HttpOperation, stream: ?Stream = null, head_emitted: bool = false, status: u16 = 0 };
    allocator: std.mem.Allocator,
    scripts: std.ArrayListUnmanaged(Script) = .empty,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    pub fn init(allocator: std.mem.Allocator) MockClient {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MockClient) void {
        for (self.pending.items) |pending| pending.operation.release();
        self.scripts.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn client(self: *MockClient) HttpClient {
        return .{ .context = self, .vtable = &vtable };
    }
    pub fn append(self: *MockClient, script: Script) !void {
        try self.scripts.append(self.allocator, script);
    }
    pub fn pump(self: *MockClient) void {
        if (self.pending.items.len == 0) return;
        const pending = self.pending.orderedRemove(0);
        const operation = pending.operation;
        var token = operation.token();
        defer token.deinit();
        if (token.isCancelled()) {
            finish(operation, .cancelled);
            return;
        }
        const script = if (self.scripts.items.len == 0) Script{ .failure = .{ .category = .unavailable, .message = "mock script exhausted" } } else self.scripts.orderedRemove(0);
        switch (script) {
            .pending => tryAppendPending(self, pending),
            .chunk => |bytes| {
                var current = pending;
                const stream = current.stream orelse {
                    finish(operation, failureResult(operation.allocator, .{ .category = .invalid_argument, .message = "chunk script requires a streaming request" }));
                    return;
                };
                if (!emitHead(&current, 200)) return;
                stream.callback(stream.context, bytes) catch {
                    finish(operation, failureResult(operation.allocator, .{ .category = .resource_exhausted, .message = "stream consumer rejected response data" }));
                    return;
                };
                tryAppendPending(self, current);
            },
            .failure => |failure| finish(operation, failureResult(operation.allocator, failure)),
            .response => |response| {
                if (response.body.len > operation.response_body_limit) {
                    finish(operation, failureResult(operation.allocator, .{ .category = .resource_exhausted, .native_code = response.native_code, .message = "response body limit exceeded" }));
                    return;
                }
                var current = pending;
                if (current.stream) |stream| {
                    if (!emitHead(&current, response.status)) return;
                    stream.callback(stream.context, response.body) catch {
                        finish(operation, failureResult(operation.allocator, .{ .category = .resource_exhausted, .message = "stream consumer rejected response data" }));
                        return;
                    };
                }
                const body = memory.SharedBuffer.initCopy(operation.allocator, if (pending.stream == null) response.body else "", .network) catch {
                    finish(operation, failureResult(operation.allocator, .{ .category = .resource_exhausted, .message = "response allocation failed" }));
                    return;
                };
                finish(operation, .{ .response = .{ .status = response.status, .body = body, .allocator = operation.allocator } });
            },
        }
    }
    fn tryAppendPending(self: *MockClient, pending: Pending) void {
        self.pending.append(self.allocator, pending) catch finish(pending.operation, failureResult(pending.operation.allocator, .{ .category = .resource_exhausted, .message = "mock queue allocation failed" }));
    }
    fn emitHead(pending: *Pending, status: u16) bool {
        if (pending.head_emitted) {
            if (pending.status == status) return true;
            finish(pending.operation, failureResult(pending.operation.allocator, .{ .category = .protocol, .message = "stream response status changed after body delivery" }));
            return false;
        }
        pending.head_emitted = true;
        pending.status = status;
        const stream = pending.stream orelse return true;
        const callback = stream.head orelse return true;
        callback(stream.context, .{ .status = status }) catch {
            finish(pending.operation, failureResult(pending.operation.allocator, .{ .category = .resource_exhausted, .message = "stream consumer rejected response head" }));
            return false;
        };
        return true;
    }
    fn start(context: ?*anyopaque, allocator: std.mem.Allocator, _: Request, options: Options, stream: ?Stream, completion: Completion, userdata: ?*anyopaque) StartError!*HttpOperation {
        const self: *MockClient = @ptrCast(@alignCast(context.?));
        const operation = try createOperation(allocator, options, completion, userdata);
        self.pending.append(self.allocator, .{ .operation = operation, .stream = stream }) catch {
            abandon(operation);
            return error.OutOfMemory;
        };
        return operation;
    }
    const vtable = VTable{ .start = start };
};

test "mock delivery is executor-bound, bounded, and keeps native code" {
    const Probe = struct {
        called: usize = 0,
        result: ?Result = null,
        fn done(raw: ?*anyopaque, result: Result) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.called += 1;
            self.result = result;
        }
    };
    var mock = MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.append(.{ .response = .{ .body = "hello", .native_code = 42 } });
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var probe = Probe{};
    const operation = try mock.client().start(std.testing.allocator, .{ .url = "https://fixture" }, .{ .executor = queue.executor(), .response_body_limit = 3 }, Probe.done, &probe);
    defer operation.deinit();
    mock.pump();
    try std.testing.expectEqual(@as(usize, 0), probe.called);
    _ = queue.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.called);
    switch (probe.result.?) {
        .failure => |failure| try std.testing.expectEqual(@as(i64, 42), failure.native_code),
        else => return error.TestUnexpectedResult,
    }
    probe.result.?.deinit();
    probe.result = null;
}
test "mock cancellation delivers cancelled on selected executor" {
    const Probe = struct {
        calls: usize = 0,
        fn done(raw: ?*anyopaque, result: Result) void {
            _ = result;
            @as(*@This(), @ptrCast(@alignCast(raw.?))).calls += 1;
        }
    };
    var mock = MockClient.init(std.testing.allocator);
    defer mock.deinit();
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var probe = Probe{};
    const operation = try mock.client().start(std.testing.allocator, .{ .url = "https://fixture" }, .{ .executor = queue.executor() }, Probe.done, &probe);
    defer operation.deinit();
    operation.cancel();
    mock.pump();
    _ = queue.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "mock streaming delivers borrowed chunks before one terminal completion" {
    const Probe = struct {
        chunks: std.ArrayListUnmanaged(u8) = .empty,
        terminals: usize = 0,
        head_seen: bool = false,
        fn head(raw: ?*anyopaque, value: ResponseHead) StreamError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.head_seen or value.status != 200) return error.InvalidData;
            self.head_seen = true;
        }
        fn chunk(raw: ?*anyopaque, bytes: []const u8) StreamError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!self.head_seen) return error.InvalidData;
            self.chunks.appendSlice(std.testing.allocator, bytes) catch return error.ResourceExhausted;
        }
        fn done(raw: ?*anyopaque, result: Result) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var owned = result;
            defer owned.deinit();
            self.terminals += 1;
            switch (owned) {
                .response => |response| {
                    const bytes = response.body.bytes() catch @panic("stream response body unavailable");
                    std.testing.expectEqual(@as(usize, 0), bytes.len) catch @panic("stream response retained a body");
                },
                else => @panic("unexpected stream terminal"),
            }
        }
    };
    var mock = MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.append(.{ .response = .{ .body = "data: one\n\ndata: two\n\n" } });
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var probe = Probe{};
    defer probe.chunks.deinit(std.testing.allocator);
    const operation = try mock.client().startStream(std.testing.allocator, .{ .url = "https://fixture" }, .{ .executor = queue.executor() }, .{ .callback = Probe.chunk, .context = &probe, .head = Probe.head }, Probe.done, &probe);
    defer operation.deinit();
    mock.pump();
    try std.testing.expectEqualStrings("data: one\n\ndata: two\n\n", probe.chunks.items);
    try std.testing.expect(probe.head_seen);
    try std.testing.expectEqual(@as(usize, 0), probe.terminals);
    _ = queue.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.terminals);
}

test "completion owns result and teardown drops queued delivery" {
    const Probe = struct {
        calls: usize = 0,
        fn done(raw: ?*anyopaque, result: Result) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            var owned = result;
            owned.deinit();
        }
    };
    var mock = MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.append(.{ .response = .{ .body = "owned" } });
    var queue = executor.TestExecutor.init(std.testing.allocator);
    defer queue.deinit();
    var probe = Probe{};
    const operation = try mock.client().start(std.testing.allocator, .{ .url = "https://fixture" }, .{ .executor = queue.executor() }, Probe.done, &probe);
    mock.pump();
    operation.deinit();
    _ = queue.pump();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}
