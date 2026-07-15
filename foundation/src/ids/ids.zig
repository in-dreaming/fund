const std = @import("std");
const builtin = @import("builtin");

/// A distinct integer-backed identifier. `Tag` gives each ID domain a unique type.
/// Values are plain integers: use `toInt` and `fromInt` for explicit serialization.
pub fn IntegerId(comptime Tag: type, comptime Int: type) type {
    comptime {
        if (@typeInfo(Int) != .int) @compileError("IntegerId requires an integer backing type");
    }

    return struct {
        value: Int,

        pub const tag = Tag;
        pub const Backing = Int;

        pub fn init(value: Int) @This() {
            return .{ .value = value };
        }
        pub fn toInt(self: @This()) Int {
            return self.value;
        }
        pub fn fromInt(value: Int) @This() {
            return .init(value);
        }
    };
}

/// A distinct fixed-byte identifier. The byte array is the serialized form.
pub fn ByteId(comptime Tag: type, comptime length: usize) type {
    return struct {
        bytes: [length]u8,

        pub const tag = Tag;
        pub const byte_length = length;

        pub fn init(bytes: [length]u8) @This() {
            return .{ .bytes = bytes };
        }
        pub fn toBytes(self: @This()) [length]u8 {
            return self.bytes;
        }
        pub fn fromBytes(bytes: [length]u8) @This() {
            return .init(bytes);
        }
    };
}

fn typeTag(comptime Tag: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(Tag));
}

/// A generation-checked handle. It packs a 32-bit slot index and generation into
/// a C-compatible `u64`. Generation zero is reserved, so raw value zero is null.
pub fn Handle(comptime Tag: type) type {
    return struct {
        raw: u64 = 0,
        debug_tag: if (builtin.mode == .Debug) u64 else void = if (builtin.mode == .Debug) typeTag(Tag) else {},

        pub const tag = Tag;
        pub const null_handle: @This() = .{};

        pub fn init(slot_index: u32, slot_generation: u32) @This() {
            if (slot_generation == 0) return .null_handle;
            return .{ .raw = (@as(u64, slot_generation) << 32) | slot_index };
        }
        pub fn fromU64(raw: u64) @This() {
            if ((raw >> 32) == 0) return .null_handle;
            return .{ .raw = raw };
        }
        pub fn toU64(self: @This()) u64 {
            return self.raw;
        }
        pub fn index(self: @This()) u32 {
            return @truncate(self.raw);
        }
        pub fn generation(self: @This()) u32 {
            return @truncate(self.raw >> 32);
        }
        pub fn isValid(self: @This()) bool {
            return self.generation() != 0 and (builtin.mode != .Debug or self.debug_tag == typeTag(Tag));
        }
    };
}

/// C ABI helper. Exported `fd_` functions are deliberately deferred to Task 07.
pub fn handleToC(handle: anytype) u64 {
    return handle.toU64();
}

/// An allocator-owned, non-concurrent table of handle-owned values.
///
/// `get` and `getConst` return borrowed pointers. Any call to `insert` or
/// `reserve` may relocate storage and invalidate all returned pointers. `remove`
/// invalidates the removed value's pointer immediately. Mutating a value through
/// `get` does not alter its handle. `deinit` frees table storage but does not call
/// a destructor for `T`; callers must release resources owned by stored values.
/// A removed handle is permanently stale. A slot whose generation reaches
/// `u32::max` is retired instead of recycled, preventing generation wraparound.
pub fn HandleTable(comptime T: type, comptime Tag: type) type {
    const H = Handle(Tag);
    return struct {
        const Self = @This();
        const Slot = struct {
            generation: u32 = 1,
            occupied: bool = false,
            retired: bool = false,
            next_free: ?u32 = null,
            value: T = undefined,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: ?u32 = null,
        count: usize = 0,

        pub const HandleType = H;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn capacity(self: *const Self) usize {
            return self.slots.capacity;
        }
        pub fn len(self: *const Self) usize {
            return self.count;
        }
        pub fn reserve(self: *Self, additional: usize) !void {
            try self.slots.ensureUnusedCapacity(self.allocator, additional);
        }
        pub fn insert(self: *Self, value: T) !H {
            if (self.free_head) |index| {
                const slot = &self.slots.items[index];
                self.free_head = slot.next_free;
                slot.next_free = null;
                slot.occupied = true;
                slot.value = value;
                self.count += 1;
                return H.init(index, slot.generation);
            }

            if (self.slots.items.len > std.math.maxInt(u32)) return error.OutOfMemory;
            try self.slots.append(self.allocator, .{ .value = value, .occupied = true });
            self.count += 1;
            return H.init(@intCast(self.slots.items.len - 1), 1);
        }
        pub fn get(self: *Self, handle: H) ?*T {
            const slot = self.slotFor(handle) orelse return null;
            return &slot.value;
        }
        pub fn getConst(self: *const Self, handle: H) ?*const T {
            const slot = self.slotForConst(handle) orelse return null;
            return &slot.value;
        }
        /// Removes a value and transfers it to the caller. The caller owns it.
        pub fn remove(self: *Self, handle: H) ?T {
            const slot = self.slotFor(handle) orelse return null;
            const value = slot.value;
            slot.occupied = false;
            self.count -= 1;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.retired = true;
                slot.next_free = null;
            } else {
                slot.generation += 1;
                const index = handle.index();
                slot.next_free = self.free_head;
                self.free_head = index;
            }
            return value;
        }
        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self };
        }

        pub const Iterator = struct {
            table: *Self,
            index: usize = 0,

            /// The returned pointer obeys the table's normal pointer invalidation rules.
            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.table.slots.items.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.table.slots.items[index];
                    if (slot.occupied) return .{ .handle = H.init(@intCast(index), slot.generation), .value = &slot.value };
                }
                return null;
            }
        };
        pub const Entry = struct { handle: H, value: *T };

        fn slotFor(self: *Self, handle: H) ?*Slot {
            if (!handle.isValid()) return null;
            const index: usize = handle.index();
            if (index >= self.slots.items.len) return null;
            const slot = &self.slots.items[index];
            if (!slot.occupied or slot.generation != handle.generation()) return null;
            return slot;
        }
        fn slotForConst(self: *const Self, handle: H) ?*const Slot {
            if (!handle.isValid()) return null;
            const index: usize = handle.index();
            if (index >= self.slots.items.len) return null;
            const slot = &self.slots.items[index];
            if (!slot.occupied or slot.generation != handle.generation()) return null;
            return slot;
        }
    };
}

