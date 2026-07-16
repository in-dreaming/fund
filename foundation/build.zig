const std = @import("std");

const Features = struct {
    http: bool = false,
    database: bool = false,
    compression: bool = false,
    profiler: bool = false,
    process: bool = false,
    filesystem: bool = false,
    yyjson: bool = false,
    zstd: bool = false,
    lz4: bool = false,
    blake3: bool = false,
    tracy: bool = false,
    libuv: bool = false,
};

fn profileDefaults(profile: []const u8) Features {
    if (std.mem.eql(u8, profile, "game")) return .{ .filesystem = true, .compression = true, .zstd = true, .lz4 = true, .blake3 = true, .profiler = true, .tracy = true };
    if (std.mem.eql(u8, profile, "agent")) return .{ .http = true, .database = true, .yyjson = true };
    if (std.mem.eql(u8, profile, "tooling")) return .{ .http = true, .database = true, .process = true, .filesystem = true, .yyjson = true, .compression = true, .zstd = true, .lz4 = true, .libuv = true };
    if (std.mem.eql(u8, profile, "server")) return .{ .http = true, .database = true, .yyjson = true, .libuv = true };
    return .{};
}

fn validateFeatures(profile: []const u8, features: Features) void {
    if (std.mem.eql(u8, profile, "core") and (features.http or features.database or features.compression or features.profiler or features.process or features.filesystem or features.yyjson or features.zstd or features.lz4 or features.blake3 or features.tracy or features.libuv)) @panic("core permits no optional capabilities; select another profile or omit feature flags");
    if (!features.compression and (features.zstd or features.lz4)) @panic("-Dzstd and -Dlz4 require -Dcompression=true");
    if (!features.profiler and features.tracy) @panic("-Dtracy requires -Dprofiler=true");
    if (features.http and !std.mem.eql(u8, profile, "agent") and !std.mem.eql(u8, profile, "tooling") and !std.mem.eql(u8, profile, "server") and !std.mem.eql(u8, profile, "game")) @panic("-Dhttp is not allowed by this profile");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const profile = b.option([]const u8, "profile", "Build profile: core, game, agent, tooling, or server") orelse "core";
    const requested_http = b.option(bool, "http", "Enable the HTTP capability");
    const requested_database = b.option(bool, "database", "Enable the database capability");
    const requested_compression = b.option(bool, "compression", "Enable compression capabilities");
    const requested_profiler = b.option(bool, "profiler", "Enable profiler capability");
    const requested_process = b.option(bool, "process", "Enable process capability");
    const requested_filesystem = b.option(bool, "filesystem", "Enable filesystem capability");
    const requested_yyjson = b.option(bool, "yyjson", "Enable the yyjson JSON adapter");
    const requested_zstd = b.option(bool, "zstd", "Enable the zstd compression adapter");
    const requested_lz4 = b.option(bool, "lz4", "Enable the LZ4 compression adapter");
    const requested_blake3 = b.option(bool, "blake3", "Enable the BLAKE3 hashing adapter");
    const requested_tracy = b.option(bool, "tracy", "Enable the Tracy performance trace adapter");
    const requested_libuv = b.option(bool, "libuv", "Enable the libuv tooling adapter");
    const enable_testing = b.option(bool, "testing", "Enable deterministic testing infrastructure in non-test builds") orelse false;

    if (!std.mem.eql(u8, profile, "core") and !std.mem.eql(u8, profile, "game") and !std.mem.eql(u8, profile, "agent") and !std.mem.eql(u8, profile, "tooling") and !std.mem.eql(u8, profile, "server")) {
        @panic("-Dprofile must be core, game, agent, tooling, or server");
    }

    const defaults = profileDefaults(profile);
    const enable_http = requested_http orelse defaults.http;
    const enable_database = requested_database orelse defaults.database;
    const enable_compression = requested_compression orelse defaults.compression;
    const enable_profiler = requested_profiler orelse defaults.profiler;
    const enable_process = requested_process orelse defaults.process;
    const enable_filesystem = requested_filesystem orelse defaults.filesystem;
    const enable_yyjson = requested_yyjson orelse defaults.yyjson;
    const enable_zstd = requested_zstd orelse defaults.zstd;
    const enable_lz4 = requested_lz4 orelse defaults.lz4;
    const enable_blake3 = requested_blake3 orelse defaults.blake3;
    const enable_tracy = requested_tracy orelse defaults.tracy;
    const enable_libuv = requested_libuv orelse defaults.libuv;
    validateFeatures(profile, .{ .http = enable_http, .database = enable_database, .compression = enable_compression, .profiler = enable_profiler, .process = enable_process, .filesystem = enable_filesystem, .yyjson = enable_yyjson, .zstd = enable_zstd, .lz4 = enable_lz4, .blake3 = enable_blake3, .tracy = enable_tracy, .libuv = enable_libuv });

    const options = b.addOptions();
    options.addOption([]const u8, "profile", profile);
    options.addOption(bool, "http", enable_http);
    options.addOption(bool, "database", enable_database);
    options.addOption(bool, "compression", enable_compression);
    options.addOption(bool, "profiler", enable_profiler);
    options.addOption(bool, "process", enable_process);
    options.addOption(bool, "filesystem", enable_filesystem);
    options.addOption(bool, "yyjson", enable_yyjson);
    options.addOption(bool, "zstd", enable_zstd);
    options.addOption(bool, "lz4", enable_lz4);
    options.addOption(bool, "blake3", enable_blake3);
    options.addOption(bool, "tracy", enable_tracy);
    options.addOption(bool, "libuv", enable_libuv);
    options.addOption(bool, "testing", enable_testing);
    options.addOption(bool, "json", enable_yyjson or std.mem.eql(u8, profile, "agent") or std.mem.eql(u8, profile, "tooling") or std.mem.eql(u8, profile, "server"));
    options.addOption(bool, "hash", enable_blake3 or std.mem.eql(u8, profile, "game"));
    options.addOption(bool, "logging", !std.mem.eql(u8, profile, "core"));
    options.addOption(bool, "metrics", std.mem.eql(u8, profile, "agent") or std.mem.eql(u8, profile, "tooling") or std.mem.eql(u8, profile, "server"));
    options.addOption(bool, "trace", enable_profiler or std.mem.eql(u8, profile, "agent") or std.mem.eql(u8, profile, "tooling") or std.mem.eql(u8, profile, "server"));

    const foundation = b.addModule("foundation", .{
        .root_source_file = b.path("src/foundation.zig"),
        .target = target,
        .optimize = optimize,
    });
    foundation.addOptions("build_options", options);

    const cabi_library = b.addLibrary(.{ .name = "foundation", .root_module = foundation, .linkage = .static });
    const install_cabi = b.addInstallArtifact(cabi_library, .{});
    const install_header = b.addInstallFile(b.path("include/foundation.h"), "include/foundation.h");
    const cabi_step = b.step("cabi", "Build the static C ABI library and public header");
    cabi_step.dependOn(&install_cabi.step);
    cabi_step.dependOn(&install_header.step);

    const cabi_smoke = b.addExecutable(.{
        .name = "cabi_smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    cabi_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/cabi_smoke.c"), .flags = &.{"-std=c11"} });
    cabi_smoke.root_module.addIncludePath(b.path("include"));
    cabi_smoke.root_module.linkLibrary(cabi_library);
    const run_cabi_smoke = b.addRunArtifact(cabi_smoke);
    const cabi_test_step = b.step("cabi-test", "Compile and run a C11 consumer of foundation.h");
    cabi_test_step.dependOn(&run_cabi_smoke.step);

    const cabi_cpp_smoke = b.addExecutable(.{
        .name = "cabi_cpp_smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    cabi_cpp_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/cabi_cpp.cpp"), .flags = &.{"-std=c++17"} });
    cabi_cpp_smoke.root_module.addIncludePath(b.path("include"));
    cabi_cpp_smoke.root_module.linkLibrary(cabi_library);
    const run_cabi_cpp_smoke = b.addRunArtifact(cabi_cpp_smoke);
    cabi_test_step.dependOn(&run_cabi_cpp_smoke.step);

    const fixture_plugin_module = b.createModule(.{
        .root_source_file = b.path("tests/fixture_plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_plugin_module.addImport("foundation", foundation);
    const fixture_plugin = b.addLibrary(.{ .name = "foundation_fixture_plugin", .root_module = fixture_plugin_module, .linkage = .dynamic });
    cabi_test_step.dependOn(&fixture_plugin.step);

    const plugin_lifecycle_tests = b.addExecutable(.{
        .name = "plugin_lifecycle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/plugin_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    plugin_lifecycle_tests.root_module.addImport("foundation", foundation);
    const run_plugin_lifecycle = b.addRunArtifact(plugin_lifecycle_tests);
    run_plugin_lifecycle.addArtifactArg(fixture_plugin);
    cabi_test_step.dependOn(&run_plugin_lifecycle.step);

    const tests = b.addTest(.{ .root_module = foundation });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Foundation tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_plugin_lifecycle.step);

    const benchmark = b.addExecutable(.{
        .name = "foundation_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/foundation_benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.root_module.addImport("foundation", foundation);
    const run_benchmark = b.addRunArtifact(benchmark);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run one Foundation benchmark and emit a JSON result");
    benchmark_step.dependOn(&run_benchmark.step);

    const benchmark_smoke_run = b.addRunArtifact(benchmark);
    benchmark_smoke_run.addArgs(&.{ "--samples", "1", "--warmup", "0", "--machine", "ci-smoke" });
    const benchmark_smoke = b.step("benchmark-smoke", "Compile and run a calibrated-threshold-free benchmark smoke check");
    benchmark_smoke.dependOn(&benchmark_smoke_run.step);

    if (enable_yyjson) {
        const yyjson_module = b.createModule(.{
            .root_source_file = b.path("adapters/yyjson/yyjson.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        yyjson_module.addIncludePath(b.path("third_party/yyjson/source/src"));
        yyjson_module.addCSourceFile(.{ .file = b.path("third_party/yyjson/source/src/yyjson.c"), .flags = &.{"-std=c11"} });
        yyjson_module.addCSourceFile(.{ .file = b.path("adapters/yyjson/yyjson.c"), .flags = &.{"-std=c11"} });
        yyjson_module.addImport("foundation", foundation);
        const yyjson_tests = b.addTest(.{ .root_module = yyjson_module });
        const run_yyjson_tests = b.addRunArtifact(yyjson_tests);
        test_step.dependOn(&run_yyjson_tests.step);
    }

    if (enable_http) {
        const curl_module = b.addModule("curl_adapter", .{
            .root_source_file = b.path("adapters/curl/curl.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        curl_module.addImport("foundation", foundation);
        const curl_tests = b.addTest(.{ .root_module = curl_module });
        const run_curl_tests = b.addRunArtifact(curl_tests);
        test_step.dependOn(&run_curl_tests.step);
    }

    if (enable_zstd) {
        const module = b.createModule(.{ .root_source_file = b.path("adapters/zstd/zstd.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/zstd/lib"));
        module.addCSourceFiles(.{ .root = b.path("third_party/zstd/lib"), .files = &.{ "common/debug.c", "common/entropy_common.c", "common/error_private.c", "common/fse_decompress.c", "common/pool.c", "common/threading.c", "common/xxhash.c", "common/zstd_common.c", "compress/fse_compress.c", "compress/hist.c", "compress/huf_compress.c", "compress/zstdmt_compress.c", "compress/zstd_compress.c", "compress/zstd_compress_literals.c", "compress/zstd_compress_sequences.c", "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c", "compress/zstd_fast.c", "compress/zstd_lazy.c", "compress/zstd_ldm.c", "compress/zstd_opt.c", "decompress/huf_decompress.c", "decompress/zstd_ddict.c", "decompress/zstd_decompress.c", "decompress/zstd_decompress_block.c" }, .flags = &.{ "-std=c11", "-DZSTD_DISABLE_ASM", "-DZSTD_MULTITHREAD=0" } });
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
    }
    if (enable_lz4) {
        const module = b.createModule(.{ .root_source_file = b.path("adapters/lz4/lz4.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/lz4/lib"));
        module.addCSourceFile(.{ .file = b.path("third_party/lz4/lib/lz4.c"), .flags = &.{"-std=c11"} });
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
    }
    if (enable_blake3) {
        const module = b.createModule(.{ .root_source_file = b.path("adapters/blake3/blake3.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/blake3/c"));
        inline for (.{ "adapters/blake3/blake3.c", "third_party/blake3/c/blake3.c", "third_party/blake3/c/blake3_dispatch.c", "third_party/blake3/c/blake3_portable.c" }) |source| module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-DBLAKE3_NO_SSE2", "-DBLAKE3_NO_SSE41", "-DBLAKE3_NO_AVX2", "-DBLAKE3_NO_AVX512", "-DBLAKE3_NO_NEON" } });
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
    }
    if (enable_tracy) {
        const module = b.createModule(.{ .root_source_file = b.path("adapters/tracy/tracy.zig"), .target = target, .optimize = optimize, .link_libcpp = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/tracy/public"));
        if (target.result.os.tag == .windows) {
            module.linkSystemLibrary("ws2_32", .{});
            module.linkSystemLibrary("dbghelp", .{});
        }
        module.addCSourceFile(.{ .file = b.path("third_party/tracy/public/TracyClient.cpp"), .flags = &.{ "-std=c++17", "-DTRACY_ENABLE", "-DTRACY_TIMER_QPC" } });
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
    }
    if (enable_database) {
        const module = b.createModule(.{ .root_source_file = b.path("adapters/sqlite/sqlite.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/sqlite"));
        module.addCSourceFile(.{ .file = b.path("third_party/sqlite/sqlite3.c"), .flags = &.{ "-std=c11", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_USE_URI=1" } });
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
        foundation.addImport("sqlite_adapter", module);
    }
    if (enable_libuv) {
        if (target.result.os.tag != .windows) @panic("the vendored libuv adapter currently supports Windows hosts only");
        const module = b.createModule(.{ .root_source_file = b.path("adapters/libuv/libuv.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/libuv/include"));
        module.addIncludePath(b.path("third_party/libuv/src"));
        module.addCSourceFile(.{ .file = b.path("adapters/libuv/libuv_bridge.c"), .flags = &.{ "-std=c11", "-DWIN32_LEAN_AND_MEAN", "-D_WIN32_WINNT=0x0602", "-D_CRT_DECLARE_NONSTDC_NAMES=0" } });
        module.addCSourceFiles(.{ .root = b.path("third_party/libuv"), .files = &.{ "src/fs-poll.c", "src/idna.c", "src/inet.c", "src/random.c", "src/strscpy.c", "src/strtok.c", "src/thread-common.c", "src/threadpool.c", "src/timer.c", "src/uv-common.c", "src/uv-data-getter-setters.c", "src/version.c", "src/win/async.c", "src/win/core.c", "src/win/detect-wakeup.c", "src/win/dl.c", "src/win/error.c", "src/win/fs.c", "src/win/fs-event.c", "src/win/getaddrinfo.c", "src/win/getnameinfo.c", "src/win/handle.c", "src/win/loop-watcher.c", "src/win/pipe.c", "src/win/thread.c", "src/win/poll.c", "src/win/process.c", "src/win/process-stdio.c", "src/win/signal.c", "src/win/snprintf.c", "src/win/stream.c", "src/win/tcp.c", "src/win/tty.c", "src/win/udp.c", "src/win/util.c", "src/win/winapi.c", "src/win/winsock.c" }, .flags = &.{ "-std=c11", "-DWIN32_LEAN_AND_MEAN", "-D_WIN32_WINNT=0x0602", "-D_CRT_DECLARE_NONSTDC_NAMES=0" } });
        inline for (.{ "psapi", "user32", "advapi32", "iphlpapi", "userenv", "ws2_32", "dbghelp", "ole32", "shell32" }) |name| module.linkSystemLibrary(name, .{});
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
        foundation.addImport("event_loop_adapter", module);
    }

    const dependency_check = b.addSystemCommand(&.{ "zig", "run", "tools/dependency_check.zig", "--", "third_party/manifests/entries" });
    const dependency_step = b.step("dependency-check", "Validate dependency manifests");
    dependency_step.dependOn(&dependency_check.step);

    const boundary_check = b.addSystemCommand(&.{ "zig", "run", "tools/boundary_check.zig", "--", "src", "include", "examples" });
    const boundary_step = b.step("boundary-check", "Reject vendor imports outside adapters");
    boundary_step.dependOn(&boundary_check.step);

    const check_step = b.step("check", "Run Foundation governance checks");
    check_step.dependOn(&dependency_check.step);
    check_step.dependOn(&boundary_check.step);

    const release_check = b.addSystemCommand(&.{ "zig", "run", "tools/release_check.zig", "--", "third_party/manifests/entries", "third_party/THIRD_PARTY_NOTICES.txt" });
    const release_step = b.step("release-check", "Validate release notices and license inputs");
    release_step.dependOn(&release_check.step);
    check_step.dependOn(&release_check.step);

    const examples_step = b.step("examples", "Build the selected profile consumer fixture");
    const example_name = if (std.mem.eql(u8, profile, "game")) "game" else if (std.mem.eql(u8, profile, "agent")) "agent" else if (std.mem.eql(u8, profile, "tooling")) "tooling" else if (std.mem.eql(u8, profile, "server")) "server" else "core";
    const example = b.addExecutable(.{ .name = b.fmt("foundation_{s}_example", .{example_name}), .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example_name})), .target = target, .optimize = optimize }) });
    example.root_module.addImport("foundation", foundation);
    examples_step.dependOn(&example.step);
    const run_example = b.addRunArtifact(example);
    const examples_test_step = b.step("examples-test", "Run the selected profile consumer fixture");
    examples_test_step.dependOn(&run_example.step);
}
