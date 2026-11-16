//! List box (tier 2): a column of options, one of them selected, in both front ends. Follows the
//! five-commit recipe of widgets/base.zig and is written against the public API of tiers 0 and 1
//! only.
//!
//! State lives in the application: the options (strings) and the selected row (`u32`, `none` for
//! no selection). Every option row has the same height (`rowHeight`), so the row under the
//! pointer is index arithmetic on the list's last rect, not a hit test per row.
//!
//! The comptime side (`ct.list`, `ComptimeList`) also carries the shared comptime page this
//! file's sibling widgets (vlist, table, tree, progress, spinner, colorpicker) build on:
//! `CtFrame`, the comptime front end's tables and `Frame.end`'s pass sequence, and
//! `CtPointer`, hover, hold and focus exactly as the runtime front end's `Interaction` reports
//! them.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const paint = @import("../draw/paint.zig");
const layout = @import("../layout/layout.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const Keymap = @import("../interact/focus.zig").Keymap;
const base = @import("base.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// The keys a list answers to. USB HID usage ids, as `focus.Keymap`; a host with other codes
/// passes its own to `keys`.
pub const default_keys: Keymap = .{};

/// Why `State` cannot back a comptime list bound to `selected` with option fields `items`, or
/// null when it can. `validate` turns the answer into a compile error; tests read it directly.
pub fn check(comptime State: type, comptime selected: []const u8, comptime items: []const []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, selected)) return "list: state has no field '" ++ selected ++ "' for the selection";
        if (@FieldType(State, selected) != u32) return "list: selection field '" ++ selected ++ "' must be a u32 (a row, or none)";
        if (items.len == 0) return "list: a list needs at least one option";
        for (items) |f| {
            if (!@hasField(State, f)) return "list: state has no field '" ++ f ++ "' for an option";
            if (@FieldType(State, f) != []const u8) return "list: option field '" ++ f ++ "' must be a []const u8";
        }
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime selected: []const u8, comptime items: []const []const u8) void {
    if (comptime check(State, selected, items)) |msg| @compileError(msg);
}

// ---- look: one function per part, called by both front ends -------------------------------

/// Height of every option row: one line of text and the theme's padding above and below.
pub fn rowHeight(th: *const Theme) f32 {
    return th.text_px + 2 * th.pad;
}

/// Inset of the option rows inside the list's border.
pub fn inset(th: *const Theme) f32 {
    _ = th;
    return 2;
}

pub fn listStyle(th: *const Theme) Style {
    return .{
        .dir = .y,
        .min = .{ 120, 0 },
        .pad = @splat(inset(th)),
        .radius = th.radius,
        .fill = th.control_held,
        .border = 1,
        .border_color = th.control_hot,
        .role = .group,
    };
}

/// The list's outline by focus: at rest, focused.
pub fn listBorder(th: *const Theme, focused: bool) Color {
    const t: base.OnOff = .{ th.control_hot, th.accent };
    return t[@intFromBool(focused)];
}

pub fn optionStyle(th: *const Theme) Style {
    return .{
        .dir = .x,
        .size = .{ .fill, .px(rowHeight(th)) },
        .pad = .{ th.pad, 0, th.pad, 0 },
        .cross = .center,
        .radius = th.radius,
    };
}

/// An option's fill by state, indexed by `hot | selected << 1`: rest, under the pointer,
/// selected, selected and under the pointer.
pub fn optionFills(th: *const Theme) base.StateColors {
    return .{ .transparent, th.control, th.accent, th.accent };
}

pub fn optionFill(th: *const Theme, hot: bool, selected: bool) Color {
    return optionFills(th)[@as(u2, @intFromBool(hot)) | (@as(u2, @intFromBool(selected)) << 1)];
}

/// The option row at height `y`, for a list whose last rect starts at `top`: clamped into the
/// `count` rows, so the border and padding pick the nearest row.
pub fn rowAt(th: *const Theme, top: f32, y: f32, count: u32) u32 {
    const k = @floor((y - top - inset(th)) / rowHeight(th));
    const hi: f32 = @floatFromInt(count -| 1);
    return @intFromFloat(std.math.clamp(k, 0, hi));
}

