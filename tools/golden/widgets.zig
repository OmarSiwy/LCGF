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
//! with tools/golden/ref/widgets/<frame>.png.
const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Quad = lcgf.draw_list.Quad;
const Replay = lcgf.input.Replay;
const Input = lcgf.input.Input;
const gfx = lcgf.quad_shader;

/// Each widget page: frame-name prefix, page type (with `Run`), replay, golden frames.
const pages = .{
    .{ "", w.Reference(.default), w.reference_replay, w.golden_frames },
    .{ "card-", lcgf.widgets_card.Page(.default), lcgf.widgets_card.replay, lcgf.widgets_card.golden_frames },
    .{ "label-", lcgf.widgets_label.Page, lcgf.widgets_label.Page.replay, lcgf.widgets_label.Page.golden_frames },
    .{ "button-", lcgf.widgets_button.Page, lcgf.widgets_button.Page.replay, lcgf.widgets_button.Page.golden_frames },
    .{ "checkbox-", lcgf.widgets_checkbox.Page, lcgf.widgets_checkbox.Page.replay, lcgf.widgets_checkbox.Page.golden_frames },
    .{ "radio-", lcgf.widgets_radio.Page, lcgf.widgets_radio.Page.replay, lcgf.widgets_radio.Page.golden_frames },
    .{ "switch-", lcgf.widgets_switch.Page, lcgf.widgets_switch.Page.replay, lcgf.widgets_switch.Page.golden_frames },
    .{ "toggle-", lcgf.widgets_toggle.Page, lcgf.widgets_toggle.Page.replay, lcgf.widgets_toggle.Page.golden_frames },
    .{ "slider-", lcgf.widgets_slider.Page, lcgf.widgets_slider.Page.replay, lcgf.widgets_slider.Page.golden_frames },
    .{ "range-", lcgf.widgets_range.Page, lcgf.widgets_range.Page.replay, lcgf.widgets_range.Page.golden_frames },
    .{ "chip-", lcgf.widgets_chip.Page, lcgf.widgets_chip.Page.replay, lcgf.widgets_chip.Page.golden_frames },
    .{ "separator-", lcgf.widgets_separator.Page(.default), lcgf.widgets_separator.replay, lcgf.widgets_separator.golden_frames },
    .{ "spacer-", lcgf.widgets_spacer.Page(.default), lcgf.widgets_spacer.replay, lcgf.widgets_spacer.golden_frames },
    .{ "accordion-", lcgf.widgets_accordion.Page(.default), lcgf.widgets_accordion.replay, lcgf.widgets_accordion.golden_frames },
    .{ "tabs-", lcgf.widgets_tabs.Page(.default), lcgf.widgets_tabs.replay, lcgf.widgets_tabs.golden_frames },
    .{ "splitter-", lcgf.widgets_splitter.Page(.default), lcgf.widgets_splitter.replay, lcgf.widgets_splitter.golden_frames },
    .{ "scroll-", lcgf.widgets_scroll.Page(.default), lcgf.widgets_scroll.replay, lcgf.widgets_scroll.golden_frames },
    .{ "toolbar-", lcgf.widgets_toolbar.Page(.default), lcgf.widgets_toolbar.replay, lcgf.widgets_toolbar.golden_frames },
    .{ "breadcrumb-", lcgf.widgets_breadcrumb.Page(.default), lcgf.widgets_breadcrumb.replay, lcgf.widgets_breadcrumb.golden_frames },
    .{ "icon-", lcgf.widgets_icon.Page(.default), lcgf.widgets_icon.replay, lcgf.widgets_icon.golden_frames },
    .{ "statusbar-", lcgf.widgets_statusbar.Page(.default), lcgf.widgets_statusbar.replay, lcgf.widgets_statusbar.golden_frames },
    .{ "list-", lcgf.widgets_list.Page, lcgf.widgets_list.Page.replay, lcgf.widgets_list.Page.golden_frames },
    .{ "vlist-", lcgf.widgets_vlist.Page, lcgf.widgets_vlist.Page.replay, lcgf.widgets_vlist.Page.golden_frames },
    .{ "table-", lcgf.widgets_table.Page, lcgf.widgets_table.Page.replay, lcgf.widgets_table.Page.golden_frames },
    .{ "tree-", lcgf.widgets_tree.Page, lcgf.widgets_tree.Page.replay, lcgf.widgets_tree.Page.golden_frames },
    .{ "progress-", lcgf.widgets_progress.Page, lcgf.widgets_progress.Page.replay, lcgf.widgets_progress.Page.golden_frames },
    .{ "spinner-", lcgf.widgets_spinner.Page, lcgf.widgets_spinner.Page.replay, lcgf.widgets_spinner.Page.golden_frames },
    .{ "colorpicker-", lcgf.widgets_colorpicker.Page, lcgf.widgets_colorpicker.Page.replay, lcgf.widgets_colorpicker.Page.golden_frames },
    .{ "image-", lcgf.widgets_image.Page(.default), lcgf.widgets_image.replay, lcgf.widgets_image.golden_frames },
    .{ "", lcgf.widgets_popover.golden, lcgf.widgets_popover.golden.src, lcgf.widgets_popover.golden.frames },
    .{ "", lcgf.widgets_tooltip.golden, lcgf.widgets_tooltip.golden.src, lcgf.widgets_tooltip.golden.frames },
    .{ "", lcgf.widgets_menu.golden, lcgf.widgets_menu.golden.src, lcgf.widgets_menu.golden.frames },
    .{ "", lcgf.widgets_menubar.golden, lcgf.widgets_menubar.golden.src, lcgf.widgets_menubar.golden.frames },
    .{ "", lcgf.widgets_contextmenu.golden, lcgf.widgets_contextmenu.golden.src, lcgf.widgets_contextmenu.golden.frames },
    .{ "", lcgf.widgets_dialog.golden, lcgf.widgets_dialog.golden.src, lcgf.widgets_dialog.golden.frames },
    .{ "", lcgf.widgets_toast.golden, lcgf.widgets_toast.golden.src, lcgf.widgets_toast.golden.frames },
    .{ "", lcgf.widgets_select.golden, lcgf.widgets_select.golden.src, lcgf.widgets_select.golden.frames },
    .{ "", lcgf.widgets_combobox.golden, lcgf.widgets_combobox.golden.src, lcgf.widgets_combobox.golden.frames },
    .{ "", lcgf.widgets_datepicker.golden, lcgf.widgets_datepicker.golden.src, lcgf.widgets_datepicker.golden.frames },
    .{ "search-", lcgf.widgets_search.Page, lcgf.widgets_search.Page.replay, lcgf.widgets_search.Page.golden_frames },
    .{ "number-", lcgf.widgets_number.Page, lcgf.widgets_number.Page.replay, lcgf.widgets_number.Page.golden_frames },
    .{ "textarea-", lcgf.widgets_textarea.Page, lcgf.widgets_textarea.Page.replay, lcgf.widgets_textarea.Page.golden_frames },
    .{ "textfield-", lcgf.widgets_textfield.Page, lcgf.widgets_textfield.Page.replay, lcgf.widgets_textfield.Page.golden_frames },
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
            const c: lcgf.types.Color = if (x >= 64 or y >= 48)
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
