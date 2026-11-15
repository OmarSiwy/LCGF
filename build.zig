//! Build file for LCGR. Zig 0.17.1 (prototype/build.zig is the verified example of this API).
//!
//!   zig build                      compile the library module
//!   zig build test                 run every test reachable from src/lcgr.zig
//!   zig build test -Dcpu=x86_64_v3 same, with 8 SIMD lanes on x86-64
//!   zig build test-build           compile the tests only, e.g. with -Dtarget=aarch64-linux
//!   zig build fmt                  fail if any Zig file is not formatted (CI runs this)
//!   zig build fuzz [--fuzz=N]      tools/fuzz tests; with --fuzz, coverage-guided fuzzing
//!   zig build fuzz-run -- 60       tools/fuzz seeded loop for 60 s (ci/run.sh fuzz)
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

    // Fuzz entry points (tools/fuzz). They drive the prototype core until it is ported to src/.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ui", .module = b.createModule(.{ .root_source_file = b.path("prototype/ui.zig") }) }},
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    b.step("fuzz", "Run the fuzz tests (add --fuzz=N to fuzz)").dependOn(&b.addRunArtifact(fuzz_tests).step);
    const fuzz_run = b.addRunArtifact(b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_mod }));
    fuzz_run.addPassthruArgs();
    b.step("fuzz-run", "Fuzz for a time: -- [seconds] [seed] [first]").dependOn(&fuzz_run.step);

    const fmt = b.addFmt(.{ .paths = &.{b.path(".")}, .check = true });
    b.step("fmt", "Check formatting of every Zig file").dependOn(&fmt.step);
}