// ---- behaviour: pure functions of the value and what happened -------------------------------

/// The selection after one navigation key (WAI-ARIA listbox: selection follows focus). Down
/// and Up move by one and stop at the ends, Home and End jump there; from no selection, Down and
/// Home select the first row and Up and End the last. Other keys leave it.
pub fn step(sel: u32, count: u32, code: u8, km: *const Keymap) u32 {
    if (count == 0) return none;
    const last = count - 1;
    const has = sel != none;
    if (code == km.down) return if (has) @min(sel + 1, last) else 0;
    if (code == km.up) return if (has) sel -| 1 else last;
    if (code == km.home) return 0;
    if (code == km.end) return last;
    return sel;
}

/// Type-ahead: the next option after `sel`, wrapping, whose text starts with `ch` (ASCII case
/// ignored); `sel` when none does.
pub fn typeAhead(items: []const []const u8, sel: u32, ch: u8) u32 {
    const n: u32 = @intCast(items.len);
    const want = std.ascii.toLower(ch);
    // From no selection the search starts at the first row.
    const from = if (sel == none) n - 1 else sel;
    for (1..n + 1) |d| {
        const k: u32 = @intCast((from + d) % n);
        const s = items[k];
        if (s.len > 0 and std.ascii.toLower(s[0]) == want) return k;
    }
    return sel;
}

/// The selection after this frame's key events, in order: navigation keys (press and repeat)
/// and the first byte of each piece of typed text.
// ponytail: one character per search; APG's multi-character prefix with a timeout needs the
// last keystroke's time kept in the application, add it when a list is long enough to want it.
pub fn keys(sel: u32, items: []const []const u8, in: *const Input, km: *const Keymap) u32 {
    var s = sel;
    const n: u32 = @intCast(items.len);
    for (in.events) |e| switch (e.kind) {
        .press, .repeat => s = step(s, n, e.code, km),
        .text => if (e.len > 0 and n > 0) {
            s = typeAhead(items, s, in.text[e.at]);
        },
        .release => {},
    };
    return s;
}

/// What a click does: selects the row under the pointer.
pub fn click(sel: u32, clicked: bool, row: u32) u32 {
    return if (clicked) row else sel;
}

// ---- accessibility ---------------------------------------------------------------------------

/// The `value` column of a list: the selected row, -1 for none.
pub fn selectedValue(sel: u32) f32 {
    return @as(f32, @floatFromInt(sel +% 1)) - 1;
}

/// Roles of the list's rows, written to the tree's `role` column (they are past `types.Role`):
/// the list a list box, each option row an option.
pub fn setRoles(t: *Tree, box: u32, first_option: u32, count: u32) void {
    t.c.role[box] = @backingInt(a11y.Role.listbox);
    // Each option is a row and its label: two tree rows.
    for (0..count) |k| t.c.role[first_option + 2 * k] = @backingInt(a11y.Role.option);
}

/// The `selected` state of the selected option, for the accessibility bridge. Rows as
/// `setRoles` took them; run before `a11y.states`.
pub fn setStates(s: *a11y.Semantics, first_option: u32, count: u32, sel: u32) void {
    if (sel >= count) return;
    s.c.state[first_option + 2 * sel] |= a11y.State.bitsOf(.{ .selected = true });
}

// ---- runtime front end ----------------------------------------------------------------------

