const std = @import("std");
const foundation = @import("foundation");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableArgument;
    const path = args.next() orelse return error.MissingPluginArgument;

    if (foundation.plugin.Plugin.load(path, 2)) |_| return error.ExpectedFeatureFailure else |err| if (err != error.InvalidDescriptor) return err;
    var plugin = try foundation.plugin.Plugin.load(path, 1);
    var host_context: usize = 42;
    try plugin.start(&host_context);
    if (plugin.start(null)) |_| return error.ExpectedStartFailure else |err| if (err != error.InvalidState) return err;
    var lease = try plugin.acquire();
    if (plugin.unload()) |_| return error.ExpectedBusy else |err| if (err != error.Busy) return err;
    lease.release();
    try plugin.stop();
    if (plugin.stop()) |_| return error.ExpectedStopFailure else |err| if (err != error.InvalidState) return err;
    try plugin.unload();
    if (plugin.start(null)) |_| return error.ExpectedUnloadedStartFailure else |err| if (err != error.InvalidState) return err;
    if (plugin.acquire()) |_| return error.ExpectedUnloadedAcquireFailure else |err| if (err != error.InvalidState) return err;
    if (plugin.unload()) |_| return error.ExpectedRepeatedUnloadFailure else |err| if (err != error.InvalidState) return err;
}
