const std = @import("std");

/// Classification for diagnostics and optional allocation accounting. It does not
/// select an allocator or change the ownership contract.
pub const MemoryTag = enum(u16) {
    general,
    io,
    network,
    serialization,
    c_abi,
    @"test",
};

pub const DebugMetadata = struct {
    label: []const u8 = "",
    allocation_id: u64 = 0,
};

pub const Mutability = enum { read_only, mutable };

/// Optional byte budget shared by allocations. Callers own the budget and must
/// keep it alive until every buffer using it has been released.
pub const AllocationBudget = struct {
    limit: usize,
    used: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(limit: usize) AllocationBudget {
        return .{ .limit = limit };
    }

    pub fn reserve(self: *AllocationBudget, amount: usize) error{BudgetExceeded}!void {
        var current = self.used.load(.acquire);
        while (true) {
            if (amount > self.limit -| current) return error.BudgetExceeded;
            if (self.used.cmpxchgWeak(current, current + amount, .acq_rel, .acquire) == null) return;
            current = self.used.load(.acquire);
        }
    }

    pub fn release(self: *AllocationBudget, amount: usize) void {
        const previous = self.used.fetchSub(amount, .acq_rel);
        std.debug.assert(previous >= amount);
    }

    pub fn bytesUsed(self: *const AllocationBudget) usize {
        return self.used.load(.acquire);
    }
};

/// Invoked exactly once, synchronously on the thread that releases the final
/// `SharedBuffer` reference. `bytes` is valid only for the duration of the call.
pub const ReleaseCallback = *const fn (userdata: ?*anyopaque, bytes: []u8) void;

const Storage = struct {
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    bytes: []u8,
    mutability: Mutability,
    tag: MemoryTag,
    debug: DebugMetadata,
    release_callback: ?ReleaseCallback,
    release_userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
    budget: ?*AllocationBudget,

    fn retain(self: *Storage) void {
        const previous = self.references.fetchAdd(1, .acq_rel);
        std.debug.assert(previous != std.math.maxInt(u32));
    }

    fn release(self: *Storage) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;

        if (self.budget) |budget| budget.release(self.bytes.len);
        if (self.release_callback) |callback| {
            callback(self.release_userdata, self.bytes);
        } else {
            self.allocator.free(self.bytes);
        }
        self.allocator.destroy(self);
    }
};

/// Reference-counted byte storage. `bytes` and `mutableBytes` return borrowed
/// slices that become invalid when this buffer is released. `clone` creates a
/// shared owner; each owner must call `release` exactly once. No constructor
/// accepts borrowed data because borrowed memory cannot safely escape as shared
/// ownership.
pub const SharedBuffer = struct {
    storage: ?*Storage,
    offset: usize,
    length: usize,

    /// Allocator-owned copy. The buffer owns the copied allocation and releases
    /// it with `allocator` after the final reference is released.
    pub fn initCopy(allocator: std.mem.Allocator, source: []const u8, tag: MemoryTag) !SharedBuffer {
        return initCopyWithBudget(allocator, source, tag, null, .{});
    }

    /// As `initCopy`, additionally reserving `source.len` bytes from `budget`.
    pub fn initCopyWithBudget(allocator: std.mem.Allocator, source: []const u8, tag: MemoryTag, budget: ?*AllocationBudget, debug: DebugMetadata) !SharedBuffer {
        if (budget) |value| try value.reserve(source.len);
        errdefer if (budget) |value| value.release(source.len);
        const copied_bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(copied_bytes);
        return initStorage(allocator, copied_bytes, .mutable, tag, debug, null, null, budget);
    }

    /// Adopts externally allocated `bytes`. On allocation failure, `callback`
    /// is invoked synchronously to return the external memory. On final release,
    /// it is invoked exactly once on the final releaser's thread.
    pub fn adopt(allocator: std.mem.Allocator, storage_bytes: []u8, mutability: Mutability, tag: MemoryTag, callback: ReleaseCallback, userdata: ?*anyopaque, budget: ?*AllocationBudget, debug: DebugMetadata) !SharedBuffer {
        if (budget) |value| value.reserve(storage_bytes.len) catch |err| {
            callback(userdata, storage_bytes);
            return err;
        };
        errdefer if (budget) |value| value.release(storage_bytes.len);
        return initStorage(allocator, storage_bytes, mutability, tag, debug, callback, userdata, budget) catch |err| {
            callback(userdata, storage_bytes);
            return err;
        };
    }

    fn initStorage(allocator: std.mem.Allocator, storage_bytes: []u8, mutability: Mutability, tag: MemoryTag, debug: DebugMetadata, callback: ?ReleaseCallback, userdata: ?*anyopaque, budget: ?*AllocationBudget) !SharedBuffer {
        const storage = try allocator.create(Storage);
        storage.* = .{ .bytes = storage_bytes, .mutability = mutability, .tag = tag, .debug = debug, .release_callback = callback, .release_userdata = userdata, .allocator = allocator, .budget = budget };
        return .{ .storage = storage, .offset = 0, .length = storage_bytes.len };
    }

    /// Creates another shared owner. The returned buffer must be released once.
    pub fn clone(self: SharedBuffer) error{Released}!SharedBuffer {
        const storage = self.storage orelse return error.Released;
        storage.retain();
        return self;
    }

    /// Releases this owner. It is idempotent for convenience during error paths.
    pub fn release(self: *SharedBuffer) void {
        const storage = self.storage orelse return;
        self.storage = null;
        self.offset = 0;
        self.length = 0;
        storage.release();
    }

    /// Borrowed immutable view valid until this owner is released.
    pub fn bytes(self: SharedBuffer) error{Released}![]const u8 {
        const storage = self.storage orelse return error.Released;
        return storage.bytes[self.offset .. self.offset + self.length];
    }

    /// Borrowed mutable view valid until this owner is released. Read-only
    /// adopted storage rejects mutation even through slices.
    pub fn mutableBytes(self: SharedBuffer) error{ Released, ReadOnly }![]u8 {
        const storage = self.storage orelse return error.Released;
        if (storage.mutability == .read_only) return error.ReadOnly;
        return storage.bytes[self.offset .. self.offset + self.length];
    }

    /// Creates a checked shared sub-slice. The returned owner must be released.
    pub fn subSlice(self: SharedBuffer, offset: usize, length: usize) error{ Released, OutOfBounds }!SharedBuffer {
        const storage = self.storage orelse return error.Released;
        if (offset > self.length or length > self.length - offset) return error.OutOfBounds;
        storage.retain();
        return .{ .storage = storage, .offset = self.offset + offset, .length = length };
    }

    pub fn memoryTag(self: SharedBuffer) error{Released}!MemoryTag {
        return (self.storage orelse return error.Released).tag;
    }
};

