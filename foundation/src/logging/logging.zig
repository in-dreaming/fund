const std = @import("std");
const time = @import("../time/time.zig");
const trace = @import("../trace/trace.zig");
const executor = @import("../executor/executor.zig");
const shutdown = @import("../async/shutdown.zig");

pub const Level = enum(u8) { debug, info, warn, err };
pub const Category = u64;
pub const FieldValue = union(enum) { boolean: bool, integer: i64, float: f64, text: []const u8 };
pub const Field = struct { key: []const u8, value: FieldValue, sensitive: bool = false };
/// All slices in this record are borrowed for the call to `Sink.write` only.
pub const LogRecord = struct { timestamp: time.WallTimestamp, level: Level, category: Category, message: []const u8, fields: []const Field = &.{}, trace_context: ?trace.Context = null };
pub const Error = error{ Failed, Full, DeadlineExceeded, OutOfMemory, Reentrant };
pub const Overflow = enum { reject, drop_newest, drop_oldest };
pub const Redactor = *const fn (Field) ?Field;
pub const SinkVTable = struct { write: *const fn (?*anyopaque, LogRecord) Error!void, flush: *const fn (?*anyopaque, ?time.MonotonicInstant) Error!void };
/// Borrowed sink facade. It is invoked by the caller of `Logger.log`, or the
/// explicitly host-pumped dispatcher executor; it never runs on an incidental thread.
pub const Sink = struct {
    context: ?*anyopaque,
    vtable: *const SinkVTable,
    pub fn write(self: Sink, record: LogRecord) Error!void {
        return self.vtable.write(self.context, record);
    }
    pub fn flush(self: Sink, deadline: ?time.MonotonicInstant) Error!void {
        return self.vtable.flush(self.context, deadline);
    }
};
pub const Stats = struct { dropped: u64 = 0, failed_exports: u64 = 0 };

pub const NoopSink = struct {
    pub fn sink(_: *NoopSink) Sink {
        return .{ .context = null, .vtable = &vtable };
    }
    fn write(_: ?*anyopaque, _: LogRecord) Error!void {}
    fn flush(_: ?*anyopaque, _: ?time.MonotonicInstant) Error!void {}
    const vtable = SinkVTable{ .write = write, .flush = flush };
};
pub const ConsoleSink = struct {
    pub fn sink(self: *ConsoleSink) Sink {
        return .{ .context = self, .vtable = &vtable };
    }
    fn write(_: ?*anyopaque, record: LogRecord) Error!void {
        std.debug.print("[{s}] {d}: {s}\n", .{ @tagName(record.level), record.category, record.message });
    }
    fn flush(_: ?*anyopaque, _: ?time.MonotonicInstant) Error!void {}
    const vtable = SinkVTable{ .write = write, .flush = flush };
};
/// Test sink retaining allocator-owned records in bounded oldest-first order.
pub const MemoryRing = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    records: std.ArrayListUnmanaged(OwnedRecord) = .empty,
    pub fn init(allocator: std.mem.Allocator, capacity: usize) MemoryRing {
        return .{ .allocator = allocator, .capacity = capacity };
    }
    pub fn deinit(self: *MemoryRing) void {
        for (self.records.items) |*item| item.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn sink(self: *MemoryRing) Sink {
        return .{ .context = self, .vtable = &vtable };
    }
    pub fn len(self: *const MemoryRing) usize {
        return self.records.items.len;
    }
    pub fn at(self: *const MemoryRing, index: usize) LogRecord {
        return self.records.items[index].record();
    }
    fn write(raw: ?*anyopaque, input: LogRecord) Error!void {
        const self: *MemoryRing = @ptrCast(@alignCast(raw.?));
        if (self.capacity == 0) return;
        if (self.records.items.len == self.capacity) {
            var old = self.records.orderedRemove(0);
            old.deinit(self.allocator);
        }
        self.records.append(self.allocator, try OwnedRecord.copy(self.allocator, input)) catch return error.OutOfMemory;
    }
    fn flush(_: ?*anyopaque, _: ?time.MonotonicInstant) Error!void {}
    const vtable = SinkVTable{ .write = write, .flush = flush };
};

