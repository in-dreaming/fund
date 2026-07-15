const std = @import("std");
const foundation = @import("foundation");

pub fn main() !void {
    var queue = foundation.executor.MainThreadQueue.init(std.heap.page_allocator);
    defer queue.deinit();
    var clock = foundation.time.GameClock{};
    var shutdown = foundation.shutdown.ShutdownCoordinator.init(std.heap.page_allocator);
    defer shutdown.deinit();
    _ = queue.pump();
    _ = try shutdown.run(clock.clock(), .graceful, clock.clock().monotonicNow().after(.milliseconds(1)));
}
