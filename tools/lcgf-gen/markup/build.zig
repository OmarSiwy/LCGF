//! Build helpers of the markup compiler: Lexbor as a static library, and `addMarkup`, which a
//! downstream `build.zig` calls (re-exported by lcgf's root build.zig).

const std = @import("std");
const Build = std.Build;

/// Lexbor 3.0.1 (build.zig.zon, lazy) plus lexbor.c, compiled for `target`. Only lcgf-gen links
/// it; an application never does.
pub fn addLexbor(b: *Build, root: Build.LazyPath, lexbor: *Build.Dependency, target: Build.ResolvedTarget) *Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true });
    const lib = b.addLibrary(.{ .name = "lexbor", .linkage = .static, .root_module = module });
    const windows = target.result.os.tag == .windows;
    const flags: []const []const u8 = if (windows) &.{ "-std=c99", "-DLEXBOR_STATIC" } else &.{ "-std=c99", "-DLEXBOR_STATIC", "-D_POSIX_C_SOURCE=199309L" };
    // The pinned Zig keeps the archive's top-level directory.
    // The pinned Zig strips the archive's top directory (CI fetches it fresh).
    const source = "source";
    module.addIncludePath(lexbor.path(source));
    module.addCSourceFiles(.{ .root = root, .files = &.{"tools/lcgf-gen/markup/lexbor.c"}, .flags = flags });
    const port = if (windows) "ports/windows_nt" else "ports/posix";
    const dep = lexbor.builder;
    const io = b.graph.io;
    for ([_][]const u8{ "core", "ns", "tag", "dom", "html", "css", "selectors", port }) |component| {
        const sub = b.pathJoin(&.{ source, "lexbor", component });
        var dir = dep.root.root_dir.handle.openDir(io, b.pathJoin(&.{ dep.root.sub_path, sub }), .{ .iterate = true }) catch
            std.debug.panic("cannot open Lexbor {s}", .{component});
        defer dir.close(io);
        var walk = dir.walk(b.allocator) catch @panic("cannot walk Lexbor sources");
        defer walk.deinit(io);
        var files: std.ArrayList([]const u8) = .empty;
        while (walk.next(io) catch @panic("cannot read Lexbor sources")) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".c"))
                files.append(b.allocator, b.dupe(entry.path)) catch @panic("out of memory");
        }
        std.mem.sort([]const u8, files.items, {}, lessPath);
        module.addCSourceFiles(.{ .root = lexbor.path(sub), .files = files.items, .flags = flags });
    }
    return lib;
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `zig build markup`: the compiler's unit tests, its fixtures against their hand-written twins,
/// and its diagnostics against their expected text. Returns the step for `test` to include.
pub fn steps(b: *Build, lexbor: *Build.Dependency, lcgf: *Build.Module, lcgf_host: *Build.Module, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Step {
    const step = b.step("markup", "Test the HTML/CSS compiler: units, fixtures against their twins, diagnostics");
    const pending = b.step("markup-pending", "Build the markup fixtures that wait for engine API (docs/plans/markup-engine-api.md); expected to fail until main lands it");
    const cost = b.step("markup-cost-obj", "Build the zero-cost probe of each fixture over its generated and its hand-written page into zig-out/markup-cost/");
    const root = b.path(".");
    const lib = addLexbor(b, root, lexbor, b.graph.host);
    const unit = b.addTest(.{ .name = "markup-units", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lcgf-gen/markup/tests.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_host }},
    }) });
    unit.root_module.linkLibrary(lib);
    step.dependOn(&b.addRunArtifact(unit).step);

    const gen = b.addExecutable(.{ .name = "lcgf-gen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lcgf-gen/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_host }},
    }) });
    gen.root_module.linkLibrary(lib);
    b.step("lcgf-gen", "Build lcgf-gen for this machine, with the HTML front end, into zig-out/bin").dependOn(&b.addInstallArtifact(gen, .{}).step);

    // Fixtures: the page generated from page.html against the hand-written twin.zig.
    const dir = "tools/lcgf-gen/markup/testdata";
    var pages: std.ArrayList(Build.Module.Import) = .empty;
    pages.append(b.allocator, .{ .name = "lcgf", .module = lcgf }) catch @panic("out of memory");
    for (manifest.manifest.fixtures) |f| {
        const html = b.path(b.fmt("{s}/{s}/page.html", .{ dir, f.name }));
        const app = if (f.app) b.createModule(.{ .root_source_file = b.path(b.fmt("{s}/{s}/app.zig", .{ dir, f.name })), .imports = &.{.{ .name = "lcgf", .module = lcgf }} }) else null;
        const page = addPage(b, gen, lcgf, .{ .html = html, .frontend = "spec", .app = app, .runtime_vars = if (f.runtime_vars.len > 0) f.runtime_vars else null });
        const page_rt = addPage(b, gen, lcgf, .{ .html = html, .frontend = "runtime", .app = app, .runtime_vars = if (f.runtime_vars.len > 0) f.runtime_vars else null });
        for (f.wrong_apps) |x| {
            const wrong = b.createModule(.{ .root_source_file = b.path(b.fmt("{s}/{s}/app_{s}.zig", .{ dir, f.name, x })), .imports = &.{.{ .name = "lcgf", .module = lcgf }} });
            pages.append(b.allocator, .{ .name = b.fmt("{s}_{s}", .{ f.name, x }), .module = addPage(b, gen, lcgf, .{ .html = html, .frontend = "spec", .app = wrong }) }) catch @panic("out of memory");
        }
        if (f.runtime_vars.len > 0 and !f.spec_only) {
            const rt_test = b.addTest(.{ .name = b.fmt("markup-{s}-tokens", .{f.name}), .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}/{s}/runtime_test.zig", .{ dir, f.name })),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "page_rt", .module = page_rt }, .{ .name = "page", .module = page } },
            }) });
            step.dependOn(&b.addRunArtifact(rt_test).step);
        }
        if (f.waits_for.len == 0) pages.append(b.allocator, .{ .name = f.name, .module = page }) catch @panic("out of memory");
        const twin = b.createModule(.{ .root_source_file = b.path(b.fmt("{s}/{s}/twin.zig", .{ dir, f.name })), .imports = &.{.{ .name = "lcgf", .module = lcgf }} });
        if (app) |a| twin.addImport("app", a);
        const t = b.addTest(.{ .name = b.fmt("markup-{s}", .{f.name}), .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "/fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "page", .module = page }, .{ .name = "twin", .module = twin } },
        }) });
        (if (f.waits_for.len == 0) step else pending).dependOn(&b.addRunArtifact(t).step);
        // The same page through the runtime frontend: identical frames (base.Harness).
        const parity = b.addTest(.{ .name = b.fmt("markup-{s}-runtime", .{f.name}), .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "/parity.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "page", .module = page }, .{ .name = "page_rt", .module = page_rt }, .{ .name = "twin", .module = twin } },
        }) });
        (if (f.waits_for.len == 0 and !f.spec_only) step else pending).dependOn(&b.addRunArtifact(parity).step);
        // The zero-cost probe over both sides, ReleaseFast and stripped (ci/jobs/markup-zero-cost.sh).
        if (f.waits_for.len == 0) {
            const twin_ui = b.createModule(.{ .root_source_file = b.path(dir ++ "/cost_twin.zig"), .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "twin", .module = twin } } });
            for ([_]struct { []const u8, *Build.Module }{ .{ "page", page }, .{ "twin", twin_ui } }) |side| {
                const obj = b.addObject(.{ .name = b.fmt("{s}-{s}", .{ f.name, side[0] }), .root_module = b.createModule(.{
                    .root_source_file = b.path(dir ++ "/cost_probe.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .strip = true,
                    .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "ui", .module = side[1] } },
                }) });
                cost.dependOn(&b.addInstallFile(obj.getEmittedBin(), b.fmt("markup-cost/{s}-{s}.o", .{ f.name, side[0] })).step);
            }
            // A page with no `--t-*` token is the same runtime page with --runtime-vars.
            if (f.runtime_vars.len == 0 and !f.spec_only) {
                const with_vars = addPage(b, gen, lcgf, .{ .html = html, .frontend = "runtime", .app = app, .runtime_vars = "t-" });
                for ([_]struct { []const u8, *Build.Module }{ .{ "rt", page_rt }, .{ "rtvars", with_vars } }) |side| {
                    const obj = b.addObject(.{ .name = b.fmt("{s}-{s}", .{ f.name, side[0] }), .root_module = b.createModule(.{
                        .root_source_file = b.path(dir ++ "/cost_probe_rt.zig"),
                        .target = target,
                        .optimize = .ReleaseFast,
                        .strip = true,
                        .imports = &.{ .{ .name = "lcgf", .module = lcgf }, .{ .name = "ui", .module = side[1] }, .{ .name = "twin", .module = twin } },
                    }) });
                    cost.dependOn(&b.addInstallFile(obj.getEmittedBin(), b.fmt("markup-cost/{s}-{s}.o", .{ f.name, side[0] })).step);
                }
            }
        }
    }
    // The check block: each testdata/compile_fail/<case>.zig drives a fixture's page with a
    // wrong handler type and must fail with the message on its `//! expect: ` first line.
    {
        const io = b.graph.io;
        const sub = dir ++ "/compile_fail";
        var d = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, sub }), .{ .iterate = true }) catch @panic("cannot open " ++ sub);
        defer d.close(io);
        b.dependOnDirectoryContents(b.path(sub));
        var it = d.iterate();
        while (it.next(io) catch @panic("cannot list " ++ sub)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            b.dependOnFileContents(b.path(b.fmt("{s}/{s}", .{ sub, entry.name })));
            const text = d.readFileAlloc(io, entry.name, b.allocator, .limited(1 << 16)) catch @panic("cannot read a compile-fail case");
            const tag = "//! expect: ";
            if (!std.mem.startsWith(u8, text, tag)) std.debug.panic("{s}/{s}: first line is not '{s}<message>'", .{ sub, entry.name, tag });
            const case = b.addObject(.{ .name = b.dupe(entry.name[0 .. entry.name.len - 4]), .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}/{s}", .{ sub, entry.name })),
                .target = target,
                .optimize = optimize,
                .imports = pages.items,
            }) });
            case.expect_errors = .{ .contains = text[tag.len..std.mem.indexOfScalar(u8, text, '\n').?] };
            step.dependOn(&case.step);
        }
    }
    // Diagnostics: each testdata/errors/<case>.html must fail with exactly <case>.err.
    {
        const io = b.graph.io;
        const sub = dir ++ "/errors";
        var d = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, sub }), .{ .iterate = true }) catch @panic("cannot open " ++ sub);
        defer d.close(io);
        b.dependOnDirectoryContents(b.path(sub));
        var it = d.iterate();
        while (it.next(io) catch @panic("cannot list " ++ sub)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
            const stem = entry.name[0 .. entry.name.len - 5];
            b.dependOnFileContents(b.path(b.fmt("{s}/{s}.err", .{ sub, stem })));
            const expected = d.readFileAlloc(io, b.fmt("{s}.err", .{stem}), b.allocator, .limited(1 << 16)) catch std.debug.panic("{s}/{s}.err is missing", .{ sub, stem });
            const run = b.addRunArtifact(gen);
            run.setCwd(b.path(sub));
            run.addArgs(&.{ entry.name, "--no-warnings", "--lang", "zig" });
            run.expectExitCode(1);
            run.expectStdErrEqual(expected);
            run.addFileInput(b.path(b.fmt("{s}/{s}", .{ sub, entry.name })));
            step.dependOn(&run.step);
        }
    }
    return step;
}

