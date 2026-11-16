//! Golden-image dumper for the reference widgets: replays `widgets_base.reference_replay`
//! through both front ends with the widget harness (which fails if they draw differently), and
//! writes the named frame as tools/golden/gpu.py draws it, into a directory:
//!
//!     zig build widget-dump -- <frame> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt
//!
//! Frame names are a page's prefix plus one of its `golden_frames` (`rest`, `card-rest`): one
//! line per page in `pages` below. ci/jobs/widget-golden.sh renders each one and compares it
//! with tools/widgetgolden/ref/<frame>.png.
const std = @import("std");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const Quad = lcgr.draw_list.Quad;
const Replay = lcgr.input.Replay;
const Input = lcgr.input.Input;
const gfx = lcgr.quad_shader;

/// Each widget page: frame-name prefix, page type (with `Run`), replay, golden frames.
const pages = .{
    .{ "", w.Reference(.default), w.reference_replay, w.golden_frames },
    .{ "card-", lcgr.widgets_card.Page(.default), lcgr.widgets_card.replay, lcgr.widgets_card.golden_frames },
    .{ "label-", lcgr.widgets_label.Page, lcgr.widgets_label.Page.replay, lcgr.widgets_label.Page.golden_frames },
    .{ "button-", lcgr.widgets_button.Page, lcgr.widgets_button.Page.replay, lcgr.widgets_button.Page.golden_frames },
    .{ "checkbox-", lcgr.widgets_checkbox.Page, lcgr.widgets_checkbox.Page.replay, lcgr.widgets_checkbox.Page.golden_frames },
    .{ "radio-", lcgr.widgets_radio.Page, lcgr.widgets_radio.Page.replay, lcgr.widgets_radio.Page.golden_frames },
    .{ "switch-", lcgr.widgets_switch.Page, lcgr.widgets_switch.Page.replay, lcgr.widgets_switch.Page.golden_frames },
    .{ "toggle-", lcgr.widgets_toggle.Page, lcgr.widgets_toggle.Page.replay, lcgr.widgets_toggle.Page.golden_frames },
    .{ "slider-", lcgr.widgets_slider.Page, lcgr.widgets_slider.Page.replay, lcgr.widgets_slider.Page.golden_frames },
    .{ "range-", lcgr.widgets_range.Page, lcgr.widgets_range.Page.replay, lcgr.widgets_range.Page.golden_frames },
    .{ "chip-", lcgr.widgets_chip.Page, lcgr.widgets_chip.Page.replay, lcgr.widgets_chip.Page.golden_frames },
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

    inline for (pages) |page| inline for (page[3]) |g| {
        if (std.mem.eql(u8, name, page[0] ++ g[0])) return dump(page[1], page[2], g[1], io, out_path);
    };
    return error.UnknownFrame;
}

fn dump(comptime Page: type, replay_src: []const u8, target: u32, io: std.Io, out_path: []const u8) !void {
    const S = struct {
        var harness: Page.Run = .{};
    };
    const harness = &S.harness;
    harness.init();
    var text: [16]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var replay: Replay = .{ .src = replay_src };
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
