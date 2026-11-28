//! Build file for LCGF. Zig 0.18.0-dev.1151+8dfb7a7cc.
//!
//! `zig build --help` lists every step with its description; CI runs them through ci/jobs/.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // std's width query never returns 16, so 16 lanes can only be tested by forcing the count.
    const options = b.addOptions();
    options.addOption(?u32, "lanes", b.option(u32, "lanes", "SIMD lanes per vector (default: the target's)"));

    options.addOption(bool, "fixed_point", b.option(bool, "fixed-point", "Embedded panel coordinates in signed Q12.4") orelse false);

    // The package root. Every lane exports its file from here, so one module sees them all.
    const lcgf = b.addModule("lcgf", .{
        .root_source_file = b.path("src/lcgf.zig"),
        .target = target,
        .optimize = optimize,
    });
    lcgf.addOptions("build_options", options);

    // Unicode property tables, generated on the host from the UCD files (src/text/unicode/gen.zig).
    const ucd_gen = b.addRunArtifact(b.addExecutable(.{ .name = "ucd-gen", .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/unicode/gen.zig"),
        .target = b.graph.host,
    }) }));
    const ucd_tables = ucd_gen.addOutputFileArg("unicode_tables.zig");
    // The Unicode Character Database 16.0.0, a build.zig.zon dependency (UCD.zip, pinned hash).
    const ucd = b.dependency("ucd", .{});
    for ([_][]const u8{ "auxiliary/GraphemeBreakProperty", "emoji/emoji-data", "DerivedCoreProperties", "auxiliary/WordBreakProperty", "LineBreak", "EastAsianWidth", "extracted/DerivedGeneralCategory", "extracted/DerivedBidiClass", "BidiBrackets", "Scripts" }) |f|
        ucd_gen.addFileArg(ucd.path(b.fmt("{s}.txt", .{f})));
    lcgf.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });

    const lib = b.addLibrary(.{ .name = "lcgf", .root_module = lcgf });
    b.getInstallStep().dependOn(&lib.step);

    const custom_draw_scene = b.createModule(.{
        .root_source_file = b.path("src/render/custom_draw_scene.zig"),
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    // The wgpu-native back end (src/render/wgpu/native.zig): outside the tiers, a module of its
    // own over lcgf. wgpu-native's release archive for the target (build.zig.zon, lazy), its
    // headers translated here (@cImport is gone), its static library linked.
    const wgpu_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/wgpu/native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // Draws the render conformance scenes as PNGs (src/render/wgpu/play.zig).
    const wgpu_play = b.addExecutable(.{ .name = "wgpu-play", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/wgpu/play.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // The wgpu side of the Vulkan back end's probe (src/render/vk/probe_wgpu.zig), over the
    // wgpu back end's native.zig as a module.
    const vk_probe_wgpu = b.addExecutable(.{ .name = "vk-probe-wgpu", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/vk/probe_wgpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    const wgpu_native_mod = b.createModule(.{
        .root_source_file = b.path("src/render/wgpu/native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    vk_probe_wgpu.root_module.addImport("wgpu_native", wgpu_native_mod);
    // The wgpu-native major to build against: one archive per major and host target in
    // build.zig.zon, fetched only when picked, so plain builds download none. The binding
    // compiles against the picked release's own translated header.
    const wgpu_version = b.option(WgpuNative, "wgpu-native", "wgpu-native major for the wgpu steps (v27, v29)");
    const wgpu_host = b.fmt("{s}_{s}", .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) });
    const wgpu_targets = [_][]const u8{ "linux_x86_64", "linux_aarch64", "macos_x86_64", "macos_aarch64", "windows_x86_64" };
    const wgpu_supported = wgpu_version != null and for (wgpu_targets) |t| {
        if (std.mem.eql(u8, t, wgpu_host)) break true;
    } else false;
    const wgpu_step = b.step("wgpu", "Test the wgpu-native back end on a real adapter, -Dwgpu-native=v29 (ci/run.sh wgpu)");
    const wgpu_play_step = b.step("wgpu-play", "Build zig-out/bin/wgpu-play (draws the render conformance scenes with wgpu-native)");
    const vk_probe_wgpu_step = b.step("vk-probe-wgpu", "Build zig-out/bin/vk-probe-wgpu (the wgpu side of the Vulkan back end's probe), -Dwgpu-native=v29");
    if (!wgpu_supported) {
        const fail = b.addFail(if (wgpu_version == null) "the wgpu steps need -Dwgpu-native=v27 or v29" else "wgpu-native has no archive for this target in build.zig.zon");
        wgpu_step.dependOn(&fail.step);
        wgpu_play_step.dependOn(&fail.step);
        vk_probe_wgpu_step.dependOn(&fail.step);
    }
    if (if (wgpu_supported) b.lazyDependency(b.fmt("wgpu_native_{s}_{s}", .{ @tagName(wgpu_version.?), wgpu_host }), .{}) else null) |wgpu_native| {
        const wgpu_h = b.addTranslateC(.{ .root_source_file = wgpu_native.path("include/webgpu/wgpu.h"), .target = target, .optimize = optimize });
        wgpu_h.addIncludePath(wgpu_native.path("include"));
        const wgpu_c = wgpu_h.createModule();
        vk_probe_wgpu.root_module.addImport("wgpu_c", wgpu_c);
        // wgpu_native_mod carries its own link inputs, for vk-probe-wgpu and lcgf_render.
        for ([_]*std.Build.Module{ wgpu_tests.root_module, wgpu_play.root_module, wgpu_native_mod }) |m| {
            m.addImport("wgpu_c", wgpu_c);
            m.addObjectFile(wgpu_native.path("lib/libwgpu_native.a"));
            switch (target.result.os.tag) {
                .macos => for ([_][]const u8{ "Metal", "QuartzCore", "Foundation" }) |f| m.linkFramework(f, .{}),
                .windows => for ([_][]const u8{ "d3dcompiler_47", "ws2_32", "userenv", "bcrypt", "ntdll", "opengl32", "user32", "gdi32", "ole32", "oleaut32", "propsys", "runtimeobject", "unwind" }) |l| m.linkSystemLibrary(l, .{ .use_pkg_config = .no }),
                // Rust panics unwind: libunwind is Zig's own, built for the target.
                else => for ([_][]const u8{ "m", "dl", "pthread", "unwind" }) |l| m.linkSystemLibrary(l, .{}),
            }
        }
        // The repository's lcgf_render.gpu shaders: WebGPU takes the WGSL as it is.
        const wgpu_shaders = addGpuShaders(b, .wgpu, .{ .prebuilt = b.path("src/render/shaders/gen") }, repo_gpu_shaders(b));
        for ([_]*std.Build.Module{ wgpu_tests.root_module, wgpu_play.root_module }) |m| m.addImport("gpu_shaders", wgpu_shaders);
        wgpu_step.dependOn(&b.addRunArtifact(wgpu_tests).step);
        wgpu_play_step.dependOn(&b.addInstallArtifact(wgpu_play, .{}).step);
        vk_probe_wgpu_step.dependOn(&b.addInstallArtifact(vk_probe_wgpu, .{}).step);
    }

    // The render back end an application builds against (src/render/select.zig): one, chosen
    // at compile time, no dispatch. `auto` is the target's own API.
    const render = switch (b.option(RenderOption, "render", "Render back end of the lcgf_render module (default auto: the target's own API)") orelse .auto) {
        .auto => autoRender(target.result),
        inline else => |k| @field(Render, @tagName(k)),
    };
    const render_options = b.addOptions();
    render_options.addOption(Render, "render", render);
    const lcgf_render = b.addModule("lcgf_render", .{
        .root_source_file = b.path("src/render/select.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    lcgf_render.addOptions("render_options", render_options);
    if (renderBackend(b, render, target, optimize, lcgf, wgpu_native_mod)) |m| lcgf_render.addImport("render_backend", m);
    // lcgf_app (src/app/app.zig): an application in a desktop window in one call, with the
    // shells this target needs. A dependent takes it as `dep.module("lcgf_app")`, or builds
    // its executable with `addApp`.
    const app_shell = struct {
        fn module(bb: *std.Build, path: []const u8, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
            return bb.createModule(.{ .root_source_file = bb.path(path), .target = t, .optimize = o, .imports = imports });
        }
    };
    const lcgf_import: []const std.Build.Module.Import = &.{.{ .name = "lcgf", .module = lcgf }};
    const app_imports: []const std.Build.Module.Import = switch (target.result.os.tag) {
        .linux => &.{
            .{ .name = "lcgf", .module = lcgf },
            .{ .name = "x11", .module = app_shell.module(b, "src/shell/x11/x11.zig", target, optimize, lcgf_import) },
            .{ .name = "wayland", .module = app_shell.module(b, "src/shell/wayland/wayland.zig", target, optimize, lcgf_import) },
        },
        .windows => &.{
            .{ .name = "lcgf", .module = lcgf },
            .{ .name = "win32", .module = app_shell.module(b, "src/shell/win32/win32.zig", target, optimize, lcgf_import) },
        },
        .macos => &.{
            .{ .name = "lcgf", .module = lcgf },
            .{ .name = "macos", .module = b.createModule(.{ .root_source_file = b.path("src/shell/macos/macos.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "metal", .module = renderBackend(b, .metal, target, optimize, lcgf, wgpu_native_mod).? } } }) },
        },
        else => lcgf_import,
    };
    // libc on macOS, and on Linux exactly when the back end is a GPU one (its loader is opened
    // with dlopen): `-Drender=sw` stays without.
    const linux = target.result.os.tag == .linux;
    const app_libc = target.result.os.tag == .macos or (linux and render != .sw);
    const app_mod = b.addModule("lcgf_app", .{ .root_source_file = b.path("src/app/app.zig"), .target = target, .optimize = optimize, .link_libc = app_libc, .imports = app_imports });
    app_mod.addOptions("render_options", render_options);
    // The GPU window (src/app/gpu.zig's loop, src/app/gpu_x11.zig): Vulkan over the X11 shell's window.
    if (linux and render == .vk) if (renderBackend(b, .vk, target, optimize, lcgf, wgpu_native_mod)) |app_vk| {
        app_mod.addImport("vk", app_vk);
        app_mod.addImport("x11_gpu", b.createModule(.{
            .root_source_file = b.path("src/shell/x11/gpu.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "vk", .module = app_vk }, .{ .name = "x11", .module = app_imports[1].module } },
        }));
    };
    // The text service's font discovery (src/app/text.zig), linking what lcgf_app links, and
    // the test face of its tests.
    app_mod.addImport("font_system", appText(b, target, optimize, lcgf, app_libc).import_table.get("font_system").?);
    app_mod.addAnonymousImport("layout.ttf", .{ .root_source_file = b.path("src/text/layout/testdata/layout.ttf") });
    // A downstream application consumes the modules and library above. The
    // benchmarks, SDK probes, docs and examples belong to this repository.
    if (!b.isRoot()) return;

    const gallery_font = b.createModule(.{
        .root_source_file = b.path("src/example/font.zig"),
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    const styling_gallery = b.addExecutable(.{ .name = "styling-gallery", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/styling/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "gallery_font", .module = gallery_font } },
    }) });
    const render_gallery = b.addRunArtifact(styling_gallery);
    render_gallery.addArg(b.option([]const u8, "gallery-output", "Styling gallery PNG path") orelse "styling-gallery.png");
    b.step("styling-gallery", "Render the portable styling gallery as a PNG (-Dgallery-output=path)").dependOn(&render_gallery.step);

    const styling_check = b.step("styling-check", "Run the token authoring regressions");
    const token_check = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "tools/stylegen", "-p", "test_*.py" });
    token_check.has_side_effects = true;
    styling_check.dependOn(&token_check.step);

    const tests = b.addTest(.{ .root_module = lcgf });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // For targets this machine cannot run (ci/run.sh cross).
    b.step("test-build", "Compile the tests without running them").dependOn(&tests.step);
    // The Unicode conformance files (src/text/unicode/conformance.zig): seconds, so not in `test`.
    const conformance = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/unicode/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    for ([_][]const u8{ "auxiliary/GraphemeBreakTest", "auxiliary/WordBreakTest", "auxiliary/LineBreakTest", "BidiTest", "BidiCharacterTest", "Scripts" }) |f|
        conformance.root_module.addAnonymousImport(b.fmt("{s}.txt", .{std.fs.path.basename(f)}), .{ .root_source_file = ucd.path(b.fmt("{s}.txt", .{f})) });
    b.step("conformance", "Run the Unicode conformance files").dependOn(&b.addRunArtifact(conformance).step);
    // Lines laid out and reordered for display against BidiCharacterTest (src/text/layout/conformance.zig).
    const text_conformance = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/layout/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    text_conformance.root_module.addAnonymousImport("BidiCharacterTest.txt", .{ .root_source_file = ucd.path("BidiCharacterTest.txt") });
    b.step("text-conformance", "Lay out and reorder BidiCharacterTest lines").dependOn(&b.addRunArtifact(text_conformance).step);

    // The package root built ReleaseFast, for the branch census and the benchmark.
    const lcgf_fast = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = target, .optimize = .ReleaseFast });
    lcgf_fast.addOptions("build_options", options);
    // The data scene's text fields segment text (bench/scenes/data.zig).
    lcgf_fast.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
    const census_probe = b.addObject(.{ .name = "census_src", .root_module = b.createModule(.{
        .root_source_file = b.path("src/census_probes.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) });
    // Separate format objects preserve the actual shader loops under each probe
    // symbol: LLVM can otherwise merge cross-format bodies into uncounted helpers.
    const census_alpha8_probe = b.addObject(.{ .name = "census_alpha8", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/sw/census_probe_alpha8.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) });
    const census_step = b.step("census-src-obj", "Emit census_src.o and census_alpha8.o for independent branch censuses");
    census_step.dependOn(&b.addInstallFile(census_probe.getEmittedBin(), "census_src.o").step);
    census_step.dependOn(&b.addInstallFile(census_alpha8_probe.getEmittedBin(), "census_alpha8.o").step);

    // tools/golden/: dumps a draw-feature scene for tools/golden/gpu.py (ci/run.sh draw-golden).
    const draw_dump_mod = b.createModule(.{
        .root_source_file = b.path("tools/golden/draw.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lcgf", .module = lcgf },
            // The canvas label scene: the text service's distance atlas (src/app/labels.zig).
            .{ .name = "app_text", .module = appText(b, target, optimize, lcgf, false) },
        },
    });
    draw_dump_mod.addAnonymousImport("layout.ttf", .{ .root_source_file = b.path("src/text/layout/testdata/layout.ttf") });
    const draw_dump = b.addRunArtifact(b.addExecutable(.{ .name = "draw-dump", .root_module = draw_dump_mod }));
    draw_dump.addPassthruArgs();
    b.step("draw-dump", "Dump a draw-feature scene: -- <scene> <dir>").dependOn(&draw_dump.step);

    // tools/golden/: dumps a reference-widget frame for tools/golden/gpu.py (ci/run.sh widget-golden).
    const widget_dump = b.addRunArtifact(b.addExecutable(.{ .name = "widget-dump", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/golden/widgets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) }));
    widget_dump.addPassthruArgs();
    b.step("widget-dump", "Dump a reference-widget frame: -- <frame> <dir>").dependOn(&widget_dump.step);

    // The benchmark and comparison harnesses drive the production runtime.
    const src_scenes_root = b.path("bench/scenes/scenes.zig");
    const bench_src_ui = b.createModule(.{ .root_source_file = b.path("bench/micro/src_ui.zig"), .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }} });
    const bench_src_scenes = b.createModule(.{ .root_source_file = src_scenes_root, .imports = &.{.{ .name = "ui", .module = bench_src_ui }} });
    const bench = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/micro/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_fast }, .{ .name = "scenes", .module = bench_src_scenes } },
    }) });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    b.step("bench", "Run the frame benchmark (Linux)").dependOn(&bench_run.step);
    // The software renderer over whole frames and isolated quad kinds (bench/micro/swbench.zig).
    const swbench = b.addExecutable(.{ .name = "swbench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/micro/swbench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_fast }, .{ .name = "scenes", .module = bench_src_scenes } },
    }) });
    const swbench_run = b.addRunArtifact(swbench);
    swbench_run.addPassthruArgs();
    b.step("swbench", "Run the software renderer benchmark (Linux)").dependOn(&swbench_run.step);
    b.step("swbench-build", "Build zig-out/bin/swbench").dependOn(&b.addInstallArtifact(swbench, .{}).step);
    // The window layer's text service over 300 runs (bench/micro/apptext.zig).
    const apptext_mod = b.createModule(.{
        .root_source_file = b.path("bench/micro/apptext.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "lcgf", .module = lcgf_fast },
            .{ .name = "app_text", .module = appText(b, target, .ReleaseFast, lcgf_fast, false) },
        },
    });
    const layout_ttf = b.path("src/text/layout/testdata/layout.ttf");
    apptext_mod.addAnonymousImport("layout.ttf", .{ .root_source_file = layout_ttf });
    const symbols_ttf = b.path("src/app/testdata/symbols.ttf");
    apptext_mod.addAnonymousImport("symbols.ttf", .{ .root_source_file = symbols_ttf });
    const apptext = b.addExecutable(.{ .name = "apptext-bench", .root_module = apptext_mod });
    const apptext_run = b.addRunArtifact(apptext);
    b.step("app-text-bench", "Time the text service's frames (Linux)").dependOn(&apptext_run.step);
    // Canvas labels under zoom: distance fields against rasterising again (bench/micro/canvastext.zig).
    const canvastext_mod = b.createModule(.{
        .root_source_file = b.path("bench/micro/canvastext.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_fast }, .{ .name = "app_text", .module = appText(b, target, .ReleaseFast, lcgf_fast, false) } },
    });
    canvastext_mod.addAnonymousImport("layout.ttf", .{ .root_source_file = layout_ttf });
    const canvastext = b.addExecutable(.{ .name = "canvastext-bench", .root_module = canvastext_mod });
    const canvastext_run = b.addRunArtifact(canvastext);
    b.step("canvas-text-bench", "Measure canvas label candidates under zoom (Linux)").dependOn(&canvastext_run.step);
    // The canvas batch in software: 100k primitives panned and zoomed (bench/micro/canvasbench.zig).
    const canvasbench = b.addExecutable(.{ .name = "canvasbench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/micro/canvasbench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) });
    b.step("canvasbench-build", "Build zig-out/bin/canvasbench (the canvas benchmark, Linux)").dependOn(&b.addInstallArtifact(canvasbench, .{}).step);
    const probe = b.addSystemCommand(&.{ "python3", "bench/micro/probe.py", "--" });
    probe.addArtifactArg(bench);
    probe.addArg("--idle");
    b.step("probe", "Print resident memory and idle wake-ups after one frame (Linux)").dependOn(&probe.step);
    const styling_bench = b.addRunArtifact(b.addExecutable(.{ .name = "styling-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/styling/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) }));
    styling_bench.addPassthruArgs();
    b.step("styling-bench", "Measure five styling workloads in software (Linux; -- output.json)").dependOn(&styling_bench.step);

    // Input-to-photon latency of the example in the headless shell (bench/gates/latency.zig).
    const gates_latency = b.addRunArtifact(b.addExecutable(.{ .name = "gates-latency", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/gates/latency.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) }));
    b.step("gates-latency", "Print input-to-photon latency of the example, headless (bench/gates/)").dependOn(&gates_latency.step);

    // Section sizes of the software frame dumper and benchmark (ReleaseSmall, ELF64).
    const size_tool = b.addExecutable(.{ .name = "size", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/micro/size.zig"),
        .target = b.graph.host,
    }) });
    const size_run = b.addRunArtifact(size_tool);
    const lcgf_small = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = target, .optimize = .ReleaseSmall });
    lcgf_small.addOptions("build_options", options);
    lcgf_small.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
    const small_src_ui = b.createModule(.{ .root_source_file = b.path("bench/micro/src_ui.zig"), .imports = &.{.{ .name = "lcgf", .module = lcgf_small }} });
    const small_src_scenes = b.createModule(.{ .root_source_file = src_scenes_root, .imports = &.{.{ .name = "ui", .module = small_src_ui }} });
    // The reference row of docs/perf/vs.md: bench/vs/lcgf/, harness.h's driver over LCGF's
    // frame, fast and small (bench/vs/measure.py).
    const vs_lcgf = b.step("vs-lcgf", "Build the LCGF row of the comparison (bench/vs/lcgf/)");
    vs_lcgf.dependOn(&b.addInstallArtifact(size_tool, .{}).step);
    // vs-lcgf-safe is the same driver with the safety checks in (ci/jobs/vs-lcgf-check.sh).
    const vs_modes = [_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSmall, .ReleaseSafe };
    for (vs_modes, [_][]const u8{ "vs-lcgf", "vs-lcgf-small", "vs-lcgf-safe" }) |mode, name| {
        const core = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = target, .optimize = mode });
        core.addOptions("build_options", options);
        const ui_mod = b.createModule(.{ .root_source_file = b.path("bench/micro/src_ui.zig"), .imports = &.{.{ .name = "lcgf", .module = core }} });
        const scenes_mod = b.createModule(.{ .root_source_file = src_scenes_root, .imports = &.{.{ .name = "ui", .module = ui_mod }} });
        const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path("bench/vs/lcgf/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{ .{ .name = "lcgf", .module = core }, .{ .name = "scenes", .module = scenes_mod } },
        }) });
        vs_lcgf.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    for ([_][2][]const u8{ .{ "golden-dump", "tools/golden/dump.zig" }, .{ "bench", "bench/micro/bench.zig" } }) |ex| {
        const exe = b.addExecutable(.{ .name = ex[0], .root_module = b.createModule(.{
            .root_source_file = b.path(ex[1]),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf_small }, .{ .name = "scenes", .module = small_src_scenes } },
        }) });
        size_run.addArtifactArg(exe);
        if (std.mem.eql(u8, ex[0], "golden-dump")) {
            b.step("golden-dump", "Build the production GPU pixel-check fixture").dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }
    b.step("size", "Print text, rodata, data and bss of each example (Linux)").dependOn(&size_run.step);
    const size_tests = b.addTest(.{ .root_module = size_tool.root_module });
    test_step.dependOn(&b.addRunArtifact(size_tests).step);

    // Competitor harnesses (bench/vs/, docs/perf/vs.md, ci/jobs/vs-*.sh): `zig build vs-NAME`
    // installs zig-out/bin/vs-NAME (ReleaseFast, timed), vs-NAME-small (ReleaseSmall, sized) and
    // the size tool. Each framework is a lazy dependency, fetched only for its own step.
    const resize_adapters = b.step("vs-resize-adapters", "Build the native comparison adapters for bench/vs/window-resize/build.sh");
    const vs_clay = b.step("vs-clay", "Build the Clay comparison harness (bench/vs/clay/)");
    vs_clay.dependOn(&b.addInstallArtifact(size_tool, .{}).step);
    if (b.lazyDependency("clay", .{})) |clay| {
        const adapter = resizeAdapter(b, resize_adapters, target, "clay", false);
        adapter.addCSourceFile(.{ .file = b.path("bench/vs/window-resize/clay.c"), .flags = &.{"-std=gnu99"} });
        adapter.addIncludePath(clay.path(""));
        // vs-clay links glibc dynamically (Clay's fastest frames; libc's code is not in its
        // loaded bytes); vs-clay-static is static against musl, for resident memory and start-up
        // beside the LCGF row, a static binary without libc: neither then pays for a dynamic C
        // library's loading and pages (bench/vs/measure.py --startup).
        var musl = target.query;
        musl.abi = .musl;
        const static = b.resolveTargetQuery(musl);
        for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSmall, .ReleaseFast }, [_][]const u8{ "vs-clay", "vs-clay-small", "vs-clay-static" }, [_]bool{ false, false, true }) |mode, name, is_static| {
            const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{ .target = if (is_static) static else target, .optimize = mode, .link_libc = true }) });
            exe.root_module.addCSourceFile(.{ .file = b.path("bench/vs/clay/main.c"), .flags = &.{"-std=gnu99"} });
            exe.root_module.addIncludePath(clay.path(""));
            vs_clay.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
        // Clay's layout alone, built as src/render/web/layout.zig is (zig-out/web/clay-layout.wasm).
        const wasm = b.addExecutable(.{ .name = "clay-layout", .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }) });
        wasm.root_module.addCSourceFile(.{ .file = b.path("bench/vs/clay/layout.c"), .flags = &.{"-std=gnu99"} });
        wasm.root_module.addIncludePath(clay.path(""));
        wasm.entry = .disabled; // its one export is named in the source: no --export-dynamic
        vs_clay.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    }
    const vs_imgui = b.step("vs-imgui", "Build the Dear ImGui comparison harness (bench/vs/imgui/)");
    vs_imgui.dependOn(&b.addInstallArtifact(size_tool, .{}).step);
    if (b.lazyDependency("imgui", .{})) |imgui| {
        const imgui_sources: []const []const u8 = &.{ "imgui.cpp", "imgui_draw.cpp", "imgui_widgets.cpp", "imgui_tables.cpp", "backends/imgui_impl_null.cpp" };
        const adapter = resizeAdapter(b, resize_adapters, target, "imgui", true);
        adapter.addCSourceFile(.{ .file = b.path("bench/vs/window-resize/imgui.cpp"), .flags = &.{"-std=c++17"} });
        adapter.addCSourceFiles(.{ .root = imgui.path(""), .files = imgui_sources, .flags = &.{"-std=c++17"} });
        adapter.addIncludePath(imgui.path(""));
        adapter.addIncludePath(imgui.path("backends"));
        for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSmall }, [_][]const u8{ "vs-imgui", "vs-imgui-small" }) |mode, name| {
            const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{ .target = target, .optimize = mode, .link_libcpp = true }) });
            exe.root_module.addCSourceFile(.{ .file = b.path("bench/vs/imgui/main.cpp"), .flags = &.{"-std=c++17"} });
            exe.root_module.addCSourceFiles(.{ .root = imgui.path(""), .files = imgui_sources, .flags = &.{"-std=c++17"} });
            exe.root_module.addIncludePath(imgui.path(""));
            exe.root_module.addIncludePath(imgui.path("backends"));
            vs_imgui.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }
    const vs_lvgl = b.step("vs-lvgl", "Build the LVGL comparison harness (bench/vs/lvgl/)");
    vs_lvgl.dependOn(&b.addInstallArtifact(size_tool, .{}).step);
    if (b.lazyDependency("lvgl", .{})) |lvgl| {
        // LVGL's defaults (LV_CONF_SKIP, no lv_conf.h) plus: 32-bit colour, Montserrat 20 for the
        // headings, and the C library's malloc instead of LVGL's fixed 64 KiB pool.
        const flags: []const []const u8 = &.{ "-std=gnu99", "-DLV_CONF_SKIP", "-DLV_COLOR_DEPTH=32", "-DLV_FONT_MONTSERRAT_20=1", "-DLV_USE_STDLIB_MALLOC=LV_STDLIB_CLIB", "-DLV_USE_STDLIB_STRING=LV_STDLIB_CLIB", "-DLV_USE_STDLIB_SPRINTF=LV_STDLIB_CLIB" };
        const adapter = resizeAdapter(b, resize_adapters, target, "lvgl", false);
        adapter.addCSourceFile(.{ .file = b.path("bench/vs/window-resize/lvgl.c"), .flags = flags });
        adapter.addCSourceFiles(.{ .root = lvgl.path(""), .files = &@import("bench/vs/lvgl/sources.zig").files, .flags = flags });
        adapter.addIncludePath(lvgl.path("include"));
        adapter.addIncludePath(lvgl.path("src"));
        for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSmall }, [_][]const u8{ "vs-lvgl", "vs-lvgl-small" }) |mode, name| {
            const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{ .target = target, .optimize = mode, .link_libc = true }) });
            exe.root_module.addCSourceFile(.{ .file = b.path("bench/vs/lvgl/main.c"), .flags = flags });
            exe.root_module.addCSourceFiles(.{ .root = lvgl.path(""), .files = &@import("bench/vs/lvgl/sources.zig").files, .flags = flags });
            exe.root_module.addIncludePath(lvgl.path("include"));
            exe.root_module.addIncludePath(lvgl.path("src"));
            vs_lvgl.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }

    // Conformance scenes as files for a real GPU (src/render/conformance/, ci/run.sh conformance).
    const conformance_dump = b.addExecutable(.{ .name = "conformance-dump", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/conformance/dump.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("conformance-dump", "Build zig-out/bin/conformance-dump (writes the render conformance scenes)").dependOn(&b.addInstallArtifact(conformance_dump, .{}).step);
    // The software renderer drawing a dumped frame as a PNG (src/render/sw/play.zig, ci/run.sh sw-golden).
    const sw_play = b.addExecutable(.{ .name = "sw-play", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/sw/play.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) });
    b.step("sw-play", "Build zig-out/bin/sw-play (draws a dumped frame in software)").dependOn(&b.addInstallArtifact(sw_play, .{}).step);

    // Every shader variant as files for a real GPU to validate (src/render/shaders/, ci/run.sh shaders).
    const shaders_dump = b.addExecutable(.{ .name = "shaders-dump", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/shaders/dump.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("shaders-dump", "Build zig-out/bin/shaders-dump (writes every shader variant)").dependOn(&b.addInstallArtifact(shaders_dump, .{}).step);

    // Fuzz the production frame, layout and hit-test paths.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    b.step("fuzz", "Run the fuzz tests (add --fuzz=N to fuzz)").dependOn(&b.addRunArtifact(fuzz_tests).step);
    const fuzz_run = b.addRunArtifact(b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_mod }));
    fuzz_run.addPassthruArgs();
    b.step("fuzz-run", "Fuzz for a time: -- [seconds] [seed] [first]").dependOn(&fuzz_run.step);

    // Object whose exported functions read the comptime flatten tables (ci/jobs/ct-rodata.sh
    // checks they land in read-only data).
    const ct_rodata = b.addObject(.{ .name = "ct_rodata", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/rodata_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("ct-rodata", "Build the object the read-only-data check reads").dependOn(&b.addInstallFile(ct_rodata.getEmittedBin(), "ct_rodata.o").step);
    // Read-only and RAM bytes of each example comptime UI (ci/jobs/ct-sizes.sh).
    const ct_sizes = b.addRunArtifact(b.addExecutable(.{ .name = "ct-sizes", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/sizes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) }));
    b.step("ct-sizes", "Print read-only and RAM bytes of each example comptime UI").dependOn(&ct_sizes.step);
    // Layout time of each example comptime UI against the runtime tree (ReleaseFast).
    const ct_layout_bench = b.addRunArtifact(b.addExecutable(.{ .name = "ct-layout-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/layout_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) }));
    b.step("ct-layout-bench", "Time comptime layout against the runtime tree per example").dependOn(&ct_layout_bench.step);
    // Both front ends in one program and one draw list (C0193-C0196): its tests, then the program.
    const ct_mixed_mod = b.createModule(.{
        .root_source_file = b.path("src/comptime/mixed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    const ct_mixed_step = b.step("ct-mixed", "Run the mixed front-end example (src/comptime/mixed.zig) and its tests");
    ct_mixed_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ct_mixed_mod })).step);
    ct_mixed_step.dependOn(&b.addRunArtifact(b.addExecutable(.{ .name = "ct-mixed", .root_module = ct_mixed_mod })).step);
    const ct_paint_bench = b.addRunArtifact(b.addExecutable(.{ .name = "ct-paint-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/paint_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) }));
    b.step("ct-paint-bench", "Time full static paint and single-field patches against runtime paint").dependOn(&ct_paint_bench.step);
    // Code size of comptime layout, table-driven against unrolled (C0165): installs
    // zig-out/bin/ct-layout-size for `nm --size-sort` and runs it for the timings.
    const ct_layout_size = b.addExecutable(.{ .name = "ct-layout-size", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/layout_size_probe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }},
    }) });
    const ct_layout_size_run = b.addRunArtifact(ct_layout_size);
    ct_layout_size_run.step.dependOn(&b.addInstallArtifact(ct_layout_size, .{}).step);
    b.step("ct-layout-size", "Time and install comptime layout, table-driven and unrolled").dependOn(&ct_layout_size_run.step);
    const ct_feature_sizes = b.step("ct-feature-sizes", "Link stripped renderer feature variants for the size comparison");
    for ([_][]const u8{ "plain", "caption", "full" }, 0..) |name, mode| {
        const size_probe = b.createModule(.{
            .root_source_file = b.path("src/comptime/feature_size_probe.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "lcgf", .module = lcgf }},
        });
        const opt = b.addOptions();
        opt.addOption(u8, "mode", @intCast(mode));
        size_probe.addOptions("probe_options", opt);
        const lib_probe = b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = size_probe });
        ct_feature_sizes.dependOn(&b.addInstallFile(lib_probe.getEmittedBin(), b.fmt("ct-feature-sizes/{s}.so", .{name})).step);
    }
    // Compile-fail cases for the comptime front end's rules (src/comptime/compile_fail/): each
    // file is built as an object and must fail with the message on its `//! expect: ` first line.
    const compile_fail = b.step("ct-compile-fail", "Check each comptime rule rejects its compile-fail case");
    {
        const io = b.graph.io;
        const sub = "src/comptime/compile_fail";
        var dir = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, sub }), .{ .iterate = true }) catch @panic("cannot open " ++ sub);
        defer dir.close(io);
        // The cases are read while configuring, so the configuration cache must know about them.
        b.dependOnDirectoryContents(b.path(sub));
        var it = dir.iterate();
        while (it.next(io) catch @panic("cannot list " ++ sub)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            b.dependOnFileContents(b.path(b.pathJoin(&.{ sub, entry.name })));
            const text = dir.readFileAlloc(io, entry.name, b.allocator, .limited(1 << 16)) catch @panic("cannot read a compile-fail case");
            const tag = "//! expect: ";
            if (!std.mem.startsWith(u8, text, tag)) std.debug.panic("{s}/{s}: first line is not '{s}<message>'", .{ sub, entry.name, tag });
            const case = b.addObject(.{ .name = b.dupe(entry.name[0 .. entry.name.len - 4]), .root_module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(&.{ sub, entry.name })),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lcgf", .module = lcgf }},
            }) });
            case.expect_errors = .{ .contains = text[tag.len..std.mem.indexOfScalar(u8, text, '\n').?] };
            compile_fail.dependOn(&case.step);
        }
    }
    // Object exporting the comptime setter (ci/jobs/ct-setter.sh checks it is a store and an OR).
    const ct_setter = b.addObject(.{ .name = "ct_setter", .root_module = b.createModule(.{
        .root_source_file = b.path("src/comptime/setter_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("ct-setter", "Build the object the setter-shape check reads").dependOn(&b.addInstallFile(ct_setter.getEmittedBin(), "ct_setter.o").step);
    // Font parser fuzzing (src/text/font/fuzz.zig): seeded mutation loop for a set time.
    const font_fuzz = b.addRunArtifact(b.addExecutable(.{ .name = "font-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/font/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    font_fuzz.addPassthruArgs();
    b.step("font-fuzz", "Fuzz the font parser: -- [seconds] [seed] [first]").dependOn(&font_fuzz.step);
    // PNG decoder fuzzing (src/assets/png_fuzz.zig): seeded mutation loop for a set time.
    const png_fuzz = b.addRunArtifact(b.addExecutable(.{ .name = "png-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("src/assets/png_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    png_fuzz.addPassthruArgs();
    b.step("png-fuzz", "Fuzz the PNG decoder: -- [seconds] [seed] [first]").dependOn(&png_fuzz.step);

    // The optional HarfBuzz adapter: outside the tiers (it links a C library), so a module of
    // its own over lcgf, never imported by it.
    const harfbuzz = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/shape/harfbuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // HarfBuzz 13.2.1 from build.zig.zon (lazy: fetched only for this step), compiled from its
    // single-file amalgamation; no system library.
    if (b.lazyDependency("harfbuzz", .{})) |hb| {
        const hb_lib = b.addLibrary(.{ .name = "harfbuzz", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }) });
        hb_lib.root_module.addCSourceFile(.{ .file = hb.path("src/harfbuzz.cc"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DHB_NO_MT" } });
        harfbuzz.root_module.linkLibrary(hb_lib);
    }
    b.step("harfbuzz", "Test the HarfBuzz shaping adapter (HarfBuzz built from source)").dependOn(&b.addRunArtifact(harfbuzz).step);

    // Developer tools (src/devtools/): outside the tiers (timing reads the host's std.Io clock),
    // so a module of its own over lcgf, never imported by it.
    const devtools = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/devtools/devtools.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    devtools.root_module.addAnonymousImport("example.replay", .{ .root_source_file = b.path("src/shell/testdata/example.replay") });
    b.step("devtools", "Test the inspector and developer tools (ci/run.sh devtools)").dependOn(&b.addRunArtifact(devtools).step);

    // System font discovery for the fallback chain (src/text/fallback/system.zig): outside the
    // tiers (DirectWrite, Core Text, fontconfig), a module of its own over lcgf.
    const fallback_system = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/fallback/system.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    const fallback_run = b.addRunArtifact(fallback_system);
    // Its result depends on the installed fonts, which the cache cannot see.
    fallback_run.has_side_effects = true;
    b.step("fallback-system", "Render the mixed-script sample from system fonts (ci/run.sh fallback-system)").dependOn(&fallback_run.step);
    b.step("fallback-system-build", "Compile the system font discovery tests without running them").dependOn(&fallback_system.step);

    // The i18n tables against CLDR 49 JSON (lazy: fetched only for this step). Test-only, so a
    // module of its own over lcgf; the tables themselves stay hand-written and tier 0.
    const i18n_cldr = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/i18n/cldr.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    if (b.lazyDependency("cldr_core", .{})) |core| {
        i18n_cldr.root_module.addAnonymousImport("plurals.json", .{ .root_source_file = core.path("supplemental/plurals.json") });
        i18n_cldr.root_module.addAnonymousImport("numberingSystems.json", .{ .root_source_file = core.path("supplemental/numberingSystems.json") });
    }
    for ([_][]const u8{ "en", "de", "fr", "ru", "pl", "ja", "ar" }) |l| {
        if (b.lazyDependency("cldr_numbers", .{})) |numbers|
            i18n_cldr.root_module.addAnonymousImport(b.fmt("numbers-{s}.json", .{l}), .{ .root_source_file = numbers.path(b.fmt("main/{s}/numbers.json", .{l})) });
        if (b.lazyDependency("cldr_dates", .{})) |dates|
            i18n_cldr.root_module.addAnonymousImport(b.fmt("gregorian-{s}.json", .{l}), .{ .root_source_file = dates.path(b.fmt("main/{s}/ca-gregorian.json", .{l})) });
    }
    b.step("i18n-cldr", "Check the i18n locale tables against CLDR 49").dependOn(&b.addRunArtifact(i18n_cldr).step);

    // Path golden images (src/draw/paths_golden.zig; ci/run.sh paths-golden compares them).
    const paths_golden = b.addRunArtifact(b.addExecutable(.{ .name = "paths-golden", .root_module = b.createModule(.{
        .root_source_file = b.path("src/draw/paths_golden.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) }));
    paths_golden.addPassthruArgs();
    b.step("paths-golden", "Draw the path scenes for the golden check: -- OUT.bin").dependOn(&paths_golden.step);

    // The Vulkan back end (src/render/vk/vk.zig): a module of its own over lcgf. Khronos
    // Vulkan-Headers (build.zig.zon, lazy) translated with VK_NO_PROTOTYPES; the loader is the
    // platform's libvulkan, opened at run time, so nothing Vulkan is linked.
    const vk_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/vk/vk.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // Draws the render conformance scenes as PNGs (src/render/vk/play.zig).
    const vk_play = b.addExecutable(.{ .name = "vk-play", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/vk/play.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // Memory and frame-time probe against the wgpu back end (src/render/vk/probe.zig).
    const vk_probe = b.addExecutable(.{ .name = "vk-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/vk/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    const vk_step = b.step("vk", "Test the Vulkan back end on a real implementation (ci/run.sh vk)");
    const vk_play_step = b.step("vk-play", "Build zig-out/bin/vk-play (draws the render conformance scenes with Vulkan) and vk-probe");
    if (b.lazyDependency("vulkan_headers", .{})) |vulkan_headers| {
        const vk_h = b.addTranslateC(.{ .root_source_file = vulkan_headers.path("include/vulkan/vulkan_core.h"), .target = target, .optimize = optimize });
        vk_h.addIncludePath(vulkan_headers.path("include"));
        vk_h.defineCMacro("VK_NO_PROTOTYPES", null);
        const vk_c = vk_h.createModule();
        const vk_shaders = addGpuShaders(b, .vk, .{ .prebuilt = b.path("src/render/shaders/gen") }, repo_gpu_shaders(b));
        // The gpu guide's example (docs/guide/gpu.zig), run on the device by a vk test.
        vk_tests.root_module.addAnonymousImport("guide_gpu", .{ .root_source_file = b.path("docs/guide/gpu.zig") });
        for ([_]*std.Build.Module{ vk_tests.root_module, vk_play.root_module, vk_probe.root_module }) |m| {
            m.addImport("vk_c", vk_c);
            // The repository's lcgf_render.gpu shaders (src/render/gpu/*.wgsl), translated.
            m.addImport("gpu_shaders", vk_shaders);
            // The committed SPIR-V of the shipped shaders (src/render/shaders/gen/, from naga).
            m.addAnonymousImport("stock_spv", .{ .root_source_file = b.path("src/render/shaders/gen/stock.spv") });
            m.addAnonymousImport("canvas_spv", .{ .root_source_file = b.path("src/render/shaders/gen/canvas.spv") });
            m.addAnonymousImport("example_spv", .{ .root_source_file = b.path("src/render/shaders/gen/example.spv") });
            // The render conformance goldens, for the in-test comparison (src/render/vk/scenes.zig).
            for ([_][]const u8{ "rects", "clip", "text", "custom" }) |n|
                m.addAnonymousImport(b.fmt("golden_{s}", .{n}), .{ .root_source_file = b.path(b.fmt("src/render/conformance/{s}.png", .{n})) });
        }
        // The custom-node timing of docs/research/custom-webgpu/, through lcgf_render.gpu: a
        // matched pair, the same scene with and without the application's drawing compiled in.
        // It replaced the wgpu-native guest experiment (probe_guest.zig, retired; see the report).
        const experiment = b.step("custom-draw-probe", "Build the matched custom-node timing probes (src/render/vk/probe_projection.zig)");
        const probe_shaders = addGpuShaders(b, .vk, .naga, &.{.{ .name = "node", .path = b.path("src/render/vk/probe_projection.wgsl") }});
        for ([_]bool{ false, true }) |enabled| {
            const features = b.addOptions();
            features.addOption(bool, "enabled", enabled);
            const node_probe = b.addExecutable(.{ .name = if (enabled) "custom-draw-projection" else "custom-draw-native", .root_module = b.createModule(.{
                .root_source_file = b.path("src/render/vk/probe_projection.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "vk_c", .module = vk_c }, .{ .name = "gpu_shaders", .module = vk_shaders }, .{ .name = "probe_shaders", .module = probe_shaders } },
            }) });
            node_probe.root_module.addImport("custom_draw_scene", custom_draw_scene);
            node_probe.root_module.addOptions("custom_draw", features);
            for ([_][]const u8{ "stock", "example", "canvas" }) |shader| node_probe.root_module.addAnonymousImport(b.fmt("{s}_spv", .{shader}), .{
                .root_source_file = b.path(b.fmt("src/render/shaders/gen/{s}.spv", .{shader})),
            });
            experiment.dependOn(&b.addInstallArtifact(node_probe, .{}).step);
        }
        // The projection's zero-cost check (src/render/vk/gpu_probe.zig, ci/jobs/gpu-zero-cost.sh):
        // a hand-written draw and the same draw through lcgf_render.gpu, ReleaseFast.
        const gpu_probe = b.addObject(.{ .name = "gpu-probe", .root_module = b.createModule(.{
            .root_source_file = b.path("src/render/vk/gpu_probe.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "vk_c", .module = vk_c }, .{ .name = "gpu_shaders", .module = vk_shaders } },
        }) });
        b.step("gpu-probe", "Build zig-out/gpu-probe.o, the projection's zero-cost check (ci/run.sh gpu-zero-cost)").dependOn(&b.addInstallFile(gpu_probe.getEmittedBin(), "gpu-probe.o").step);
        // The canvas benchmark on Vulkan: 100k primitives panned, zoomed and edited, ReleaseFast.
        const vk_canvasbench = b.addExecutable(.{ .name = "vk-canvasbench", .root_module = b.createModule(.{
            .root_source_file = b.path("src/render/vk/canvasbench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf_fast }, .{ .name = "vk_c", .module = vk_c } },
        }) });
        vk_canvasbench.root_module.addAnonymousImport("canvasbench", .{ .root_source_file = b.path("bench/micro/canvasbench.zig"), .imports = &.{.{ .name = "lcgf", .module = lcgf_fast }} });
        for ([_][]const u8{ "stock", "example", "canvas" }) |v|
            vk_canvasbench.root_module.addAnonymousImport(b.fmt("{s}_spv", .{v}), .{ .root_source_file = b.path(b.fmt("src/render/shaders/gen/{s}.spv", .{v})) });
        b.step("vk-canvasbench", "Build zig-out/bin/vk-canvasbench (the canvas benchmark on Vulkan)").dependOn(&b.addInstallArtifact(vk_canvasbench, .{}).step);
        vk_step.dependOn(&b.addRunArtifact(vk_tests).step);
        vk_play_step.dependOn(&b.addInstallArtifact(vk_play, .{}).step);
        vk_play_step.dependOn(&b.addInstallArtifact(vk_probe, .{}).step);
    }

    const render_check = b.addObject(.{ .name = "render-select", .root_module = lcgf_render });
    b.step("render", "Compile the lcgf_render module for -Drender and -Dtarget (src/render/select.zig)").dependOn(&render_check.step);
    if (render == .wgpu and !wgpu_supported) render_check.step.dependOn(&b.addFail("-Drender=wgpu needs -Dwgpu-native=v27 or v29 on a target with an archive").step);
    // The selector's zero-cost check (src/render/select_probe.zig, ci/run.sh render-select):
    // one probe object through lcgf_render and one through the back end's own module,
    // ReleaseFast and stripped, in zig-out/render-probe/.
    const render_probe_step = b.step("render-probe", "Build the -Drender probe through the selector and directly into zig-out/render-probe/");
    render_probe_step.dependOn(&render_check.step);
    for ([_]bool{ true, false }) |selector| {
        const probe_options = b.addOptions();
        probe_options.addOption(bool, "selector", selector);
        const m = b.createModule(.{
            .root_source_file = b.path("src/render/select_probe.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{.{ .name = "lcgf", .module = lcgf }},
        });
        m.addOptions("probe_options", probe_options);
        if (selector) m.addImport("lcgf_render", lcgf_render) else {
            m.addOptions("render_options", render_options);
            if (renderBackend(b, render, target, optimize, lcgf, wgpu_native_mod)) |backend| m.addImport("render_backend", backend);
        }
        const obj = b.addObject(.{ .name = "probe", .root_module = m });
        render_probe_step.dependOn(&b.addInstallFile(obj.getEmittedBin(), b.fmt("render-probe/{s}.o", .{if (selector) "selector" else "direct"})).step);
    }

    // The GL ES back end (src/render/gles/gles.zig): a module of its own over lcgf. EGL and
    // GL ES are the platform's, opened at run time, so nothing GL is linked.
    const gles_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/gles/gles.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // Draws the render conformance scenes as PNGs (src/render/gles/play.zig).
    const gles_play = b.addExecutable(.{ .name = "gles-play", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/gles/play.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // The committed GLSL ES 3.0 of the shipped shaders (src/render/shaders/gen/, from naga).
    const gles_shaders = addGpuShaders(b, .gles, .{ .prebuilt = b.path("src/render/shaders/gen") }, repo_gpu_shaders(b));
    for ([_]*std.Build.Module{ gles_tests.root_module, gles_play.root_module }) |m| {
        m.addImport("gpu_shaders", gles_shaders);
        for ([_][]const u8{ "stock", "example", "canvas" }) |v| for ([_][]const u8{ "vert", "frag" }) |stage| {
            m.addAnonymousImport(b.fmt("{s}_{s}", .{ v, stage }), .{ .root_source_file = b.path(b.fmt("src/render/shaders/gen/{s}.{s}", .{ v, stage })) });
        };
    }
    b.step("gles", "Test the GL ES back end on a real driver (ci/run.sh gles)").dependOn(&b.addRunArtifact(gles_tests).step);
    b.step("gles-play", "Build zig-out/bin/gles-play (draws the render conformance scenes with GL ES)").dependOn(&b.addInstallArtifact(gles_play, .{}).step);

    // The bare-metal example (src/shell/baremetal/firmware.zig), a module of its own over lcgf:
    // its test runs it here, and it is built as a freestanding executable for two
    // microcontrollers (ci/run.sh baremetal).
    const baremetal_step = b.step("baremetal", "Run the bare-metal example and build it for Cortex-M7 and RV32IMAC");
    const firmware_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/baremetal/firmware.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    baremetal_step.dependOn(&b.addRunArtifact(firmware_test).step);
    for ([_]struct { []const u8, std.Target.Query }{
        .{ "cortex-m7", .{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 } } },
        .{ "rv32imac", .{ .cpu_arch = .riscv32, .os_tag = .freestanding, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.sifive_e31 } } }, // RV32IMAC
    }) |mcu| {
        const mcu_target = b.resolveTargetQuery(mcu[1]);
        const mcu_lcgf = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = mcu_target, .optimize = .ReleaseSmall });
        mcu_lcgf.addOptions("build_options", options);
        mcu_lcgf.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
        const firmware = b.addExecutable(.{ .name = b.fmt("firmware-{s}", .{mcu[0]}), .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/baremetal/firmware.zig"),
            .target = mcu_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "lcgf", .module = mcu_lcgf }},
        }) });
        firmware.entry = .{ .symbol_name = "_start" };
        baremetal_step.dependOn(&b.addInstallArtifact(firmware, .{}).step);
    }
    // The embedded profile's demo (examples/embedded/demo.zig): its test runs here, and it is
    // linked freestanding, unstripped so its symbols can be checked (ci/run.sh embedded).
    const embedded_step = b.step("embedded", "Run the embedded demo and link it for microcontrollers");
    const sim_step = b.step("embedded-sim", "Replay the counter board on a simulated SPI display");
    const sim_module = b.createModule(.{ .root_source_file = b.path("examples/embedded/simulator.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lcgf", .module = lcgf }} });
    sim_step.dependOn(&b.addRunArtifact(b.addExecutable(.{ .name = "embedded-simulator", .root_module = sim_module })).step);
    sim_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sim_module })).step);
    const no_float = b.option(bool, "no-float", "Bake the fixed embedded panel and render it with integer-only firmware") orelse false;
    const embedded_root = b.path(if (no_float) "examples/embedded/integer.zig" else "examples/embedded/demo.zig");
    const baked = if (no_float) blk: {
        const host_lcgf = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = b.graph.host, .optimize = .ReleaseFast });
        host_lcgf.addOptions("build_options", options);
        host_lcgf.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
        const bake = b.addRunArtifact(b.addExecutable(.{ .name = "bake-embedded-panel", .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embedded/bake.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "lcgf", .module = host_lcgf }},
        }) }));
        break :blk bake.addOutputFileArg("panel_assets.zig");
    } else null;
    const embedded_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = embedded_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    if (baked) |asset| embedded_test.root_module.addAnonymousImport("panel_assets", .{ .root_source_file = asset });
    embedded_step.dependOn(&b.addRunArtifact(embedded_test).step);
    const embedded_unit = b.addTest(.{ .name = "embedded-test", .root_module = lcgf, .filters = &.{"embedded"} });
    embedded_step.dependOn(&b.addRunArtifact(embedded_unit).step);
    for ([_]struct { []const u8, std.Target.Query }{
        .{ "cortex-m7", .{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 } } },
        .{ "rv32imac", .{ .cpu_arch = .riscv32, .os_tag = .freestanding, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.sifive_e31 } } },
    }) |mcu| {
        const mcu_target = b.resolveTargetQuery(mcu[1]);
        const mcu_lcgf = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = mcu_target, .optimize = .ReleaseSmall });
        mcu_lcgf.addOptions("build_options", options);
        mcu_lcgf.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
        const demo = b.addExecutable(.{ .name = b.fmt("embedded-demo-{s}", .{mcu[0]}), .root_module = b.createModule(.{
            .root_source_file = embedded_root,
            .target = mcu_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .imports = &.{.{ .name = "lcgf", .module = mcu_lcgf }},
        }) });
        if (baked) |asset| {
            demo.root_module.addAnonymousImport("panel_assets", .{ .root_source_file = asset });
            embedded_step.dependOn(&b.addInstallFile(demo.getEmittedAsm(), b.fmt("asm/embedded-{s}.s", .{mcu[0]})).step);
        }
        demo.entry = .{ .symbol_name = "_start" };
        embedded_step.dependOn(&b.addInstallArtifact(demo, .{}).step);
    }
    // The web back end (src/render/web/): wasm32-freestanding modules and the JavaScript that
    // loads them, installed together in zig-out/web/ for a browser (ci/run.sh web).
    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_optimize = b.option(std.builtin.OptimizeMode, "web-optimize", "Optimize mode of the web modules (default ReleaseSmall)") orelse .small;
    const lcgf_web = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = web_target, .optimize = web_optimize });
    lcgf_web.addOptions("build_options", options);
    lcgf_web.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
    const web_step = b.step("web", "Build the web examples and their JavaScript into zig-out/web/ (ci/run.sh web)");
    // The repository's lcgf_render.gpu shaders, for scenes.wasm: the browser takes the WGSL.
    const web_shaders = addGpuShaders(b, .web, .{ .prebuilt = b.path("src/render/shaders/gen") }, repo_gpu_shaders(b));
    for ([_][]const u8{ "hello", "scenes", "layout" }) |name| {
        const wasm = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/render/web/{s}.zig", .{name})),
            .target = web_target,
            .optimize = web_optimize,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf_web }, .{ .name = "gpu_shaders", .module = web_shaders } },
        }) });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    }
    web_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("src/render/web"), .install_dir = .{ .custom = "web" }, .install_subdir = "", .include_extensions = &.{ ".js", ".html" } }).step);
    // The web shell's example (src/shell/web/): the shell from lcgf, the back end as a module.
    const render_web = b.createModule(.{ .root_source_file = b.path("src/render/web/web.zig"), .target = web_target, .optimize = web_optimize, .imports = &.{.{ .name = "lcgf", .module = lcgf_web }} });
    const shell_wasm = b.addExecutable(.{ .name = "shell", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/web/main.zig"),
        .target = web_target,
        .optimize = web_optimize,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_web }, .{ .name = "render_web", .module = render_web } },
    }) });
    shell_wasm.entry = .disabled;
    shell_wasm.rdynamic = true;
    web_step.dependOn(&b.addInstallArtifact(shell_wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    web_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("src/shell/web"), .install_dir = .{ .custom = "web" }, .install_subdir = "", .include_extensions = &.{ ".js", ".html" } }).step);

    // The Metal back end (src/render/metal/metal.zig): a module of its own over lcgf. libobjc,
    // Metal and QuartzCore are the platform's, opened at run time, so nothing is linked and it
    // cross-compiles from Linux (ci/run.sh metal).
    const metal_tests = b.addTest(.{ .name = "metal-test", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/metal/metal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // Draws the render conformance scenes as PNGs on a Mac (src/render/metal/play.zig).
    const metal_play = b.addExecutable(.{ .name = "metal-play", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/metal/play.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    const metal_custom = b.addExecutable(.{ .name = "metal-webgpu-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/metal/probe_webgpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "wgpu_native", .module = wgpu_native_mod } },
    }) });
    metal_custom.root_module.addImport("custom_draw_scene", custom_draw_scene);
    metal_custom.root_module.addImport("custom_draw_sample", b.createModule(.{
        .root_source_file = b.path("src/render/wgpu/custom_draw_sample.zig"),
        .imports = &.{.{ .name = "wgpu_native", .module = wgpu_native_mod }},
    }));
    const metal_custom_step = b.step("metal-webgpu-probe", "Build the shared WebGPU callback experiment on macOS with -Dwgpu-native=v29");
    if (target.result.os.tag == .macos and wgpu_version == .v29) {
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            const root: std.Build.LazyPath = .{ .cwd_relative = sdk };
            metal_custom.root_module.addFrameworkPath(root.path(b, "System/Library/Frameworks"));
            metal_custom.root_module.addLibraryPath(root.path(b, "usr/lib"));
        }
        metal_custom_step.dependOn(&b.addInstallArtifact(metal_custom, .{}).step);
    } else metal_custom_step.dependOn(&b.addFail("requires a macOS target and -Dwgpu-native=v29").step);
    // The committed MSL of the shipped shaders (src/render/shaders/gen/, from naga).
    const metal_shaders = addGpuShaders(b, .metal, .{ .prebuilt = b.path("src/render/shaders/gen") }, repo_gpu_shaders(b));
    for ([_]*std.Build.Module{ metal_tests.root_module, metal_play.root_module, metal_custom.root_module }) |m| {
        m.addImport("gpu_shaders", metal_shaders);
        for ([_][]const u8{ "stock", "example", "canvas" }) |v|
            m.addAnonymousImport(b.fmt("{s}_metal", .{v}), .{ .root_source_file = b.path(b.fmt("src/render/shaders/gen/{s}.metal", .{v})) });
    }
    b.step("metal", "Test the Metal back end (device tests skip off macOS)").dependOn(&b.addRunArtifact(metal_tests).step);
    b.step("metal-build", "Build the Metal back end's tests for -Dtarget without running them").dependOn(&b.addInstallArtifact(metal_tests, .{}).step);
    b.step("metal-play", "Build zig-out/bin/metal-play (draws the render conformance scenes with Metal)").dependOn(&b.addInstallArtifact(metal_play, .{}).step);

    // The Direct3D 12 back end (src/render/d3d12/d3d12.zig): a module of its own over lcgf, always
    // built for x86_64-windows (ci/run.sh d3d12 runs it under Wine). Zig's own MinGW-w64 headers
    // are translated for the structs and constants (com.zig checks its hand-written vtable slots
    // against them); d3d12, dxgi and d3dcompiler_47 are linked from Zig's MinGW import libraries.
    const win = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const lcgf_win = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = win, .optimize = optimize });
    lcgf_win.addOptions("build_options", options);
    lcgf_win.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
    const d3d12_h = b.addTranslateC(.{ .root_source_file = b.path("src/render/d3d12/c.h"), .target = win, .optimize = optimize, .link_libc = true });
    const d3d12_c = d3d12_h.createModule();
    const d3d12_tests = b.addTest(.{ .name = "d3d12-test", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/d3d12/d3d12.zig"),
        .target = win,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_win }, .{ .name = "d3d12_c", .module = d3d12_c } },
    }) });
    // Draws the render conformance scenes as PNGs (src/render/d3d12/play.zig).
    const d3d12_play = b.addExecutable(.{ .name = "d3d12-play", .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/d3d12/play.zig"),
        .target = win,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_win }, .{ .name = "d3d12_c", .module = d3d12_c } },
    }) });
    const d3d12_shaders = addGpuShaders(b, .d3d12, .{ .prebuilt = b.path("src/render/shaders/gen") }, repo_gpu_shaders(b));
    for ([_]*std.Build.Module{ d3d12_tests.root_module, d3d12_play.root_module }) |m| {
        m.addImport("gpu_shaders", d3d12_shaders);
        for ([_][]const u8{ "d3d12", "dxgi", "d3dcompiler_47", "user32", "kernel32" }) |l| m.linkSystemLibrary(l, .{ .use_pkg_config = .no });
        // The committed HLSL of the shipped shaders (src/render/shaders/gen/, from naga).
        for ([_][]const u8{ "stock", "example", "canvas" }) |v|
            m.addAnonymousImport(b.fmt("{s}_hlsl", .{v}), .{ .root_source_file = b.path(b.fmt("src/render/shaders/gen/{s}.hlsl", .{v})) });
        for ([_][]const u8{ "rects", "clip", "text", "custom" }) |n|
            m.addAnonymousImport(b.fmt("golden_{s}", .{n}), .{ .root_source_file = b.path(b.fmt("src/render/conformance/{s}.png", .{n})) });
    }
    const d3d12_step = b.step("d3d12", "Build zig-out/bin/d3d12-test.exe (the Direct3D 12 back end's tests) and d3d12-play.exe (draws the render conformance scenes); ci/run.sh d3d12 runs them under Wine");
    d3d12_step.dependOn(&b.addInstallArtifact(d3d12_tests, .{}).step);
    d3d12_step.dependOn(&b.addInstallArtifact(d3d12_play, .{}).step);

    // The AccessKit bridge (src/a11y/accesskit/): outside the tiers, a module of its own over
    // lcgf. AccessKit's C release archive (build.zig.zon, lazy) carries prebuilt static
    // libraries per target; its few calls are declared by hand (c.zig), so no header is
    // translated.
    const accesskit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/a11y/accesskit/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    const accesskit_step = b.step("accesskit", "Test the AccessKit bridge against AccessKit's C library (ci/run.sh accesskit)");
    const accesskit_build_step = b.step("accesskit-build", "Compile and link the AccessKit bridge tests without running them");
    const accesskit_smoke_step = b.step("accesskit-smoke", "Build zig-out/bin/accesskit-smoke (the example on AT-SPI, Linux)");
    const ak_os = target.result.os.tag;
    const ak_arch: ?[]const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .x86 => "x86",
        .aarch64 => if (ak_os == .macos) "arm64" else if (ak_os == .windows) "arm64" else null,
        else => null,
    };
    const ak_lib: ?[]const u8 = if (ak_arch) |arch| switch (ak_os) {
        .linux => b.fmt("lib/linux/{s}/static/libaccesskit.a", .{arch}),
        .macos => b.fmt("lib/macos/{s}/static/libaccesskit.a", .{arch}),
        .windows => if (target.result.abi == .msvc) b.fmt("lib/windows/{s}/msvc/static/accesskit.lib", .{arch}) else b.fmt("lib/windows/{s}/mingw/static/libaccesskit.a", .{arch}),
        else => null,
    } else null;
    const enable_accesskit = b.option(bool, "accesskit", "Resolve the optional AccessKit dependency") orelse true;
    if (!enable_accesskit or ak_lib == null) {
        const fail = b.addFail(if (!enable_accesskit) "enable -Daccesskit for the AccessKit steps" else "AccessKit's archive has no static library for this target");
        accesskit_step.dependOn(&fail.step);
        accesskit_build_step.dependOn(&fail.step);
    }
    if (if (enable_accesskit and ak_lib != null) b.lazyDependency("accesskit", .{}) else null) |ak| {
        const m = accesskit_tests.root_module;
        m.addObjectFile(ak.path(ak_lib.?));
        switch (ak_os) {
            .macos => {
                if (b.graph.environ_map.get("SDKROOT")) |sdk| {
                    const root: std.Build.LazyPath = .{ .cwd_relative = sdk };
                    m.addSystemFrameworkPath(root.path(b, "System/Library/Frameworks"));
                    m.addLibraryPath(root.path(b, "usr/lib"));
                }
                for ([_][]const u8{ "AppKit", "Foundation" }) |f| m.linkFramework(f, .{});
            },
            .windows => for ([_][]const u8{ "uiautomationcore", "user32", "oleaut32", "ole32", "ntdll", "userenv", "ws2_32", "bcrypt", "unwind" }) |l| m.linkSystemLibrary(l, .{ .use_pkg_config = .no }),
            // Rust panics unwind: libunwind is Zig's own, built for the target.
            else => for ([_][]const u8{ "m", "dl", "pthread", "unwind" }) |l| m.linkSystemLibrary(l, .{}),
        }
        if (ak_os == .linux) {
            // The example on AT-SPI with no window, for the screen-reader smoke test
            // (src/a11y/accesskit/smoke.zig, ci/jobs/accesskit-linux.sh).
            const smoke = b.addExecutable(.{ .name = "accesskit-smoke", .root_module = b.createModule(.{
                .root_source_file = b.path("src/a11y/accesskit/smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "lcgf", .module = lcgf }},
            }) });
            smoke.root_module.addObjectFile(ak.path(ak_lib.?));
            for ([_][]const u8{ "m", "dl", "pthread", "unwind" }) |l| smoke.root_module.linkSystemLibrary(l, .{});
            accesskit_smoke_step.dependOn(&b.addInstallArtifact(smoke, .{}).step);
        }
        accesskit_step.dependOn(&b.addRunArtifact(accesskit_tests).step);
        accesskit_build_step.dependOn(&accesskit_tests.step);
    }

    // The X11 shell (src/shell/x11/x11.zig): a module of its own over lcgf, Linux only. Its
    // tests that need a server run when LCGF_X11_TEST_DISPLAY names one (ci/run.sh x11).
    const x11_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/x11/x11.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    x11_tests.root_module.addAnonymousImport("example.replay", .{ .root_source_file = b.path("src/shell/testdata/example.replay") });
    const x11_run = b.addRunArtifact(x11_tests);
    x11_run.has_side_effects = true; // the result depends on the X server, not only on the inputs
    b.step("x11", "Test the X11 shell (on a server when LCGF_X11_TEST_DISPLAY is set; ci/run.sh x11)").dependOn(&x11_run.step);
    // The example application in an X11 window (src/shell/x11/example.zig).
    const x11_example = b.addExecutable(.{ .name = "x11-example", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/x11/example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("x11-example", "Build zig-out/bin/x11-example (the example in an X11 window)").dependOn(&b.addInstallArtifact(x11_example, .{}).step);
    // Vulkan over an X window (src/shell/x11/gpu.zig): a module over lcgf and the Vulkan back
    // end, which opens the Vulkan loader and libxcb at run time and so links libc. Its test
    // draws into a window of the server LCGF_X11_TEST_DISPLAY names (ci/run.sh x11-gpu: Xvfb
    // and Mesa lavapipe).
    const x11_gpu_step = b.step("x11-gpu", "Test Vulkan over an X window (ci/run.sh x11-gpu)");
    if (renderBackend(b, .vk, target, optimize, lcgf, wgpu_native_mod)) |x11_vk| {
        const x11_gpu_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/x11/gpu.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lcgf", .module = lcgf },
                .{ .name = "vk", .module = x11_vk },
                .{ .name = "x11", .module = b.createModule(.{
                    .root_source_file = b.path("src/shell/x11/x11.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "lcgf", .module = lcgf }},
                }) },
            },
        }) });
        const x11_gpu_run = b.addRunArtifact(x11_gpu_tests);
        x11_gpu_run.has_side_effects = true; // the result depends on the server and the driver
        x11_gpu_step.dependOn(&x11_gpu_run.step);
    }

    // The Win32 shell (src/shell/win32/win32.zig): a module of its own over lcgf. user32, gdi32
    // and kernel32 are the system's; build with -Dtarget=x86_64-windows.
    const win32_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/win32/win32.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("win32", "Test the Win32 shell on Windows").dependOn(&b.addRunArtifact(win32_tests).step);
    b.step("win32-build", "Compile the Win32 shell's tests without running them (ci/run.sh win32)").dependOn(&win32_tests.step);
    // The shells' example in a Win32 window (src/shell/win32/example.zig).
    const win32_example = b.addExecutable(.{ .name = "win32-example", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/win32/example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("win32-example", "Build zig-out/bin/win32-example.exe, the example in a Win32 window").dependOn(&b.addInstallArtifact(win32_example, .{}).step);

    // The iOS shell (src/shell/ios/ios.zig) and its example, over lcgf and the Metal back end.
    // UIKit, Core Foundation and Metal are opened at run time; without an iOS SDK nothing links
    // here, so the example is a static library an app bundle links (ci/run.sh ios).
    const ios_metal = renderBackend(b, .metal, target, optimize, lcgf, wgpu_native_mod).?;
    const ios_example = b.addLibrary(.{ .name = "ios-example", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/ios/example.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "metal", .module = ios_metal } },
    }) });
    b.step("ios-build", "Build zig-out/lib/libios-example.a, the example in the iOS shell (-Dtarget=aarch64-ios; --replay runs the input replay test)").dependOn(&b.addInstallArtifact(ios_example, .{}).step);

    // The Android shell (src/shell/android/android.zig) and its example, over lcgf and the
    // Vulkan back end: a shared library a NativeActivity loads. There is no NDK here, so the
    // Android libraries are linked through stubs: empty shared libraries named libandroid.so,
    // liblog.so, libdl.so, libm.so and libc.so (libc's defines `abort` and `pthread_create`,
    // which the shell always calls, so the linker keeps it), and empty crtbegin_so.o and
    // crtend_so.o, in a sysroot a build tool lays out with the libc file that points Zig at
    // it. They only give the library its DT_NEEDED entries; at run time the device's own
    // libraries answer. Every NDK declaration is written by hand (android.zig).
    const android_step = b.step("android-build", "Build zig-out/lib/libandroid-example.so, the example in the Android shell (-Dtarget=aarch64-linux-android)");
    if (target.result.abi.isAndroid()) {
        const stubs = b.addWriteFiles();
        const empty_src = stubs.add("empty.zig", "");
        const libc_src = stubs.add("libc.zig", "export fn abort() void {}\nexport fn pthread_create() void {}\n");
        const crt = b.addObject(.{ .name = "crt", .root_module = b.createModule(.{ .root_source_file = empty_src, .target = target, .optimize = .ReleaseSmall }) });
        const sysroot_tool = b.addRunArtifact(b.addExecutable(.{ .name = "android-sysroot", .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/android/sysroot.zig"),
            .target = b.graph.host,
        }) }));
        const sysroot = sysroot_tool.addOutputDirectoryArg("android-sysroot");
        sysroot_tool.addFileArg(crt.getEmittedBin());
        for ([_][]const u8{ "c", "m", "dl", "android", "log" }) |name| {
            const stub = b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = b.createModule(.{
                .root_source_file = if (std.mem.eql(u8, name, "c")) libc_src else empty_src,
                .target = target,
                .optimize = .ReleaseSmall,
            }) });
            sysroot_tool.addFileArg(stub.getEmittedBin());
        }
        const android_vk = renderBackend(b, .vk, target, optimize, lcgf, wgpu_native_mod).?;
        const android_example = b.addLibrary(.{ .name = "android-example", .linkage = .dynamic, .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/android/example.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "vk", .module = android_vk } },
        }) });
        android_example.setLibCFile(sysroot.path(b, "libc.txt"));
        android_example.root_module.addLibraryPath(sysroot);
        for ([_][]const u8{ "dl", "android", "log" }) |name| android_example.root_module.linkSystemLibrary(name, .{ .needed = true, .use_pkg_config = .no });
        android_step.dependOn(&b.addInstallArtifact(android_example, .{}).step);
    } else android_step.dependOn(&b.addFail("android-build needs -Dtarget=aarch64-linux-android").step);

    // The Wayland shell (src/shell/wayland/): a module of its own over lcgf, Linux only. Its
    // tests run against a fake compositor on a socket pair; wayland-example opens a real window.
    const wayland_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/wayland/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("wayland", "Test the Wayland shell against a fake compositor (ci/run.sh wayland)").dependOn(&b.addRunArtifact(wayland_tests).step);
    const wayland_example = b.addExecutable(.{ .name = "wayland-example", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/wayland/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    b.step("wayland-example", "Build zig-out/bin/wayland-example (the example in a Wayland window)").dependOn(&b.addInstallArtifact(wayland_example, .{}).step);

    // docs/: the API index, generated from the files src/lcgf.zig exports (docs/api/apiindex.py,
    // zig-out/docs/API.md; ci/run.sh docs). It reads src/ itself, so it runs every time.
    const api_index = b.addSystemCommand(&.{"python3"});
    api_index.addFileArg(b.path("docs/api/apiindex.py"));
    api_index.addFileArg(b.path("src/lcgf.zig"));
    api_index.has_side_effects = true;
    const docs_step = b.step("docs", "Generate zig-out/docs/API.md and test the guides' examples");
    docs_step.dependOn(&b.addInstallFile(api_index.addOutputFileArg("API.md"), "docs/API.md").step);
    // The guides (docs/guide/*.md): their examples run as tests, and every zig block they show
    // must be a piece of those examples (docs/guide/snippets.py).
    const guide_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("docs/guide/guides.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    }) });
    // docs/guide/backends.zig draws through the selector: its own lcgf_render, with sw, so the
    // example runs without a GPU whatever -Drender says.
    const guide_render_options = b.addOptions();
    guide_render_options.addOption(Render, "render", .sw);
    const guide_render = b.createModule(.{ .root_source_file = b.path("src/render/select.zig"), .imports = &.{.{ .name = "lcgf", .module = lcgf }} });
    guide_render.addOptions("render_options", guide_render_options);
    guide_tests.root_module.addImport("lcgf_render", guide_render);
    docs_step.dependOn(&b.addRunArtifact(guide_tests).step);
    const snippets = b.addSystemCommand(&.{"python3"});
    snippets.addFileArg(b.path("docs/guide/snippets.py"));
    snippets.addDirectoryArg(b.path("docs/guide"));
    snippets.has_side_effects = true;
    docs_step.dependOn(&snippets.step);
    // The compile-error catalogue (docs/guide/errors.md): each case in docs/guide/errors/ must
    // fail with the message on its `//! expect: ` first line, as in ct-compile-fail above.
    {
        const io = b.graph.io;
        const sub = "docs/guide/errors";
        var dir = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, sub }), .{ .iterate = true }) catch @panic("cannot open " ++ sub);
        defer dir.close(io);
        b.dependOnDirectoryContents(b.path(sub));
        var it = dir.iterate();
        while (it.next(io) catch @panic("cannot list " ++ sub)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            b.dependOnFileContents(b.path(b.pathJoin(&.{ sub, entry.name })));
            const text = dir.readFileAlloc(io, entry.name, b.allocator, .limited(1 << 16)) catch @panic("cannot read a compile-error case");
            const tag = "//! expect: ";
            if (!std.mem.startsWith(u8, text, tag)) std.debug.panic("{s}/{s}: first line is not '{s}<message>'", .{ sub, entry.name, tag });
            const case = b.addObject(.{ .name = b.dupe(entry.name[0 .. entry.name.len - 4]), .root_module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(&.{ sub, entry.name })),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lcgf", .module = lcgf }},
            }) });
            case.expect_errors = .{ .contains = text[tag.len..std.mem.indexOfScalar(u8, text, '\n').?] };
            docs_step.dependOn(&case.step);
        }
    }

    // The examples (examples/): their smoke tests, and each one in an X11 window
    // (src/example/window.zig) as zig-out/bin/example-<name> (ci/run.sh examples, examples-x11).
    const examples_step = b.step("examples", "Run the examples' smoke tests and build zig-out/bin/example-<name> (X11)");
    examples_step.dependOn(&b.addInstallFile(b.path("src/example/font/LICENSE.txt"), "share/licenses/examples/DejaVu.txt").step);
    const desktop = DesktopExamples.init(b, b.path("."), lcgf, target, optimize);
    const resize_app = desktop.app(b.path("bench/vs/window-resize/lcgf.zig"));
    const resize_exe = desktop.executable(resize_app, "resize-lcgf");
    b.step("vs-window-resize", "Build the LCGF window repaint benchmark").dependOn(&b.addInstallArtifact(resize_exe, .{}).step);
    const examples_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "host", .module = desktop.host } },
    }) });
    examples_step.dependOn(&b.addRunArtifact(examples_tests).step);
    for ([_][]const u8{ "hello", "counter", "form", "list", "dashboard", "viewport", "texture" }) |name| {
        const app = desktop.app(b.path(b.fmt("examples/{s}/app.zig", .{name})));
        const exe = desktop.executable(app, b.fmt("example-{s}", .{name}));
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    // The microcontroller demo (examples/mcu/app.zig) also links for a Cortex-M7 with no OS.
    const m7 = b.resolveTargetQuery(.{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 } });
    const m7_lcgf = b.createModule(.{ .root_source_file = b.path("src/lcgf.zig"), .target = m7, .optimize = .ReleaseSmall });
    m7_lcgf.addOptions("build_options", options);
    m7_lcgf.addAnonymousImport("unicode_tables", .{ .root_source_file = ucd_tables });
    const mcu_exe = b.addExecutable(.{ .name = "example-mcu-cortex-m7", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/mcu/app.zig"),
        .target = m7,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "lcgf", .module = m7_lcgf }},
    }) });
    mcu_exe.entry = .{ .symbol_name = "_start" };
    examples_step.dependOn(&b.addInstallArtifact(mcu_exe, .{ .dest_dir = .{ .override = .{ .custom = "mcu" } } }).step);

    // The macOS shell (src/shell/macos/macos.zig): a module of its own over lcgf and the Metal
    // back end. AppKit, Metal and libobjc are opened at run time, so nothing is linked and it
    // cross-compiles from Linux (ci/run.sh shell-macos); build with -Dtarget=aarch64-macos.
    const macos_metal = renderBackend(b, .metal, target, optimize, lcgf, wgpu_native_mod).?;
    const macos_tests = b.addTest(.{ .name = "macos-test", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/macos/macos.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "metal", .module = macos_metal } },
    }) });
    b.step("macos", "Test the macOS shell on macOS").dependOn(&b.addRunArtifact(macos_tests).step);
    b.step("macos-build", "Compile and link the macOS shell's tests without running them (ci/run.sh shell-macos)").dependOn(&b.addInstallArtifact(macos_tests, .{}).step);
    // The shells' example in a macOS window (src/shell/macos/example.zig).
    const macos_example = b.addExecutable(.{ .name = "macos-example", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/macos/example.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "metal", .module = macos_metal } },
    }) });
    b.step("macos-example", "Build zig-out/bin/macos-example, the example in a macOS window").dependOn(&b.addInstallArtifact(macos_example, .{}).step);

    // examples/app: the hello window through lcgf_app, for any desktop target.
    const app_example = b.addExecutable(.{ .name = "app-example", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/app/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "lcgf_app", .module = app_mod } },
    }) });
    b.step("app-example", "Build zig-out/bin/app-example: examples/app through lcgf_app (any desktop -Dtarget)").dependOn(&b.addInstallArtifact(app_example, .{}).step);
    // examples/surface: widgets around rings a WGSL shader draws into a `Surface`, on Vulkan.
    if (linux and render == .vk) {
        const wave: GpuShader = .{ .name = "wave", .path = b.path("examples/surface/wave.wgsl") };
        const surface_shaders = addGpuShaders(b, .vk, .{ .prebuilt = b.path("examples/surface/gen") }, &.{wave});
        const surface_example = b.addExecutable(.{ .name = "surface-example", .root_module = b.createModule(.{
            .root_source_file = b.path("examples/surface/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "lcgf_app", .module = app_mod }, .{ .name = "surface_shaders", .module = surface_shaders } },
        }) });
        b.step("surface-example", "Build zig-out/bin/surface-example: examples/surface, a shader's rings in a Surface (Linux, -Drender=vk)").dependOn(&b.addInstallArtifact(surface_example, .{}).step);
    }
    // The window layer's text service (src/app/text.zig), headless: the repository's test font
    // drawn through it and the software back end. Built with libc too, for fallback-system:
    // asking fontconfig for the system's faces needs libc's loader on Linux.
    for ([_]bool{ false, true }) |libc| {
        const text_mod = appText(b, target, optimize, lcgf, libc);
        const test_font = b.path("src/text/layout/testdata/layout.ttf");
        text_mod.addAnonymousImport("layout.ttf", .{ .root_source_file = test_font });
        const text_tests = b.addTest(.{ .name = "app-text-test", .root_module = text_mod });
        const run = b.addRunArtifact(text_tests);
        if (libc) {
            run.has_side_effects = true; // the installed fonts
            const step = b.step("app-text-system", "Draw text through the service from system fonts");
            step.dependOn(&run.step);
        } else {
            test_step.dependOn(&run.step);
            b.step("app-text", "Test the window layer's text service alone").dependOn(&run.step);
        }
    }
    // lcgf_app's own tests, on an X server when LCGF_X11_TEST_DISPLAY names one (ci/run.sh app).
    const app_tests = b.addRunArtifact(b.addTest(.{ .root_module = app_mod }));
    app_tests.has_side_effects = true; // the result depends on the X server
    b.step("app-test", "Test lcgf_app (on a server when LCGF_X11_TEST_DISPLAY is set; ci/run.sh app)").dependOn(&app_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&app_tests.step);

    // Two compile-error cases of docs/guide/errors/ are syntax errors on purpose, which zig fmt
    // cannot parse.
    // bench/vs/capy/main.zig is Zig 0.14 source, built inside a Capy checkout (its build.sh).
    // zig-out holds generated Zig.
    const fmt = b.addFmt(.{ .paths = &.{b.path(".")}, .exclude_paths = &.{ b.path("docs/guide/errors/shift_or.zig"), b.path("docs/guide/errors/packed_struct.zig"), b.path("bench/vs/capy/main.zig"), b.path("zig-out") }, .check = true });
    b.step("fmt", "Check formatting of every Zig file").dependOn(&fmt.step);
    // The performance guide's build-time rules (docs/CODE_STANDARD.md): formatting, then no file
    // over the findings recorded for it in ci/perf_tidy_baseline.json.
    const tidy = b.addSystemCommand(&.{ "python3", "ci/perf_tidy_gate.py", "src", "build.zig" });
    tidy.setCwd(b.path("."));
    tidy.has_side_effects = true; // the sources are not declared inputs: check on every run
    const lint = b.step("lint", "Check formatting and the performance rules (a ratchet)");
    lint.dependOn(&fmt.step);
    lint.dependOn(&tidy.step);
}

