//! Theme tests across the widget set: every stock theme and density applied to every widget page
//! that takes a theme, through both front ends. The per-feature tests sit next to the code in
//! theme.zig; this file checks the claim of target G2 (docs/TARGETS.md), "every visual of every
//! widget can be replaced", for the widgets that exist.

const std = @import("std");
const theme = @import("theme.zig");
const base = @import("../widgets/base.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Replay = @import("../core/input.zig").Replay;
const testing = std.testing;

const card = @import("../widgets/card.zig");
const list = @import("../widgets/list.zig");
const vlist = @import("../widgets/vlist.zig");
const table = @import("../widgets/table.zig");
const tree = @import("../widgets/tree.zig");
const progress = @import("../widgets/progress.zig");
const spinner = @import("../widgets/spinner.zig");
const colorpicker = @import("../widgets/colorpicker.zig");

/// The stock themes at every density.
const themes = .{
    theme.Folded(theme.dark, .compact).theme,
    theme.Dark.theme,
    theme.Folded(theme.dark, .spacious).theme,
    theme.Folded(theme.light, .compact).theme,
    theme.Light.theme,
    theme.Folded(theme.light, .spacious).theme,
};

/// Every widget page that takes a theme, with its replay.
const pages = .{
    .{ base.Reference, base.reference_replay },
    .{ card.Page, card.replay },
    .{ list.Example, list.Page.replay },
    .{ vlist.Example, vlist.Page.replay },
    .{ table.Example, table.Page.replay },
    .{ tree.Example, tree.Page.replay },
    .{ progress.Example, progress.Page.replay },
    .{ spinner.Example, spinner.Page.replay },
    .{ colorpicker.Example, colorpicker.Page.replay },
};

/// Replays `src` through page `P(th)` in both front ends, which must agree every frame. In a
/// theme whose palette shares no colour with the dark palette, no quad or text in any frame may
/// carry a dark-palette colour: every colour the widget shows came from the theme, none is
/// fixed in the widget.
fn expectPage(comptime P: fn (comptime base.Theme) type, comptime th: base.Theme, src: []const u8) !void {
    const S = struct {
        var h: P(th).Run = .{};
    };
    const h = &S.h;
    h.init();
    var text: [64]u8 = undefined;
    var evs: [16]Input.Event = undefined;
    var contacts: [2]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = src };
    const foreign = comptime !sharesColour(th);
    while (try replay.next(buf)) |in| {
        const out = try h.frame(in);
        if (!foreign) continue;
        const d = out.runtime.draw;
        for (d.quads[0..d.quad_len]) |q| {
            try expectNotDark(q.fill);
            try expectNotDark(q.border_color);
        }
        for (d.runs[0..d.run_len]) |r| try expectNotDark(r.color);
    }
    try testing.expect(h.frames > 0);
}

fn sharesColour(th: base.Theme) bool {
    for ([_]types.Color{ th.text, th.panel, th.control, th.control_hot, th.control_held, th.accent }) |c| {
        for (theme.dark_palette) |p| if (c.bitsOf() == p.bitsOf()) return true;
    }
    return false;
}

fn expectNotDark(c: u32) !void {
    for (theme.dark_palette) |p| try testing.expect(c != p.bitsOf());
}

test "theme switch: every widget page in every stock theme and density, both front ends" {
    inline for (pages) |page| {
        inline for (themes) |th| try expectPage(page[0], th, page[1]);
    }
}

test "theme switch: every pair of stock themes, behaviour unchanged" {
    inline for (themes, 0..) |a, i| {
        inline for (themes, 0..) |b, j| {
            if (i != j) try theme.expectSwitch(a, b);
        }
    }
}

test "light themes are foreign to the dark palette, so the page test checks them" {
    try testing.expect(!sharesColour(theme.Light.theme));
    try testing.expect(sharesColour(theme.Dark.theme));
}
