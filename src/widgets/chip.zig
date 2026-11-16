//! Chip: a short caption on a pill (a tag, a filter, a recipient), optionally with a button
//! that asks to remove it. Tier 2, written against the public API of tiers 0 and 1 (the
//! recipe in base.zig).
//!
//! Accessibility: the pill is presentational; what assistive technology meets is its caption,
//! static text (role label), and, on a removable chip, the remove button (role button, named
//! by its caption). A chip is therefore static text, or static text and a button.
//!
//! State: the caption, the application's string, and nothing else: removing a chip is the
//! application's to do when it is asked (the remove button's click), as a list of chips is
//! the application's data. The runtime front end takes the caption as `str` and the remove
//! button's caption as an optional string; the comptime front end binds both as string fields
//! (checked as labels' bindings), the remove button's optional.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const button_zig = @import("button.zig");

// ---- spec -----------------------------------------------------------------------------------

/// The id of the remove button of the chip named `owner`, in both front ends: the runtime one
/// derives it with `Id.with`, the comptime one from the button's spec name `<chip>.remove`.
pub fn removeId(owner: Id) Id {
    return owner.with(0);
}

/// The chip's name from its remove button's comptime name `<chip>.remove`.
pub fn chipName(comptime remove: []const u8) []const u8 {
    return remove[0 .. remove.len - ".remove".len];
}

// ---- look -----------------------------------------------------------------------------------

/// The pill: caption (then the remove button) in a row, padded wider than tall, fully rounded
/// at the theme's text size, in the control's hot colour so a remove button at rest shows on
/// it; static text to assistive technology through its caption, nothing itself.
pub fn chipStyle(th: *const Theme) Style {
    const h = th.text_px * 1.25 + 8;
    return .{ .dir = .x, .pad = .{ 10, 4, 4, 4 }, .gap = 6, .radius = h * 0.5, .fill = th.control_hot, .cross = .center };
}