const WgpuNative = enum { v27, v29 };
const Render = enum { sw, vk, metal, d3d12, gles, web, wgpu };
const RenderOption = enum { auto, sw, vk, metal, d3d12, gles, web, wgpu };

/// The target's own API, what `-Drender=auto` picks.
fn autoRender(t: std.Target) Render {
    if (t.cpu.arch.isWasm()) return .web;
    return switch (t.os.tag) {
        .macos, .ios => .metal,
        .windows => .d3d12,
        .freestanding => .sw,
        else => .vk,
    };
}

/// The module of render back end `kind` for `target`, with the generated sources it embeds
/// (src/render/shaders/gen/) and its C headers translated. Null for sw, which is part of lcgf.
/// `wgpu` is the given module (it needs the -Dwgpu-native archive).
fn renderBackend(b: *std.Build, kind: Render, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lcgf: *std.Build.Module, wgpu: *std.Build.Module) ?*std.Build.Module {
    const root = switch (kind) {
        .sw => return null,
        .wgpu => return wgpu,
        .vk => "src/render/vk/vk.zig",
        .metal => "src/render/metal/metal.zig",
        .d3d12 => "src/render/d3d12/d3d12.zig",
        .gles => "src/render/gles/gles.zig",
        .web => "src/render/web/web.zig",
    };
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = kind != .web,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    const shader = struct {
        fn add(mb: *std.Build, mod: *std.Build.Module, comptime name: []const u8, comptime file: []const u8) void {
            for ([_][]const u8{ "stock", "example", "canvas" }) |v|
                mod.addAnonymousImport(mb.fmt("{s}_" ++ name, .{v}), .{ .root_source_file = mb.path(mb.fmt("src/render/shaders/gen/{s}." ++ file, .{v})) });
        }
    };
    switch (kind) {
        .vk => {
            shader.add(b, m, "spv", "spv");
            if (b.lazyDependency("vulkan_headers", .{})) |vulkan_headers| {
                // Android translates as plain Linux on the same CPU: the headers are the same
                // (VKAPI_CALL differs only on 32-bit ARM); translate-c rejects any ABI version
                // but glibc's.
                const t = if (target.result.abi.isAndroid()) b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .linux, .abi = .gnu }) else target;
                const vk_h = b.addTranslateC(.{ .root_source_file = vulkan_headers.path("include/vulkan/vulkan_core.h"), .target = t, .optimize = optimize });
                vk_h.addIncludePath(vulkan_headers.path("include"));
                vk_h.defineCMacro("VK_NO_PROTOTYPES", null);
                m.addImport("vk_c", vk_h.createModule());
            }
        },
        .metal => shader.add(b, m, "metal", "metal"),
        .gles => for ([_][]const u8{ "vert", "frag" }) |stage| for ([_][]const u8{ "stock", "example", "canvas" }) |v|
            m.addAnonymousImport(b.fmt("{s}_{s}", .{ v, stage }), .{ .root_source_file = b.path(b.fmt("src/render/shaders/gen/{s}.{s}", .{ v, stage })) }),
        .d3d12 => {
            shader.add(b, m, "hlsl", "hlsl");
            const d3d12_h = b.addTranslateC(.{ .root_source_file = b.path("src/render/d3d12/c.h"), .target = target, .optimize = optimize, .link_libc = true });
            m.addImport("d3d12_c", d3d12_h.createModule());
            for ([_][]const u8{ "d3d12", "dxgi", "d3dcompiler_47", "user32", "kernel32" }) |l| m.linkSystemLibrary(l, .{ .use_pkg_config = .no });
        },
        .sw, .wgpu, .web => {},
    }
    return m;
}