test "nested slices invoke an external callback once" {
    const Probe = struct {
        releases: usize = 0,
        fn release(context: ?*anyopaque, bytes: []u8) void {
            const probe: *@This() = @ptrCast(@alignCast(context.?));
            probe.releases += 1;
            std.testing.allocator.free(bytes);
        }
    };
    var probe = Probe{};
    const input = try std.testing.allocator.dupe(u8, "abcdef");
    var buffer = try SharedBuffer.adopt(std.testing.allocator, input, .read_only, .network, Probe.release, &probe, null, .{});
    var clone = try buffer.clone();
    var slice = try clone.subSlice(1, 4);
    var nested = try slice.subSlice(1, 2);
    try std.testing.expectEqualStrings("cd", try nested.bytes());
    nested.release();
    buffer.release();
    slice.release();
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    clone.release();
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
}

test "zero length bounds and read-only policy" {
    var buffer = try SharedBuffer.initCopy(std.testing.allocator, "", .general);
    defer buffer.release();
    var empty = try buffer.subSlice(0, 0);
    defer empty.release();
    try std.testing.expectEqual(@as(usize, 0), (try empty.bytes()).len);
    try std.testing.expectError(error.OutOfBounds, buffer.subSlice(1, 0));

    const Probe = struct {
        fn release(_: ?*anyopaque, bytes: []u8) void {
            std.testing.allocator.free(bytes);
        }
    };
    const input = try std.testing.allocator.dupe(u8, "r");
    var read_only = try SharedBuffer.adopt(std.testing.allocator, input, .read_only, .@"test", Probe.release, null, null, .{});
    defer read_only.release();
    try std.testing.expectError(error.ReadOnly, read_only.mutableBytes());
}

test "allocation failure releases adopted memory and budget" {
    const Probe = struct {
        calls: usize = 0,
        fn release(context: ?*anyopaque, bytes: []u8) void {
            const probe: *@This() = @ptrCast(@alignCast(context.?));
            probe.calls += 1;
            std.testing.allocator.free(bytes);
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var probe = Probe{};
    var budget = AllocationBudget.init(4);
    const input = try std.testing.allocator.dupe(u8, "data");
    try std.testing.expectError(error.OutOfMemory, SharedBuffer.adopt(failing.allocator(), input, .mutable, .@"test", Probe.release, &probe, &budget, .{}));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), budget.bytesUsed());
}

test "budget exhaustion and release accounting" {
    var budget = AllocationBudget.init(3);
    try std.testing.expectError(error.BudgetExceeded, SharedBuffer.initCopyWithBudget(std.testing.allocator, "four", .general, &budget, .{}));
    var buffer = try SharedBuffer.initCopyWithBudget(std.testing.allocator, "abc", .general, &budget, .{});
    try std.testing.expectEqual(@as(usize, 3), budget.bytesUsed());
    buffer.release();
    try std.testing.expectEqual(@as(usize, 0), budget.bytesUsed());
}

test "budget rejection returns adopted storage" {
    const Probe = struct {
        calls: usize = 0,
        fn release(context: ?*anyopaque, bytes: []u8) void {
            const probe: *@This() = @ptrCast(@alignCast(context.?));
            probe.calls += 1;
            std.testing.allocator.free(bytes);
        }
    };
    var probe = Probe{};
    var budget = AllocationBudget.init(0);
    const input = try std.testing.allocator.dupe(u8, "x");
    try std.testing.expectError(error.BudgetExceeded, SharedBuffer.adopt(std.testing.allocator, input, .mutable, .@"test", Probe.release, &probe, &budget, .{}));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "concurrent retained owners release once" {
    const Probe = struct {
        calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        fn release(context: ?*anyopaque, bytes: []u8) void {
            const probe: *@This() = @ptrCast(@alignCast(context.?));
            _ = probe.calls.fetchAdd(1, .acq_rel);
            std.testing.allocator.free(bytes);
        }
        fn worker(buffer: SharedBuffer) void {
            var owned = buffer;
            owned.release();
        }
    };
    var probe = Probe{};
    const input = try std.testing.allocator.dupe(u8, "stress");
    var root = try SharedBuffer.adopt(std.testing.allocator, input, .mutable, .@"test", Probe.release, &probe, null, .{});
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Probe.worker, .{try root.clone()});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), probe.calls.load(.acquire));
    root.release();
    try std.testing.expectEqual(@as(usize, 1), probe.calls.load(.acquire));
}
