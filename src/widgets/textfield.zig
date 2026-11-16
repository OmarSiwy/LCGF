//! Text field: one line of editable text. Tier 2, written against the public API of tiers 0 and
//! 1 (the recipe in base.zig). The editing itself is src/text/edit/ (`Editor`); this file gives
//! it a box, a caret and a selection, routes the focused field's keys to it, and asks the host
//! for text input (prototype/ui.zig `Platform.wants_text`, `ime_rect`).
//!
//! State: a `Text(cap)`, the application's: the field's bytes (`cap` of them), its `Editor`, and
//! what passes between the field and the host each frame (the IME's composition in, the
//! clipboard and the text-input request out). The runtime front end takes a `*Text(cap)`; the
//! comptime front end binds a `Text(cap)` field of the state (checked while compiling).
//!
//! Text is measured as the front ends measure it, with `Mono`: every byte is `advance` wide, so
//! the caret's x is its byte offset times the advance, and a click maps back the same way to
//! the nearest grapheme boundary.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const edit = @import("../text/edit/edit.zig");
const keyboard = @import("../interact/keyboard.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Response = types.Response;
const Style = types.Style;
const TextStyle = types.TextStyle;

// ---- spec -----------------------------------------------------------------------------------

/// A text field's state, `cap` bytes of text. Plain data with defaults (an empty field); give it
/// text with `init`. It may be copied and moved: the editor is pointed at `bytes` again each
/// time the widget uses it (`editor`).
pub fn Text(comptime cap: u32) type {
    return struct {
        const Self = @This();
        pub const capacity = cap;

        bytes: [cap]u8 = undefined,
        ed: edit.Editor = .{ .b = .{ .buf = &.{} } },
        /// Where copied and cut text goes; `clipboard.set` points into it.
        copied: [cap]u8 = undefined,
        /// Set by the widget each frame, for the host to read after it: text to put on the
        /// clipboard (`set`) and a paste to answer with typed text next frame (`paste`).
        clipboard: keyboard.Clipboard = .{},
        /// Set by the host before the frame: what its input method is composing. Shown at the
        /// caret while the field is focused, until it commits (as typed text) or drops it.
        ime: keyboard.Composition = .{},
        /// Set by the widget each frame: while focused, a request for text input with the IME
        /// window at the caret (the runtime front end also copies it to `Platform`).
        input: keyboard.TextInput = .{},
        /// What this frame's input did to the text (`Result.submitted`: Enter).
        result: edit.Result = .{},
        /// How far the text is scrolled, px (a text area: lines), to keep the caret in view.
        scroll: f32 = 0,
        /// The pointer held the field last frame: a press is the first frame it does.
        held: bool = false,

        /// A field holding `initial` (cut at `cap` bytes, at a code point), caret at its end.
        pub fn init(initial: []const u8) Self {
            var s: Self = .{};
            s.set(initial);
            // No pointer into a value that is about to be copied (`editor` sets it again).
            s.ed.b.buf = &.{};
            return s;
        }

        /// The editor over this value's own bytes.
        pub fn editor(s: *Self) *edit.Editor {
            s.ed.b.buf = &s.bytes;
            return &s.ed;
        }

        /// The text, valid until the next edit.
        pub fn text(s: *Self) []const u8 {
            return s.editor().text();
        }

        /// Replaces the whole text (not recorded for undo), caret at its end.
        pub fn set(s: *Self, str: []const u8) void {
            var n: usize = @min(str.len, cap);
            while (n < str.len and n > 0 and str[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(s.bytes[0..n], str[0..n]);
            const ed = s.editor();
            ed.b.gap = @intCast(n);
            ed.b.after = 0;
            ed.place(@intCast(n));
            ed.preedit = .{ 0, 0 };
            ed.preedit_sel = .{ 0, 0 };
        }
    };
}

/// Whether `T` is a `Text(cap)`.
pub fn isText(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "capacity") and T == Text(T.capacity);
}

/// Why `State`'s field `name` cannot be the text of a `widget` (a `Text(cap)`), or null.
pub fn textError(comptime State: type, comptime widget: []const u8, comptime name: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, name)) return widget ++ " '" ++ name ++ "': the state has no such field";
        const FT = @FieldType(State, name);
        if (isText(FT)) return null;
        return widget ++ " '" ++ name ++ "' needs a textfield.Text(cap) field, not " ++ @typeName(FT);
    }
}