/// Wire a standalone desktop example to the package's shared X11 runner and replay harness.
/// What `addApp` builds.
pub const AppOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// An executable over the lcgf dependency `dep` (made with the same `target` and `optimize`:
/// `b.dependency("lcgf", .{ .target = target, .optimize = optimize })`) whose root imports
/// `lcgf` and `lcgf_app`, the shells for its target wired in: call `lcgf_app.run` from `main`.
pub fn addApp(b: *std.Build, dep: *std.Build.Dependency, o: AppOptions) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = o.name, .root_module = b.createModule(.{
        .root_source_file = o.root_source_file,
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{ .{ .name = "lcgf", .module = dep.module("lcgf") }, .{ .name = "lcgf_app", .module = dep.module("lcgf_app") } },
    }) });
}

pub fn buildDesktopExample(b: *std.Build, name: []const u8) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pkg = b.dependency("lcgf", .{ .target = target, .optimize = optimize, .render = .sw });
    const desktop = DesktopExamples.init(b, pkg.path("."), pkg.module("lcgf"), target, optimize);
    const app = desktop.app(b.path("app.zig"));
    const exe = desktop.executable(app, name);
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&b.addInstallFile(pkg.path("src/example/font/LICENSE.txt"), b.fmt("share/licenses/{s}/DejaVu.txt", .{name})).step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open the example in an X11 window").dependOn(&run.step);
    b.step("test", "Run the headless replay tests").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app })).step);
}