/// A list of `items` with `selected.*` the selected row. Clicking a row selects it; while the
/// list has focus (a press on it gives it), the arrow keys, Home, End and type-ahead move the
/// selection.
pub fn list(f: *Frame, th: *const Theme, id: Id, items: []const []const u8, selected: *u32) Response {
    const n: u32 = @intCast(items.len);
    const box = f.open(id, listStyle(th));
    const r = f.interact(box, .button);
    const top = f.lastRect(id).y0;
    const under = rowAt(th, top, f.in.pointer[1], n);
    selected.* = click(selected.*, r.clicked, under);
    if (r.focused) selected.* = keys(selected.*, items, f.in, &default_keys);
    const t = f.tree();
    t.c.look[box.ix()].border_color = listBorder(th, r.focused).bitsOf();
    const first = t.len;
    for (items, 0..) |s, k| {
        const row = f.open(.none, optionStyle(th));
        f.setFill(row, optionFill(th, r.hovered and under == k, selected.* == k));
        _ = base.label(f, th, s);
        f.close();
    }
    f.close();
    t.c.value[box.ix()] = selectedValue(selected.*);
    setRoles(t, box.ix(), first, n);
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A list named `id` selecting into the u32 field `selected`, one option per string field
    /// in `items` (a tuple of enum literals): `ct.list(th, .fruit, .selected, .{ .apple, .pear })`.
    pub fn list(comptime th: Theme, comptime id: @EnumLiteral(), comptime selected: @EnumLiteral(), comptime items: anytype) Spec {
        var opts: [items.len]Spec = undefined;
        for (&opts, items) |*o, item| o.* = spec_zig.row(optionStyle(&th), .{base.ct.label(th, item)});
        var s = spec_zig.col(listStyle(&th), opts);
        s.id = @tagName(id);
        s.bind = @tagName(selected);
        return s;
    }
};

/// The option fields of the list node `n` (built by `ct.list`): each option row's label binding.
pub fn itemFields(comptime n: Spec) [n.children.len][]const u8 {
    var out: [n.children.len][]const u8 = undefined;
    for (&out, n.children) |*o, c| o.* = c.children[0].bind.?;
    return out;
}

/// The comptime front end for a page of lists: rows, columns and labels as in `base.ComptimeUi`,
/// and every node with an id a list made by `ct.list`. State in `Signals`, input through
/// `Events`; look and behaviour through the functions above.
pub fn ComptimeList(comptime State: type, comptime spec: Spec, comptime th: Theme) type {
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    inline for (E.widget_nodes) |row| {
        const n = nodeAt(spec, row);
        validate(State, n.bind.?, &itemFields(n));
    }
    const Tables = CtFrame(flatten.count(spec) + 1, @max(labelCount(spec), 1));
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = S;

        page: Tables = .{},
        signals: S.Runtime = .{},
        pointer: CtPointer(E) = .{},
        font: Mono = .{},

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        pub fn frame(ui: *Self, in: *const Input) Output {
            const event = ui.pointer.step(in);
            const state = &ui.signals.state;
            inline for (0..E.widget_count) |k| {
                const n = comptime nodeAt(spec, E.widget_nodes[k]);
                const w = comptime E.widget(k);
                const fields = comptime itemFields(n);
                var items: [fields.len][]const u8 = undefined;
                inline for (&items, fields) |*s, f| s.* = @field(state, f);
                const clicked = if (event) |e| e == w else false;
                var sel: u32 = @field(state, n.bind.?);
                sel = click(sel, clicked, rowAt(&th, ui.pointer.rects.c[1][k], in.pointer[1], fields.len));
                if (ui.pointer.focus == w) sel = keys(sel, &items, in, &default_keys);
                ui.signals.set(comptime field(n.bind.?), sel);
            }

            const tb = ui.page.begin(in);
            var next: u32 = 0;
            ui.push(spec, 0, &next, in);
            const t = ui.page.end(in);
            ui.pointer.store(t);
            return .{ .draw = &tb.d, .tree = t, .event = event };
        }

        fn push(ui: *Self, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const tb = &ui.page.tables;
            const state = &ui.signals.state;
            const row = next.*;
            next.* += 1;
            if (n.kind == .label) {
                pushLabel(tb, parent, &n.style, @field(state, n.bind.?), &th);
                return;
            }
            if (n.id == null) {
                const i = tb.t.push(parent, .none, &n.style);
                inline for (n.children) |c| ui.push(c, i, next, in);
                tb.t.seal(i);
                return;
            }
            // A list (`ct.list`).
            const w: E.Widget = @fromBackingInt(@as(E.Index, @intCast(row)));
            const r = ui.pointer.response(w, in);
            const count: u32 = n.children.len;
            const sel: u32 = @field(state, n.bind.?);
            const under = rowAt(&th, ui.pointer.rectOf(w).y0, in.pointer[1], count);
            const box = tb.t.push(parent, .hash(n.id.?), &n.style);
            tb.t.c.look[box].border_color = listBorder(&th, r.focused).bitsOf();
            const first = tb.t.len;
            inline for (n.children, 0..) |o, j| {
                next.* += 2;
                var s = o.style;
                s.fill = optionFill(&th, r.hovered and under == j, sel == j);
                const i = tb.t.push(box, .none, &s);
                pushLabel(tb, i, &o.children[0].style, @field(state, o.children[0].bind.?), &th);
                tb.t.seal(i);
            }
            tb.t.seal(box);
            tb.t.c.value[box] = selectedValue(sel);
            setRoles(&tb.t, box, first, count);
        }

        fn field(comptime name: []const u8) S.Field {
            return comptime std.meta.stringToEnum(S.Field, name).?;
        }
    };
}

