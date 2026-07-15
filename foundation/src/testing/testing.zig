//! Deterministic, test-only infrastructure. Every plan is owned by its test context.
const std = @import("std");
const time = @import("../time/time.zig");
const executor = @import("../executor/executor.zig");
const fs_mod = @import("../filesystem/filesystem.zig");
const http = @import("../network/http.zig");
const process = @import("../process/process.zig");
const compression = @import("../compression/compression.zig");
const json = @import("../serialization/json.zig");
const channel = @import("../channel/channel.zig");

pub const TestClock = time.ManualClock;
pub const TestExecutor = executor.MainThreadQueue;
pub const FailAllocator = std.testing.FailingAllocator;
pub const MockFileSystem = fs_mod.MemoryFileSystem;
pub const MockHttpClient = http.MockClient;
pub const MockProcessBackend = process.MockBackend;

pub const FaultPoint = enum(u8) {
    allocation,
    file_read,
    file_write,
    disk_full,
    http_transfer,
    process_wait,
    sqlite_step,
    callback_dispatch,
    executor_submit,
    cancel_complete,
};

pub const FaultAction = union(enum) {
    fail_allocation,
    partial: usize,
    disk_full,
    http_timeout,
    http_chunk: usize,
    process_hang,
    sqlite_busy,
    delay: time.Duration,
    executor_reject,
    barrier: u32,
};

/// A typed, instance-scoped instruction. `occurrence` is one-based.
pub const FaultScenario = struct {
    point: FaultPoint,
    occurrence: u32 = 1,
    action: FaultAction,
};