const DesktopExamples = struct {
    b: *std.Build,
    lcgf: *std.Build.Module,
    host: *std.Build.Module,
    x11: *std.Build.Module,
    window: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn init(b: *std.Build, root: std.Build.LazyPath, lcgf: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) DesktopExamples {
        const imports: []const std.Build.Module.Import = &.{.{ .name = "lcgf", .module = lcgf }};
        return .{
            .b = b,
            .lcgf = lcgf,
            .host = b.createModule(.{ .root_source_file = root.path(b, "src/example/host.zig"), .imports = imports }),
            .x11 = b.createModule(.{ .root_source_file = root.path(b, "src/shell/x11/x11.zig"), .target = target, .optimize = optimize, .imports = imports }),
            .window = root.path(b, "src/example/window.zig"),
            .target = target,
            .optimize = optimize,
        };
    }

    fn app(d: DesktopExamples, source: std.Build.LazyPath) *std.Build.Module {
        return d.b.createModule(.{
            .root_source_file = source,
            .target = d.target,
            .optimize = d.optimize,
            .imports = &.{ .{ .name = "lcgf", .module = d.lcgf }, .{ .name = "host", .module = d.host } },
        });
    }

    fn executable(d: DesktopExamples, application: *std.Build.Module, name: []const u8) *std.Build.Step.Compile {
        return d.b.addExecutable(.{ .name = name, .root_module = d.b.createModule(.{
            .root_source_file = d.window,
            .target = d.target,
            .optimize = d.optimize,
            .imports = &.{
                .{ .name = "lcgf", .module = d.lcgf },
                .{ .name = "x11", .module = d.x11 },
                .{ .name = "host", .module = d.host },
                .{ .name = "example", .module = application },
            },
        }) });
    }
};

