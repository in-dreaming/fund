const cabi = @import("foundation").cabi;

fn start(_: ?*const anyopaque) callconv(.c) cabi.ErrorCode {
    return .ok;
}
fn stop() callconv(.c) void {}
const descriptor = cabi.PluginDescriptor{
    .struct_size = @sizeOf(cabi.PluginDescriptor),
    .struct_version = 1,
    .abi_version_ = cabi.abi_version,
    .feature_bits = 1,
    .build_id = .{ .data = "fixture".ptr, .length = "fixture".len },
    .start = start,
    .stop = stop,
};
pub export fn fd_plugin_get_descriptor() callconv(.c) *const cabi.PluginDescriptor {
    return &descriptor;
}