/// Why `State` cannot hold a text field over `name` with its placeholder in string field
/// `hint`, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8, comptime hint: []const u8) ?[]const u8 {
    return textError(State, "textfield", name) orelse base.fieldError(State, "textfield placeholder", hint, []const u8);
}

// ---- look -----------------------------------------------------------------------------------

/// Width of one byte of text, px: the front ends measure with `Mono`.
pub fn advance(th: *const Theme) f32 {
    return th.text_px * (Mono{}).advance;
}

/// Height of one line of text, px.
pub fn lineHeight(th: *const Theme) f32 {
    return th.text_px * (Mono{}).line;
}

/// The field's padding: the theme's `pad` across, half of it up and down.
pub fn padding(th: *const Theme) [4]f32 {
    return .{ th.pad, th.pad / 2, th.pad, th.pad / 2 };
}

/// The box: as wide as it is given (at least 80), one line tall; it clips its text, scrolled
/// by `scroll` px. Not yet painted.
pub fn fieldStyle(th: *const Theme, focused: bool, scroll: f32) Style {
    _ = focused;
    return .{
        .dir = .x,
        .size = .{ .fill, .fit },
        .min = .{ 80, 0 },
        .pad = padding(th),
        .clip = true,
        .scroll = .{ scroll, 0 },
    };
}

/// The text, or the placeholder (`hint`) when the field is empty.
pub fn textStyle(th: *const Theme, hint: bool) TextStyle {
    _ = hint;
    return .{ .px = th.text_px, .color = th.text };
}

/// The selection behind the text, from x `sel[0]` to `sel[1]` px, one line tall.
pub fn selectionStyle(th: *const Theme, sel: [2]f32, top: f32) Style {
    return .{ .float = true, .offset = .{ sel[0], top }, .size = .{ .px(sel[1] - sel[0]), .px(lineHeight(th)) } };
}

/// The caret: 1 px wide at x `x`, one line tall.
pub fn caretStyle(th: *const Theme, x: f32, top: f32, focused: bool) Style {
    _ = focused;
    return .{ .float = true, .offset = .{ x, top }, .size = .{ .px(1), .px(lineHeight(th)) } };
}

/// What a single-line field shows this frame: its text or placeholder, and where the caret and
/// the selection are, px from the text's left edge.
pub const Shown = struct {
    str: []const u8,
    hint: bool,
    caret: f32,
    sel: [2]f32,
};

pub fn shown(s: anytype, th: *const Theme, hint: []const u8) Shown {
    const ed = s.editor();
    const t = ed.text();
    const adv = advance(th);
    const sel = ed.selection();
    const empty = t.len == 0;
    return .{
        .str = if (empty) hint else t,
        .hint = empty,
        .caret = @as(f32, @floatFromInt(ed.shownCaret())) * adv,
        .sel = .{ @as(f32, @floatFromInt(sel[0])) * adv, @as(f32, @floatFromInt(sel[1])) * adv },
    };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A text field named `id` over `s` (a `*Text(cap)`), showing `hint` while empty. Returns its
/// response.
pub fn textfield(f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8) Response {
    const r0 = f.ctx.inter.response(id);
    const node = f.open(id, fieldStyle(th, r0.focused, s.scroll));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    const v = shown(s, th, hint);
    _ = f.leaf(.none, selectionStyle(th, v.sel, 0));
    _ = f.textStyled(v.str, textStyle(th, v.hint), .{});
    _ = f.leaf(.none, caretStyle(th, v.caret, 0, r0.focused));
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A text field named `id` over the `Text(cap)` field `bind`, showing the string field
    /// `hint` while empty.
    pub fn textfield(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: @EnumLiteral()) Spec {
        var s = spec_zig.row(fieldStyle(&th, false, 0), .{ Spec{ .kind = .col }, Spec{ .kind = .label }, Spec{ .kind = .col } });
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind), @tagName(hint));
        return s;
    }
};