// ---- shared comptime page: used by this file's sibling widgets too ---------------------------

/// The tables of a comptime page with exactly `rows` tree rows (the root included) and `runs`
/// text runs, carved from a buffer inside the value, and `Frame.end`'s pass sequence over them.
/// `begin` opens the runtime front end's root; push the page under row 0, then `end`.
pub fn CtFrame(comptime rows: u32, comptime runs: u32) type {
    return struct {
        const Self = @This();
        buf: [bytes]u8 align(mem.column_align) = undefined,
        tables: Tables = undefined,
        font: Mono = .{},

        pub const Tables = struct {
            t: Tree,
            tx: Texts,
            cu: Customs,
            strings: Strings,
            d: DrawList,

            fn carve(carver: *mem.Carver) Tables {
                return .{
                    .t = Tree.init(carver, rows),
                    .tx = Texts.init(carver, runs),
                    .cu = Customs.init(carver, 1),
                    .strings = .{ .buf = carver.slice(u8, string_bytes) },
                    .d = DrawList.init(carver, rows, runs, 1),
                };
            }
        };
        const string_bytes = 64 * runs;
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tables.carve(&counter);
            break :blk counter.off;
        };

        /// Carves the tables (the value may have moved since last frame), clears them and pushes
        /// the root `Context.begin` pushes.
        pub fn begin(p: *Self, in: *const Input) *Tables {
            var carver: mem.Carver = .{ .buf = &p.buf };
            p.tables = Tables.carve(&carver);
            const tb = &p.tables;
            tb.t.reset();
            tb.tx.reset();
            tb.cu.reset();
            tb.strings.reset();
            _ = tb.t.push(0, context.root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });
            return tb;
        }

        /// Seals the root, lays out and paints: `Frame.end`'s passes, in its order.
        pub fn end(p: *Self, in: *const Input) *const Tree {
            const tb = &p.tables;
            const t = &tb.t;
            const tx = &tb.tx;
            t.seal(0);
            p.font.measure(tx);
            layout.prepare(t);
            layout.applyText(t, tx, .x);
            layout.fit(t, .x);
            layout.resolve(t, .x, in.viewport[0]);
            layout.textAvail(t, tx);
            p.font.wrap(tx);
            layout.applyText(t, tx, .y);
            layout.fit(t, .y);
            layout.resolve(t, .y, in.viewport[1]);
            layout.place(t);
            layout.finalize(t);
            paint.emit(t, tx, &tb.cu, tb.strings.buf[0..tb.strings.len], &tb.d);
            return t;
        }
    };
}

/// A text leaf as `base.label` makes it: `style` (a label's), the string, the theme's text.
pub fn pushLabel(tb: anytype, parent: u32, style: *const Style, str: []const u8, th: *const Theme) void {
    const i = tb.t.push(parent, .none, style);
    const span = tb.strings.add(str);
    tb.t.c.text[i] = tb.tx.push(i, span, &base.labelText(th));
}