const manifest = @import("manifest.zig");

pub const Options = struct {
    /// The page. `<link rel=stylesheet>` and `<style>` in it are read too.
    html: Build.LazyPath,
    /// More stylesheets, after the page's own, in order.
    css: []const Build.LazyPath = &.{},
    /// The app module: components, an app `State` (`lcgf-state`), item types. Imported as `app`.
    app: ?*Build.Module = null,
    /// Also copy the generated file into this source directory (`-Dmarkup-emit=src/gen`).
    emit: ?[]const u8 = null,
    /// Use this checked-in generated file instead; the build fails when it is stale.
    vendored: ?Build.LazyPath = null,
    /// `spec` or `runtime`; null takes the page's own `lcgf-frontend` (spec when it has none).
    frontend: ?[]const u8 = null,
    /// `--runtime-vars=` prefix: `var(--<prefix>*)` become run-time theme tokens.
    runtime_vars: ?[]const u8 = null,
};

/// The Zig module generated from `o.html`, importing `lcgf` (the `framework` dependency's) and
/// `app`. Null while the lazy Lexbor fetch is pending; the build runner then fetches and reruns.
pub fn addMarkup(b: *Build, framework: *Build.Dependency, o: Options) ?*Build.Module {
    const lexbor = framework.builder.lazyDependency("lexbor", .{}) orelse return null;
    const gen = addHostGen(b, framework.path(""), lexbor, framework.module("lcgf_host"));
    return addPage(b, gen, framework.module("lcgf"), o);
}