// Native comparison sources are supplied by Zig's pinned package dependencies.
fn resizeAdapter(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, name: []const u8, cpp: bool) *std.Build.Module {
    const module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true, .link_libcpp = cpp });
    const lib = b.addLibrary(.{ .name = b.fmt("resize-{s}-adapter", .{name}), .root_module = module });
    step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    return module;
}

/// A WGSL shader for `lcgf_render.gpu`: its name (the declaration in the generated module) and
/// its source file.
pub const GpuShader = struct { name: []const u8, path: std.Build.LazyPath };

/// How `addGpuShaders` gets each back end's translation: run naga-cli (on PATH, 30.x) at build
/// time, or read committed outputs `<dir>/gpu_<name>.{spv,metal,hlsl}` and
/// `gpu_<name>.<entry>.{vert,frag,comp}` (src/render/shaders/translate.sh writes them).
pub const GpuShaderSource = union(enum) { naga, prebuilt: std.Build.LazyPath };

/// The module of `shaders` for back end `backend`: one declaration per shader, a namespace with
/// `wgsl` (the source, which the projection reflects at compile time) and the translation that
/// back end consumes (`spv`, `msl`, `hlsl`, or `glsl_<entry>` per entry point). Only the selected
/// back end's translation is embedded. A downstream build calls this through the dependency:
///
///     const shaders = lcgf.addGpuShaders(b, .vk, .naga, &.{.{ .name = "tinted", .path = b.path("tinted.wgsl") }});
///     exe.root_module.addImport("gpu_shaders", shaders);
pub fn addGpuShaders(b: *std.Build, backend: anytype, source: GpuShaderSource, shaders: []const GpuShader) *std.Build.Module {
    const kind = std.meta.stringToEnum(Render, @tagName(backend)) orelse @panic("addGpuShaders: unknown back end");
    const files = b.addWriteFiles();
    var root: std.ArrayList(u8) = .empty;
    root.appendSlice(b.allocator, "//! Generated by build.zig addGpuShaders: WGSL and this back end's translation of each shader.\n") catch @panic("OOM");
    for (shaders) |s| {
        _ = files.addCopyFile(s.path, b.fmt("{s}.wgsl", .{s.name}));
        root.print(b.allocator, "pub const {s} = struct {{\n    pub const wgsl = @embedFile(\"{s}.wgsl\");\n", .{ s.name, s.name }) catch @panic("OOM");
        const one = struct {
            fn output(bb: *std.Build, f: *std.Build.Step.WriteFile, src: GpuShaderSource, shader: GpuShader, file: []const u8, args: []const []const u8) void {
                switch (src) {
                    .prebuilt => |dir| _ = f.addCopyFile(dir.path(bb, bb.fmt("gpu_{s}", .{file})), file),
                    .naga => {
                        const run = bb.addSystemCommand(&.{"naga"});
                        run.addArgs(args);
                        run.addFileArg(shader.path);
                        _ = f.addCopyFile(run.addOutputFileArg(file), file);
                    },
                }
            }
        };
        switch (kind) {
            .vk => {
                one.output(b, files, source, s, b.fmt("{s}.spv", .{s.name}), &.{});
                root.print(b.allocator, "    pub const spv = @embedFile(\"{s}.spv\");\n", .{s.name}) catch @panic("OOM");
            },
            .metal => {
                one.output(b, files, source, s, b.fmt("{s}.metal", .{s.name}), &.{});
                root.print(b.allocator, "    pub const msl = @embedFile(\"{s}.metal\");\n", .{s.name}) catch @panic("OOM");
            },
            .d3d12 => {
                one.output(b, files, source, s, b.fmt("{s}.hlsl", .{s.name}), &.{});
                root.print(b.allocator, "    pub const hlsl = @embedFile(\"{s}.hlsl\");\n", .{s.name}) catch @panic("OOM");
            },
            .gles => for (wgslEntryPoints(b, s.path)) |e| {
                const ext = switch (e.stage) {
                    .vertex => "vert",
                    .fragment => "frag",
                    .compute => "comp",
                };
                const file = b.fmt("{s}.{s}.{s}", .{ s.name, e.name, ext });
                one.output(b, files, source, s, file, &.{ "--profile", if (e.stage == .compute) "es310" else "es300", "--shader-stage", @tagName(e.stage), "--entry-point", e.name });
                root.print(b.allocator, "    pub const glsl_{s} = @embedFile(\"{s}\");\n", .{ e.name, file }) catch @panic("OOM");
            },
            .web, .wgpu, .sw => {},
        }
        root.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    }
    return b.createModule(.{ .root_source_file = files.add("gpu_shaders.zig", root.items) });
}

