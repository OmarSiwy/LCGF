//! Build file for LCGR. Zig 0.17.1 (prototype/build.zig is the verified example of this API).
//!
//!   zig build                      compile the library module
//!   zig build test                 run every test reachable from src/lcgr.zig
//!   zig build test -Dcpu=x86_64_v3 same, with 8 SIMD lanes on x86-64
//!   zig build test-build           compile the tests only, e.g. with -Dtarget=aarch64-linux
//!   zig build fmt                  fail if any Zig file is not formatted (CI runs this)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The package root. Every lane exports its file from here, so one module sees them all.
    const lcgr = b.addModule("lcgr", .{
        .root_source_file = b.path("src/lcgr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{ .name = "lcgr", .root_module = lcgr });
    b.getInstallStep().dependOn(&lib.step);

    const tests = b.addTest(.{ .root_module = lcgr });
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
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

    const fmt = b.addFmt(.{ .paths = &.{b.path(".")}, .check = true });
    b.step("fmt", "Check formatting of every Zig file").dependOn(&fmt.step);
}
