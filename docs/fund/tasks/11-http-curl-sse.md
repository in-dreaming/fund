# Task 11: HTTP facade, SSE, and curl adapter

## Objective

Implement the HTTP client facade, deterministic mock backend, production libcurl adapter, TLS configuration mapping, and incremental SSE parser.

## Rationale

Agent/tools/server consumers need HTTP with consistent ownership, cancellation, limits, errors, metrics, trace hooks, and callback threads. libcurl should own protocol/TLS complexity; Foundation owns the stable semantic boundary.

## Design

`HttpClient.start(request, options)` returns an operation. Requests cover URL, method, ordered headers, optional streaming/body source, timeout, response-body limit, redirect/proxy/TLS policy, cancellation, and chosen executor. Responses expose status, headers, and bounded `SharedBuffer` or streaming chunks. Backend callbacks never directly enter business code.

The curl adapter is the sole libcurl integration and maps native codes without losing them. Use system TLS by default and unify trust store, certificate paths/client certificate references, verification, sensitive-data cleanup, and test-only trust configuration. Never log credentials or private key data.

SSE is a standalone incremental parser over arbitrary byte chunks. It implements event/data/id/retry/comment and line-ending rules, bounded field/event sizes, UTF-8 policy, and end-of-stream behavior; it does not perform HTTP.

## Implementation scope

- Define HTTP/TLS types, facade/vtable, request/response ownership, stream backpressure, limits, and observability hooks.
- Implement mock backend with scripted responses, delays, errors, chunks, cancellation races, and executor delivery.
- Integrate pinned libcurl with dependency manifest/license and loopback-server tests; no public-internet tests.
- Map timeout/cancel/errors, ensure request resources survive until backend completion, and register shutdown behavior.
- Implement and fuzz/test the incremental SSE parser independently.

Do not implement HTTP, TLS, proxy, certificate validation, or connection pooling algorithms.

## Dependencies

- Task 01.
- Tasks 03 through 05.

## Completion checks

- Mock and curl conformance tests cover methods, headers, upload/download, redirects policy, response limits, partial chunks, timeout, cancellation, executor rejection, native-code retention, and teardown with requests in flight.
- A loopback TLS fixture validates trust success/failure without disabling verification in production defaults.
- SSE tests split every fixture at every possible byte boundary and cover CR/LF variants, multiline data, comments, retry/id, EOF, invalid UTF-8 policy, and size limits.
- curl/TLS credentials do not appear in logs/errors, curl is omitted when disabled, and vendor APIs occur only in the adapter.

