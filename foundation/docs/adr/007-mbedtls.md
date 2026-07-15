# ADR 007: Mbed TLS adapter

Status: rejected for the current release, 2026-07-15.

Mbed TLS would replace or supplement a mature TLS dependency while no owned
budget or profiled default HTTP/TLS bottleneck exists. That conflicts with the
Foundation rule against replacing mature defaults solely because an alternative
exists. Retain the current libcurl transport/TLS arrangement.

A future proposal needs the same evidence as ADR 005 plus cryptographic update,
certificate-policy, supported-platform, fallback, removal, and conformance plans.
Until then it has no build feature or dependency manifest.
