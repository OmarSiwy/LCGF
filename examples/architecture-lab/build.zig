//! Standalone application over the containing LCGF checkout; no copied framework sources.
const std = @import("std");
const Architecture = @import("src/architecture.zig").Architecture;
const Framework = enum { checkout };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lanes = b.option(u32, "lanes", "Override SIMD lane count for validation");
    const package = b.dependency("lcgf", .{
        .target = target,
        .optimize = optimize,
        .render = .sw,
        .lanes = lanes,
    });
    const lcgf = package.module("lcgf");
    const host = b.createModule(.{
        .root_source_file = package.path("src/example/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    const app = b.createModule(.{
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "host", .module = host } },
    });
    const options = b.addOptions();
    options.addOption(Architecture, "architecture", b.option(Architecture, "architecture", "Application architecture") orelse .viper);
    options.addOption(Framework, "framework", .checkout);
    options.addOption([]const u8, "framework_revision", b.option([]const u8, "revision", "Source revision recorded in benchmark metadata") orelse "working-tree");
    options.addOption(bool, "incremental", b.option(bool, "incremental", "Retain pixels and upload changed regions in the desktop host") orelse true);
    app.addOptions("app_options", options);

    const tests = b.addTest(.{ .root_module = app });
    const host_tests = b.addTest(.{ .root_module = host });
    const run_host_tests = b.addRunArtifact(host_tests);
    const test_step = b.step("test", "Run application invariants, all five architectures, and full/retained host comparisons");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&run_host_tests.step);
    b.step("host-test", "Compare incremental and full software host output").dependOn(&run_host_tests.step);
    const framework_tests = b.addTest(.{ .root_module = lcgf });
    b.step("framework-test", "Run the dependency's complete core regression suite").dependOn(&b.addRunArtifact(framework_tests).step);

    const format = b.addFmt(.{
        .paths = &.{ b.path("app.zig"), b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tools") },
        .check = true,
    });
    b.step("fmt", "Check example and benchmark Zig formatting").dependOn(&format.step);
    const check = b.step("check", "Compile tests and the supported host, and check formatting");
    check.dependOn(&tests.step);
    check.dependOn(&host_tests.step);
    check.dependOn(&format.step);

    // All hosts can build and run the headless snapshot and measurement tools.
    // Default installation always includes the snapshot executable.
    const bench_build = b.step("bench-build", "Install the static application and core benchmarks without timing them");
    inline for (.{ "bench", "core_bench", "snapshot", "geometry", "incremental_bench", "reuse_bench" }) |name| {
        const executable_name = if (std.mem.eql(u8, name, "snapshot")) "architecture-snapshot" else name;
        const tool = b.addExecutable(.{ .name = executable_name, .root_module = b.createModule(.{
            .root_source_file = b.path("tools/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "app", .module = app }, .{ .name = "lcgf", .module = lcgf }, .{ .name = "host", .module = host } },
        }) });
        if (std.mem.eql(u8, name, "geometry")) {
            // A source file belongs to one Zig module. The host imports its atlas
            // privately; this generated copy lets the diagnostic inspect it too.
            const atlas = b.addWriteFiles();
            const atlas_root = atlas.addCopyFile(package.path("src/example/font.zig"), "font.zig");
            _ = atlas.addCopyFile(package.path("src/example/font/mono.a8"), "font/mono.a8");
            tool.root_module.addImport("font", b.createModule(.{
                .root_source_file = atlas_root,
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lcgf", .module = lcgf }},
            }));
        }
        const run_tool = b.addRunArtifact(tool);
        run_tool.addPassthruArgs();
        const install = b.addInstallArtifact(tool, .{});
        if (std.mem.eql(u8, name, "snapshot")) {
            b.getInstallStep().dependOn(&install.step);
            check.dependOn(&tool.step);
        }
        if (std.mem.eql(u8, name, "bench") or std.mem.eql(u8, name, "core_bench")) bench_build.dependOn(&install.step);
        if (std.mem.eql(u8, name, "incremental_bench") or std.mem.eql(u8, name, "reuse_bench"))
            b.step(name ++ "-build", "Install this benchmark without running it").dependOn(&install.step);
        b.step(name, if (std.mem.eql(u8, name, "snapshot")) "Render the application to a PPM image without a display" else if (std.mem.eql(u8, name, "geometry")) "Inspect quad geometry and shader eligibility without timing" else "Measure CPU frame work and check observable output").dependOn(&run_tool.step);
    }

    if (target.result.os.tag == .linux) {
        const x11 = b.createModule(.{
            .root_source_file = package.path("src/shell/x11/x11.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lcgf", .module = lcgf }},
        });
        const x11_tests = b.addTest(.{ .root_module = x11 });
        x11_tests.root_module.addAnonymousImport("example.replay", .{ .root_source_file = package.path("src/shell/testdata/example.replay") });
        const x11_run = b.addRunArtifact(x11_tests);
        x11_run.has_side_effects = true;
        b.step("x11-test", "Check upload packets and explicitly enabled live X11 tests").dependOn(&x11_run.step);
        const desktop = b.addExecutable(.{ .name = "architecture-lab", .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/x11.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "app", .module = app }, .{ .name = "lcgf", .module = lcgf }, .{ .name = "host", .module = host }, .{ .name = "x11", .module = x11 } },
        }) });
        b.installArtifact(desktop);
        check.dependOn(&desktop.step);
        const run = b.addRunArtifact(desktop);
        run.addPassthruArgs();
        b.step("run", "Open the Linux/X11 application; optional argument: seconds").dependOn(&run.step);
    } else {
        b.step("run", "The native window adapter requires Linux/X11").dependOn(&b.addFail("The native adapter requires Linux/X11. Use `zig build snapshot` or provide a platform adapter.").step);
    }
    b.getInstallStep().dependOn(&b.addInstallFile(package.path("src/example/font/LICENSE.txt"), "share/licenses/architecture-lab/DejaVu.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(package.path("LICENSE"), "share/licenses/architecture-lab/LCGF.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("LICENSE"), "share/licenses/architecture-lab/Lab.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("licenses/Unicode.txt"), "share/licenses/architecture-lab/Unicode.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("licenses/UCD-16.0.0-ReadMe.txt"), "share/licenses/architecture-lab/UCD-16.0.0-ReadMe.txt").step);
}
