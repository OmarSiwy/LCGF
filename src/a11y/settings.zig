//! Accessibility settings (tier 2): the platform's accessibility preferences as plain inputs,
//! and what they change. Shells read the platform (Windows high contrast, `prefers-contrast`,
//! ...) and set the fields; this file turns them into theme tokens (src/theme/theme.zig), so
//! honouring a setting needs no per-widget code.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const theme = @import("../theme/theme.zig");
const base = @import("../widgets/base.zig");
const Color = types.Color;
const Tokens = theme.Tokens;
const Focus = @import("../interact/focus.zig").Focus;
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("tree.zig");
const settings_data = @import("settings_data.zig");
const Spec = spec_zig.Spec;

pub const Settings = settings_data.Settings;
pub const progress = settings_data.progress;

/// The range `Settings.text_scale` is clamped to: past both ends of what platforms offer
/// (Android 0.85, iOS accessibility sizes about 3.1).
pub const text_scale_min: f32 = 0.5;
pub const text_scale_max: f32 = 4;

/// Light text and yellow accents on black, as the platforms' high-contrast themes draw them.
/// Control faces stay apart from the panel and from each other so states still show.
// ponytail: one dark palette; add a light high-contrast palette if a platform asks for one.
pub const high_contrast_palette: theme.Palette = .{
    Color.rgb(255, 255, 255), // text
    Color.rgb(0, 0, 0), // surface
    Color.rgb(32, 32, 32), // control
    Color.rgb(64, 64, 64), // control_hot
    Color.rgb(16, 16, 16), // control_held
    Color.rgb(255, 230, 0), // accent
};

/// `tok` adjusted by the settings: the tokens the widget theme is built from.
pub fn tokens(s: *const Settings, tok: *const Tokens) Tokens {
    var out = tok.*;
    if (s.high_contrast) out.palette = high_contrast_palette;
    const k = @min(@max(s.text_scale, text_scale_min), text_scale_max);
    for (&out.text_size) |*px| px.* *= k;
    return out;
}

/// The widget theme of `tok` under the settings. Cheap enough to call every frame, so a change
/// of setting restyles the next frame.
pub fn widgets(s: *const Settings, tok: *const Tokens) base.Theme {
    return theme.widgets(&tokens(s, tok));
}

/// Applies `always_show_focus` to this frame's ring: call after `Focus.step`, before
/// `Focus.ring`. Without the setting the ring follows keys and the pointer as before.
pub fn showFocus(s: *const Settings, fo: *Focus) void {
    fo.visible = simd.orB(fo.visible, s.always_show_focus);
}

// ---- contrast check -------------------------------------------------------------------------

/// WCAG 2 minimum contrast for body text: level AA (1.4.3) and AAA (1.4.6).
pub const aa: f32 = 4.5;
pub const aaa: f32 = 7;
/// WCAG 1.4.11 non-text contrast, for marks and outlines at every level.
pub const non_text: f32 = 3;

/// A foreground role drawn over a background role, and the contrast it needs.
pub const Pair = struct { fg: theme.Role, bg: theme.Role, min: f32 };

/// The pairs the widgets draw, with body text held to `text_min` (`aa` or `aaa`): text on the
/// panel and on every control face; a checked box and a slider's fill against the track; the
/// focus outline against the panel.
pub fn pairs(text_min: f32) [6]Pair {
    return .{
        .{ .fg = .text, .bg = .surface, .min = text_min },
        .{ .fg = .text, .bg = .control, .min = text_min },
        .{ .fg = .text, .bg = .control_hot, .min = text_min },
        .{ .fg = .text, .bg = .control_held, .min = text_min },
        .{ .fg = .accent, .bg = .control, .min = non_text },
        .{ .fg = .accent, .bg = .surface, .min = non_text },
    };
}

/// The first pair of `pairs(text_min)` whose colours in `tok` contrast less than it needs, or
/// null when every pair passes. Runs at compile time too, so a theme can assert it is readable;
/// `std.math.pow` spends branches there, so raise the quota (10,000 covers one check):
/// `comptime { @setEvalBranchQuota(10_000); std.debug.assert(check(&tok, aa) == null); }`.
pub fn check(tok: *const Tokens, text_min: f32) ?Pair {
    for (pairs(text_min)) |p| {
        if (contrast(tok.color(p.fg), tok.color(p.bg)) < p.min) return p;
    }
    return null;
}

/// WCAG 2 contrast ratio of two opaque colours, 1 (same luminance) to 21 (black on white).
pub fn contrast(a: Color, b: Color) f32 {
    const la = luminance(a) + 0.05;
    const lb = luminance(b) + 0.05;
    return @max(la, lb) / @min(la, lb);
}

