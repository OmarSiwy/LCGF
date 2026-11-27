//! Status bar (tier 2): a strip along the foot of a window showing short pieces of status
//! text side by side ("Ready", "Ln 4, Col 12"). The texts are application state (strings).
//! Written against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `statusbar.bar(f, th, &.{ "Ready", "Ln 4" })`.
//! Comptime: `statusbar.ct.statusbar(th, .{ .status, .position })`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Theme = base.Theme;
const a11y = @import("../a11y/tree.zig");
const Input = @import("../core/input.zig").Input;

// ---- spec ---------------------------------------------------------------------------------

/// A status bar showing `texts` side by side, the first at the start. Returns its node.
pub fn bar(f: *Frame, th: *const Theme, texts: []const []const u8) Node {
    return barFace(f, texts, barStyle(th), base.labelText(th));
}

/// `bar` laid out by `face` instead of `barStyle(th)`, its texts drawn in `text`.
pub fn barFace(f: *Frame, texts: []const []const u8, face: Style, text: types.TextStyle) Node {
    const n = f.open(.none, face);
    f.tree().c.role[n.ix()] = role;
    for (texts) |s| _ = f.text(s, text);
    f.close();
    return n;
}

/// The strip: as wide as its parent, on the panel colour, its texts in a row spaced by two
/// pads, inset by a pad at the ends and by the gap above and below (a status bar is
/// thinner than a toolbar).
pub fn barStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .pad = .{ th.pad, th.gap, th.pad, th.gap }, .gap = 2 * th.pad, .cross = .center, .fill = th.panel };
}

// ---- accessibility ------------------------------------------------------------------------

/// What assistive technology sees: the strip is a `status`, a polite live region, so a
/// screen reader announces its texts when they change without moving focus. Its texts are
/// static text inside it. `types.Role` has no status, so both front ends write the byte, and
/// the harness compares it. No name of its own (a page labels it with
/// `Semantics.labelled_by`), value 0, no states.
pub const role: u8 = @backingInt(a11y.Role.status);

/// The status bar as a spec node.
pub const ct = struct {
    /// A status bar showing the string fields `texts` (a tuple of field names) side by side.
    /// It takes no input, so it has no id. Mistakes are compile errors: no texts, or a name
    /// that is not a string field of the state struct (`ComptimeUi`).
    pub fn statusbar(comptime th: Theme, comptime texts: anytype) Spec {
        if (texts.len == 0) @compileError("a status bar shows at least one text");
        var kids: [texts.len]Spec = undefined;
        for (&kids, texts) |*k, t| k.* = base.ct.label(th, t);
        var s = spec_zig.row(barStyle(&th), kids);
        s.widget = Bar;
        return s;
    }

    /// Builds the bar in the comptime front end: the strip with its role, then its texts.
    const Bar = struct {
        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const t = &ui.tables.t;
            const i = t.push(parent, .none, &n.style);
            t.c.role[i] = role;
            next.* += 1;
            inline for (n.children) |c| ui.push(comptime spec_zig.inheritText(c, n.text_style), i, next, in);
            t.seal(i);
        }
    };
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The example page: a window whose body (a Save button) fills it, and a status bar of two
/// texts at its foot, in both front ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    const window: Style = .{ .dir = .y, .size = .{ .fill, .fill } };
    const body: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(8) };
    return struct {
        pub const App = struct {
            saves: u32 = 0,
            status: []const u8 = "Ready",
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, window);
                _ = f.open(.none, body);
                app.saves += @intFromBool(base.button(f, &th, .from("save"), "Save").clicked);
                f.close();
                _ = bar(f, &th, &.{ app.status, "Ln 4, Col 12" });
                f.close();
            }
        };
        pub const State = struct {
            save_text: []const u8 = "Save",
            status: []const u8 = "Ready",
            position: []const u8 = "Ln 4, Col 12",
        };
        pub const spec = spec_zig.col(window, .{
            spec_zig.col(body, .{base.ct.button(th, .save, .save_text)}),
            ct.statusbar(th, .{ .status, .position }),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/statusbar.replay");

/// The frames of `replay` kept as golden images (tools/golden/ref/widgets/statusbar-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "saved", 6 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, window 1, body 2, button 3 (label 4), bar 5, texts 6 and 7.
const rows = struct {
    const bar = 5;
    const text = [2]u32{ 6, 7 };
};

test "barFace: the theme's styles draw as bar" {
    const S = struct {
        const texts = [_][]const u8{ "Ready", "Ln 1" };
        fn build(f: *Frame, k: u1) void {
            const th: *const Theme = &.default;
            _ = if (k == 0) bar(f, th, &texts) else barFace(f, &texts, barStyle(th), base.labelText(th));
        }
    };
    try base.expectSameFace(.{ .nodes = 8, .texts = 4, .customs = 1, .strings = 64, .depth = 8 }, S.build, .{ 10, 10 });
}

/// A face and a text style unlike the theme's, as a page sets them from data.
const restyled = struct {
    const th: Theme = .default;
    const P = Page(th);
    const face: Style = blk: {
        var s = barStyle(&th);
        s.pad = @splat(9);
        s.fill = .rgb(20, 40, 60);
        break :blk s;
    };
    const text: types.TextStyle = .{ .px = 17, .color = .rgb(250, 220, 120) };
    const window: Style = .{ .dir = .y, .size = .{ .fill, .fill } };
    const body: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(8) };
    const App = struct {
        pub fn build(_: *App, f: *Frame) void {
            _ = f.open(.none, window);
            _ = f.open(.none, body);
            _ = base.button(f, &th, .from("save"), "Save");
            f.close();
            _ = barFace(f, &.{ "Ready", "Ln 4, Col 12" }, face, text);
            f.close();
        }
    };
    const spec = spec_zig.col(window, .{
        spec_zig.col(body, .{base.ct.button(th, .save, .save_text)}),
        spec_zig.styled(spec_zig.textStyled(ct.statusbar(th, .{ .status, .position }), text), face),
    });
    var h: base.Harness(App, base.ComptimeUi(P.State, spec, th), .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 }) = .{};
};