/// The remove button: a small round button (role button) around its caption, filled from the
/// control fills by hover and held as a button is (`button.buttonFill`).
pub fn removeStyle(th: *const Theme, r: Response) Style {
    const h = th.text_px * 1.25;
    return .{ .dir = .x, .pad = .{ 4, 0, 4, 0 }, .radius = h * 0.5, .main = .center, .cross = .center, .fill = button_zig.buttonFill(th, r), .role = .button };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A chip showing `str`, with a remove button named `removeId(id)` and captioned `remove`
/// when that is not null. The response is the remove button's (empty without one); its
/// `clicked` asks the application to remove the chip, set when the button fires as any
/// button does (`button.activated`: a click, or Enter or Space while it has focus).
pub fn chip(f: *Frame, th: *const Theme, id: Id, str: []const u8, remove: ?[]const u8) Response {
    _ = f.open(.none, chipStyle(th));
    _ = label_zig.label(f, th, str);
    var r: Response = .{};
    if (remove) |caption| {
        const b = f.open(removeId(id), removeStyle(th, .{}));
        r = f.interact(b, .button);
        r.clicked = button_zig.activated(r.clicked, r.focused, f.in);
        f.setFill(b, button_zig.buttonFill(th, r));
        f.setCursor(.pointer, r.hovered);
        _ = label_zig.label(f, th, caption);
        f.close();
    }
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A chip named `id` showing the string field `text`, with a remove button captioned by
    /// the string field `remove` when it is not null: `ct.chip(th, .rust, .rust_text,
    /// .remove_text)` or `ct.chip(th, .draft, .draft_text, null)`. The chip itself is no
    /// widget; its remove button is the widget `<id>.remove`, a button (void event, focus
    /// stop) whose click asks the application to remove the chip.
    pub fn chip(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: @EnumLiteral(), comptime remove: ?@EnumLiteral()) Spec {
        const caption = label_zig.ct.label(th, text);
        const kids: []const Spec = if (remove) |r| &.{ caption, .{
            .kind = .button,
            .id = @tagName(id) ++ ".remove",
            .children = &.{label_zig.ct.label(th, r)},
        } } else &.{caption};
        return .{ .kind = .chip, .style = chipStyle(&th), .children = kids };
    }
};

// ---- example page -------------------------------------------------------------------------

/// The chip's example page: removable chips Zig and Rust and a plain Draft on a panel, in both
/// front ends. The application counts the removals it is asked for (a comptime spec cannot
/// drop a node; a runtime application would stop building the chip). Its replay
/// (testdata/chip.replay) clicks and uses the keys; its golden images
/// (tools/widgetgolden/ref/chip-*.png) show the remove button at rest, hovered and held.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .cross = .start, .fill = th.panel };

    pub const App = struct {
        removed: [2]u32 = .{ 0, 0 },
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            app.removed[0] += @intFromBool(chip(f, &th, .from("zig"), "Zig", "x").clicked);
            app.removed[1] += @intFromBool(chip(f, &th, .from("rust"), "Rust", "x").clicked);
            _ = chip(f, &th, .from("draft"), "Draft", null);
            f.close();
        }
    };
    pub const State = struct {
        zig_text: []const u8 = "Zig",
        rust_text: []const u8 = "Rust",
        draft_text: []const u8 = "Draft",
        remove_text: []const u8 = "x",
    };
    pub const spec = spec_zig.row(panel, .{
        ct.chip(th, .zig, .zig_text, .remove_text),
        ct.chip(th, .rust, .rust_text, .remove_text),
        ct.chip(th, .draft, .draft_text, null),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/chip.replay");
    /// Frames kept as golden images, by name: tools/widgetgolden/ref/chip-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "hover", 1 }, .{ "held", 2 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "ct.chip: no widget of its own; the remove button, when asked for, is a focusable button" {
    const events = @import("../comptime/events.zig");
    const plain = comptime ct.chip(.default, .draft, .draft_text, null);
    try testing.expectEqual(spec_zig.Kind.chip, plain.kind);
    try testing.expectEqual(null, plain.id);
    try testing.expectEqual(@as(usize, 1), plain.children.len);
    try testing.expectEqual(0, events.Events(plain).widget_count);
    const removable = comptime ct.chip(.default, .rust, .rust_text, .remove_text);
    try testing.expectEqual(@as(usize, 2), removable.children.len);
    const r = removable.children[1];
    try testing.expectEqual(spec_zig.Kind.button, r.kind);
    try testing.expectEqualStrings("rust.remove", r.id.?);
    try testing.expectEqualStrings("rust", comptime chipName(r.id.?));
    try testing.expectEqualStrings("remove_text", r.children[0].bind.?);
    const E = events.Events(removable);
    try testing.expectEqual(void, @FieldType(E.Event, "rust.remove"));
    try testing.expectEqualSlices(E.Widget, &.{.@"rust.remove"}, E.focus_order);
}

test "chip state: captions bind as labels do; removeId differs from the chip's id" {
    const State = struct { text: []const u8 = "Rust", n: u32 = 0 };
    try testing.expectEqual(null, comptime label_zig.bindError(State, "text"));
    try testing.expect(comptime label_zig.bindError(State, "n") != null);
    try testing.expect(removeId(.from("rust")) != Id.from("rust"));
    try testing.expectEqual(Id.from("rust").with(0), removeId(.from("rust")));
}

/// A removable chip and a plain one in both front ends, in theme `th`: the tests' page until
/// the example page (C0700).
fn Two(comptime th: Theme) type {
    return struct {
        const row: Style = .{ .dir = .x, .pad = @splat(8), .gap = 8, .cross = .center };
        pub const App = struct {
            removed: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("row"), row);
                app.removed = chip(f, &th, .from("rust"), "Rust", "x").clicked;
                _ = chip(f, &th, .from("draft"), "Draft", null);
                f.close();
            }
        };
        pub const State = struct { rust_text: []const u8 = "Rust", remove_text: []const u8 = "x", draft_text: []const u8 = "Draft" };
        pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ ct.chip(th, .rust, .rust_text, .remove_text), ct.chip(th, .draft, .draft_text, null) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "chip look: a rounded pill around its caption and its remove button, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 240, 60 } };
    var out = try h.frame(&in);
    // Rows: root, row, chip (2), caption (3), remove (4), its caption (5), chip (6), caption (7).
    const t = out.runtime.tree;
    const pill = t.rect(2);
    try testing.expectApproxEqAbs(@as(f32, 17.5 + 8), pill.h(), 0.5);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[2].fill);
    try testing.expectEqual(pill.x0 + 10, t.rect(3).x0);
    const rm = t.rect(4);
    try testing.expectEqual(t.rect(3).x1 + 6, rm.x0);
    try testing.expectEqual(pill.x1 - 4, rm.x1);
    try testing.expectEqual(@backingInt(removeId(.from("rust"))), t.c.id[4]);
    try testing.expectEqual(th.control.bitsOf(), t.c.look[4].fill);
    // The plain chip: its caption, padded, and nothing else.
    try testing.expectEqual(@as(u32, 8), t.len);
    try testing.expectEqual(t.rect(6).x0 + 10, t.rect(7).x0);
    // Hovering the remove button lights it as a button.
    in.pointer = .{ (rm.x0 + rm.x1) * 0.5, (rm.y0 + rm.y1) * 0.5 };
    out = try h.frame(&in);
    try testing.expectEqual(th.control_hot.bitsOf(), out.runtime.tree.c.look[4].fill);
}

