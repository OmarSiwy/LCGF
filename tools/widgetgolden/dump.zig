//! Golden-image dumper for the widgets: replays a page's input (`widgets_base.reference_replay`,
//! or a widget's own, see `pages`) through both front ends with the widget harness (which fails
//! if they draw differently), and writes the named frame as tools/golden/gpu.py draws it, into
//! a directory:
//!
//!     zig build widget-dump -- <frame> <dir>     quad.wgsl, quads.bin, glyphs.bin, cmds.txt,
//!                                                 tex<id>.rgba for each texture in `textures`
//!
//! The pages' textures are uploaded here, as an application would: each one the frame samples
//! is written as RGBA8 rows with a `texture <id> <w> <h> <file>` line in cmds.txt, and gpu.py
//! binds it in place of its stand-in atlas, so the images show the texture's pixels.
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
    .{ "separator-", lcgr.widgets_separator.Page(.default), lcgr.widgets_separator.replay, lcgr.widgets_separator.golden_frames },
    .{ "spacer-", lcgr.widgets_spacer.Page(.default), lcgr.widgets_spacer.replay, lcgr.widgets_spacer.golden_frames },
    .{ "accordion-", lcgr.widgets_accordion.Page(.default), lcgr.widgets_accordion.replay, lcgr.widgets_accordion.golden_frames },
    .{ "tabs-", lcgr.widgets_tabs.Page(.default), lcgr.widgets_tabs.replay, lcgr.widgets_tabs.golden_frames },
    .{ "splitter-", lcgr.widgets_splitter.Page(.default), lcgr.widgets_splitter.replay, lcgr.widgets_splitter.golden_frames },
    .{ "scroll-", lcgr.widgets_scroll.Page(.default), lcgr.widgets_scroll.replay, lcgr.widgets_scroll.golden_frames },
    .{ "toolbar-", lcgr.widgets_toolbar.Page(.default), lcgr.widgets_toolbar.replay, lcgr.widgets_toolbar.golden_frames },
    .{ "breadcrumb-", lcgr.widgets_breadcrumb.Page(.default), lcgr.widgets_breadcrumb.replay, lcgr.widgets_breadcrumb.golden_frames },
    .{ "icon-", lcgr.widgets_icon.Page(.default), lcgr.widgets_icon.replay, lcgr.widgets_icon.golden_frames },
    .{ "statusbar-", lcgr.widgets_statusbar.Page(.default), lcgr.widgets_statusbar.replay, lcgr.widgets_statusbar.golden_frames },
    .{ "list-", lcgr.widgets_list.Page, lcgr.widgets_list.Page.replay, lcgr.widgets_list.Page.golden_frames },
    .{ "vlist-", lcgr.widgets_vlist.Page, lcgr.widgets_vlist.Page.replay, lcgr.widgets_vlist.Page.golden_frames },
    .{ "table-", lcgr.widgets_table.Page, lcgr.widgets_table.Page.replay, lcgr.widgets_table.Page.golden_frames },
    .{ "tree-", lcgr.widgets_tree.Page, lcgr.widgets_tree.Page.replay, lcgr.widgets_tree.Page.golden_frames },
    .{ "progress-", lcgr.widgets_progress.Page, lcgr.widgets_progress.Page.replay, lcgr.widgets_progress.Page.golden_frames },
    .{ "spinner-", lcgr.widgets_spinner.Page, lcgr.widgets_spinner.Page.replay, lcgr.widgets_spinner.Page.golden_frames },
    .{ "colorpicker-", lcgr.widgets_colorpicker.Page, lcgr.widgets_colorpicker.Page.replay, lcgr.widgets_colorpicker.Page.golden_frames },
    .{ "image-", lcgr.widgets_image.Page(.default), lcgr.widgets_image.replay, lcgr.widgets_image.golden_frames },
    .{ "", lcgr.widgets_popover.golden, lcgr.widgets_popover.golden.src, lcgr.widgets_popover.golden.frames },
    .{ "", lcgr.widgets_tooltip.golden, lcgr.widgets_tooltip.golden.src, lcgr.widgets_tooltip.golden.frames },
    .{ "", lcgr.widgets_menu.golden, lcgr.widgets_menu.golden.src, lcgr.widgets_menu.golden.frames },
    .{ "", lcgr.widgets_menubar.golden, lcgr.widgets_menubar.golden.src, lcgr.widgets_menubar.golden.frames },
    .{ "", lcgr.widgets_contextmenu.golden, lcgr.widgets_contextmenu.golden.src, lcgr.widgets_contextmenu.golden.frames },
    .{ "", lcgr.widgets_dialog.golden, lcgr.widgets_dialog.golden.src, lcgr.widgets_dialog.golden.frames },
    .{ "", lcgr.widgets_toast.golden, lcgr.widgets_toast.golden.src, lcgr.widgets_toast.golden.frames },
    .{ "", lcgr.widgets_select.golden, lcgr.widgets_select.golden.src, lcgr.widgets_select.golden.frames },
    .{ "", lcgr.widgets_combobox.golden, lcgr.widgets_combobox.golden.src, lcgr.widgets_combobox.golden.frames },
    .{ "", lcgr.widgets_datepicker.golden, lcgr.widgets_datepicker.golden.src, lcgr.widgets_datepicker.golden.frames },
    .{ "search-", lcgr.widgets_search.Page, lcgr.widgets_search.Page.replay, lcgr.widgets_search.Page.golden_frames },
    .{ "number-", lcgr.widgets_number.Page, lcgr.widgets_number.Page.replay, lcgr.widgets_number.Page.golden_frames },
    .{ "textarea-", lcgr.widgets_textarea.Page, lcgr.widgets_textarea.Page.replay, lcgr.widgets_textarea.Page.golden_frames },
    .{ "textfield-", lcgr.widgets_textfield.Page, lcgr.widgets_textfield.Page.replay, lcgr.widgets_textfield.Page.golden_frames },
};
/// A texture a page samples, RGBA8 (`Color` bits, premultiplied), row by row.
const Texture = struct { id: u16, w: u32, h: u32, pixels: []const u32 };

