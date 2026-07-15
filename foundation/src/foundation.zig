//! Foundation public Zig module root.
//! Ownership and ABI contracts are documented in `docs/architecture.md`.
const builtin = @import("builtin");

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
pub const json = if (build_options.json) @import("serialization/json.zig") else struct {};
pub const compression = if (build_options.compression) @import("compression/compression.zig") else struct {};
pub const hash = if (build_options.hash) @import("hash/hash.zig") else struct {};
pub const logging = if (build_options.logging) @import("logging/logging.zig") else struct {};
pub const metrics = if (build_options.metrics) @import("metrics/metrics.zig") else struct {};
pub const trace = if (build_options.trace) @import("trace/trace.zig") else struct {};
pub const http = if (build_options.http) @import("network/http.zig") else struct {};
pub const sse = if (build_options.http) @import("network/sse.zig") else struct {};
/// SQLite database capability. Disabled builds contain no SQLite source or link input.
pub const database = if (build_options.database) @import("sqlite_adapter") else struct {};
/// Optional owner-pumped libuv adapter. It is absent unless built with `-Dlibuv`.
pub const libuv = if (build_options.libuv) @import("event_loop_adapter") else struct {};
/// Deterministic test infrastructure. This is compiled for `zig test` and is
/// absent from non-test artifacts unless built with `-Dtesting=true`.
pub const testing = if (builtin.is_test or build_options.testing) @import("testing/testing.zig") else struct {};

// Keep C exports reachable when Foundation is built as a static library.
comptime {
    _ = cabi;
}

test "foundation module loads" {
    _ = build_options.profile;
}