test "ct.statusbar restyled: the same frames as barFace over the replay" {
    try testing.expect(try base.expectReplayAgrees(&restyled.h, replay) > 2);
}

test "statusbar: both front ends build a strip of texts at the window's foot" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 8), t.len);
    const r = t.rect(rows.bar);
    try testing.expectEqual(@as(f32, 320), r.w());
    try testing.expectEqual(@as(f32, 200), r.y1);
    try testing.expect(t.rect(rows.text[1]).x0 >= t.rect(rows.text[0]).x1);
}

test "statusbar: on the panel colour, texts inset and spaced; any theme alike" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const th = Theme.default;
    const t = out.runtime.tree;
    const r = t.rect(rows.bar);
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[rows.bar].fill);
    try testing.expectEqual(r.x0 + th.pad, t.rect(rows.text[0]).x0);
    try testing.expectEqual(r.y0 + th.gap, t.rect(rows.text[0]).y0);
    try testing.expectEqual(t.rect(rows.text[0]).x1 + 2 * th.pad, t.rect(rows.text[1]).x0);
    try testing.expectEqual(th.text.bitsOf(), out.runtime.texts.c.color[t.c.text[rows.text[0]]]);

    const Light = Page(.{ .panel = .rgb(240, 240, 240), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    const lo = try S.light.frame(&in);
    const lt = lo.runtime.tree;
    try testing.expectEqual(lt.rect(rows.bar).x0 + 12, lt.rect(rows.text[0]).x0);
}

test "statusbar: takes no input; hit testing and the tab order skip it" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    // Press and release on the first text: nothing held, nothing focused.
    const r = out.runtime.tree.rect(rows.text[0]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.active);
    try testing.expectEqual(@as(?Default.Ui.Events.Widget, null), h.ui.pointer.pressed);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    try check.expectInert(out.runtime.tree, &.{ rows.bar, rows.text[0], rows.text[1] });
    // Only the Save button is a widget in the comptime front end.
    try testing.expectEqual(1, Default.Ui.Events.widget_count);
}

test "statusbar: role status, a polite live region holding its texts, no name, value 0, no states, in both front ends" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    const trees = [2]*const @import("../core/tree.zig").Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        try testing.expectEqual(a11y.Role.status, @as(a11y.Role, @fromBackingInt(t.c.role[rows.bar])));
        try testing.expectEqual(a11y.Live.polite, a11y.live[t.c.role[rows.bar]]);
        try testing.expectEqual(types.none, sem.c.name[rows.bar]);
        try testing.expectEqual(@as(f32, 0), t.c.value[rows.bar]);
        try testing.expectEqual(@as(u8, 0), sem.c.state[rows.bar]);
        for (rows.text, [2][]const u8{ "Ready", "Ln 4, Col 12" }) |r, want| {
            try testing.expectEqual(a11y.Role.label, @as(a11y.Role, @fromBackingInt(t.c.role[r])));
            try testing.expectEqualStrings(want, check.nameOf(&sem, tx, str, r));
        }
    }
}

test "statusbar: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var clicks: [7]bool = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        clicks[k] = if (out.comptime_.event) |e| e == .save else false;
        // The application acts on the click: the status text changes in both front ends.
        if (clicks[k]) {
            h.app.status = "Saved";
            h.ui.signals.set(.status, "Saved");
        }
        const t = out.runtime.tree;
        const run = t.c.text[rows.text[0]];
        const shown = h.ctx.strings[h.ctx.cur].buf[out.runtime.texts.c.start[run]..][0..out.runtime.texts.c.bytes[run]];
        try testing.expectEqualStrings(if (k == 6) "Saved" else "Ready", shown);
    }
    try testing.expectEqual(@as(u32, 7), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true, false }, &clicks);
    try testing.expectEqual(@as(u32, 1), h.app.saves);
}

test "golden_frames: name frames the status bar replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 7);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