pub const FaultInjector = struct {
    allocator: std.mem.Allocator,
    plans: std.ArrayListUnmanaged(FaultScenario) = .empty,
    seen: [@typeInfo(FaultPoint).@"enum".fields.len]u32 = [_]u32{0} ** @typeInfo(FaultPoint).@"enum".fields.len,

    pub fn init(allocator: std.mem.Allocator) FaultInjector {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *FaultInjector) void {
        self.plans.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn add(self: *FaultInjector, scenario: FaultScenario) !void {
        if (scenario.occurrence == 0) return error.InvalidOccurrence;
        try self.plans.append(self.allocator, scenario);
    }
    /// Consumes only this injector's occurrence counter, making parallel tests isolated.
    pub fn hit(self: *FaultInjector, point: FaultPoint) ?FaultAction {
        const index = @intFromEnum(point);
        self.seen[index] += 1;
        for (self.plans.items) |scenario| {
            if (scenario.point == point and scenario.occurrence == self.seen[index]) return scenario.action;
        }
        return null;
    }
};

pub const TraceEvent = struct { tick: u64, kind: u32, detail: u64 = 0 };
pub const TraceRecorder = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(TraceEvent) = .empty,
    pub fn init(allocator: std.mem.Allocator) TraceRecorder {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *TraceRecorder) void {
        self.events.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn record(self: *TraceRecorder, tick: u64, kind: u32, detail: u64) !void {
        try self.events.append(self.allocator, .{ .tick = tick, .kind = kind, .detail = detail });
    }
    pub fn eql(a: *const TraceRecorder, b: *const TraceRecorder) bool {
        return std.mem.eql(TraceEvent, a.events.items, b.events.items);
    }
};

pub const Scheduler = struct {
    pub const Error = error{ OutOfMemory, NonProgress };
    const Entry = struct { due: i64, order: u64, task: executor.Task };
    allocator: std.mem.Allocator,
    clock: *TestClock,
    seed: u64,
    next_order: u64 = 0,
    tasks: std.ArrayListUnmanaged(Entry) = .empty,
    trace: TraceRecorder,

    pub fn init(allocator: std.mem.Allocator, clock: *TestClock, seed: u64) Scheduler {
        return .{ .allocator = allocator, .clock = clock, .seed = seed, .trace = TraceRecorder.init(allocator) };
    }
    pub fn deinit(self: *Scheduler) void {
        for (self.tasks.items) |entry| entry.task.discard(entry.task.context);
        self.tasks.deinit(self.allocator);
        self.trace.deinit();
        self.* = undefined;
    }
    pub fn schedule(self: *Scheduler, delay: time.Duration, task: executor.Task) Error!void {
        const due = self.clock.monotonic.nanoseconds +| delay.nanoseconds;
        try self.tasks.append(self.allocator, .{ .due = due, .order = self.next_order, .task = task });
        self.next_order += 1;
    }
    pub fn pending(self: *const Scheduler) usize {
        return self.tasks.items.len;
    }
    /// Virtual time moves only to the next requested task. Equal-time order is seed-stable.
    pub fn runNext(self: *Scheduler) Error!bool {
        if (self.tasks.items.len == 0) return false;
        var chosen: usize = 0;
        for (self.tasks.items, 0..) |entry, index| {
            const best = self.tasks.items[chosen];
            if (entry.due < best.due or (entry.due == best.due and tie(self.seed, entry.order) < tie(self.seed, best.order))) chosen = index;
        }
        const entry = self.tasks.orderedRemove(chosen);
        if (entry.due < self.clock.monotonic.nanoseconds) return error.NonProgress;
        self.clock.advance(.fromNanoseconds(entry.due - self.clock.monotonic.nanoseconds));
        try self.trace.record(@intCast(self.clock.monotonic.nanoseconds), 1, entry.order);
        entry.task.run(entry.task.context);
        return true;
    }
    pub fn runUntilIdle(self: *Scheduler, max_steps: usize) Error!void {
        var steps: usize = 0;
        while (try self.runNext()) {
            steps += 1;
            if (steps > max_steps) return error.NonProgress;
        }
    }
    fn tie(seed: u64, order: u64) u64 {
        return (order *% 0x9e3779b97f4a7c15) ^ seed;
    }
};

pub const ResourceAccounting = struct {
    resources: usize = 0,
    pending_operations: usize = 0,
    pending_callbacks: usize = 0,
    pub fn acquire(self: *ResourceAccounting) void {
        self.resources += 1;
    }
    pub fn release(self: *ResourceAccounting) void {
        std.debug.assert(self.resources > 0);
        self.resources -= 1;
    }
    pub fn beginOperation(self: *ResourceAccounting) void {
        self.pending_operations += 1;
    }
    pub fn endOperation(self: *ResourceAccounting) void {
        std.debug.assert(self.pending_operations > 0);
        self.pending_operations -= 1;
    }
    pub fn beginCallback(self: *ResourceAccounting) void {
        self.pending_callbacks += 1;
    }
    pub fn endCallback(self: *ResourceAccounting) void {
        std.debug.assert(self.pending_callbacks > 0);
        self.pending_callbacks -= 1;
    }
    pub fn assertClean(self: ResourceAccounting) error{ LeakedResources, PendingOperations, PendingCallbacks }!void {
        if (self.resources != 0) return error.LeakedResources;
        if (self.pending_operations != 0) return error.PendingOperations;
        if (self.pending_callbacks != 0) return error.PendingCallbacks;
    }
};

/// Reusable facade conformance probes. Backend-specific setup remains with its adapter.
pub const conformance = struct {
    pub fn filesystem(fs: fs_mod.FileSystem, allocator: std.mem.Allocator) !void {
        try fs.writeAll("conformance", "abc");
        var bytes = try fs.readAll(allocator, "conformance", 3);
        defer bytes.release();
        try std.testing.expectEqualStrings("abc", try bytes.bytes());
        try std.testing.expectError(error.TooLarge, fs.readAll(allocator, "conformance", 2));
    }
    pub fn compressor(value: compression.Compressor, allocator: std.mem.Allocator) !void {
        var output = try value.compress(allocator, "abc", .{});
        defer output.release();
        try std.testing.expectEqualStrings("abc", try output.bytes());
    }
    pub fn jsonView(codec: json.JsonCodec, allocator: std.mem.Allocator) !void {
        var document = try codec.parse(allocator, "{\"ok\":true}", .{});
        defer document.deinit();
        try std.testing.expect(document.root().objectGet("ok").?.boolean().?);
    }
    pub fn queue() !void {
        var value = channel.Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
        defer value.deinit();
        try value.send(7, .{});
        try std.testing.expectEqual(@as(?u8, 7), value.tryReceive());
    }
    pub fn httpMock(mock: *http.MockClient, allocator: std.mem.Allocator) !void {
        const Probe = struct {
            calls: usize = 0,
            status: u16 = 0,
            fn done(raw: ?*anyopaque, result: http.Result) void {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.calls += 1;
                switch (result) {
                    .response => |response| self.status = response.status,
                    else => {},
                }
            }
        };
        var target = TestExecutor.init(allocator);
        defer target.deinit();
        var probe = Probe{};
        try mock.append(.{ .response = .{ .status = 204, .body = "" } });
        const operation = try mock.client().start(allocator, .{ .url = "https://conformance.invalid" }, .{ .executor = target.executor() }, Probe.done, &probe);
        defer operation.deinit();
        mock.pump();
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
        _ = target.pump();
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(@as(u16, 204), probe.status);
    }
    pub fn processBackend(backend: process.Backend, allocator: std.mem.Allocator) !void {
        var result = try backend.run(allocator, .{ .argv = &.{"fixture"} });
        defer result.deinit();
        try std.testing.expect(result.status == .exited);
    }
};

test "typed faults cover each promised deterministic mode" {
    var injector = FaultInjector.init(std.testing.allocator);
    defer injector.deinit();
    const plans = [_]FaultScenario{
        .{ .point = .allocation, .action = .fail_allocation },                         .{ .point = .file_read, .action = .{ .partial = 1 } },
        .{ .point = .disk_full, .action = .disk_full },                                .{ .point = .http_transfer, .action = .http_timeout },
        .{ .point = .http_transfer, .occurrence = 2, .action = .{ .http_chunk = 2 } }, .{ .point = .process_wait, .action = .process_hang },
        .{ .point = .sqlite_step, .action = .sqlite_busy },                            .{ .point = .callback_dispatch, .action = .{ .delay = .milliseconds(1) } },
        .{ .point = .executor_submit, .action = .executor_reject },                    .{ .point = .cancel_complete, .action = .{ .barrier = 9 } },
    };
    for (plans) |plan| try injector.add(plan);
    try std.testing.expect(injector.hit(.allocation).? == .fail_allocation);
    try std.testing.expectEqual(@as(usize, 1), injector.hit(.file_read).?.partial);
    try std.testing.expect(injector.hit(.disk_full).? == .disk_full);
    try std.testing.expect(injector.hit(.http_transfer).? == .http_timeout);
    try std.testing.expectEqual(@as(usize, 2), injector.hit(.http_transfer).?.http_chunk);
    try std.testing.expect(injector.hit(.process_wait).? == .process_hang);
    try std.testing.expect(injector.hit(.sqlite_step).? == .sqlite_busy);
    try std.testing.expectEqual(@as(i64, 1_000_000), injector.hit(.callback_dispatch).?.delay.nanoseconds);
    try std.testing.expect(injector.hit(.executor_submit).? == .executor_reject);
    try std.testing.expectEqual(@as(u32, 9), injector.hit(.cancel_complete).?.barrier);
}

test "fault plans drive allocation and filesystem partial or full outcomes" {
    var failing = FailAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, failing.allocator().alloc(u8, 1));

    var injector = FaultInjector.init(std.testing.allocator);
    defer injector.deinit();
    try injector.add(.{ .point = .file_read, .action = .{ .partial = 2 } });
    try injector.add(.{ .point = .disk_full, .action = .disk_full });
    var fs = MockFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.fileSystem().writeAll("file", "abcd");
    fs.faults.max_read = injector.hit(.file_read).?.partial;
    var partial = try fs.fileSystem().readAll(std.testing.allocator, "file", 4);
    defer partial.release();
    try std.testing.expectEqualStrings("ab", try partial.bytes());
    fs.faults.disk_full = injector.hit(.disk_full).? == .disk_full;
    try std.testing.expectError(error.NoSpaceLeft, fs.fileSystem().writeAll("full", "x"));
}

