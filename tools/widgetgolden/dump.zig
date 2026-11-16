//! Golden-image dumper for the widget pages: replays a page's input through both front ends
//! with the widget harness (which fails if they draw differently), and writes the named frame
//! as tools/golden/gpu.py draws it, into a directory:
//!
//!     zig build widget-dump -- <frame> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! A page is a struct with `Run` (a `widgets_base.Harness`), `replay` (its input) and
//! `golden_frames` (name, frame number); frame names are unique across `pages`. Add a widget's
//! page with one line there. ci/jobs/widget-golden.sh renders each frame that has a reference
//! and compares it with tools/widgetgolden/ref/<frame>.png.
const std = @import("std");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const Quad = lcgr.draw_list.Quad;
const Replay = lcgr.input.Replay;
const Input = lcgr.input.Input;
const gfx = lcgr.quad_shader;

/// The reference widgets of widgets/base.zig.
const Reference = struct {
    pub const Run = w.Reference(.default).Run;
    pub const replay = w.reference_replay;
    pub const golden_frames = w.golden_frames;
};

const pages = .{
    Reference,
    lcgr.widgets_list.Page,
    lcgr.widgets_vlist.Page,
};

var glyph_quads: [4096]Quad = undefined;
var first: [256]u32 = undefined;
var count: [256]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const name = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    inline for (pages) |P| {
        inline for (P.golden_frames) |g| {
            if (std.mem.eql(u8, name, g[0])) return dump(P, g[1], init.io, out_path);
        }
    }
    return error.UnknownFrame;
}

fn dump(comptime P: type, target: u32, io: std.Io, out_path: []const u8) !void {
    const S = struct {
        var harness: P.Run = .{};
    };
    const harness = &S.harness;
    harness.init();
    var text: [256]u8 = undefined;
    var events: [64]Input.Event = undefined;
    var contacts: [8]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var replay: Replay = .{ .src = P.replay };
    var pair: ?P.Run.Pair = null;
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
