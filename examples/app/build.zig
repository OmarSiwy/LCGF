const std = @import("std");
const lcgf = @import("lcgf");

/// The hello window as a package of its own: what an application's build.zig is. LCGF is the
/// dependency, with its render back end left at the default, and `addApp` gives the
/// executable `lcgf` and `lcgf_app`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
    const exe = lcgf.addApp(b, dep, .{
        .name = "app",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    b.step("run", "Open the window").dependOn(&b.addRunArtifact(exe).step);
    // ci/run.sh examples runs `install test` in every example; ci/run.sh app runs the window.
    b.step("test", "Build the application").dependOn(&exe.step);
}
