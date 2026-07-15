# Task 00: Bootstrap, governance, and build skeleton

## Objective

Create the compilable Foundation project skeleton, pin the Zig toolchain, establish feature/module boundaries, and make third-party dependencies auditable before product code is added.

## Rationale

Build boundaries and dependency rules are architectural behavior. Establishing them first prevents optional libraries from leaking into core and gives every later task one reproducible toolchain and dependency intake path.

## Design

Use a minimal `foundation` package whose default build contains only an empty/stub public root and tests. Define named build options for `core`, `game`, `agent`, `tooling`, and `server`, plus individual optional capabilities. Profiles select capabilities; capability modules must not infer a profile.

Pin one stable Zig release supported by the environment. Record the exact version in a toolchain file and CI; do not use an unbounded minimum. Establish machine-readable dependency manifests and a validation step that rejects missing required fields, floating refs, absent license files, or patches not referenced by a manifest.

## Implementation scope

- Create the repository shape required by `setup.md`, but add placeholder files only where Zig/build tooling requires them.
- Add `foundation/build.zig`, `build.zig.zon`, a public Zig module root, an empty C header with include guards, and a smoke test.
- Define build options/features without downloading optional dependencies. The default and `core` graphs must contain no optional vendor library.
- Add the pinned Zig version declaration and developer commands to `foundation/README.md`.
- Add dependency manifest schema/template, license/patch directories, and a validator callable from `zig build dependency-check`.
- Add initial architecture-boundary documentation: ownership classes, stable error mapping rules, C ABI rules, callback contract template, and allowed dependency directions.
- Add CI that checks formatting, dependency manifests, default/core build and tests, and C header syntax on supported host runners.
- Add a source-level boundary check that detects vendor headers/imports outside their matching adapter directory. Make its allowlist explicit and reviewed in source control.

Do not integrate a third-party library or implement runtime facilities in this task.

## Dependencies

None.

## Completion checks

- The pinned Zig version is exact and used by CI documentation/configuration.
- `zig build`, `zig build test`, and `zig build dependency-check` pass from `foundation/`.
- A deliberately invalid manifest fixture is rejected by a validator test.
- Default/core dependency inspection shows no curl, libuv, yyjson, SQLite, zstd, LZ4, BLAKE3, Tracy, mimalloc, or Mbed TLS linkage.
- The boundary check has both a passing fixture and a test proving a forbidden vendor import is detected.
- CI configuration invokes the same commands documented for local use.

