const std = @import("std");
const foundation = @import("foundation");

pub fn main() !void {
    var source = try foundation.cancellation.CancellationSource.init(std.heap.page_allocator);
    defer source.deinit();
    var queue = foundation.executor.MainThreadQueue.init(std.heap.page_allocator);
    defer queue.deinit();
    _ = source.cancel(.shutdown);
    _ = queue.pump();
}
