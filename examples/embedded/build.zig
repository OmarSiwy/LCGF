const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fixed = b.option(bool, "fixed-point", "Use fixed-point rectangle coordinates") orelse false;
    const no_float = b.option(bool, "no-float", "Bake the panel assets for integer-only firmware") orelse false;
    const host = b.dependency("lcgf", .{ .target = target, .optimize = optimize, .render = .sw, .@"fixed-point" = fixed });
    const sim = b.createModule(.{
        .root_source_file = b.path("simulator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = host.module("lcgf") }},
    });
    const exe = b.addExecutable(.{ .name = "embedded-simulator", .root_module = sim });
    b.installArtifact(exe);
    b.step("run", "Replay touch input on the simulated SPI panel").dependOn(&b.addRunArtifact(exe).step);
    const tests = b.step("test", "Verify simulator pixels and the selected firmware profile");
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sim })).step);

    const root = b.path(if (no_float) "integer.zig" else "demo.zig");
    const assets = if (no_float) blk: {
        const baker = b.dependency("lcgf", .{ .target = b.graph.host, .optimize = .ReleaseFast, .render = .sw, .@"fixed-point" = fixed });
        const bake = b.addRunArtifact(b.addExecutable(.{ .name = "bake-panel", .root_module = b.createModule(.{
            .root_source_file = b.path("bake.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "lcgf", .module = baker.module("lcgf") }},
        }) }));
        break :blk bake.addOutputFileArg("panel_assets.zig");
    } else null;
    const test_mod = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = host.module("lcgf") }},
    });
    if (assets) |file| test_mod.addAnonymousImport("panel_assets", .{ .root_source_file = file });
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
    const firmware = b.step("firmware", "Build freestanding Cortex-M7 and RV32IMAC counter boards");
    for ([_]struct { []const u8, std.Target.Query }{
        .{ "cortex-m7", .{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 } } },
        .{ "rv32imac", .{ .cpu_arch = .riscv32, .os_tag = .freestanding, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.sifive_e31 } } },
    }) |board| {
        const cpu = b.resolveTargetQuery(board[1]);
        const pkg = b.dependency("lcgf", .{ .target = cpu, .optimize = .ReleaseSmall, .render = .sw, .@"fixed-point" = fixed });
        const image = b.addExecutable(.{ .name = b.fmt("counter-{s}", .{board[0]}), .root_module = b.createModule(.{
            .root_source_file = root,
            .target = cpu,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "lcgf", .module = pkg.module("lcgf") }},
        }) });
        if (assets) |file| image.root_module.addAnonymousImport("panel_assets", .{ .root_source_file = file });
        image.entry = .{ .symbol_name = "_start" };
        firmware.dependOn(&b.addInstallArtifact(image, .{}).step);
    }
}
