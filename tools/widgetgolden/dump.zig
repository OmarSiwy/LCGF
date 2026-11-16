//! Golden-image dumper for the widgets: replays a page's input (`widgets_base.reference_replay`,
//! or a widget's own, see `pages`) through both front ends with the widget harness (which fails
//! if they draw differently), and writes the named frame as tools/golden/gpu.py draws it, into
//! a directory:
//!
//!     zig build widget-dump -- <frame> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! Frame names are the pages' `frames` (`widgets_base.golden_frames`, ...).
//! ci/jobs/widget-golden.sh renders each one and compares it with
//! tools/widgetgolden/ref/<frame>.png.
const std = @import("std");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const Quad = lcgr.draw_list.Quad;
const Replay = lcgr.input.Replay;
const Input = lcgr.input.Input;
const gfx = lcgr.quad_shader;

/// The pages with golden frames: each has `Run` (a `widgets_base.Harness`), `src` (its replay)
/// and `frames` (name, frame index). A widget lane adds its page here, one line.
const pages = .{
    struct {
        pub const Run = w.Reference(.default).Run;
        pub const src = w.reference_replay;
        pub const frames = w.golden_frames;
    },
    lcgr.widgets_popover.golden,
    lcgr.widgets_tooltip.golden,
    lcgr.widgets_menu.golden,
    lcgr.widgets_menubar.golden,
    lcgr.widgets_contextmenu.golden,
    lcgr.widgets_dialog.golden,
    lcgr.widgets_toast.golden,
};

var glyph_quads: [1024]Quad = undefined;
var first: [16]u32 = undefined;
var count: [16]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const name = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    inline for (pages) |page| {
        inline for (page.frames) |g| {
            if (std.mem.eql(u8, name, g[0])) return dump(page, g[1], io, out_path);
        }
    }
    return error.UnknownFrame;
}

/// Replays `page` up to frame `target` and writes that frame's draw list to `out_path`.
fn dump(comptime page: type, target: u32, io: std.Io, out_path: []const u8) !void {
    const S = struct {
        var harness: page.Run = .{};
    };
    const harness = &S.harness;
    harness.init();
    var text: [16]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var replay: Replay = .{ .src = page.src };
    var pair: ?page.Run.Pair = null;
    while (try replay.next(buf)) |in| {
        const p = try harness.frame(in);
        if (harness.frames - 1 == target) {
            pair = p;
            break;
        }
    }
    const d = (pair orelse return error.ReplayTooShort).runtime.draw;
    const n = harness.ui.font.quads(d, &glyph_quads, .{ .first = &first, .count = &count });

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "quad.wgsl", .data = gfx.wgsl });
    try dir.writeFile(io, .{ .sub_path = "quads.bin", .data = d.quadBytes() });
    try dir.writeFile(io, .{ .sub_path = "glyphs.bin", .data = std.mem.sliceAsBytes(glyph_quads[0..@max(n, 1)]) });

    var out: [16 * 1024]u8 = undefined;
    var wr = std.Io.Writer.fixed(&out);
    try wr.print("stride {d}\n", .{gfx.stride});
    for (gfx.attrs) |a| try wr.print("attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .quads => |b| try wr.print("quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
        .text => |k| try wr.print("text {d} {d}\n", .{ first[k], count[k] }),
        .custom => return error.PageHasCustom,
    };
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = wr.buffered() });
}
