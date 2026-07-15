# Foundation task index

Use [`setup.md`](setup.md) together with exactly one task document. The numeric order is a convenient delivery order; the dependency lists are authoritative.

| ID | Task | Depends on |
| --- | --- | --- |
| 00 | [Bootstrap, governance, and build skeleton](00-bootstrap-governance.md) | None |
| 01 | [Base types, errors, and clocks](01-base-error-time.md) | 00 |
| 02 | [Strong IDs and stable handles](02-ids-handles.md) | 00, 01 |
| 03 | [Memory conventions and SharedBuffer](03-shared-buffer.md) | 00, 01 |
| 04 | [Cancellation and shutdown](04-cancellation-shutdown.md) | 01, 02, 03 |
| 05 | [Future, operation, and executor contracts](05-async-executor.md) | 01-04 |
| 06 | [Bounded channels and mailboxes](06-channels-mailboxes.md) | 02, 04, 05 |
| 07 | [C ABI and plugin boundary](07-cabi-plugin.md) | 01-05 |
| 08 | [Filesystem facade and standard backends](08-filesystem.md) | 01-05 |
| 09 | [Process facade and native backend](09-process.md) | 01, 03-05 |
| 10 | [JSON codecs, views, and schema subset](10-json-schema.md) | 00, 01, 03 |
| 11 | [HTTP facade, SSE, and curl adapter](11-http-curl-sse.md) | 01, 03-05 |
| 12 | [Compression and content hashing](12-compression-hash.md) | 01, 03, 08 |
| 13 | [SQLite adapter](13-sqlite.md) | 01, 03-05 |
| 14 | [Logging, metrics, and performance trace](14-observability.md) | 01, 03-06, 08 |
| 15 | [libuv tooling, file watch, and IPC adapters](15-libuv-tooling.md) | 04, 05, 08, 09, 11 |
| 16 | [Deterministic testing and fault injection](16-testing-faults.md) | 01-15 |
| 17 | [Build profiles, CI, and acceptance integration](17-profiles-ci-acceptance.md) | 07, 08, 10-16 |
| 18 | [Evidence-gated platform optimization](18-platform-optimization-gate.md) | 17 |
| 19 | [Platform runtime acceptance closure](19-platform-runtime-acceptance.md) | 09, 11, 15, 17, 18 |