const OwnedRecord = struct {
    record_value: LogRecord,
    message: []u8,
    fields: []Field,
    key_storage: [][]u8,
    text_storage: [][]u8,
    fn copy(allocator: std.mem.Allocator, input: LogRecord) !OwnedRecord {
        const message = try allocator.dupe(u8, input.message);
        errdefer allocator.free(message);
        const fields = try allocator.alloc(Field, input.fields.len);
        errdefer allocator.free(fields);
        const keys = try allocator.alloc([]u8, input.fields.len);
        errdefer allocator.free(keys);
        const texts = try allocator.alloc([]u8, input.fields.len);
        errdefer allocator.free(texts);
        for (input.fields, 0..) |field, i| {
            keys[i] = try allocator.dupe(u8, field.key);
            texts[i] = &.{};
            fields[i] = field;
            fields[i].key = keys[i];
            if (field.value == .text) {
                texts[i] = try allocator.dupe(u8, field.value.text);
                fields[i].value = .{ .text = texts[i] };
            }
        }
        var copy_record = input;
        copy_record.message = message;
        copy_record.fields = fields;
        return .{ .record_value = copy_record, .message = message, .fields = fields, .key_storage = keys, .text_storage = texts };
    }
    fn deinit(self: *OwnedRecord, allocator: std.mem.Allocator) void {
        for (self.key_storage) |value| allocator.free(value);
        for (self.text_storage) |value| if (value.len != 0) allocator.free(value);
        allocator.free(self.key_storage);
        allocator.free(self.text_storage);
        allocator.free(self.fields);
        allocator.free(self.message);
    }
    fn view(self: *const OwnedRecord) LogRecord {
        return self.record_value;
    }
};

/// Bounded, host-pumped asynchronous dispatcher. `worker` names the executor
/// responsible for pumping; callers call `pump` from that executor. Logging
/// while a sink is running is rejected to prevent unbounded reentrant export.
pub const AsyncDispatcher = struct {
    allocator: std.mem.Allocator,
    clock: time.Clock,
    worker: executor.Executor,
    sink: Sink,
    capacity: usize,
    overflow: Overflow,
    redactor: ?Redactor = null,
    pending: std.ArrayListUnmanaged(OwnedRecord) = .empty,
    stats_value: Stats = .{},
    exporting: bool = false,
    mutex: std.Thread.Mutex = .{},
    pub fn init(allocator: std.mem.Allocator, clock: time.Clock, worker: executor.Executor, sink: Sink, capacity: usize, overflow: Overflow) AsyncDispatcher {
        return .{ .allocator = allocator, .clock = clock, .worker = worker, .sink = sink, .capacity = capacity, .overflow = overflow };
    }
    pub fn deinit(self: *AsyncDispatcher) void {
        for (self.pending.items) |*item| item.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn log(self: *AsyncDispatcher, input: LogRecord) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.exporting) return error.Reentrant;
        var record = input;
        var scratch: [32]Field = undefined;
        if (input.fields.len <= scratch.len and self.redactor != null) {
            var count: usize = 0;
            for (input.fields) |field| if (self.redactor.?(field)) |redacted| {
                scratch[count] = redacted;
                count += 1;
            };
            record.fields = scratch[0..count];
        }
        if (self.pending.items.len == self.capacity) switch (self.overflow) {
            .reject => return error.Full,
            .drop_newest => {
                self.stats_value.dropped += 1;
                return;
            },
            .drop_oldest => {
                var old = self.pending.orderedRemove(0);
                old.deinit(self.allocator);
                self.stats_value.dropped += 1;
            },
        };
        self.pending.append(self.allocator, OwnedRecord.copy(self.allocator, record) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }
    pub fn pump(self: *AsyncDispatcher) usize {
        var count: usize = 0;
        while (true) {
            self.mutex.lock();
            if (self.pending.items.len == 0) {
                self.mutex.unlock();
                break;
            }
            var item = self.pending.orderedRemove(0);
            self.exporting = true;
            self.mutex.unlock();
            self.sink.write(item.view()) catch {
                self.mutex.lock();
                self.stats_value.failed_exports += 1;
                self.mutex.unlock();
            };
            item.deinit(self.allocator);
            self.mutex.lock();
            self.exporting = false;
            self.mutex.unlock();
            count += 1;
        }
        return count;
    }
    pub fn flush(self: *AsyncDispatcher, deadline: time.MonotonicInstant) Error!void {
        while (self.pending.items.len != 0) {
            if (self.clock.monotonicNow().nanoseconds >= deadline.nanoseconds) return error.DeadlineExceeded;
            _ = self.pump();
        }
        return self.sink.flush(deadline) catch return error.Failed;
    }
    pub fn stats(self: *AsyncDispatcher) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats_value;
    }
    /// Registers the host-pumped flush in Foundation's observability phase.
    /// The dispatcher must outlive the coordinator.
    pub fn registerShutdown(self: *AsyncDispatcher, coordinator: *shutdown.ShutdownCoordinator, order: u32) !void {
        try coordinator.register(.{ .phase = .flush_observability, .order = order, .callback = shutdownFlush, .userdata = self });
    }
    fn shutdownFlush(raw: ?*anyopaque, _: shutdown.ShutdownMode, deadline: ?time.MonotonicInstant) shutdown.ParticipantResult {
        const self: *AsyncDispatcher = @ptrCast(@alignCast(raw.?));
        const limit = deadline orelse self.clock.monotonicNow();
        self.flush(limit) catch return if (self.pending.items.len == 0) .failed else .pending;
        return .complete;
    }
};

