//! Foundation public Zig module root.
//! Ownership and ABI contracts are documented in `docs/architecture.md`.

pub const build_options = @import("build_options");

test "foundation module loads" {
    _ = build_options.profile;
}
