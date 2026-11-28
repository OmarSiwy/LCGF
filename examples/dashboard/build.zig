const std = @import("std");
const lcgf = @import("lcgf");

/// An application's build: LCGF as the dependency, its render back end left at the default,
/// and `addApp` for the executable. The tests play recordings into the same `App` without a
/// window (`lcgf_replay`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
    const exe = lcgf.addApp(b, dep, .{
        .name = "dashboard",
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    // The bundled bitmap font's licence: a window with no font files draws with it.
    const licence = b.addInstallFile(dep.path("src/example/font/LICENSE.txt"), "share/licenses/dashboard/DejaVu.txt");
    b.getInstallStep().dependOn(&licence.step);
    b.step("run", "Open the window").dependOn(&b.addRunArtifact(exe).step);
    exe.root_module.addImport("lcgf_replay", dep.module("lcgf_replay"));
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the headless replay tests").dependOn(&b.addRunArtifact(tests).step);
}