/// Pointer and focus for the widgets of `E` as the runtime front end's `Interaction` reports
/// them: a click on release over the widget pressed, capture while held (only the held widget
/// shows hover), and focus moved by every press (to the widget under it, or to nothing). Every
/// widget of a page built on this senses focus. Judged against last frame's rects (`store`).
pub fn CtPointer(comptime E: type) type {
    return struct {
        const Self = @This();
        pointer: E.Pointer = .{},
        /// Last frame's widget rects.
        rects: E.Rects = .{},
        focus: ?E.Widget = null,

        /// This frame's click, from `Events.pointer`; moves focus on a press.
        pub fn step(p: *Self, in: *const Input) ?E.Event {
            const press = in.buttons.left and !p.pointer.down;
            if (press) p.focus = E.at(&p.rects, in.pointer[0], in.pointer[1]);
            return E.pointer(&p.pointer, &p.rects, in);
        }

        /// Hover, held and focus for `w`, as `Frame.interact` returns them.
        pub fn response(p: *const Self, w: E.Widget, in: *const Input) Response {
            const held = p.pointer.pressed == w;
            const owned = p.pointer.pressed == null or held;
            const under = E.at(&p.rects, in.pointer[0], in.pointer[1]) == w;
            return .{ .hovered = under and owned, .held = held, .focused = p.focus == w };
        }

        /// Last frame's rect of `w`.
        pub fn rectOf(p: *const Self, w: E.Widget) types.Rect {
            const k = slotOf(w);
            return .{ .x0 = p.rects.c[0][k], .y0 = p.rects.c[1][k], .x1 = p.rects.c[2][k], .y1 = p.rects.c[3][k] };
        }

        /// Keeps this frame's widget rects for the next frame's input. `t` is the page's tree:
        /// spec row r is tree row r + 1, under the root.
        pub fn store(p: *Self, t: *const Tree) void {
            p.rects = .{};
            for (0..4) |side| {
                for (E.widget_nodes, 0..) |node, k| p.rects.c[side][k] = t.c.vis[side][@as(usize, node) + 1];
            }
        }

        fn slotOf(w: E.Widget) usize {
            inline for (0..E.widget_count) |k| if (E.widget(k) == w) return k;
            unreachable;
        }
    };
}

/// Spec nodes in `n`'s subtree that show text.
pub fn labelCount(comptime n: Spec) u32 {
    var k: u32 = @intFromBool(n.kind == .label);
    for (n.children) |c| k += labelCount(c);
    return k;
}

/// The spec node at depth-first row `row` of `n`.
pub fn nodeAt(comptime n: Spec, comptime row: comptime_int) Spec {
    comptime {
        var i = 0;
        return nodeWalk(n, row, &i).?;
    }
}

fn nodeWalk(comptime n: Spec, comptime row: comptime_int, comptime next: *comptime_int) ?Spec {
    if (next.* == row) return n;
    next.* += 1;
    for (n.children) |c| if (nodeWalk(c, row, next)) |r| return r;
    return null;
}

// ---- example page -----------------------------------------------------------------------------