/// The repository's own lcgf_render.gpu shaders (src/render/gpu/), for its tests and players.
fn repo_gpu_shaders(b: *std.Build) []const GpuShader {
    return b.allocator.dupe(GpuShader, &.{
        .{ .name = "gradient", .path = b.path("src/render/gpu/gradient.wgsl") },
        .{ .name = "textured", .path = b.path("src/render/gpu/textured.wgsl") },
        .{ .name = "fill", .path = b.path("src/render/gpu/fill.wgsl") },
        .{ .name = "instanced", .path = b.path("src/render/gpu/instanced.wgsl") },
    }) catch @panic("OOM");
}

const WgslEntry = struct { stage: enum { vertex, fragment, compute }, name: []const u8 };

/// The entry points of a WGSL file, read when the build graph is made (GLSL needs one
/// translation per entry point). The full reflection runs at compile time (src/render/gpu/reflect.zig).
fn wgslEntryPoints(b: *std.Build, path: std.Build.LazyPath) []const WgslEntry {
    // Read while configuring, so the configuration cache must know about the file; that limits
    // a shader to a source file of a package, not a generated one.
    const sp = switch (path) {
        .src_path => |sp| sp,
        else => @panic("addGpuShaders: a shader is a source file (b.path)"),
    };
    b.dependOnFileContents(path);
    const owner = sp.owner;
    const text = owner.root.root_dir.handle.readFileAlloc(b.graph.io, owner.pathJoin(&.{ owner.root.sub_path, sp.sub_path }), b.allocator, .limited(1 << 20)) catch |e|
        std.debug.panic("addGpuShaders: cannot read {s}: {t}", .{ sp.sub_path, e });
    var out: std.ArrayList(WgslEntry) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var pending: ?@FieldType(WgslEntry, "stage") = null;
    while (it.next()) |raw| {
        const line = if (std.mem.indexOf(u8, raw, "//")) |k| raw[0..k] else raw;
        inline for (.{ "vertex", "fragment", "compute" }) |st| {
            if (std.mem.indexOf(u8, line, "@" ++ st) != null) pending = @field(@FieldType(WgslEntry, "stage"), st);
        }
        if (pending) |st| if (std.mem.indexOf(u8, line, "fn ")) |k| {
            var rest = std.mem.trimStart(u8, line[k + 3 ..], " ");
            const end = std.mem.indexOfAny(u8, rest, " (") orelse rest.len;
            out.append(b.allocator, .{ .stage = st, .name = rest[0..end] }) catch @panic("OOM");
            pending = null;
        };
    }
    return out.items;
}

/// The window layer's text service (src/app/text.zig) over `lcgf_mod`, with the platform's
/// font discovery (src/text/fallback/system.zig), which needs libc on Linux.
fn appText(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lcgf_mod: *std.Build.Module, libc: bool) *std.Build.Module {
    const system = b.createModule(.{
        .root_source_file = b.path("src/text/fallback/system.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = libc,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_mod }},
    });
    return b.createModule(.{
        .root_source_file = b.path("src/app/text.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = libc,
        .imports = &.{ .{ .name = "lcgf", .module = lcgf_mod }, .{ .name = "font_system", .module = system } },
    });
}
