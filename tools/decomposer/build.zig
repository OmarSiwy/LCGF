const std = @import("std");

/// Build the HTML/CSS reader for the machine running Zig, including during cross builds.
/// The framework's target module never links these sources.
pub fn addParser(b: *std.Build, root: std.Build.LazyPath, lexbor: *std.Build.Dependency) *std.Build.Step.Compile {
    const host = b.graph.host;
    const module = b.createModule(.{ .target = host, .optimize = .ReleaseFast, .link_libc = true });
    const executable = b.addExecutable(.{ .name = "decomposer-parse", .root_module = module });
    const flags: []const []const u8 = if (host.result.os.tag == .windows)
        &.{ "-std=c99", "-DLEXBOR_STATIC" }
    else
        &.{ "-std=c99", "-DLEXBOR_STATIC", "-D_POSIX_C_SOURCE=199309L" };
    module.addIncludePath(lexbor.path("source"));
    module.addCSourceFiles(.{ .root = root.path(b, "tools/decomposer"), .files = &.{ "main.c", "html.c", "css.c", "widgets.c" }, .flags = flags });
    const port = if (host.result.os.tag == .windows) "ports/windows_nt" else "ports/posix";
    for ([_][]const u8{ "core", "ns", "tag", "dom", "html", "css", "selectors", port }) |component| {
        const sub = b.pathJoin(&.{ "source/lexbor", component });
        const dep = lexbor.builder;
        const io = b.graph.io;
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
    return executable;
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