test "chip input: the remove button asks for removal on click, Enter and Space; the chip takes nothing, in both front ends" {
    const h = &two;
    h.init();
    const k = base.keys;
    var in: Input = .{ .viewport = .{ 240, 60 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const rm = t.rect(4);
    const body = t.rect(3);
    const plain = t.rect(6);
    const at = struct {
        fn mid(r: types.Rect) [2]f32 {
            return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
        }
    }.mid;
    const enter = [_]Input.Event{.{ .kind = .press, .code = k.enter }};
    const sup = [_]Input.Event{.{ .kind = .release, .code = k.space }};
    const Step = struct { at: [2]f32, left: bool = false, events: []const Input.Event = &.{}, removed: bool };
    const steps = [_]Step{
        .{ .at = at(body), .left = true, .removed = false }, // the caption: nothing
        .{ .at = at(body), .removed = false },
        .{ .at = at(plain), .left = true, .removed = false }, // the plain chip: nothing
        .{ .at = at(plain), .removed = false },
        .{ .at = at(rm), .left = true, .removed = false },
        .{ .at = at(rm), .removed = true }, // click
        .{ .at = at(rm), .events = &enter, .removed = true },
        .{ .at = at(rm), .events = &sup, .removed = true },
        .{ .at = at(rm), .removed = false },
    };
    for (steps) |st| {
        in.pointer = st.at;
        in.buttons.left = st.left;
        in.events = st.events;
        const o = try h.frame(&in);
        try testing.expectEqual(st.removed, h.app.removed);
        try testing.expectEqual(st.removed, if (o.comptime_.event) |e| e == .@"rust.remove" else false);
    }
}

var chip_semantics: base.Semantic(16) = .{};

test "chip a11y: static text, and a button named by its caption when removable, in both front ends" {
    const a11y = @import("../a11y/tree.zig");
    const h = &two;
    h.init();
    const in: Input = .{ .viewport = .{ 240, 60 } };
    _ = try h.frame(&in);
    const x = &chip_semantics;
    try x.run(h);
    // The pills are presentational.
    try testing.expectEqual(null, x.row(2));
    try testing.expectEqual(null, x.row(6));
    for ([3]u32{ 3, 4, 7 }, [3]a11y.Role{ .label, .button, .label }, [3][]const u8{ "Rust", "x", "Draft" }) |node, role, name| {
        const r = x.row(node).?;
        try testing.expectEqual(@backingInt(role), x.out[0].c.role[r]);
        try testing.expectEqualStrings(name, x.name(0, r));
        try testing.expectEqualStrings(name, x.name(1, r));
        try testing.expectEqual(@as(f32, 0), x.out[0].c.value[r]);
        try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
    }
    try testing.expectEqual(@backingInt(removeId(.from("rust"))), x.out[0].c.id[x.row(4).?]);
}

var page: Page.Run = .{};

test "Page: the chip replay asks for removal by click and keys only on remove buttons, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var asked: [2]u32 = .{ 0, 0 };
    while (try replay.next(buf)) |in| {
        const out = try h.frame(in);
        if (out.comptime_.event) |e| switch (e) {
            .@"zig.remove" => asked[0] += 1,
            .@"rust.remove" => asked[1] += 1,
        };
        try testing.expectEqual(h.app.removed, asked);
    }
    const t = &h.ctx.trees[h.ctx.cur];
    // The rects the replay's comment gives.
    try testing.expectEqual(types.Rect{ .x0 = 53, .y0 = 16, .x1 = 70, .y1 = 34 }, t.rect(t.find(removeId(.from("zig")))));
    try testing.expectEqual(types.Rect{ .x0 = 131, .y0 = 16, .x1 = 148, .y1 = 34 }, t.rect(t.find(removeId(.from("rust")))));
    try testing.expectEqual([2]f32{ 22, 47 }, [2]f32{ t.rect(3).x0, t.rect(3).x1 });
    try testing.expectEqual([2]u32{ 2, 0 }, h.app.removed);
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < h.frames);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
