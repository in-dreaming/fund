const std = @import("std");
const foundation = @import("foundation");

pub fn main() !void {
    var queue = foundation.executor.MainThreadQueue.init(std.heap.page_allocator);
    defer queue.deinit();
    queue.close();
}
