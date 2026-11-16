//! Golden-image dumper for the widgets: replays a page's input (`widgets_base.reference_replay`,
//! or a widget's own, see `pages`) through both front ends with the widget harness (which fails
//! if they draw differently), and writes the named frame as tools/golden/gpu.py draws it, into
//! a directory:
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
    .{ "separator-", lcgr.widgets_separator.Page(.default), lcgr.widgets_separator.replay, lcgr.widgets_separator.golden_frames },
    .{ "spacer-", lcgr.widgets_spacer.Page(.default), lcgr.widgets_spacer.replay, lcgr.widgets_spacer.golden_frames },
    .{ "accordion-", lcgr.widgets_accordion.Page(.default), lcgr.widgets_accordion.replay, lcgr.widgets_accordion.golden_frames },
    .{ "tabs-", lcgr.widgets_tabs.Page(.default), lcgr.widgets_tabs.replay, lcgr.widgets_tabs.golden_frames },
    .{ "splitter-", lcgr.widgets_splitter.Page(.default), lcgr.widgets_splitter.replay, lcgr.widgets_splitter.golden_frames },
    .{ "scroll-", lcgr.widgets_scroll.Page(.default), lcgr.widgets_scroll.replay, lcgr.widgets_scroll.golden_frames },
    .{ "toolbar-", lcgr.widgets_toolbar.Page(.default), lcgr.widgets_toolbar.replay, lcgr.widgets_toolbar.golden_frames },
    .{ "breadcrumb-", lcgr.widgets_breadcrumb.Page(.default), lcgr.widgets_breadcrumb.replay, lcgr.widgets_breadcrumb.golden_frames },
    .{ "icon-", lcgr.widgets_icon.Page(.default), lcgr.widgets_icon.replay, lcgr.widgets_icon.golden_frames },
    .{ "list-", lcgr.widgets_list.Page, lcgr.widgets_list.Page.replay, lcgr.widgets_list.Page.golden_frames },
    .{ "vlist-", lcgr.widgets_vlist.Page, lcgr.widgets_vlist.Page.replay, lcgr.widgets_vlist.Page.golden_frames },
    .{ "table-", lcgr.widgets_table.Page, lcgr.widgets_table.Page.replay, lcgr.widgets_table.Page.golden_frames },
    .{ "tree-", lcgr.widgets_tree.Page, lcgr.widgets_tree.Page.replay, lcgr.widgets_tree.Page.golden_frames },
    .{ "progress-", lcgr.widgets_progress.Page, lcgr.widgets_progress.Page.replay, lcgr.widgets_progress.Page.golden_frames },
    .{ "spinner-", lcgr.widgets_spinner.Page, lcgr.widgets_spinner.Page.replay, lcgr.widgets_spinner.Page.golden_frames },
    .{ "colorpicker-", lcgr.widgets_colorpicker.Page, lcgr.widgets_colorpicker.Page.replay, lcgr.widgets_colorpicker.Page.golden_frames },
    .{ "", lcgr.widgets_popover.golden, lcgr.widgets_popover.golden.src, lcgr.widgets_popover.golden.frames },
    .{ "", lcgr.widgets_tooltip.golden, lcgr.widgets_tooltip.golden.src, lcgr.widgets_tooltip.golden.frames },
    .{ "", lcgr.widgets_menu.golden, lcgr.widgets_menu.golden.src, lcgr.widgets_menu.golden.frames },
    .{ "", lcgr.widgets_menubar.golden, lcgr.widgets_menubar.golden.src, lcgr.widgets_menubar.golden.frames },
    .{ "", lcgr.widgets_contextmenu.golden, lcgr.widgets_contextmenu.golden.src, lcgr.widgets_contextmenu.golden.frames },
    .{ "", lcgr.widgets_dialog.golden, lcgr.widgets_dialog.golden.src, lcgr.widgets_dialog.golden.frames },
    .{ "", lcgr.widgets_toast.golden, lcgr.widgets_toast.golden.src, lcgr.widgets_toast.golden.frames },
    .{ "", lcgr.widgets_select.golden, lcgr.widgets_select.golden.src, lcgr.widgets_select.golden.frames },
};
// Room for the largest page's text (the table example has 23 runs).
var glyph_quads: [4096]Quad = undefined;
var first: [256]u32 = undefined;
var count: [256]u32 = undefined;

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
    var text: [256]u8 = undefined;
    var events: [64]Input.Event = undefined;
    var contacts: [8]Input.Contact = undefined;
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