/// The comptime text field named `name` over field `bind`, placeholder field `hint`
/// (`Spec.widget`): the same rows as `textfield`.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime hint: []const u8) type {
    return struct {
        pub const focusable = true;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return textfield_zig.bindError(State, field, hint);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = .{ n, in };
            const Ui = @TypeOf(ui.*);
            const th = &Ui.theme;
            const s = &@field(ui.signals.state, bind);
            const focused = ui.focus == @field(Ui.Events.Widget, name);
            const t = &ui.tables.t;
            next.* += 4; // the box, the selection, the text and the caret
            const i = t.push(parent, .hash(name), &fieldStyle(th, focused, s.scroll));
            const v = shown(s, th, @field(ui.signals.state, hint));
            _ = t.push(i, .none, &selectionStyle(th, v.sel, 0));
            pushText(ui, i, v.str, textStyle(th, v.hint));
            _ = t.push(i, .none, &caretStyle(th, v.caret, 0, focused));
            t.seal(i);
        }
    };
}

const textfield_zig = @This();

/// Pushes a text leaf showing `str` under row `parent` of comptime front end `ui`, as
/// `Frame.textStyled(str, ts, .{})` does in the runtime front end.
pub fn pushText(ui: anytype, parent: u32, str: []const u8, ts: TextStyle) void {
    const tb = &ui.tables;
    const k = tb.t.push(parent, .none, &.{});
    tb.t.c.text[k] = tb.tx.push(k, tb.strings.add(str), &ts);
}

// ---- example page -------------------------------------------------------------------------

/// The text field's example page: Name (empty, placeholder "Your name") and City ("Oslo"), each
/// under its caption, on a panel, in both front ends.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };
    pub const Field = Text(64);

    pub const App = struct {
        name: Field = .{},
        city: Field = .init("Oslo"),
        submits: u32 = 0,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Name");
            _ = textfield(f, &th, .from("name"), &app.name, "Your name");
            _ = base.label(f, &th, "City");
            _ = textfield(f, &th, .from("city"), &app.city, "");
            app.submits += @intFromBool(app.name.result.submitted) + @intFromBool(app.city.result.submitted);
            f.close();
        }
    };
    pub const State = struct {
        name_text: []const u8 = "Name",
        name: Field = .{},
        name_hint: []const u8 = "Your name",
        city_text: []const u8 = "City",
        city: Field = .init("Oslo"),
        city_hint: []const u8 = "",
    };
    pub const spec = spec_zig.col(panel, .{
        base.ct.label(th, .name_text),
        ct.textfield(th, .name, .name, .name_hint),
        base.ct.label(th, .city_text),
        ct.textfield(th, .city, .city, .city_hint),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 512, .depth = 8 });
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "Text: init, set and the editor over the value's own bytes, after a move" {
    var a: Text(8) = .init("hello");
    var b = a; // moved: the editor follows the bytes
    try testing.expectEqualStrings("hello", b.text());
    try testing.expectEqual(@as(u32, 5), b.ed.caret);
    b.set("too long for eight");
    try testing.expectEqualStrings("too long", b.text());
    a.set("");
    try testing.expectEqualStrings("", a.text());
    // Cut at a code point: "é" is two bytes and does not fit after seven.
    var c: Text(8) = .init("abcdefg\u{e9}");
    try testing.expectEqualStrings("abcdefg", c.text());
}

test "bindError: a text field binds a Text(cap) and a string placeholder" {
    const State = struct { t: Text(4) = .{}, n: u32 = 0, hint: []const u8 = "" };
    try testing.expectEqual(null, comptime bindError(State, "t", "hint"));
    try testing.expectEqualStrings("textfield 'n' needs a textfield.Text(cap) field, not u32", comptime bindError(State, "n", "hint").?);
    try testing.expectEqualStrings("textfield 'x': the state has no such field", comptime bindError(State, "x", "hint").?);
    try testing.expectEqualStrings("textfield placeholder 'n' needs a []const u8 field, not u32", comptime bindError(State, "t", "n").?);
    try testing.expect(isText(Text(4)));
    try testing.expect(!isText(struct {
        pub const capacity = 4;
    }));
}

test "ct.textfield: a focusable widget" {
    const E = Page.Ui.Events;
    try testing.expectEqual(2, E.widget_count);
    try testing.expectEqualSlices(E.Widget, &.{ .name, .city }, E.focus_order);
}

var page: Page.Run = .{};

test "textfield: the page agrees in both front ends at rest" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // panel, two captions, two fields of four rows each.
    try testing.expectEqual(@as(u32, 1 + 1 + 2 + 8), t.len);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
