# ADR 005: Platform HTTP/TLS adapter

Status: deferred, 2026-07-15.

The default HTTP transport is libcurl and no measured default profile misses an
owned HTTP/TLS budget. No profiling evidence attributes a miss to libcurl or its
TLS backend. Retain libcurl; do not introduce WinHTTP, Schannel, or another
platform transport.

Any future adapter must remain behind the HTTP facade, preserve error mapping,
callback executor affinity, cancellation and shutdown behavior, loopback
integration coverage, feature pruning, and a libcurl fallback. Security updates
and platform TLS-policy drift are the ongoing maintenance cost; removal is
feature disablement.