/// WCAG 2 relative luminance of an sRGB colour, 0 to 1. Alpha is ignored.
pub fn luminance(c: Color) f32 {
    const ch = [3]u8{ c.r, c.g, c.b };
    const w = [3]f32{ 0.2126, 0.7152, 0.0722 };
    var l: f32 = 0;
    for (ch, w) |v, k| {
        const x = @as(f32, @floatFromInt(v)) / 255;
        l += k * if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
    }
    return l;
}

// ---- lint for the comptime front end -----------------------------------------------------

/// What a comptime spec can get wrong for assistive technology, checked while compiling.
pub const Rule = enum {
    /// An interactive node (one with an id) whose role is `none`: presentational, so it is
    /// left out of the semantic tree and a screen reader never finds it.
    no_role,
    /// An interactive node whose role takes its name from its content (a button, a checkbox)
    /// with no label in its subtree: it is announced with no name.
    unnamed,
    /// An interactive node inside another: ARIA allows no interactive content in a button or
    /// a checkbox, and readers announce only the outer one.
    nested,
};

pub const Finding = struct {
    rule: Rule,
    /// Depth-first row in the spec, as `flatten` numbers it.
    row: u32,
    /// The widget's id.
    id: []const u8,
};

/// Every finding in `spec`, in row order. Empty for a clean spec.
pub fn findings(comptime spec: Spec) []const Finding {
    comptime {
        @setEvalBranchQuota(1000 + 100 * @import("../comptime/flatten.zig").count(spec));
        var out: []const Finding = &.{};
        var row: u32 = 0;
        lintWalk(spec, false, &row, &out);
        const final = out[0..out.len].*;
        return &final;
    }
}

fn lintWalk(comptime s: Spec, comptime inside: bool, comptime row: *u32, comptime out: *[]const Finding) void {
    const here = row.*;
    row.* += 1;
    if (s.id) |id| {
        const role = @backingInt(s.style.role);
        if (role == 0) out.* = out.* ++ [_]Finding{.{ .rule = .no_role, .row = here, .id = id }};
        if (a11y.from_content[role] != 0 and !hasLabel(s))
            out.* = out.* ++ [_]Finding{.{ .rule = .unnamed, .row = here, .id = id }};
        if (inside) out.* = out.* ++ [_]Finding{.{ .rule = .nested, .row = here, .id = id }};
    }
    for (s.children) |c| lintWalk(c, inside or s.id != null, row, out);
}

fn hasLabel(comptime s: Spec) bool {
    if (s.kind == .label) return true;
    for (s.children) |c| if (hasLabel(c)) return true;
    return false;
}

/// The compile error `lint` gives for `found`, one line per finding.
pub fn message(comptime found: []const Finding) []const u8 {
    comptime {
        var m: []const u8 = "";
        for (found) |f| m = m ++ std.fmt.comptimePrint("\nwidget '{s}' (spec row {d}): {s}", .{ f.id, f.row, switch (f.rule) {
            .no_role => "has an id but no role; set `style.role` so assistive technology sees it",
            .unnamed => "has no label to be named by; add a label child",
            .nested => "is inside another interactive widget; move it out",
        } });
        return std.fmt.comptimePrint("accessibility lint: {d} finding(s){s}", .{ found.len, m });
    }
}

