# ADR 006: mimalloc allocator adapter

Status: deferred, 2026-07-15.

The baseline reports workload allocation accounting but has no calibrated
allocator event collector, owned allocation/memory budget, or profile evidence
that the default allocator causes a budget miss. Introducing mimalloc would add
a dependency and global allocator policy risk without evidence.

Reconsider after same-host default/mimalloc comparison captures allocation count,
high-water memory, CPU time, binary size, and latency variance. The adapter must
be optional, have a standard allocator fallback, pass allocation-failure and
shutdown suites, carry a dependency manifest/security policy, and be removable
by feature disablement.
