//! Foundation public Zig module root.
//! Ownership and ABI contracts are documented in `docs/architecture.md`.

pub const build_options = @import("build_options");
pub const errors = @import("error/error.zig");
pub const ids = @import("ids/ids.zig");
pub const memory = @import("memory/shared_buffer.zig");
pub const time = @import("time/time.zig");
pub const cancellation = @import("async/cancellation.zig");
pub const shutdown = @import("async/shutdown.zig");
pub const executor = @import("executor/executor.zig");
pub const future = @import("async/future.zig");
pub const operation = @import("async/operation.zig");
pub const channel = @import("channel/channel.zig");
pub const cabi = @import("cabi/cabi.zig");
pub const plugin = @import("plugin/plugin.zig");
pub const filesystem = if (build_options.filesystem) @import("filesystem/filesystem.zig") else struct {};
pub const process = if (build_options.process) @import("process/process.zig") else struct {};
pub const json = @import("serialization/json.zig");

// Keep C exports reachable when Foundation is built as a static library.
comptime {
    _ = cabi;
}

test "foundation module loads" {
    _ = build_options.profile;
}