/// The example page: a caption and a list of five fruits on a panel, in both front ends, in
/// theme `th`. Its tests and golden images (tools/widgetgolden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };
        const fruits = [_][]const u8{ "Apple", "Banana", "Cherry", "Damson", "Elder" };

        /// Runtime front end: the application owns the options and the selection.
        pub const App = struct {
            selected: u32 = none,
            clicked: bool = false,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = base.label(f, &th, "Fruit");
                app.clicked = list(f, &th, .from("fruit"), &fruits, &app.selected).clicked;
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const State = struct {
            title: []const u8 = "Fruit",
            selected: u32 = none,
            apple: []const u8 = fruits[0],
            banana: []const u8 = fruits[1],
            cherry: []const u8 = fruits[2],
            damson: []const u8 = fruits[3],
            elder: []const u8 = fruits[4],
        };
        pub const spec = spec_zig.col(panel, .{
            base.ct.label(th, .title),
            ct.list(th, .fruit, .selected, .{ .apple, .banana, .cherry, .damson, .elder }),
        });
        pub const Ui = ComptimeList(State, spec, th);
        pub const limits: context.Limits = .{ .nodes = 32, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

var harness: Example(theme).Run = .{};

test "list: roles, value and the selected state for accessibility" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try h.frame(&in);
    h.app.selected = 2;
    h.ui.signals.state.selected = 2;
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const box = t.find(.from("fruit"));
    try testing.expectEqual(@backingInt(a11y.Role.listbox), t.c.role[box]);
    for (0..5) |j| try testing.expectEqual(@backingInt(a11y.Role.option), t.c.role[box + 1 + 2 * j]);
    try testing.expectEqual(@as(f32, 2), t.c.value[box]);
    try testing.expectEqual(@as(f32, -1), selectedValue(none));

    // The bridge's view: the list box named by nothing, the options by their text, one selected.
    var sbuf: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &sbuf };
    var sem = a11y.Semantics.init(&carver, t.cap);
    sem.clear();
    setStates(&sem, box + 1, 5, 2);
    a11y.names(t, &sem);
    a11y.states(t, &sem);
    const selected_bit = a11y.State.bitsOf(.{ .selected = true });
    for (0..5) |j| try testing.expectEqual(j == 2, sem.c.state[box + 1 + 2 * j] & selected_bit != 0);
    // An option takes its name from its content: its label's text run ("Cherry").
    try testing.expectEqual(t.c.text[box + 2 + 2 * 2], sem.c.name[box + 1 + 2 * 2]);
    try testing.expect(sem.c.name[box + 1 + 2 * 2] != none);
}

test "check: what a comptime list's state must have" {
    const Good = struct { sel: u32 = none, a: []const u8 = "A", b: []const u8 = "B" };
    const Bad = struct { sel: i32 = 0, a: u8 = 0 };
    try testing.expectEqual(null, comptime check(Good, "sel", &.{ "a", "b" }));
    try testing.expectEqualStrings("list: state has no field 'x' for the selection", comptime check(Good, "x", &.{"a"}).?);
    try testing.expectEqualStrings("list: selection field 'sel' must be a u32 (a row, or none)", comptime check(Bad, "sel", &.{"a"}).?);
    try testing.expectEqualStrings("list: a list needs at least one option", comptime check(Good, "sel", &.{}).?);
    try testing.expectEqualStrings("list: state has no field 'c' for an option", comptime check(Good, "sel", &.{ "a", "c" }).?);
    const Bad2 = struct { sel: u32 = 0, a: u8 = 0 };
    try testing.expectEqualStrings("list: option field 'a' must be a []const u8", comptime check(Bad2, "sel", &.{"a"}).?);
}

test "ct.list: one widget, a column of option rows each holding a label" {
    const spec = comptime spec_zig.col(.{}, .{
        base.ct.label(theme, .title),
        ct.list(theme, .fruit, .selected, .{ .apple, .banana, .cherry, .damson, .elder }),
    });
    const E = events.Events(spec);
    try testing.expectEqual(1, E.widget_count);
    try testing.expectEqual(@as(usize, 2), @backingInt(E.Widget.fruit));
    const n = comptime nodeAt(spec, 2);
    try testing.expectEqual(5, n.children.len);
    try testing.expectEqualStrings("selected", n.bind.?);
    try testing.expectEqualStrings("cherry", (comptime itemFields(n))[2]);
    try testing.expectEqual(rowHeight(&theme), n.children[0].style.size[1].v);
    // 1 column + 1 caption + 1 list + 5 x (row + label).
    try testing.expectEqual(13, flatten.count(spec));
}

