# Foundation

Foundation is the reusable Zig/C runtime layer described by this repository.

## Toolchain

This project is pinned to Zig `0.16.0`. Install that exact release before building.

## Commands

Run these commands from this directory:

```powershell
zig fmt --check build.zig src adapters tests examples tools
zig build
zig build test
zig build dependency-check
zig build boundary-check
zig build check
```

The default profile is `core`. Profiles are selected with `-Dprofile=core|game|agent|tooling|server`; individual capabilities are explicit opt-ins (`-Dhttp`, `-Ddatabase`, `-Dcompression`, `-Dprofiler`, and `-Dprocess`). This bootstrap does not download, compile, or link optional vendors.
