const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const framework = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
    const lcgf = framework.module("lcgf");
    const page = b.addModule("page", .{
        .root_source_file = b.path("page.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    // OPTIONAL_HANDLERS
    const font = b.createModule(.{
        .root_source_file = framework.path("src/example/font.zig"),
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    const check = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "page", .module = page },
            .{ .name = "lcgf", .module = lcgf },
            .{ .name = "font", .module = font },
        },
    }) });
    b.getInstallStep().dependOn(&check.step);
    b.step("test", "Render a native page frame into memory").dependOn(&b.addRunArtifact(check).step);
}
