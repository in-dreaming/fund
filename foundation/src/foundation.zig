//! Foundation public Zig module root.
//! Ownership and ABI contracts are documented in `docs/architecture.md`.

pub const build_options = @import("build_options");
pub const errors = @import("error/error.zig");
pub const time = @import("time/time.zig");

test "foundation module loads" {
    _ = build_options.profile;
}