/// Texture 1: the image page's picture (widgets_image Page `photo`, its top-left 64 x 48
/// quarter): sky, sun and a hill. The other quarters are magenta, so a wrong uv rect shows.
/// Texture 2: the icon page's 40 x 24 coverage atlas, white where covered: a 16 px document at
/// 0, 0 and a 24 px "save" arrow into a tray at 16, 0.
const textures = [_]Texture{ photo(), icons() };

fn photo() Texture {
    const tw = 128;
    const th = 96;
    const px = comptime blk: {
        @setEvalBranchQuota(400_000);
        var out: [tw * th]u32 = undefined;
        for (0..th) |y| for (0..tw) |x| {
            const c: lcgr.types.Color = if (x >= 64 or y >= 48)
                .rgb(255, 0, 255)
            else if ((@as(i32, x) - 46) * (@as(i32, x) - 46) + (@as(i32, y) - 12) * (@as(i32, y) - 12) < 50)
                .rgb(255, 214, 90)
            else if (y > 28 + @abs(@as(i32, @intCast(x)) - 22) / 5)
                .rgb(40, 120 + @as(u8, @intCast(y)), 60)
            else
                .rgb(80 + @as(u8, @intCast(y * 2)), 150 + @as(u8, @intCast(y)), 235);
            out[y * tw + x] = c.bitsOf();
        };
        break :blk out;
    };
    return .{ .id = 1, .w = tw, .h = th, .pixels = &px };
}

fn icons() Texture {
    const tw = 40;
    const th = 24;
    const px = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [tw * th]u32 = @splat(0);
        for (0..th) |yu| for (0..tw) |xu| {
            const x: i32 = @intCast(xu);
            const y: i32 = @intCast(yu);
            // 16 px: a page with its top-right corner folded, and three lines of text.
            const page = x >= 3 and x <= 12 and y >= 1 and y <= 14 and x + 14 - y <= 22 and
                (x == 3 or x == 12 or y == 1 or y == 14 or x + 14 - y == 22 or
                    (x >= 5 and x <= 10 and (y == 5 or y == 8 or y == 11)));
            // 24 px, from x 16: an arrow down into a tray.
            const lx = x - 16;
            const stem = lx >= 11 and lx <= 12 and y >= 2 and y <= 11;
            const head = y >= 9 and y <= 15 and @abs(lx * 2 - 23) <= 2 * (15 - y) + 1;
            const tray = (y >= 19 and y <= 20 and lx >= 3 and lx <= 20) or
                (y >= 14 and y <= 20 and (lx == 3 or lx == 4 or lx == 19 or lx == 20));
            const on = if (x < 16) page else stem or head or tray;
            out[yu * tw + xu] = if (on) 0xffff_ffff else 0;
        };
        break :blk out;
    };
    return .{ .id = 2, .w = tw, .h = th, .pixels = &px };
}

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
    for (textures) |tex| {
        var used = false;
        for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
            .quads => |b| used = used or @backingInt(b.texture) == tex.id,
            else => {},
        };
        if (!used) continue;
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "tex{d}.rgba", .{tex.id});
        try dir.writeFile(io, .{ .sub_path = name, .data = std.mem.sliceAsBytes(tex.pixels) });
        try wr.print("texture {d} {d} {d} {s}\n", .{ tex.id, tex.w, tex.h, name });
    }
    try dir.writeFile(io, .{ .sub_path = "cmds.txt", .data = wr.buffered() });
}
