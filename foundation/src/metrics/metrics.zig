const std = @import("std");
const time = @import("../time/time.zig");

pub const Kind = enum { counter, gauge, histogram, timer };
pub const Error = error{ InvalidName, Duplicate, Conflict, CardinalityExceeded, NotFound, OutOfMemory };
pub const Label = struct { key: []const u8, value: []const u8 };
pub const Registration = struct { name: []const u8, kind: Kind, labels: []const Label = &.{}, histogram_bounds: []const f64 = &.{} };
pub const Snapshot = struct { name: []const u8, kind: Kind, labels: []const Label, histogram_bounds: []const f64, value: i64, buckets: []const u64 };

const Instrument = struct {
    name: []u8,
    kind: Kind,
    labels: []Label,
    bounds: []f64,
    buckets: []std.atomic.Value(u64),
    value: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
};

fn labelsEqual(a: []const Label, b: []const Label) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.key, right.key) or !std.mem.eql(u8, left.value, right.value)) return false;
    }
    return true;
}

fn labelSchemaEqual(a: []const Label, b: []const Label) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left.key, right.key)) return false;
    return true;
}

fn boundsEqual(a: []const f64, b: []const f64) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

/// Allocator-owned registry. Names and labels are copied on registration;
/// returned snapshots borrow the registry until the next snapshot/deinit.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    cardinality_limit: usize,
    instruments: std.ArrayListUnmanaged(Instrument) = .empty,
    mutex: std.Thread.Mutex = .{},
    snapshot_buckets: std.ArrayListUnmanaged(u64) = .empty,
    pub fn init(allocator: std.mem.Allocator, cardinality_limit: usize) Registry {
        return .{ .allocator = allocator, .cardinality_limit = cardinality_limit };
    }
    pub fn deinit(self: *Registry) void {
        for (self.instruments.items) |item| {
            self.allocator.free(item.name);
            for (item.labels) |label| {
                self.allocator.free(@constCast(label.key));
                self.allocator.free(@constCast(label.value));
            }
            self.allocator.free(item.labels);
            self.allocator.free(item.bounds);
            self.allocator.free(item.buckets);
        }
        self.instruments.deinit(self.allocator);
        self.snapshot_buckets.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *Registry, registration: Registration) Error!usize {
        if (registration.name.len == 0 or std.mem.indexOfScalar(u8, registration.name, ' ') != null) return error.InvalidName;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.instruments.items, 0..) |item, index| if (std.mem.eql(u8, item.name, registration.name)) {
            if (item.kind != registration.kind or !labelSchemaEqual(item.labels, registration.labels) or !boundsEqual(item.bounds, registration.histogram_bounds)) return error.Conflict;
            if (labelsEqual(item.labels, registration.labels)) return index;
        };
        if (self.instruments.items.len >= self.cardinality_limit) return error.CardinalityExceeded;
        const name = self.allocator.dupe(u8, registration.name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name);
        const labels = self.allocator.alloc(Label, registration.labels.len) catch return error.OutOfMemory;
        errdefer self.allocator.free(labels);
        var initialized_labels: usize = 0;
        errdefer for (labels[0..initialized_labels]) |label| {
            self.allocator.free(@constCast(label.key));
            self.allocator.free(@constCast(label.value));
        };
        for (registration.labels, 0..) |label, index| {
            const key = self.allocator.dupe(u8, label.key) catch return error.OutOfMemory;
            errdefer self.allocator.free(key);
            const value = self.allocator.dupe(u8, label.value) catch return error.OutOfMemory;
            labels[index] = .{ .key = key, .value = value };
            initialized_labels += 1;
        }
        const bounds = self.allocator.dupe(f64, registration.histogram_bounds) catch return error.OutOfMemory;
        errdefer self.allocator.free(bounds);
        for (bounds, 1..) |bound, i| if (bound <= bounds[i - 1]) return error.InvalidName;
        const buckets = self.allocator.alloc(std.atomic.Value(u64), bounds.len + 1) catch return error.OutOfMemory;
        for (buckets) |*bucket| bucket.* = std.atomic.Value(u64).init(0);
        errdefer self.allocator.free(buckets);
        self.instruments.append(self.allocator, .{ .name = name, .kind = registration.kind, .labels = labels, .bounds = bounds, .buckets = buckets }) catch return error.OutOfMemory;
        return self.instruments.items.len - 1;
    }
    fn get(self: *Registry, handle: usize, expected: Kind) Error!*Instrument {
        if (handle >= self.instruments.items.len) return error.NotFound;
        const item = &self.instruments.items[handle];
        if (item.kind != expected) return error.Conflict;
        return item;
    }
    pub fn add(self: *Registry, handle: usize, amount: i64) Error!void {
        const item = try self.get(handle, .counter);
        _ = item.value.fetchAdd(amount, .monotonic);
    }
    pub fn set(self: *Registry, handle: usize, value: i64) Error!void {
        const item = try self.get(handle, .gauge);
        item.value.store(value, .monotonic);
    }
    pub fn observe(self: *Registry, handle: usize, value: f64) Error!void {
        const item = try self.get(handle, .histogram);
        var index: usize = 0;
        while (index < item.bounds.len and value > item.bounds[index]) : (index += 1) {}
        _ = item.buckets[index].fetchAdd(1, .monotonic);
    }
    pub fn observeTimer(self: *Registry, handle: usize, start: time.MonotonicInstant, end: time.MonotonicInstant) Error!void {
        const item = try self.get(handle, .timer);
        _ = item.value.fetchAdd(@max(0, end.nanoseconds -| start.nanoseconds), .monotonic);
    }
    pub fn snapshot(self: *Registry, handle: usize) Error!Snapshot {
        const item = if (handle < self.instruments.items.len) &self.instruments.items[handle] else return error.NotFound;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot_buckets.clearRetainingCapacity();
        for (item.buckets) |bucket| self.snapshot_buckets.append(self.allocator, bucket.load(.monotonic)) catch return error.OutOfMemory;
        return .{ .name = item.name, .kind = item.kind, .labels = item.labels, .histogram_bounds = item.bounds, .value = item.value.load(.monotonic), .buckets = self.snapshot_buckets.items };
    }
};

