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
    const source = "lexbor-3.0.1/source";
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
    _ = target;
    _ = optimize;
    _ = lcgf;
    const step = b.step("markup", "Test the HTML/CSS compiler: units, fixtures against their twins, diagnostics");
    const root = b.path(".");
    const unit = b.addTest(.{ .name = "markup-units", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lcgf-gen/markup/tests.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "lcgf", .module = lcgf_host }},
    }) });
    unit.root_module.linkLibrary(addLexbor(b, root, lexbor, b.graph.host));
    step.dependOn(&b.addRunArtifact(unit).step);
    return step;
}

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