test "strong IDs are distinct zero-cost types" {
    const UserId = IntegerId(struct {
        const name = "user";
    }, u64);
    const JobId = IntegerId(struct {
        const name = "job";
    }, u64);
    const TokenId = ByteId(struct {
        const name = "token";
    }, 4);
    const user = UserId.fromInt(7);
    const job = JobId.fromInt(7);
    try std.testing.expect(@TypeOf(user) != @TypeOf(job));
    try std.testing.expectEqual(@as(u64, 7), user.toInt());
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, TokenId.fromBytes(.{ 1, 2, 3, 4 }).toBytes());
}

test "handles pack boundary values and reject null generation" {
    const H = Handle(struct {
        const name = "test";
    });
    const values = [_]struct { index: u32, generation: u32 }{
        .{ .index = 0, .generation = 1 },
        .{ .index = std.math.maxInt(u32), .generation = 1 },
        .{ .index = 0, .generation = std.math.maxInt(u32) },
        .{ .index = std.math.maxInt(u32), .generation = std.math.maxInt(u32) },
    };
    for (values) |value| {
        const handle = H.init(value.index, value.generation);
        const decoded = H.fromU64(handleToC(handle));
        try std.testing.expect(decoded.isValid());
        try std.testing.expectEqual(value.index, decoded.index());
        try std.testing.expectEqual(value.generation, decoded.generation());
    }
    try std.testing.expect(!H.init(4, 0).isValid());
    try std.testing.expect(!H.fromU64(0).isValid());
}

test "handle table rejects stale and invalid handles and reuses slots" {
    const Table = HandleTable(u32, struct {
        const name = "items";
    });
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 0), table.len());
    try table.reserve(2);
    try std.testing.expect(table.capacity() >= 2);
    const first = try table.insert(11);
    try std.testing.expectEqual(@as(u32, 11), table.get(first).?.*);
    try std.testing.expectEqual(@as(?u32, 11), table.remove(first));
    try std.testing.expect(table.get(first) == null);
    try std.testing.expect(table.remove(first) == null);
    try std.testing.expect(table.get(Table.HandleType.init(99, 1)) == null);
    const second = try table.insert(22);
    try std.testing.expectEqual(first.index(), second.index());
    try std.testing.expect(second.generation() != first.generation());
    try std.testing.expectEqual(@as(u32, 22), table.getConst(second).?.*);
}

test "handle table iteration and generation retirement" {
    const Table = HandleTable(u8, struct {
        const name = "retired";
    });
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    const first = try table.insert(3);
    table.slots.items[first.index()].generation = std.math.maxInt(u32);
    const final_generation = Table.HandleType.init(first.index(), std.math.maxInt(u32));
    try std.testing.expectEqual(@as(?u8, 3), table.remove(final_generation));
    const second = try table.insert(4);
    try std.testing.expect(second.index() != first.index());
    var iterator = table.iterator();
    const entry = iterator.next().?;
    try std.testing.expectEqual(@as(u8, 4), entry.value.*);
    try std.testing.expect(iterator.next() == null);
}

test "handle table reports allocation failure without leaking" {
    const Table = HandleTable(u32, struct {
        const name = "allocation";
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var table = Table.init(failing.allocator());
    defer table.deinit();
    try std.testing.expectError(error.OutOfMemory, table.insert(1));
    try std.testing.expectEqual(@as(usize, 0), table.len());
}
