const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const profile = b.option([]const u8, "profile", "Build profile: core, game, agent, tooling, or server") orelse "core";
    const enable_http = b.option(bool, "http", "Enable the HTTP capability") orelse false;
    const enable_database = b.option(bool, "database", "Enable the database capability") orelse false;
    const enable_compression = b.option(bool, "compression", "Enable compression capabilities") orelse false;
    const enable_profiler = b.option(bool, "profiler", "Enable profiler capability") orelse false;
    const enable_process = b.option(bool, "process", "Enable process capability") orelse false;
    const enable_filesystem = b.option(bool, "filesystem", "Enable filesystem capability") orelse false;
    const enable_yyjson = b.option(bool, "yyjson", "Enable the yyjson JSON adapter") orelse false;
    const enable_zstd = b.option(bool, "zstd", "Enable the zstd compression adapter") orelse false;
    const enable_lz4 = b.option(bool, "lz4", "Enable the LZ4 compression adapter") orelse false;
    const enable_blake3 = b.option(bool, "blake3", "Enable the BLAKE3 hashing adapter") orelse false;

    if (!std.mem.eql(u8, profile, "core") and !std.mem.eql(u8, profile, "game") and !std.mem.eql(u8, profile, "agent") and !std.mem.eql(u8, profile, "tooling") and !std.mem.eql(u8, profile, "server")) {
        @panic("-Dprofile must be core, game, agent, tooling, or server");
    }

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

    const tests = b.addTest(.{ .root_module = foundation });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Foundation tests");
    test_step.dependOn(&run_tests.step);

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
        const curl_module = b.createModule(.{
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
    if (enable_database) {
        const module = b.createModule(.{ .root_source_file = b.path("adapters/sqlite/sqlite.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("foundation", foundation);
        module.addIncludePath(b.path("third_party/sqlite"));
        module.addCSourceFile(.{ .file = b.path("third_party/sqlite/sqlite3.c"), .flags = &.{ "-std=c11", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_USE_URI=1" } });
        const adapter_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(adapter_tests).step);
        foundation.addImport("sqlite_adapter", module);
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
}