/// lcgf-gen for the machine running the build, with Lexbor linked: what `addMarkup` runs.
/// `lcgf_host` is lcgf built for `b.graph.host`.
pub fn addHostGen(b: *Build, root: Build.LazyPath, lexbor: *Build.Dependency, lcgf_host: *Build.Module) *Build.Step.Compile {
    const host = b.graph.host;
    const exe = b.addExecutable(.{ .name = "lcgf-gen", .root_module = b.createModule(.{
        .root_source_file = root.path(b, "tools/lcgf-gen/main.zig"),
        .target = host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_host }},
    }) });
    exe.root_module.linkLibrary(addLexbor(b, root, lexbor, host));
    return exe;
}

/// The module `gen` generates from `o.html`, importing `lcgf` and the app module.
pub fn addPage(b: *Build, gen: *Build.Step.Compile, lcgf: *Build.Module, o: Options) *Build.Module {
    const stem = std.fs.path.stem(o.html.getDisplayName());
    const name = b.fmt("{s}_ui.zig", .{stem});
    const run = b.addRunArtifact(gen);
    run.addFileArg(o.html);
    for (o.css) |c| {
        run.addArg("--css");
        run.addFileArg(c);
    }
    run.addArgs(&.{ "--lang", "zig" });
    if (o.frontend) |fe| run.addArgs(&.{ "--frontend", fe });
    if (o.runtime_vars) |rv| run.addArg(b.fmt("--runtime-vars={s}", .{rv}));
    if (o.vendored) |v| {
        // The tool regenerates, fails when the vendored file differs, and otherwise writes it
        // out unchanged; the module compiles that output, so nothing builds against a stale file.
        run.addArg("--check");
        run.addFileArg(v);
    }
    run.addArg("-o");
    const out = run.addOutputFileArg(name);
    run.addArg("--depfile");
    _ = run.addDepFileOutputArg(b.fmt("{s}_ui.d", .{stem}));
    if (o.emit) |dir| {
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(out, b.pathJoin(&.{ dir, name }));
        b.getInstallStep().dependOn(&update.step);
    }
    const m = b.createModule(.{ .root_source_file = out });
    m.addImport("lcgf", lcgf);
    if (o.app) |a| m.addImport("app", a);
    return m;
}
