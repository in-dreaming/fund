# Windows Server 2025 baseline

Collected 2026-07-15 from commit `3e0fde0` plus the uncommitted Task 18
benchmark harness, with `zig build -Doptimize=ReleaseFast -Dprofile=<profile>
benchmark`. CPU: AMD EPYC 9754 128-Core Processor. RAM: 63 GiB. OS: Microsoft
Windows Server 2025 Datacenter 10.0.26100, build 26100. Power plan, logical-core
affinity, CPU-time collection, and benchmark executable byte size were not
available from this shared runner; those fields are null in raw results and this
baseline cannot be used for an approval decision.

Toolchain: Zig 0.16.0. Dependency pins are the Task 17 release inputs under
`third_party/manifests/entries`; no candidate dependency was enabled. The five
files preserve the measured values from stderr JSON output and add the host
metadata required by the result schema. This runner is not calibrated and no
numeric comparison or threshold should be derived from it.