pub const Noop = struct {
    pub fn register(_: *Noop, _: Registration) Error!usize {
        return 0;
    }
    pub fn add(_: *Noop, _: usize, _: i64) void {}
};

test "metrics register atomically update and snapshot" {
    var registry = Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const counter = try registry.register(.{ .name = "requests", .kind = .counter });
    try registry.add(counter, 4);
    try registry.add(counter, 2);
    try std.testing.expectEqual(@as(i64, 6), (try registry.snapshot(counter)).value);
    const histogram = try registry.register(.{ .name = "latency", .kind = .histogram, .histogram_bounds = &.{ 1, 10 } });
    try registry.observe(histogram, 1);
    try registry.observe(histogram, 11);
    const result = try registry.snapshot(histogram);
    try std.testing.expectEqualSlices(u64, &.{ 1, 0, 1 }, result.buckets);
}
test "metrics conflicts and cardinality are explicit" {
    var registry = Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    _ = try registry.register(.{ .name = "x", .kind = .counter });
    try std.testing.expectError(error.Conflict, registry.register(.{ .name = "x", .kind = .gauge }));
    try std.testing.expectError(error.CardinalityExceeded, registry.register(.{ .name = "y", .kind = .counter }));
}

test "metric identity includes copied labels and histogram bounds" {
    var registry = Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    var key = [_]u8{ 'r', 'o', 'u', 't', 'e' };
    var value = [_]u8{'a'};
    const handle = try registry.register(.{ .name = "latency", .kind = .histogram, .labels = &.{.{ .key = &key, .value = &value }}, .histogram_bounds = &.{ 1, 2 } });
    key[0] = 'X';
    value[0] = 'X';
    const snapshot_value = try registry.snapshot(handle);
    try std.testing.expectEqualStrings("route", snapshot_value.labels[0].key);
    try std.testing.expectEqualStrings("a", snapshot_value.labels[0].value);
    try std.testing.expectEqual(handle, try registry.register(.{ .name = "latency", .kind = .histogram, .labels = &.{.{ .key = "route", .value = "a" }}, .histogram_bounds = &.{ 1, 2 } }));
    const second = try registry.register(.{ .name = "latency", .kind = .histogram, .labels = &.{.{ .key = "route", .value = "b" }}, .histogram_bounds = &.{ 1, 2 } });
    try std.testing.expect(second != handle);
    try std.testing.expectError(error.Conflict, registry.register(.{ .name = "latency", .kind = .histogram, .labels = &.{.{ .key = "route", .value = "a" }}, .histogram_bounds = &.{ 1, 3 } }));
    try std.testing.expectError(error.Conflict, registry.register(.{ .name = "latency", .kind = .histogram, .labels = &.{.{ .key = "endpoint", .value = "a" }}, .histogram_bounds = &.{ 1, 2 } }));
}

test "metric registration rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var registry = Registry.init(allocator, 4);
            defer registry.deinit();
            _ = try registry.register(.{
                .name = "latency",
                .kind = .histogram,
                .labels = &.{ .{ .key = "route", .value = "/fixture" }, .{ .key = "method", .value = "GET" } },
                .histogram_bounds = &.{ 1, 5, 10 },
            });
        }
    }.run, .{});
}
