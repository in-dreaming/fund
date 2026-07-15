const std = @import("std");
const foundation = @import("foundation");

pub fn main() !void {
    var source = try foundation.cancellation.CancellationSource.init(std.heap.page_allocator);
    defer source.deinit();
    _ = source.cancel(.requested);
}