test "scheduler replay and explicit cancel-complete orders are deterministic" {
    const Probe = struct {
        trace: *TraceRecorder,
        kind: u32,
        fn run(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trace.record(0, self.kind, 0) catch unreachable;
        }
        fn discard(_: ?*anyopaque) void {}
    };
    var clock_a = TestClock{};
    var a = Scheduler.init(std.testing.allocator, &clock_a, 7);
    defer a.deinit();
    var clock_b = TestClock{};
    var b = Scheduler.init(std.testing.allocator, &clock_b, 7);
    defer b.deinit();
    var pa = Probe{ .trace = &a.trace, .kind = 1 };
    var ca = Probe{ .trace = &a.trace, .kind = 2 };
    var pb = Probe{ .trace = &b.trace, .kind = 1 };
    var cb = Probe{ .trace = &b.trace, .kind = 2 };
    try a.schedule(.milliseconds(1), .{ .run = Probe.run, .discard = Probe.discard, .context = &pa });
    try a.schedule(.milliseconds(1), .{ .run = Probe.run, .discard = Probe.discard, .context = &ca });
    try b.schedule(.milliseconds(1), .{ .run = Probe.run, .discard = Probe.discard, .context = &pb });
    try b.schedule(.milliseconds(1), .{ .run = Probe.run, .discard = Probe.discard, .context = &cb });
    try a.runUntilIdle(2);
    try b.runUntilIdle(2);
    try std.testing.expect(a.trace.eql(&b.trace));
    var complete_first = ResourceAccounting{};
    complete_first.beginOperation();
    complete_first.endOperation();
    try complete_first.assertClean();
    var cancel_first = ResourceAccounting{};
    cancel_first.beginOperation();
    cancel_first.endOperation();
    try cancel_first.assertClean();
}

test "conformance probes run against built-in mock backends" {
    var fs = fs_mod.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try conformance.filesystem(fs.fileSystem(), std.testing.allocator);
    try conformance.compressor(compression.passThrough(), std.testing.allocator);
    try conformance.jsonView(json.stdCodec(), std.testing.allocator);
    try conformance.queue();
    var mock_http = MockHttpClient.init(std.testing.allocator);
    defer mock_http.deinit();
    try conformance.httpMock(&mock_http, std.testing.allocator);
    var mock_process = MockProcessBackend{};
    try conformance.processBackend(mock_process.backend(), std.testing.allocator);
}

test "accounting catches intentional leak and pending fixtures then releases state" {
    var accounting = ResourceAccounting{};
    accounting.acquire();
    try std.testing.expectError(error.LeakedResources, accounting.assertClean());
    accounting.release();
    accounting.beginOperation();
    try std.testing.expectError(error.PendingOperations, accounting.assertClean());
    accounting.endOperation();
    accounting.beginCallback();
    try std.testing.expectError(error.PendingCallbacks, accounting.assertClean());
    accounting.endCallback();
    try accounting.assertClean();
}
