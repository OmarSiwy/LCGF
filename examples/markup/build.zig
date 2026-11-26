const std = @import("std");
const lcgf = @import("lcgf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
    // The page's UI module, generated from the HTML in the build cache; null while the lazy
    // Lexbor fetch runs (the build runner then fetches it and configures again).
    const ui = lcgf.addMarkup(b, dep, .{
        .html = b.path("ui/counter.html"),
        .emit = b.option([]const u8, "markup-emit", "Also copy the generated UI into this directory"),
        .vendored = if (b.option([]const u8, "markup-vendored", "Build from this checked-in generated UI (the build fails when it is stale)")) |p| b.path(p) else null,
    }) orelse return;
    const app = b.createModule(.{
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lcgf", .module = dep.module("lcgf") }, .{ .name = "counter_ui", .module = ui } },
    });
    const exe = b.addExecutable(.{ .name = "example-markup", .root_module = app });
    b.installArtifact(exe);
    b.step("run", "Run three headless frames and print what they drew").dependOn(&b.addRunArtifact(exe).step);
    b.step("test", "Run the headless tests").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app })).step);
}
