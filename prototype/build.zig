//! Build file for the prototype. Verified on Zig 0.17.1.
//! It is also the known-good example of the 0.17 build API for commit C0001.
//!
//!   zig build test                 run every test file (each one pulls in ui.zig)
//!   zig build test -Dcpu=x86_64_v3 same, with 8 SIMD lanes on x86-64
//!   zig build bench                build and run the frame benchmark (Linux)
//!   zig build census-obj           emit zig-out/asm_probe.o for the branch census
//!   zig build dump                 build zig-out/bin/dump for the GPU pixel check (Linux)
//!   zig build cross                compile the tests for five other targets without running them
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all prototype tests");
    for ([_][]const u8{ "example.zig", "ui_wgpu.zig", "comptime_ui_probe.zig" }) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const bench = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    b.step("bench", "Run the frame benchmark").dependOn(&b.addRunArtifact(bench).step);

    const probe = b.addObject(.{ .name = "asm_probe", .root_module = b.createModule(.{
        .root_source_file = b.path("asm_probe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    const install_probe = b.addInstallFile(probe.getEmittedBin(), "asm_probe.o");
    b.step("census-obj", "Emit the object file the branch census reads").dependOn(&install_probe.step);

    const dump = b.addExecutable(.{ .name = "dump", .root_module = b.createModule(.{
        .root_source_file = b.path("dump.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("dump", "Build the frame dumper used by render.py").dependOn(&b.addInstallArtifact(dump, .{}).step);

    const cross_step = b.step("cross", "Compile the tests for other targets (no run)");
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .wasm32, .os_tag = .wasi },
        .{ .cpu_arch = .riscv64, .os_tag = .linux },
    };
    for (cross_targets) |query| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
        }) });
        cross_step.dependOn(&t.step);
    }
}
