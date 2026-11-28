const std = @import("std");
const lcgf = @import("lcgf");

/// An application's build, as examples/hello's, with the sphere's shader: `addGpuShaders`
/// gives the module of sphere.wgsl and the translation the target's own GPU API consumes (the
/// back end LCGF picks by default), read from gen/ (written by naga: `nix develop .#shaders
/// -c naga sphere.wgsl gen/gpu_sphere.spv gen/gpu_sphere.metal gen/gpu_sphere.hlsl`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
    const exe = lcgf.addApp(b, dep, .{
        .name = "viewport",
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
    });
    const api: enum { vk, metal, d3d12 } = switch (target.result.os.tag) {
        .macos => .metal,
        .windows => .d3d12,
        else => .vk,
    };
    const sphere: lcgf.GpuShader = .{ .name = "sphere", .path = b.path("sphere.wgsl") };
    exe.root_module.addImport("viewport_shaders", lcgf.addGpuShaders(b, api, .{ .prebuilt = b.path("gen") }, &.{sphere}));
    b.installArtifact(exe);
    // The bundled bitmap font's licence: a window with no font files draws with it.
    const licence = b.addInstallFile(dep.path("src/example/font/LICENSE.txt"), "share/licenses/viewport/DejaVu.txt");
    b.getInstallStep().dependOn(&licence.step);
    b.step("run", "Open the window").dependOn(&b.addRunArtifact(exe).step);
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the headless replay tests").dependOn(&b.addRunArtifact(tests).step);
}
