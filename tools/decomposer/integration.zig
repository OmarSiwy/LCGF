const std = @import("std");
const parser_build = @import("build.zig");
const Build = std.Build;

pub const Options = struct {
    html: Build.LazyPath,
    stylesheets: []const Build.LazyPath = &.{},
    handlers: ?*Build.Module = null,
    fragment: bool = false,
};

/// Add an inspectable generated page to a downstream project's build graph.
/// A missing lazy parser dependency is retried by the Zig package manager.
pub fn addMarkup(b: *Build, framework: *Build.Dependency, opts: Options) ?*Build.Module {
    const lexbor = framework.builder.lazyDependency("lexbor", .{}) orelse return null;
    const root = framework.path("");
    const parser = parser_build.addParser(b, root, lexbor);
    return pageModule(b, root, parser, framework.module("lcgf"), opts);
}

fn compiler(b: *Build, root: Build.LazyPath, parser: *Build.Step.Compile) *Build.Step.Run {
    const cmd = b.addSystemCommand(&.{"python3"});
    cmd.addFileArg(root.path(b, "tools/decomposer/compiler.py"));
    cmd.addArg("--parser");
    cmd.addArtifactArg(parser);
    for ([_][]const u8{ "styles.py", "colors.py", "mapping.py", "roadmap.py", "page_helpers.zig", "writer.zig" }) |name|
        cmd.addFileInput(root.path(b, b.pathJoin(&.{ "tools/decomposer", name })));
    return cmd;
}

fn pageModule(b: *Build, root: Build.LazyPath, parser: *Build.Step.Compile, lcgf: *Build.Module, opts: Options) *Build.Module {
    const cmd = compiler(b, root, parser);
    cmd.addFileArg(opts.html);
    if (opts.fragment) cmd.addArg("--fragment");
    for (opts.stylesheets) |sheet| {
        cmd.addArg("--css");
        cmd.addFileArg(sheet);
    }
    cmd.addArg("--output");
    const output = cmd.addOutputFileArg("page.zig");
    cmd.addArg("--depfile");
    _ = cmd.addDepFileOutputArg("page.d");
    const module = b.createModule(.{ .root_source_file = output });
    module.addImport("lcgf", lcgf);
    if (opts.handlers) |handlers| module.addImport("handlers", handlers);
    return module;
}

pub fn steps(b: *Build, lcgf: *Build.Module, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const convert = b.step("decompose", "Compile HTML and CSS to Zig (enable with -Ddecomposer)");
    const tests = b.step("decomposer-test", "Test parser, cascade, mapping inventory and generated native pages");
    if (!(b.option(bool, "decomposer", "Enable the host HTML and CSS compiler") orelse false)) {
        const missing = b.addFail("enable the host compiler with -Ddecomposer");
        convert.dependOn(&missing.step);
        tests.dependOn(&missing.step);
        return;
    }
    const lexbor = b.lazyDependency("lexbor", .{}) orelse return;
    const parser = parser_build.addParser(b, b.path("."), lexbor);
    const cmd = compiler(b, b.path("."), parser);
    cmd.addPassthruArgs();
    convert.dependOn(&cmd.step);
    const host_tests = b.addSystemCommand(&.{"python3"});
    host_tests.addFileArg(b.path("tools/decomposer/run_tests.py"));
    host_tests.addArtifactArg(parser);
    host_tests.addFileArg(.zig_exe);
    host_tests.addDirectoryArg(b.dependency("ucd", .{}).path(""));
    tests.dependOn(&host_tests.step);
    const handlers = b.createModule(.{ .root_source_file = b.path("tools/decomposer/testdata/handlers.zig") });
    const mod = b.createModule(.{ .root_source_file = b.path("tools/decomposer/testdata/page_test.zig"), .target = target, .optimize = optimize });
    mod.addImport("lcgf", lcgf);
    for ([_][]const u8{ "counter", "readonly" }) |name| {
        mod.addImport(name, pageModule(b, b.path("."), parser, lcgf, .{
            .html = b.path(b.fmt("tools/decomposer/testdata/{s}.html", .{name})),
            .handlers = handlers,
        }));
    }
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    const forbidden = b.createModule(.{ .root_source_file = b.path("tools/decomposer/testdata/forbidden.zig"), .target = target, .optimize = optimize });
    forbidden.addImport("forbidden", pageModule(b, b.path("."), parser, lcgf, .{
        .html = b.path("tools/decomposer/testdata/forbidden.html"),
        .handlers = handlers,
    }));
    const invalid = b.addObject(.{ .name = "forbidden_write", .root_module = forbidden });
    invalid.expect_errors = .{ .contains = "Zig callback has no declared write to 'subtitle'" };
    tests.dependOn(&invalid.step);
}
