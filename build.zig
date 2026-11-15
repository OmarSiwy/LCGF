//! Build file for LCGR. Zig 0.17.1 (prototype/build.zig is the verified example of this API).
//!
//!   zig build                      compile the library module
//!   zig build test                 run every test reachable from src/lcgr.zig
//!   zig build test -Dcpu=x86_64_v3 same, with 8 SIMD lanes on x86-64
//!   zig build test -Dlanes=16      same, with the SIMD lane count forced (simd.lanes)
//!   zig build test-build           compile the tests only, e.g. with -Dtarget=aarch64-linux
//!   zig build fmt                  fail if any Zig file is not formatted (CI runs this)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // std's width query never returns 16, so 16 lanes can only be tested by forcing the count.
    const options = b.addOptions();
    options.addOption(?u32, "lanes", b.option(u32, "lanes", "SIMD lanes per vector (default: the target's)"));

    // The package root. Every lane exports its file from here, so one module sees them all.
    const lcgr = b.addModule("lcgr", .{
        .root_source_file = b.path("src/lcgr.zig"),
        .target = target,
        .optimize = optimize,
    });
    lcgr.addOptions("build_options", options);

    const lib = b.addLibrary(.{ .name = "lcgr", .root_module = lcgr });
    b.getInstallStep().dependOn(&lib.step);

    const tests = b.addTest(.{ .root_module = lcgr });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // For targets this machine cannot run (ci/run.sh cross).
    b.step("test-build", "Compile the tests without running them").dependOn(&tests.step);

    // tools/bench measures the prototype core until the ported core exports the same names.
    const bench_core = b.createModule(.{ .root_source_file = b.path("prototype/ui.zig"), .target = target, .optimize = .ReleaseFast });
    const bench = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "ui", .module = bench_core }},
    }) });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    b.step("bench", "Run the frame benchmark (Linux)").dependOn(&bench_run.step);

    // Section sizes per example, built ReleaseSmall. Linux (ELF64) only. Until examples/ exists the
    // examples are the prototype's frame dumper and the benchmark.
    const size_tool = b.addExecutable(.{ .name = "size", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/size.zig"),
        .target = b.graph.host,
    }) });
    const size_run = b.addRunArtifact(size_tool);
    const small_core = b.createModule(.{ .root_source_file = b.path("prototype/ui.zig"), .target = target, .optimize = .ReleaseSmall });
    for ([_][2][]const u8{ .{ "dump", "prototype/dump.zig" }, .{ "bench", "tools/bench/bench.zig" } }) |ex| {
        const exe = b.addExecutable(.{ .name = ex[0], .root_module = b.createModule(.{
            .root_source_file = b.path(ex[1]),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "ui", .module = small_core }},
        }) });
        size_run.addArtifactArg(exe);
    }
    b.step("size", "Print text, rodata, data and bss of each example (Linux)").dependOn(&size_run.step);
    const size_tests = b.addTest(.{ .root_module = size_tool.root_module });
    test_step.dependOn(&b.addRunArtifact(size_tests).step);

    const fmt = b.addFmt(.{ .paths = &.{b.path(".")}, .check = true });
    b.step("fmt", "Check formatting of every Zig file").dependOn(&fmt.step);
}
