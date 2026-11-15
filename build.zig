//! Build file for LCGR. Zig 0.17.1 (prototype/build.zig is the verified example of this API).
//!
//!   zig build                      compile the library module
//!   zig build test                 run every test reachable from src/lcgr.zig
//!   zig build test -Dcpu=x86_64_v3 same, with 8 SIMD lanes on x86-64
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
}