/// Fails the build when `spec` breaks a `Rule`: `comptime settings.lint(spec);` beside the
/// `ComptimeUi(State, spec, th)` it checks.
pub fn lint(comptime spec: Spec) void {
    const found = comptime findings(spec);
    if (found.len > 0) @compileError(message(found));
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "settings: the defaults leave the theme alone" {
    for ([_]Tokens{ theme.dark, theme.light }) |tok| {
        try testing.expectEqual(tok, tokens(&.{}, &tok));
        try testing.expectEqual(theme.widgets(&tok), widgets(&.{}, &tok));
    }
}

test "settings: high contrast swaps the palette and nothing else" {
    const hc = tokens(&.{ .high_contrast = true }, &theme.light);
    try testing.expectEqual(high_contrast_palette, hc.palette);
    try testing.expectEqual(theme.light.space, hc.space);
    try testing.expectEqual(theme.light.radius, hc.radius);
    try testing.expectEqual(theme.light.text_size, hc.text_size);
}

test "settings: switching high contrast on and off restyles the page, behaviour unchanged" {
    const on: Settings = .{ .high_contrast = true };
    try theme.expectSwitch(comptime widgets(&.{}, &theme.dark), comptime widgets(&on, &theme.dark));
    try theme.expectSwitch(comptime widgets(&on, &theme.light), comptime widgets(&.{}, &theme.light));
}

test "settings: text scaling multiplies every text size, clamped, and nothing else" {
    const big = tokens(&.{ .text_scale = 2 }, &theme.dark);
    for (theme.dark.text_size, big.text_size) |a, b| try testing.expectEqual(a * 2, b);
    try testing.expectEqual(theme.dark.space, big.space);
    try testing.expectEqual(theme.dark.palette, big.palette);
    const md = theme.dark.textAt(.md);
    try testing.expectEqual(md * text_scale_max, tokens(&.{ .text_scale = 100 }, &theme.dark).textAt(.md));
    try testing.expectEqual(md * text_scale_min, tokens(&.{ .text_scale = 0 }, &theme.dark).textAt(.md));
    try testing.expectEqual(md * text_scale_min, tokens(&.{ .text_scale = std.math.nan(f32) }, &theme.dark).textAt(.md));
    try testing.expectEqual(md * 2, widgets(&.{ .text_scale = 2, .high_contrast = true }, &theme.dark).text_px);
}

test "settings: scaled text draws at the scaled size, behaviour unchanged" {
    // expectSwitch checks every text run is drawn at its theme's `text_px`, and that the same
    // script of pointer moves (aimed at last frame's rects) gives the same states.
    try theme.expectSwitch(comptime widgets(&.{}, &theme.dark), comptime widgets(&.{ .text_scale = 2 }, &theme.dark));
    try theme.expectSwitch(comptime widgets(&.{}, &theme.dark), comptime widgets(&.{ .text_scale = 0.75 }, &theme.dark));
}

test "settings: reduced motion finishes every transition on its first frame" {
    const calm: Settings = .{ .reduced_motion = true };
    try testing.expectEqual(@as(f32, 0), progress(&.{}, 0, 0.3));
    try testing.expectApproxEqAbs(@as(f32, 0.5), progress(&.{}, 0.15, 0.3), 1e-6);
    try testing.expectEqual(@as(f32, 1), progress(&.{}, 0.3, 0.3));
    try testing.expectEqual(@as(f32, 1), progress(&.{}, 9, 0.3));
    try testing.expectEqual(@as(f32, 0), progress(&.{}, -1, 0.3));
    for ([_]f32{ 0, 0.01, 0.15, 5 }) |t| try testing.expectEqual(@as(f32, 1), progress(&calm, t, 0.3));
    // A zero-length transition is done at once, with or without the setting.
    try testing.expectEqual(@as(f32, 1), progress(&.{}, 0, 0));
    try testing.expectEqual(@as(f32, 1), progress(&calm, 0, 0));
}

/// Ring per frame for a two-button row, as `Interaction`, `Focus` and `showFocus` give it
/// for `src`.
fn rings(s: *const Settings, src: []const u8) ![5]types.Rect {
    const mem = @import("../core/mem.zig");
    const Tree = @import("../core/tree.zig").Tree;
    const Texts = @import("../core/texts.zig").Texts;
    const focus = @import("../interact/focus.zig");
    const Interaction = @import("../interact/interaction.zig").Interaction;
    const Input = @import("../core/input.zig").Input;
    var raw: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 4);
    var tx = Texts.init(&carver, 1);
    var sc = focus.Scopes.init(&carver, 4);
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(20) } });
    for ([_]types.Id{ .from("a"), .from("b") }) |id| {
        const n = t.push(root, id, &.{ .size = .{ .px(100), .px(20) } });
        t.seal(n);
        t.c.sense[n] = @bitCast(types.Sense.button);
    }
    t.seal(root);
    @import("../layout/layout.zig").run(&t, &tx, .{ 200, 20 });
    focus.scan(&t, &sc);
    var it: Interaction = .{};
    var fo: Focus = .{};
    var out: [5]types.Rect = @splat(.{});
    var text: [4]u8 = undefined;
    var evs: [4]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    var r: @import("../core/input.zig").Replay = .{ .src = src };
    var k: usize = 0;
    while (try r.next(.{ .text = &text, .events = &evs, .contacts = &contacts })) |in| : (k += 1) {
        it.step(&t, in);
        fo.step(&it, &t, &sc, in);
        showFocus(s, &fo);
        out[k] = fo.ring(&it, &t);
    }
    try testing.expectEqual(5, k);
    return out;
}

test "settings: always show focus keeps the ring on after the pointer, wherever focus goes" {
    // Tab focuses "a"; a click on "b" moves focus there; the release keeps it; a click on
    // nothing clears it.
    const src =
        \\frame
        \\press 43
        \\frame
        \\release 43
        \\frame
        \\pointer 150 10
        \\buttons left
        \\frame
        \\buttons
        \\pointer 150 50
        \\frame
        \\buttons left
    ;
    const a: types.Rect = .{ .x0 = -2, .y0 = -2, .x1 = 102, .y1 = 22 };
    const b: types.Rect = .{ .x0 = 98, .y0 = -2, .x1 = 202, .y1 = 22 };
    // Without the setting the click hides the ring (`:focus-visible`).
    try testing.expectEqualSlices(types.Rect, &.{ a, a, .{}, .{}, .{} }, &try rings(&.{}, src));
    // With it the ring follows focus through the click; nothing focused still draws nothing.
    try testing.expectEqualSlices(types.Rect, &.{ a, a, b, b, .{} }, &try rings(&.{ .always_show_focus = true }, src));
}