test "list: both front ends agree at rest and under the pointer" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const box = t.find(.from("fruit"));
    const r = t.rect(box);
    // Over the third option: it, and only it, takes the hover fill.
    in.pointer = .{ r.x0 + 10, r.y0 + inset(&theme) + rowHeight(&theme) * 2.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    for (0..5) |j| {
        const want = optionFill(&theme, j == 2, false);
        try testing.expectEqual(want.bitsOf(), t.c.look[box + 1 + 2 * j].fill);
    }
    try testing.expectEqual(theme.control_hot.bitsOf(), t.c.look[box].border_color);
    // Rows are one option height each, stacked inside the border.
    try testing.expectApproxEqAbs(rowHeight(&theme), t.rect(box + 1).h(), 0.5);
    try testing.expectApproxEqAbs(5 * rowHeight(&theme) + 2 * inset(&theme), r.h(), 1);
}

test "step, typeAhead, rowAt, click: the behaviour as pure functions" {
    const km = default_keys;
    try testing.expectEqual(@as(u32, 0), step(none, 3, km.down, &km));
    try testing.expectEqual(@as(u32, 2), step(none, 3, km.up, &km));
    try testing.expectEqual(@as(u32, 2), step(2, 3, km.down, &km));
    try testing.expectEqual(@as(u32, 0), step(0, 3, km.up, &km));
    try testing.expectEqual(@as(u32, 1), step(0, 3, km.down, &km));
    try testing.expectEqual(@as(u32, 0), step(2, 3, km.home, &km));
    try testing.expectEqual(@as(u32, 2), step(0, 3, km.end, &km));
    try testing.expectEqual(@as(u32, 1), step(1, 3, km.tab, &km));
    try testing.expectEqual(none, step(1, 0, km.down, &km));
    const items = [_][]const u8{ "beta", "Alpha", "bravo", "" };
    try testing.expectEqual(@as(u32, 0), typeAhead(&items, none, 'B'));
    try testing.expectEqual(@as(u32, 2), typeAhead(&items, 0, 'b'));
    try testing.expectEqual(@as(u32, 0), typeAhead(&items, 2, 'b'));
    try testing.expectEqual(@as(u32, 1), typeAhead(&items, 2, 'a'));
    try testing.expectEqual(@as(u32, 2), typeAhead(&items, 2, 'z'));
    const h = rowHeight(&theme);
    try testing.expectEqual(@as(u32, 0), rowAt(&theme, 10, 0, 4));
    try testing.expectEqual(@as(u32, 1), rowAt(&theme, 10, 12 + h * 1.5, 4));
    try testing.expectEqual(@as(u32, 3), rowAt(&theme, 10, 1000, 4));
    try testing.expectEqual(@as(u32, 5), click(5, false, 1));
    try testing.expectEqual(@as(u32, 1), click(5, true, 1));
}

test "look: fills by table index from hover and selection; outline by focus" {
    const f = optionFills(&theme);
    try testing.expectEqual(f[0], optionFill(&theme, false, false));
    try testing.expectEqual(theme.control, optionFill(&theme, true, false));
    try testing.expectEqual(theme.accent, optionFill(&theme, false, true));
    try testing.expectEqual(theme.accent, optionFill(&theme, true, true));
    try testing.expectEqual(theme.control_hot, listBorder(&theme, false));
    try testing.expectEqual(theme.accent, listBorder(&theme, true));
}

test "list: another theme restyles both front ends alike" {
    const other = comptime Theme{ .text = .rgb(20, 20, 20), .text_px = 18, .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .control_held = .rgb(160, 160, 170), .accent = .rgb(0, 120, 60), .radius = 0, .pad = 4, .gap = 10 };
    const S = struct {
        var h: Example(other).Run = .{};
    };
    S.h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try S.h.frame(&in);
    // Click the fourth option, aimed with the other theme's row height.
    const t = S.h.ctx.trees[S.h.ctx.cur];
    const r = t.rect(t.find(.from("fruit")));
    in.pointer = .{ r.x0 + 10, r.y0 + inset(&other) + rowHeight(&other) * 3.5 };
    in.buttons.left = true;
    _ = try S.h.frame(&in);
    in.buttons.left = false;
    _ = try S.h.frame(&in);
    try testing.expectEqual(@as(u32, 3), S.h.app.selected);
    try testing.expectEqual(@as(u32, 3), S.h.ui.signals.state.selected);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
