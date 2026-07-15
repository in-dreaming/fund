# Task 12: Compression and content hashing

## Objective

Define compression and streaming-hash facades and integrate zstd, LZ4, and BLAKE3 as optional, auditable adapters.

## Rationale

Foundation should unify buffers, errors, versions, streaming, and feature selection while relying on mature libraries for algorithms and SIMD. Content-addressed assets also require a stable, versioned hash representation.

## Design

`Compressor` uses an opaque pointer/vtable and supports bound calculation, one-shot and streaming compress/decompress, level, optional dictionary, checksum policy, cancellation checkpoints, and output limits. zstd is the general default; LZ4 is selected for very fast decompression. Algorithms/formats are explicit in stored metadata.

`ContentHash` stores algorithm/version plus digest bytes and has canonical binary and lowercase textual forms. A streaming hasher supports update/finalize and file hashing through the filesystem facade. BLAKE3 is the content default; do not use content hashes as authentication unless a security protocol explicitly selects an appropriate primitive.

## Implementation scope

- Define compressor and hasher facades, options, stream state/lifecycle, output sizing/limits, and error mapping.
- Integrate pinned zstd, LZ4, and BLAKE3 libraries in separate adapters with manifests/licenses.
- Implement `ContentHash` equality, parse/format, versioning, serialization, and file hashing.
- Provide deterministic mock/pass-through adapters only where useful for conformance tests; never label them as real compression/hash.
- Keep each dependency individually feature-gated.

Do not implement compression algorithms, BLAKE3 SIMD, or replace Zig's HashMap hash.

## Dependencies

- Task 01.
- Task 03.
- Task 08.

## Completion checks

- Official known-answer vectors pass for zstd, LZ4, and BLAKE3, including streaming split points and empty input.
- Tests cover corrupt/truncated data, wrong dictionary/algorithm/version, decompression bomb limits, bound overflow, allocation failure, cancellation checkpoints, and canonical hash parsing.
- File and memory hashing match and partial-read injection is handled correctly.
- Each adapter disappears from build/link output when disabled, and all dependency governance checks pass.
