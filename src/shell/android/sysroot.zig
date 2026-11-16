//! Build tool: lays out the stub sysroot the Android shell links against (build.zig) and the
//! libc file that points Zig at it. There is no NDK here; the stubs only give the shared
//! library its DT_NEEDED entries.
//!
//!     sysroot OUT CRT_OBJECT LIB...   ->  OUT/libc.txt, OUT/include/, OUT/crtbegin_so.o,
//!                                         OUT/crtend_so.o, OUT/<each LIB's basename>
//!
//! The libc file needs absolute paths, which only exist once the build runs: hence a tool.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.Usage;
    const crt = args.next() orelse return error.Usage;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);
    try out.createDirPath(io, "include");
    for ([_][]const u8{ "crtbegin_so.o", "crtend_so.o" }) |name| try cwd.copyFile(crt, out, name, io, .{});
    while (args.next()) |lib| try cwd.copyFile(lib, out, std.fs.path.basename(lib), io, .{});
    const abs = try cwd.realPathFileAlloc(io, out_path, gpa);
    try out.writeFile(io, .{ .sub_path = "libc.txt", .data = try std.fmt.allocPrint(gpa,
        \\include_dir={0s}/include
        \\sys_include_dir={0s}/include
        \\crt_dir={0s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\cc_dir={0s}
        \\darwin_sdk_dir=
        \\
    , .{abs}) });
}