test "lint: the reference page is clean" {
    const R = base.Reference(.default);
    comptime lint(R.spec);
    try testing.expectEqual(0, (comptime findings(R.spec)).len);
}

test "lint: roleless widgets, unnamed buttons and nested widgets are found by row" {
    // The probe's mixer from the plain builders: widgets with ids but no role.
    const mixer = comptime spec_zig.col(.{}, .{
        spec_zig.label(.title),
        spec_zig.row(.{}, .{ spec_zig.checkbox(.mute, .muted), spec_zig.slider(.volume, .volume) }),
        spec_zig.row(.{}, .{ spec_zig.label(.title), spec_zig.slider(.pan, .pan) }),
    });
    const m = comptime findings(mixer);
    try testing.expectEqual(3, m.len);
    inline for (m, .{ "mute", "volume", "pan" }, .{ 3, 4, 7 }) |f, id, row| {
        try testing.expectEqual(Rule.no_role, f.rule);
        try testing.expectEqualStrings(id, f.id);
        try testing.expectEqual(row, f.row);
    }

    // A button with an icon only, and a checkbox inside a button.
    const th: base.Theme = .default;
    const page = comptime blk: {
        var icon = spec_zig.row(base.buttonStyle(&th), .{Spec{ .kind = .col }});
        icon.id = "close";
        var outer = spec_zig.row(base.buttonStyle(&th), .{ base.ct.label(th, .text), base.ct.checkbox(th, .inner, .on, .text) });
        outer.id = "outer";
        break :blk spec_zig.col(.{}, .{ icon, outer });
    };
    const p = comptime findings(page);
    try testing.expectEqual(2, p.len);
    try testing.expectEqual(Finding{ .rule = .unnamed, .row = 1, .id = "close" }, p[0]);
    try testing.expectEqual(Rule.nested, p[1].rule);
    try testing.expectEqualStrings("inner", p[1].id);
    try testing.expectEqual(5, p[1].row);

    // What the build fails with.
    try testing.expectEqualStrings(
        \\accessibility lint: 2 finding(s)
        \\widget 'close' (spec row 1): has no label to be named by; add a label child
        \\widget 'inner' (spec row 5): is inside another interactive widget; move it out
    , comptime message(p));
}

test "contrast: WCAG ratios at the ends and for known pairs" {
    try testing.expectApproxEqAbs(@as(f32, 21), contrast(.black, .white), 1e-3);
    try testing.expectEqual(@as(f32, 1), contrast(.rgb(90, 140, 255), .rgb(90, 140, 255)));
    try testing.expectEqual(contrast(.black, .rgb(118, 118, 118)), contrast(.rgb(118, 118, 118), .black));
    // #767676 on white is the classic smallest grey that passes AA: 4.54.
    try testing.expectApproxEqAbs(@as(f32, 4.54), contrast(.rgb(118, 118, 118), .white), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), luminance(.white), 1e-6);
    try testing.expectEqual(@as(f32, 0), luminance(.black));
}

test "contrast check: stock themes pass AA, high contrast passes AAA, in every setting" {
    try testing.expectEqual(null, check(&theme.dark, aa));
    try testing.expectEqual(null, check(&theme.light, aa));
    // The stock themes are not AAA; the high-contrast palette is there for that.
    try testing.expect(check(&theme.dark, aaa) != null);
    const hc: Settings = .{ .high_contrast = true, .text_scale = 2 };
    for ([_]Tokens{ theme.dark, theme.light }) |tok| try testing.expectEqual(null, check(&tokens(&hc, &tok), aaa));
    // At compile time, as a theme author asserts it.
    comptime {
        @setEvalBranchQuota(10_000);
        std.debug.assert(check(&tokens(&hc, &theme.dark), aaa) == null);
    }
}

test "contrast check: reports the first pair that fails" {
    var tok = theme.dark;
    tok.palette[@backingInt(theme.Role.control_hot)] = .rgb(170, 170, 175); // light text on light grey
    try testing.expectEqual(Pair{ .fg = .text, .bg = .control_hot, .min = aa }, check(&tok, aa).?);
    tok = theme.light;
    tok.palette[@backingInt(theme.Role.accent)] = tok.color(.control);
    try testing.expectEqual(Pair{ .fg = .accent, .bg = .control, .min = non_text }, check(&tok, aa).?);
}
