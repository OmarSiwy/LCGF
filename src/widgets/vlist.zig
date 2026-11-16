//! Virtual list (tier 2): a list box over any number of options that builds only the rows on
//! screen (docs/TARGETS.md E1: cost scales with the screen, not with the data). Follows the
//! five-commit recipe of widgets/base.zig; the options, their look and their keys are the list
//! box's (widgets/list.zig), reused here.
//!
//! State lives in the application: the options (a slice of strings, any length), the selected
//! row (`u32`, `none` for no selection) and the scroll offset (`f32`, logical pixels from the
//! top). The list shows `visible` rows. Because every row has the same height, the first row
//! on screen is `floor(scroll / rowHeight)` and at most `visible + 1` rows are built, by index
//! arithmetic (as Xilem's virtual_scroll asks the app only for the indices in view); the
//! container is clipped and scrolled by the remainder.
//!
//! In the comptime front end the rows on screen are a bounded dynamic region: the spec holds
//! `visible + 1` template rows, so capacity is exact, and each frame fills as many as the
//! scroll position shows from the options slice in the state.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const base = @import("base.zig");
const list_zig = @import("list.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Why `State` cannot back a comptime virtual list with options field `items`, selection field
/// `selected` and scroll field `scroll`, showing `visible` rows; null when it can. `validate`
/// turns the answer into a compile error; tests read it directly.
pub fn check(comptime State: type, comptime items: []const u8, comptime selected: []const u8, comptime scroll: []const u8, comptime visible: u32) ?[]const u8 {
    comptime {
        if (visible == 0) return "vlist: a virtual list shows at least one row";
        if (!@hasField(State, items)) return "vlist: state has no field '" ++ items ++ "' for the options";
        if (@FieldType(State, items) != []const []const u8) return "vlist: options field '" ++ items ++ "' must be a []const []const u8";
        if (!@hasField(State, selected)) return "vlist: state has no field '" ++ selected ++ "' for the selection";
        if (@FieldType(State, selected) != u32) return "vlist: selection field '" ++ selected ++ "' must be a u32 (a row, or none)";
        if (!@hasField(State, scroll)) return "vlist: state has no field '" ++ scroll ++ "' for the scroll offset";
        if (@FieldType(State, scroll) != f32) return "vlist: scroll field '" ++ scroll ++ "' must be an f32 (pixels from the top)";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime items: []const u8, comptime selected: []const u8, comptime scroll: []const u8, comptime visible: u32) void {
    if (comptime check(State, items, selected, scroll, visible)) |msg| @compileError(msg);
}

/// Rows built for a list showing `visible` rows: one more, for the row half scrolled in at the
/// bottom while another is half scrolled out at the top.
pub fn capacity(visible: u32) u32 {
    return visible + 1;
}

/// The rows on screen: the first one and how many, for `count` options scrolled by `scroll`.
pub const Window = struct { first: u32, len: u32 };

pub fn window(th: *const Theme, count: u32, visible: u32, scroll: f32) Window {
    const first: u32 = @min(@as(u32, @intFromFloat(@max(scroll, 0) / list_zig.rowHeight(th))), count);
    return .{ .first = first, .len = @min(capacity(visible), count - first) };
}

// ---- look ------------------------------------------------------------------------------------

/// The list box's look (`list.listStyle`), `visible` rows tall, clipped, scrolled by the part
/// of `scroll` that the first built row does not take up.
pub fn vlistStyle(th: *const Theme, visible: u32, scroll: f32) Style {
    const h = list_zig.rowHeight(th);
    var s = list_zig.listStyle(th);
    s.size[1] = .px(@as(f32, @floatFromInt(visible)) * h + 2 * list_zig.inset(th));
    s.clip = true;
    s.scroll = .{ 0, @max(scroll, 0) - @floor(@max(scroll, 0) / h) * h };
    return s;
}

/// The option row at height `y`, for a list whose last rect starts at `top` scrolled by
/// `scroll`; clamped into the `count` rows.
pub fn rowAt(th: *const Theme, top: f32, y: f32, scroll: f32, count: u32) u32 {
    return list_zig.rowAt(th, top - scroll, y, count);
}

// ---- behaviour ---------------------------------------------------------------------------------

/// The largest scroll offset: the last row at the bottom edge.
pub fn maxScroll(th: *const Theme, count: u32, visible: u32) f32 {
    return @as(f32, @floatFromInt(count -| visible)) * list_zig.rowHeight(th);
}

/// The scroll offset after a wheel or touchpad movement of `delta` pixels, clamped.
pub fn wheel(th: *const Theme, scroll: f32, delta: f32, count: u32, visible: u32) f32 {
    return std.math.clamp(scroll + delta, 0, maxScroll(th, count, visible));
}

/// The scroll offset that shows row `sel` whole, moving as little as possible from `scroll`.
pub fn reveal(th: *const Theme, scroll: f32, sel: u32, visible: u32) f32 {
    if (sel == none) return scroll;
    const h = list_zig.rowHeight(th);
    const top = @as(f32, @floatFromInt(sel)) * h;
    return std.math.clamp(scroll, top + h - @as(f32, @floatFromInt(visible)) * h, top);
}

/// One frame of input, as `list`'s plus scrolling: a click selects the row under the pointer,
/// keys move the selection while focused (`list.keys`), a changed selection is scrolled into
/// view, then the wheel scrolls while the pointer is over the list. `options` is the whole
/// options slice; nothing per row is touched but the type-ahead search.
pub fn update(th: *const Theme, r: Response, top: f32, options: []const []const u8, visible: u32, sel: *u32, scroll: *f32, in: *const Input) void {
    const n: u32 = @intCast(options.len);
    const old = sel.*;
    sel.* = list_zig.click(sel.*, r.clicked, rowAt(th, top, in.pointer[1], scroll.*, n));
    if (r.focused) sel.* = list_zig.keys(sel.*, options, in, &list_zig.default_keys);
    if (sel.* != old) scroll.* = reveal(th, scroll.*, sel.*, visible);
    const delta = (in.wheel[1] * list_zig.rowHeight(th) + in.scroll[1]) * @as(f32, @floatFromInt(@intFromBool(r.hovered)));
    scroll.* = wheel(th, scroll.*, delta, n, visible);
}

// ---- accessibility ---------------------------------------------------------------------------

/// Roles of the built rows: the list a list box, each built option an option. Only rows on
/// screen exist, so only they are exported.
// ponytail: no aria-setsize/posinset, so a screen reader cannot say "row 40 of 10,000"; the
// export has no column for them yet.
pub fn setRoles(t: *Tree, box: u32, first_row: u32, len: u32) void {
    list_zig.setRoles(t, box, first_row, len);
}

// ---- runtime front end ----------------------------------------------------------------------

/// A virtual list of `options` showing `visible` rows: as `list.list`, plus the wheel scrolls
/// it, and only the rows on screen are built.
pub fn vlist(f: *Frame, th: *const Theme, id: Id, options: []const []const u8, visible: u32, selected: *u32, scroll: *f32) Response {
    const n: u32 = @intCast(options.len);
    const top = f.lastRect(id).y0;
    // The input moves the scroll the style shows, so the response is read before the list is
    // opened; `interact` then marks it and reports the same response.
    update(th, f.ctx.inter.response(id), top, options, visible, selected, scroll, f.in);
    var s = vlistStyle(th, visible, scroll.*);
    s.border_color = list_zig.listBorder(th, f.ctx.inter.response(id).focused);
    const box = f.open(id, s);
    const r = f.interact(box, .button);
    const under = rowAt(th, top, f.in.pointer[1], scroll.*, n);
    const win = window(th, n, visible, scroll.*);
    const t = f.tree();
    const first = t.len;
    for (win.first..win.first + win.len) |k| {
        const row = f.open(.none, list_zig.optionStyle(th));
        f.setFill(row, list_zig.optionFill(th, r.hovered and under == k, selected.* == k));
        _ = base.label(f, th, options[k]);
        f.close();
    }
    f.close();
    t.c.value[box.ix()] = list_zig.selectedValue(selected.*);
    setRoles(t, box.ix(), first, win.len);
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A virtual list named `id` over the options field `items` ([]const []const u8), selecting
    /// into the u32 field `selected`, scrolled by the f32 field `scroll`, `visible` rows tall.
    /// The spec holds `capacity(visible)` template rows; each binds the scroll field (scrolling
    /// changes which option it shows) and holds a label bound to the options.
    pub fn vlist(comptime th: Theme, comptime id: @EnumLiteral(), comptime items: @EnumLiteral(), comptime selected: @EnumLiteral(), comptime scroll: @EnumLiteral(), comptime visible: u32) Spec {
        var rows: [capacity(visible)]Spec = undefined;
        for (&rows) |*o| {
            o.* = spec_zig.row(list_zig.optionStyle(&th), .{base.ct.label(th, items)});
            o.bind = @tagName(scroll);
        }
        var s = spec_zig.col(list_zig.listStyle(&th), rows);
        s.id = @tagName(id);
        s.bind = @tagName(selected);
        s.widget = VListWidget(@tagName(items), @tagName(selected), @tagName(scroll), visible);
        return s;
    }

    /// The fields and row count a `ct.vlist` node was built with.
    pub fn fields(comptime n: Spec) struct { items: []const u8, selected: []const u8, scroll: []const u8, visible: u32 } {
        return .{ .items = n.children[0].children[0].bind.?, .selected = n.bind.?, .scroll = n.children[0].bind.?, .visible = n.children.len - 1 };
    }
};

/// A virtual list in `base.ComptimeUi`, for the fields and row count `ct.vlist` was given:
/// `step` applies the input to the selection and scroll fields, `push` builds the rows on
/// screen as `vlist` does.
fn VListWidget(comptime items: []const u8, comptime selected: []const u8, comptime scroll: []const u8, comptime visible: u32) type {
    return struct {
        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            comptime validate(@TypeOf(ui.signals.state), items, selected, scroll, visible);
            const state = &ui.signals.state;
            var r = list_zig.ctResponse(ui, row, in);
            r.clicked = list_zig.ctClicked(ui, row, event);
            var sel: u32 = @field(state, selected);
            var off: f32 = @field(state, scroll);
            update(&Ui.theme, r, list_zig.ctRect(ui, row).y0, @field(state, items), visible, &sel, &off, in);
            ui.signals.set(comptime Ui.field(selected), sel);
            ui.signals.set(comptime Ui.field(scroll), off);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const th = &@TypeOf(ui.*).theme;
            const row = comptime list_zig.widgetRow(@TypeOf(ui.*), n.id.?);
            const tb = &ui.tables;
            const state = &ui.signals.state;
            next.* += comptime flatten.count(n);
            const r = list_zig.ctResponse(ui, row, in);
            const options: []const []const u8 = @field(state, items);
            const count: u32 = @intCast(options.len);
            const sel: u32 = @field(state, selected);
            const off: f32 = @field(state, scroll);
            const top = list_zig.ctRect(ui, row).y0;
            var s = vlistStyle(th, visible, off);
            s.border_color = list_zig.listBorder(th, r.focused);
            const box = tb.t.push(parent, .hash(n.id.?), &s);
            const under = rowAt(th, top, in.pointer[1], off, count);
            const win = window(th, count, visible, off);
            const first = tb.t.len;
            const template = n.children[0];
            for (win.first..win.first + win.len) |k| {
                var o = template.style;
                o.fill = list_zig.optionFill(th, r.hovered and under == k, sel == k);
                const i = tb.t.push(box, .none, &o);
                list_zig.pushLabel(tb, i, &template.children[0].style, options[k], th);
                tb.t.seal(i);
            }
            tb.t.seal(box);
            tb.t.c.value[box] = list_zig.selectedValue(sel);
            setRoles(&tb.t, box, first, win.len);
        }
    };
}

// ---- example page -----------------------------------------------------------------------------

/// Two hundred options, "Item 0" to "Item 199".
const items_200: [200][]const u8 = blk: {
    @setEvalBranchQuota(200_000);
    var out: [200][]const u8 = undefined;
    for (&out, 0..) |*s, k| s.* = std.fmt.comptimePrint("Item {d}", .{k});
    break :blk out;
};

/// The example page: a caption and a virtual list of 200 options, five rows tall, on a panel,
/// in both front ends, in theme `th`. Its tests and golden images (tools/widgetgolden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };
        pub const visible = 5;

        /// Runtime front end: the application owns the options, selection and scroll offset.
        pub const App = struct {
            options: []const []const u8 = &items_200,
            selected: u32 = none,
            scroll: f32 = 0,
            clicked: bool = false,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = base.label(f, &th, "Items");
                app.clicked = vlist(f, &th, .from("items"), app.options, visible, &app.selected, &app.scroll).clicked;
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const State = struct {
            title: []const u8 = "Items",
            options: []const []const u8 = &items_200,
            selected: u32 = none,
            scroll: f32 = 0,
        };
        pub const spec = spec_zig.col(panel, .{
            base.ct.label(th, .title),
            ct.vlist(th, .items, .options, .selected, .scroll, visible),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const limits: context.Limits = .{ .nodes = 32, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

/// The example page in the default theme, its replay and the frames kept as golden images
/// (tools/widgetgolden/ref/vlist-<name>.png), as tools/widgetgolden/dump.zig takes a page.
pub const Page = struct {
    pub const Run = Example(.default).Run;
    pub const replay = @embedFile("testdata/vlist.replay");
    pub const golden_frames = .{
        .{ "rest", 0 },
        .{ "scrolled", 3 },
        .{ "selected", 5 },
        .{ "end", 6 },
    };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

var harness: Example(theme).Run = .{};

/// The option rows built under the list: the list's subtree minus the list itself, halved (a
/// row and its label).
fn builtRows(t: *const Tree, box: u32) u32 {
    return (t.c.end[box] - box - 1) / 2;
}

test "vlist: the replay gives the same frames in both front ends" {
    const h = &harness;
    h.init();
    var text: [64]u8 = undefined;
    var evs: [16]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var sel: [12]u32 = undefined;
    var scroll: [12]f32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        try testing.expectEqual(h.app.selected, h.ui.signals.state.selected);
        try testing.expectEqual(h.app.scroll, h.ui.signals.state.scroll);
        sel[k] = h.app.selected;
        scroll[k] = h.app.scroll;
        const t = out.runtime.tree;
        const box = t.find(.from("items"));
        // Never more rows than fit, whatever the scroll position.
        try testing.expect(builtRows(t, box) <= capacity(5));
        try testing.expectEqual(list_zig.selectedValue(h.app.selected), t.c.value[box]);
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(u32, &.{ none, none, none, none, none, 3, 199, 198, 199, 0, 0, 0 }, &sel);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 60, 75, 75, 75, 5850, 5850, 5850, 0, 0, 5850 }, &scroll);
}

test "vlist: roles and value; only rows on screen are exported" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try h.frame(&in);
    h.app.selected = 41;
    h.app.scroll = 40 * list_zig.rowHeight(&theme);
    h.ui.signals.state.selected = 41;
    h.ui.signals.state.scroll = h.app.scroll;
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const box = t.find(.from("items"));
    try testing.expectEqual(@backingInt(a11y.Role.listbox), t.c.role[box]);
    try testing.expectEqual(@as(f32, 41), t.c.value[box]);
    // Rows 40 to 45 are built (5 visible, one spare); each an option named by its text.
    try testing.expectEqual(@as(u32, 6), builtRows(t, box));
    for (0..6) |j| try testing.expectEqual(@backingInt(a11y.Role.option), t.c.role[box + 1 + 2 * j]);
    // The first built row shows option 40: its label is that option's text.
    const run = t.c.text[box + 2];
    const tx = out.runtime.texts;
    const strings = h.ctx.strings[h.ctx.cur].buf;
    try testing.expectEqualStrings("Item 40", strings[tx.c.start[run]..][0..tx.c.bytes[run]]);
}

test "check: what a comptime virtual list's state must have" {
    const Good = struct { o: []const []const u8 = &.{}, sel: u32 = none, sc: f32 = 0 };
    const Bad = struct { o: []const u8 = "", sel: f32 = 0, sc: u32 = 0 };
    try testing.expectEqual(null, comptime check(Good, "o", "sel", "sc", 4));
    try testing.expectEqualStrings("vlist: a virtual list shows at least one row", comptime check(Good, "o", "sel", "sc", 0).?);
    try testing.expectEqualStrings("vlist: state has no field 'x' for the options", comptime check(Good, "x", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: options field 'o' must be a []const []const u8", comptime check(Bad, "o", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: selection field 'sel' must be a u32 (a row, or none)", comptime check(struct { o: []const []const u8 = &.{}, sel: f32 = 0 }, "o", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: state has no field 'sc' for the scroll offset", comptime check(struct { o: []const []const u8 = &.{}, sel: u32 = 0 }, "o", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: scroll field 'sc' must be an f32 (pixels from the top)", comptime check(struct { o: []const []const u8 = &.{}, sel: u32 = 0, sc: u32 = 0 }, "o", "sel", "sc", 4).?);
}

test "ct.vlist: capacity(visible) template rows, whatever the option count" {
    const spec = comptime ct.vlist(theme, .items, .options, .selected, .scroll, 5);
    try testing.expectEqual(6, spec.children.len);
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("options", v.items);
    try testing.expectEqualStrings("selected", v.selected);
    try testing.expectEqualStrings("scroll", v.scroll);
    try testing.expectEqual(5, v.visible);
    // 1 list + 6 x (row + label): fixed, so the comptime page's capacity is exact.
    try testing.expectEqual(13, flatten.count(spec));
}

test "window: the rows on screen by index arithmetic" {
    const h = list_zig.rowHeight(&theme);
    try testing.expectEqual(Window{ .first = 0, .len = 6 }, window(&theme, 200, 5, 0));
    try testing.expectEqual(Window{ .first = 2, .len = 6 }, window(&theme, 200, 5, 2.5 * h));
    try testing.expectEqual(Window{ .first = 195, .len = 5 }, window(&theme, 200, 5, 195 * h));
    try testing.expectEqual(Window{ .first = 0, .len = 3 }, window(&theme, 3, 5, 0));
    try testing.expectEqual(Window{ .first = 0, .len = 0 }, window(&theme, 0, 5, 0));
    try testing.expectEqual(Window{ .first = 0, .len = 6 }, window(&theme, 200, 5, -10));
}

test "vlist: builds only the rows on screen, for 10 options or 10,000 (E1)" {
    var buffer: [context.Context.requiredBytes(Example(theme).limits)]u8 align(@import("../core/mem.zig").column_align) = undefined;
    var ctx = try context.Context.init(&buffer, Example(theme).limits);
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const many: [10_000][]const u8 = @splat("Item");
    var lens: [2]u32 = undefined;
    for (&lens, [2][]const []const u8{ many[0..10], &many }) |*len, options| {
        var sel: u32 = none;
        var scroll: f32 = 3 * list_zig.rowHeight(&theme) + 4;
        var f = ctx.begin(&in);
        _ = vlist(&f, &theme, .from("v"), options, 5, &sel, &scroll);
        const out = f.end(.{});
        len.* = out.tree.len;
        try testing.expect(out.status.ok());
    }
    // Root, list, 6 x (row + label): the same tree for both.
    try testing.expectEqual(@as(u32, 14), lens[1]);
    try testing.expectEqual(lens[0], lens[1]);
}

test "vlist: both front ends agree when scrolled part way" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try h.frame(&in);
    h.app.scroll = 37;
    h.ui.signals.state.scroll = 37;
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const box = t.find(.from("items"));
    // The first built row is option 1, pulled up by the 7 px the scroll takes past it.
    try testing.expectEqual(@as(u32, 6), builtRows(t, box));
    try testing.expectApproxEqAbs(t.rect(box).y0 + list_zig.inset(&theme) - 7, t.rect(box + 1).y0, 0.5);
}

test "wheel, reveal, maxScroll: scrolling as pure functions" {
    const h = list_zig.rowHeight(&theme);
    try testing.expectEqual(195 * h, maxScroll(&theme, 200, 5));
    try testing.expectEqual(@as(f32, 0), maxScroll(&theme, 3, 5));
    try testing.expectEqual(@as(f32, 0), wheel(&theme, 10, -50, 200, 5));
    try testing.expectEqual(195 * h, wheel(&theme, 10, 1e9, 200, 5));
    try testing.expectEqual(@as(f32, 40), wheel(&theme, 10, 30, 200, 5));
    // Row 10 below the window: scrolled until it is the last row on screen.
    try testing.expectEqual(6 * h, reveal(&theme, 0, 10, 5));
    // Row 2 above it: scrolled until it is the first.
    try testing.expectEqual(2 * h, reveal(&theme, 9 * h, 2, 5));
    // Already whole on screen: no movement.
    try testing.expectEqual(3 * h, reveal(&theme, 3 * h, 5, 5));
    try testing.expectEqual(@as(f32, 17), reveal(&theme, 17, none, 5));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
