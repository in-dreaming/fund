const std = @import("std");
const foundation = @import("foundation");

pub fn main() !void {
    var clock = foundation.time.ManualClock{};
    var shutdown = foundation.shutdown.ShutdownCoordinator.init(std.heap.page_allocator);
    defer shutdown.deinit();
    _ = try shutdown.run(clock.clock(), .graceful, clock.clock().monotonicNow().after(.milliseconds(1)));
}
