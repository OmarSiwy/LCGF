//! Golden-image dumper for the widget pages: replays a page's input through both front ends
//! with the widget harness (which fails if they draw differently), and writes the named frame
//! as tools/golden/gpu.py draws it, into a directory:
//!
//!     zig build widget-dump -- <frame> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! A frame is `<page>-<name>` for a widget page in `pages` (`label-rest`), or a bare name of
//! the reference page's `widgets_base.golden_frames` (`rest`). ci/jobs/widget-golden.sh renders
//! each one and compares it with tools/widgetgolden/ref/<frame>.png. A widget lane adds its
//! page with one line in `pages`.
const std = @import("std");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const Quad = lcgr.draw_list.Quad;
const Replay = lcgr.input.Replay;
const Input = lcgr.input.Input;
const gfx = lcgr.quad_shader;

/// The reference page in the shape every widget page has.
const Reference = struct {
    pub const Run = w.Reference(.default).Run;
    pub const replay = w.reference_replay;
    pub const golden_frames = w.golden_frames;
};

/// Pages by prefix: `Run` (a harness), `replay` (input.Replay text), `golden_frames`.
const pages = .{
    .{ "", Reference },
    .{ "label", lcgr.widgets_label.Page },
    .{ "button", lcgr.widgets_button.Page },
    .{ "checkbox", lcgr.widgets_checkbox.Page },
    .{ "radio", lcgr.widgets_radio.Page },
    .{ "switch", lcgr.widgets_switch.Page },
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

    inline for (pages) |p| {
        const prefix = if (p[0].len == 0) "" else p[0] ++ "-";
        if (std.mem.startsWith(u8, name, prefix) and (prefix.len > 0 or std.mem.indexOfScalar(u8, name, '-') == null)) {
            inline for (p[1].golden_frames) |g| {
                if (std.mem.eql(u8, name[prefix.len..], g[0])) return dump(io, p[1], g[1], out_path);
            }
        }
    }
    return error.UnknownFrame;
}

fn dump(io: std.Io, comptime Page: type, target: u32, out_path: []const u8) !void {
    const S = struct {
        var harness: Page.Run = .{};
    };
    const harness = &S.harness;
    harness.init();
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var pair: ?Page.Run.Pair = null;
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