test "logging structured redaction and bounded overflow" {
    const Hooks = struct {
        fn redact(field: Field) ?Field {
            return if (field.sensitive) null else field;
        }
    };
    var clock = time.ManualClock{};
    var worker = executor.ImmediateExecutor{};
    var ring = MemoryRing.init(std.testing.allocator, 4);
    defer ring.deinit();
    var logger = AsyncDispatcher.init(std.testing.allocator, clock.clock(), worker.executor(), ring.sink(), 1, .drop_oldest);
    defer logger.deinit();
    logger.redactor = Hooks.redact;
    try logger.log(.{ .timestamp = .{ .nanoseconds = 1 }, .level = .info, .category = 7, .message = "first", .fields = &.{ .{ .key = "secret", .value = .{ .text = "x" }, .sensitive = true }, .{ .key = "count", .value = .{ .integer = 2 } } } });
    try logger.log(.{ .timestamp = .{ .nanoseconds = 2 }, .level = .warn, .category = 7, .message = "second" });
    try std.testing.expectEqual(@as(u64, 1), logger.stats().dropped);
    try std.testing.expectEqual(@as(usize, 1), logger.pump());
    try std.testing.expectEqualStrings("second", ring.at(0).message);
}
test "trace context is carried by a log record" {
    var clock = time.ManualClock{};
    var worker = executor.ImmediateExecutor{};
    var ring = MemoryRing.init(std.testing.allocator, 1);
    defer ring.deinit();
    var logger = AsyncDispatcher.init(std.testing.allocator, clock.clock(), worker.executor(), ring.sink(), 1, .reject);
    defer logger.deinit();
    try logger.log(.{ .timestamp = .{ .nanoseconds = 0 }, .level = .info, .category = 0, .message = "correlated", .trace_context = .{ .trace_id = 4, .span_id = 9 } });
    _ = logger.pump();
    try std.testing.expectEqual(@as(u128, 4), ring.at(0).trace_context.?.trace_id);
}
test "logging flush deadline and sink failure are reported" {
    const Fail = struct {
        fn write(_: ?*anyopaque, _: LogRecord) Error!void {
            return error.Failed;
        }
        fn flush(_: ?*anyopaque, _: ?time.MonotonicInstant) Error!void {}
        const vtable = SinkVTable{ .write = write, .flush = flush };
    };
    var clock = time.ManualClock{};
    var worker = executor.ImmediateExecutor{};
    var logger = AsyncDispatcher.init(std.testing.allocator, clock.clock(), worker.executor(), .{ .context = null, .vtable = &Fail.vtable }, 1, .reject);
    defer logger.deinit();
    try logger.log(.{ .timestamp = .{ .nanoseconds = 0 }, .level = .info, .category = 0, .message = "x" });
    try std.testing.expectError(error.DeadlineExceeded, logger.flush(clock.clock().monotonicNow()));
    _ = logger.pump();
    try std.testing.expectEqual(@as(u64, 1), logger.stats().failed_exports);
}
