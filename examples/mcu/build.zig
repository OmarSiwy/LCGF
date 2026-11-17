const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host = b.dependency("lcgf", .{ .target = target, .optimize = optimize, .render = .sw });
    const simulator = b.addExecutable(.{ .name = "thermostat", .root_module = b.createModule(.{
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = host.module("lcgf") }},
    }) });
    b.installArtifact(simulator);
    b.step("run", "Replay the thermostat on the host").dependOn(&b.addRunArtifact(simulator).step);
    b.step("test", "Verify the thermostat and displayed pixels").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = simulator.root_module })).step);

    const m7 = b.resolveTargetQuery(.{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 } });
    const board = b.dependency("lcgf", .{ .target = m7, .optimize = .ReleaseSmall, .render = .sw });
    const firmware = b.addExecutable(.{ .name = "thermostat-cortex-m7", .root_module = b.createModule(.{
        .root_source_file = b.path("app.zig"),
        .target = m7,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "lcgf", .module = board.module("lcgf") }},
    }) });
    firmware.entry = .{ .symbol_name = "_start" };
    b.installArtifact(firmware);
}
