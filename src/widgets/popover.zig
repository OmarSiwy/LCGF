//! Popover (tier 2): a button that opens a floating panel next to it, the WAI-ARIA APG
//! non-modal dialog pattern. Written against the public API of tiers 0 and 1, after the recipe
//! in base.zig. The panel floats (`Style.float`) under the root at an offset taken from the
//! trigger's rect of the last frame (`Frame.lastRect`), so it is drawn above the page and takes
//! no part in its flow (prototype/ui.zig, `Style.float`).
//!
//! The open panel sits on a scrim: a transparent float the size of the viewport, under the
//! panel. A press on the scrim (anywhere outside the panel) closes the popover and is not
//! passed on, as a light-dismiss popover does.
//!
//! Also here, for the other overlay widgets (tooltip, menu, dialog, ...): `ComptimePage`, the
//! comptime front end of a page whose widget shows and hides parts of itself, and `keys`.
//!
//! Runtime: `trigger` in the page's flow, then, under the root after the page,
//! `if (begin(...)) { content; end(f); }`.
//!
//! Comptime: `const P = Popover(th, .details, .open);` gives the spec builders `P.button` and
//! `P.layer` and the hooks `ComptimePage(State, spec, th, P)` runs.

const std = @import("std");
const base = @import("base.zig");
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
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec: what the popover takes and keeps --------------------------------------------------

/// The application state a popover binds: whether it is open. A `*bool` in the runtime front
/// end, a bool field of the state struct in the comptime one.
pub const Open = bool;

/// Ids of a popover's parts, from its name: the trigger is `name`, the scrim `name_scrim`, the
/// panel `name_panel`.
pub fn partName(comptime name: []const u8, comptime part: []const u8) [:0]const u8 {
    return name ++ "_" ++ part;
}

/// What `ComptimePage` pushes for one spec row: its style, and a role from the accessibility
/// roles (`a11y.Role`) where `types.Role` has none, written to the `role` column after `push`.
pub const Part = struct {
    style: Style,
    role: ?a11y.Role = null,
    /// Optional label typography supplied by a composing hook. Null keeps the stock theme.
    text: ?types.TextStyle = null,
    /// Optional label bytes borrowed until this build copies them into the existing bounded
    /// Strings buffer. Null keeps the label's bound State string and its original behavior.
    content: ?[]const u8 = null,
};

/// `null` if `State` can hold a popover named `name` bound to `open`, else the compile error:
/// `open` must be a bool field.
pub fn checkOpen(comptime State: type, comptime name: []const u8, comptime open: []const u8) ?[]const u8 {
    if (!@hasField(State, open)) return "popover '" ++ name ++ "': state " ++ @typeName(State) ++ " has no field '" ++ open ++ "'";
    if (@FieldType(State, open) != Open) return "popover '" ++ name ++ "': field '" ++ open ++ "' must be a bool, not " ++ @typeName(@FieldType(State, open));
    return null;
}

/// `null` if every label of `spec` shows a string field of `State`, else the compile error.
pub fn checkLabels(comptime State: type, comptime spec: Spec) ?[]const u8 {
    if (spec.kind == .label) {
        if (spec_zig.labelError(spec)) |msg| return msg;
        const f = spec.bind orelse return null;
        if (!@hasField(State, f)) return "label: state " ++ @typeName(State) ++ " has no field '" ++ f ++ "'";
        if (@FieldType(State, f) != []const u8) return "label: field '" ++ f ++ "' must be a []const u8";
    }
    for (spec.children) |c| if (checkLabels(State, c)) |msg| return msg;
    return null;
}

/// The popover named `name` bound to the bool field `open`, in theme `th`: its spec builders
/// and the hooks `ComptimePage` calls.
pub fn Popover(comptime th: Theme, comptime name: @EnumLiteral(), comptime open: @EnumLiteral()) type {
    const id = @tagName(name);
    const scrim = partName(id, "scrim");
    const panel = partName(id, "panel");
    return struct {
        pub const trigger_name = id;
        pub const scrim_name = scrim;
        pub const panel_name = panel;

        /// The button that opens and closes the popover, showing the string field `text`.
        pub fn button(comptime text: anytype) Spec {
            return base.ct.button(th, name, text);
        }

        /// The scrim and the panel holding `children`, shown while the popover is open. Put it
        /// last in the page's root so it is drawn above the rest.
        pub fn layer(comptime children: anytype) Spec {
            var p = spec_zig.col(.{}, children);
            p.id = panel;
            return .{ .kind = .col, .id = scrim, .children = &.{p} };
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkOpen(State, id, @tagName(open));
        }

        /// The trigger's click toggles; a press on the scrim or Escape closes.
        pub fn step(sig: anytype, v: anytype) void {
            const was = @field(sig.state, @tagName(open));
            const toggled = toggle(was, isWidget(v.event, id));
            sig.set(open, dismiss(toggled, isWidget(v.pressed, scrim), keyPressed(v.in, keys.escape)));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const is = struct {
                fn named(comptime want: []const u8) bool {
                    return n.id != null and std.mem.eql(u8, n.id.?, want);
                }
            };
            if (comptime is.named(scrim)) {
                if (!@field(st, @tagName(open))) return null;
                return .{ .style = scrimStyle(v.in.viewport) };
            }
            if (comptime is.named(panel)) return .{ .style = panelStyle(&th, v.last.of(id)), .role = role };
            return plainPart(th, n, v.response);
        }
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The scrim: a transparent float over the whole viewport.
pub fn scrimStyle(viewport: [2]f32) Style {
    return .{ .float = true, .size = .{ .px(viewport[0]), .px(viewport[1]) } };
}

/// The panel, floating `th.gap` below the trigger's rect `at` (last frame's), left edges
/// aligned: a panel-coloured column with the control outline, padded like a button.
pub fn panelStyle(th: *const Theme, at: Rect) Style {
    return .{
        .float = true,
        .offset = .{ at.x0, at.y1 + th.gap },
        .pad = @splat(th.pad),
        .gap = th.gap,
        .fill = th.panel,
        .border = 1,
        .border_color = th.control_hot,
        .radius = th.radius,
    };
}

/// The style of a row no overlay hook claims: a label as specified, a container with an id
/// (a button) filled by its state, anything else as specified.
pub fn plainPart(comptime th: Theme, comptime n: Spec, r: Response) Part {
    var s = n.style;
    if (n.kind != .label and n.id != null) s.fill = base.buttonFill(&th, r);
    return .{ .style = s };
}

// ---- behaviour: pure functions of the state and what happened --------------------------------

/// Scancodes of the keys the overlay widgets read, as USB HID usage ids (as `focus.Keymap`;
/// what SDL and the web's `KeyboardEvent.code` map to).
pub const keys = struct {
    pub const enter: u8 = 0x28;
    pub const escape: u8 = 0x29;
    pub const tab: u8 = 0x2b;
    pub const space: u8 = 0x2c;
    pub const f10: u8 = 0x43;
    pub const right: u8 = 0x4f;
    pub const left: u8 = 0x50;
    pub const down: u8 = 0x51;
    pub const up: u8 = 0x52;
    pub const home: u8 = 0x4a;
    pub const end: u8 = 0x4d;
    /// The context-menu ("Application") key.
    pub const menu: u8 = 0x65;
};

/// Key `code` went down (or repeated) in this frame's events.
pub fn keyPressed(in: *const Input, code: u8) bool {
    return keyCount(in, code, .{}, false) != 0;
}

/// Times key `code` went down this frame, auto-repeat included; with `exact`, only with exactly
/// `mods` held.
pub fn keyCount(in: *const Input, code: u8, mods: Input.Mods, exact: bool) u32 {
    var n: u32 = 0;
    for (in.events) |e| {
        const went = simd.orB(e.kind == .press, e.kind == .repeat);
        const same = simd.orB(!exact, @as(u8, @bitCast(e.mods)) == @as(u8, @bitCast(mods)));
        n += @intFromBool(simd.andB(went, simd.andB(e.code == code, same)));
    }
    return n;
}

/// Clicking the trigger toggles the popover.
pub const toggle = base.toggle;

/// An open popover stays open unless the pointer went down outside it (on the scrim) or
/// Escape was pressed.
pub fn dismiss(open: bool, outside: bool, escape: bool) bool {
    return simd.andB(open, !simd.orB(outside, escape));
}

/// Whether optional event or widget `w` (a `?Events.Event` or `?Events.Widget`) is the widget
/// named `name`.
pub fn isWidget(w: anytype, comptime name: []const u8) bool {
    const T = @typeInfo(@TypeOf(w)).optional.child;
    const x = w orelse return false;
    if (@typeInfo(T) == .@"union") return std.meta.activeTag(x) == @field(std.meta.Tag(T), name);
    return x == @field(T, name);
}

// ---- runtime front end ------------------------------------------------------------------------

/// The trigger: a button named `name` showing `text`. A click toggles `open`.
pub fn trigger(f: *Frame, th: *const Theme, comptime name: []const u8, open: *bool, text: []const u8) Response {
    const r = base.button(f, th, .from(name), text);
    open.* = toggle(open.*, r.clicked);
    return r;
}

/// Opens the scrim and the panel of popover `name` if it is open, and returns whether it did;
/// the caller then adds the content and calls `end`. Call it at the root's depth, after the
/// rest of the page, so the panel is drawn on top.
/// A press outside the panel (on the scrim, which last frame's tree has while it is open) or
/// Escape closes it first.
pub fn begin(f: *Frame, th: *const Theme, comptime name: []const u8, open: *bool) bool {
    const scrim: Id = .from(partName(name, "scrim"));
    // The scrim's response is asked for before it is built: if it closes the popover, the
    // scrim is not built at all, as in the comptime front end.
    open.* = dismiss(open.*, f.ctx.inter.response(scrim).pressed, keyPressed(f.in, keys.escape));
    if (!open.*) return false;
    _ = f.interact(f.open(scrim, scrimStyle(f.in.viewport)), overlay_sense);
    const p = f.open(.from(partName(name, "panel")), panelStyle(th, f.lastRect(.from(name))));
    _ = f.interact(p, overlay_sense);
    f.tree().c.role[p.ix()] = @backingInt(role);
    return true;
}

/// How the scrim and the panel take the pointer: they are hit, so what is under them is not.
pub const overlay_sense: types.Sense = .{ .hover = true, .click = true };

/// Closes the panel and the scrim `begin` opened.
pub fn end(f: *Frame) void {
    f.close();
    f.close();
}

// ---- accessibility ------------------------------------------------------------------------------

/// The panel's role: a non-modal dialog (WAI-ARIA APG dialog pattern). Its value is 0.
pub const role: a11y.Role = .dialog;

/// The semantics of popover `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`: the trigger is expandable, and
/// expanded while the panel is in `t` (`aria-expanded`); the panel is named by the trigger
/// (`aria-labelledby`), so the dialog reads as "Details". Works on either front end's tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8) void {
    const trig = t.find(.from(name));
    if (trig == none) return;
    const panel = t.find(.from(partName(name, "panel")));
    s.c.state[trig] |= a11y.State.bitsOf(.{ .expandable = true, .expanded = panel != none });
    if (panel != none) s.c.labelled_by[panel] = trig;
}

/// Room for the accessibility export of a tree of up to `cap` rows: `a11y.Semantics` and an
/// `a11y.Export` in one buffer, for a widget's tests and for applications that check one.
pub fn Semantic(comptime cap: u32) type {
    return struct {
        const Self = @This();
        buf: [bytes]u8 align(mem.column_align) = undefined,
        s: a11y.Semantics = undefined,
        out: a11y.Export = undefined,

        fn carve(carver: *mem.Carver) struct { a11y.Semantics, a11y.Export } {
            return .{ a11y.Semantics.init(carver, cap), a11y.Export.init(carver, cap) };
        }
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = carve(&counter);
            break :blk counter.off;
        };

        /// Carves the columns and clears the inputs; write widget semantics into the result.
        pub fn begin(x: *Self) *a11y.Semantics {
            var carver: mem.Carver = .{ .buf = &x.buf };
            x.s, x.out = carve(&carver);
            x.s.clear();
            return &x.s;
        }

        /// Names, states and the flat export of `t`, whose text runs are `tx` over `strings`.
        pub fn finish(x: *Self, t: *const Tree, tx: *const Texts, strings: []const u8) *const a11y.Export {
            a11y.names(t, &x.s);
            a11y.states(t, &x.s);
            a11y.flatten(t, tx, strings, &x.s, &x.out);
            return &x.out;
        }
    };
}

/// Whether two exports say the same to assistive technology: rows, roles, states, values,
/// ranges and names (by hash, as the front ends keep their bytes in different buffers).
pub fn sameSemantics(a: *const a11y.Export, b: *const a11y.Export) bool {
    const n = a.len;
    if (n != b.len) return false;
    for (a.c.range, b.c.range) |x, y| if (!std.mem.eql(f32, x[0..n], y[0..n])) return false;
    return std.mem.eql(u8, a.c.role[0..n], b.c.role[0..n]) and std.mem.eql(u16, a.c.state[0..n], b.c.state[0..n]) and
        std.mem.eql(f32, a.c.value[0..n], b.c.value[0..n]) and std.mem.eql(u32, a.c.name_hash[0..n], b.c.name_hash[0..n]) and
        std.mem.eql(u32, a.c.parent[0..n], b.c.parent[0..n]);
}

// ---- comptime front end: a page whose widgets show and hide parts of themselves ---------------

/// The comptime front end of a page with an overlay widget. As `base.ComptimeUi`, but each row's
/// style comes from the widget's hook `H.part`, which may hide the row and its subtree (null),
/// and behaviour from `H.step`, run once per frame before the rows are built. `H` also has
/// `check(State) ?[]const u8`, a compile error when not null. Rows are `row`, `col` and `label`
/// spec nodes; a label shows a string field.
///
/// The hooks see a `View`: the frame's input, last frame's rects of every spec row (zero for a
/// row that was not shown), the pointer event `Events.pointer` made, the widget the left button
/// went down on this frame, and, in `part`, the row's own `Response` as `Interaction` reports
/// it.
pub fn ComptimePage(comptime State: type, comptime spec: Spec, comptime th: Theme, comptime H: type) type {
    if (comptime H.check(State)) |msg| @compileError(msg);
    if (comptime checkLabels(State, spec)) |msg| @compileError(msg);
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    const spec_rows: u32 = flatten.count(spec);
    // One root row (the runtime front end's) above the spec's rows.
    const rows: u32 = spec_rows + 1;
    const runs: u32 = @max(labelCount(spec), 1);
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = S;

        buf: [bytes]u8 align(mem.column_align) = undefined,
        tables: Tables = undefined,
        signals: S.Runtime = .{},
        pointer: E.Pointer = .{},
        /// Last frame's widget rects, which this frame's input is judged against.
        rects: E.Rects = .{},
        last: Last = .{},
        /// This frame's tree row of each spec row, `none` when hidden.
        tree_row: [spec_rows]u32 = @splat(none),
        font: Mono = .{},

        /// Last frame's layout rect of every spec row; zero for a row that was not shown.
        pub const Last = struct {
            rect: [spec_rows]Rect = @splat(.{}),

            /// The rect of the spec row with id `name`.
            pub fn of(l: *const Last, comptime name: []const u8) Rect {
                return l.rect[comptime rowOf(spec, name)];
            }
        };

        pub const View = struct {
            in: *const Input,
            last: *const Last,
            event: ?E.Event,
            /// The widget the left button went down on this frame.
            pressed: ?E.Widget,
            response: Response = .{},
            page: *const Self,

            /// The response of the widget named `name` this frame, as `part` sees its own.
            pub fn responseOf(v: *const View, comptime name: []const u8) Response {
                return v.page.response(comptime rowOf(spec, name), v);
            }
        };

        const Tables = struct {
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
        const string_bytes = spec_zig.stringCapacity(spec, 1024);
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tables.carve(&counter);
            break :blk counter.off;
        };

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        /// Steps input against last frame's rects, runs the widget's behaviour on the state,
        /// then builds, lays out and paints the frame.
        pub fn frame(ui: *Self, in: *const Input) Output {
            const press = in.buttons.left and !ui.pointer.down;
            const pressed = if (press) E.at(&ui.rects, in.pointer[0], in.pointer[1]) else null;
            const event = E.pointer(&ui.pointer, &ui.rects, in);
            var v: View = .{ .in = in, .last = &ui.last, .event = event, .pressed = pressed, .page = ui };
            H.step(&ui.signals, &v);

            var carver: mem.Carver = .{ .buf = &ui.buf };
            ui.tables = Tables.carve(&carver);
            const tb = &ui.tables;
            tb.t.reset();
            tb.tx.reset();
            tb.cu.reset();
            tb.strings.reset();
            // The runtime front end's root (`Context.begin`).
            _ = tb.t.push(0, context.root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });
            var next: u32 = 0;
            ui.push(spec, 0, &next, &v);
            tb.t.seal(0);

            // `Frame.end`'s pass sequence.
            const t = &tb.t;
            const tx = &tb.tx;
            ui.font.measure(tx);
            layout.prepare(t);
            layout.applyText(t, tx, .x);
            layout.fit(t, .x);
            layout.resolve(t, .x, in.viewport[0]);
            layout.textAvail(t, tx);
            ui.font.wrap(tx);
            layout.applyText(t, tx, .y);
            layout.fit(t, .y);
            layout.resolve(t, .y, in.viewport[1]);
            layout.place(t);
            layout.finalize(t);
            paint.emit(t, tx, &tb.cu, tb.strings.buf[0..tb.strings.len], &tb.d);

            for (&ui.last.rect, ui.tree_row) |*r, i| r.* = if (i == none) .{} else t.rect(i);
            ui.rects = .{};
            for (E.widget_nodes, 0..) |node, k| {
                const i = ui.tree_row[node];
                if (i == none) continue;
                for (0..4) |side| ui.rects.c[side][k] = t.c.vis[side][i];
            }
            return .{ .draw = &tb.d, .tree = t, .event = event };
        }

        /// Pushes `n` (spec row `next.*`) and its subtree under tree row `parent`, unless the
        /// widget's hook hides it.
        fn push(ui: *Self, comptime n: Spec, parent: u32, next: *u32, v: *View) void {
            const tb = &ui.tables;
            const row = next.*;
            next.* += 1;
            v.response = if (n.id != null) ui.response(row, v) else .{};
            const p: Part = H.part(n, &ui.signals.state, v) orelse {
                const size = comptime flatten.count(n);
                @memset(ui.tree_row[row..][0..size], none);
                next.* = row + size;
                return;
            };
            const i = tb.t.push(parent, if (n.id) |name| .hash(name) else .none, &p.style);
            if (p.role) |r| tb.t.c.role[i] = @backingInt(r);
            ui.tree_row[row] = i;
            switch (n.kind) {
                .label => {
                    const span = tb.strings.add(p.content orelse spec_zig.labelBytes(n, &ui.signals.state));
                    const text_style = p.text orelse n.text_style orelse base.labelText(&th);
                    tb.t.c.text[i] = tb.tx.push(i, span, &text_style);
                },
                .row, .col => inline for (n.children) |c| ui.push(c, i, next, v),
                .checkbox, .slider => @compileError("ComptimePage builds rows, columns and labels; use base.ComptimeUi for checkboxes and sliders"),
            }
            tb.t.seal(i);
        }

        /// What `Interaction.response` reports for the widget at spec row `row`: while a widget
        /// is held, only it shows hover.
        fn response(ui: *const Self, row: u32, v: *const View) Response {
            const w: E.Widget = @fromBackingInt(@as(E.Index, @intCast(row)));
            const held = ui.pointer.pressed == w;
            const owned = ui.pointer.pressed == null or held;
            const under = E.at(&ui.rects, v.in.pointer[0], v.in.pointer[1]) == w;
            const clicked = if (v.event) |e| e == w else false;
            return .{ .hovered = under and owned, .held = held, .pressed = v.pressed == w, .clicked = clicked };
        }
    };
}

/// Spec nodes in `n`'s subtree that show text.
fn labelCount(comptime n: Spec) u32 {
    var k: u32 = @intFromBool(n.kind == .label);
    for (n.children) |c| k += labelCount(c);
    return k;
}

/// Depth-first row of the spec node with id `name`; a compile error if there is none.
pub fn rowOf(comptime n: Spec, comptime name: []const u8) u32 {
    comptime {
        @setEvalBranchQuota(10_000);
        var i: u32 = 0;
        return rowWalk(n, name, &i) orelse @compileError("no spec node '" ++ name ++ "'");
    }
}

fn rowWalk(comptime n: Spec, comptime name: []const u8, comptime next: *u32) ?u32 {
    const i = next.*;
    next.* += 1;
    if (n.id != null and std.mem.eql(u8, n.id.?, name)) return i;
    for (n.children) |c| if (rowWalk(c, name, next)) |r| return r;
    return null;
}

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example page: a toolbar with the trigger and a label, and the popover's panel with two
/// labels, in both front ends, in theme `th`. The tests and the golden images
/// (tools/golden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };

        pub const App = struct {
            open: bool = false,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{});
                _ = f.open(.none, toolbar_style);
                _ = trigger(f, &th, "details", &app.open, "Details");
                _ = base.label(f, &th, "Layer 0");
                f.close();
                if (begin(f, &th, "details", &app.open)) {
                    _ = base.label(f, &th, "Exposure 0.25");
                    _ = base.label(f, &th, "Gamma 2.2");
                    end(f);
                }
                f.close();
            }
        };

        pub const State = struct {
            open: bool = false,
            layer: []const u8 = "Layer 0",
            exposure: []const u8 = "Exposure 0.25",
        };
        pub const P = Popover(th, .details, .open);
        pub const spec = spec_zig.col(.{}, .{
            spec_zig.row(toolbar_style, .{ P.button("Details"), base.ct.label(th, .layer) }),
            P.layer(.{ base.ct.label(th, .exposure), base.ct.label(th, "Gamma 2.2") }),
        });
        pub const Ui = ComptimePage(State, spec, th, P);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

/// Input for `Example(.default)` at 800 x 600, one commented line per frame.
pub const replay = @embedFile("testdata/popover.replay");

/// The frames of `replay` kept as golden images, by name (tools/golden/ref/widgets/<name>.png).
pub const golden_frames = .{
    .{ "popover-rest", 0 },
    .{ "popover-hover", 1 },
    .{ "popover-open", 3 },
    .{ "popover-panel", 5 },
    .{ "popover-closed", 7 },
};

/// What tools/golden/ dumps: the page's harness over `replay`.
pub const golden = struct {
    pub const Run = Example(.default).Run;
    pub const src = replay;
    pub const frames = golden_frames;
};

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;
const Page = Example;

const Default = Page(.default);
var harness: Default.Run = .{};

test "Popover: the page agrees in both front ends, closed and open" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    const closed = try h.frame(&in);
    try testing.expectEqual(@as(u32, 6), closed.runtime.tree.len);
    h.app.open = true;
    h.ui.signals.set(.open, true);
    for (0..2) |_| {
        const out = try h.frame(&in);
        try testing.expectEqual(@as(u32, 10), out.runtime.tree.len);
    }
    // The panel hangs below the trigger.
    const t = (try h.frame(&in)).runtime.tree;
    const at = t.rect(t.find(.from("details")));
    const panel = t.rect(t.find(.from("details_panel")));
    try testing.expectEqual(at.x0, panel.x0);
    try testing.expectEqual(at.y1 + Theme.default.gap, panel.y0);
}

test "panelStyle: the theme's tokens, below the trigger" {
    const th: Theme = .default;
    const s = panelStyle(&th, .{ .x0 = 10, .y0 = 20, .x1 = 60, .y1 = 40 });
    try testing.expect(s.float);
    try testing.expectEqual([2]f32{ 10, 40 + th.gap }, s.offset);
    try testing.expectEqual(th.panel, s.fill);
    try testing.expectEqual(th.control_hot, s.border_color);
    try testing.expectEqual(@as(f32, 1), s.border);
    try testing.expectEqual(th.radius, s.radius);
    try testing.expectEqual([4]f32{ th.pad, th.pad, th.pad, th.pad }, s.pad);
    // The scrim is invisible and covers the viewport.
    const sc = scrimStyle(.{ 400, 300 });
    try testing.expect(sc.float);
    try testing.expectEqual(types.Color.transparent, sc.fill);
    try testing.expectEqual([2]types.Size{ .px(400), .px(300) }, sc.size);
}

/// Other tokens, for the restyling tests.
const light: Theme = .{ .panel = .rgb(240, 240, 240), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Popover: another theme restyles both front ends alike" {
    const th = light;
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = try S.h.frame(&in);
    S.h.app.open = true;
    S.h.ui.signals.set(.open, true);
    _ = try S.h.frame(&in);
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    const panel = t.find(.from("details_panel"));
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[panel].fill);
    try testing.expectEqual(t.rect(t.find(.from("details"))).y1 + 10, t.rect(panel).y0);
}

test "Popover: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var r: Replay = .{ .src = replay };
    var open: [12]bool = undefined;
    var rows: [12]u32 = undefined;
    var fills: [12]u32 = undefined;
    while (try r.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        try testing.expectEqual(h.app.open, h.ui.signals.state.open);
        open[k] = h.app.open;
        rows[k] = t.len;
        fills[k] = t.c.look[t.find(.from("details"))].fill;
        if (k == 3) {
            // The rects the replay's comments give.
            try testing.expectEqual(Rect{ .x0 = 8, .y0 = 8, .x1 = 83, .y1 = 42 }, t.rect(t.find(.from("details"))));
            try testing.expectEqual(Rect{ .x0 = 8, .y0 = 48, .x1 = 133, .y1 = 105 }, t.rect(t.find(.from("details_panel"))));
            try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 800, .y1 = 600 }, t.rect(t.find(.from("details_scrim"))));
        }
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, true, true, true, true, false, false, false, true, false }, &open);
    try testing.expectEqualSlices(u32, &.{ 6, 6, 6, 10, 10, 10, 10, 6, 6, 6, 10, 6 }, &rows);
    const c = Theme.default.controlFills();
    // Rest, hot, held, then hot on the release frame; under the scrim it is not hot.
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), c[1].bitsOf() }, fills[0..4]);
    try testing.expectEqual(c[0].bitsOf(), fills[4]);
}

test "golden_frames: name frames the replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 12);
}

test "dismiss, toggle, keyPressed: the behaviour as pure functions" {
    try testing.expect(dismiss(true, false, false));
    try testing.expect(!dismiss(true, true, false));
    try testing.expect(!dismiss(true, false, true));
    try testing.expect(!dismiss(false, false, false));
    try testing.expect(toggle(false, true) and !toggle(true, true) and toggle(true, false));
    const evs = [_]Input.Event{ .{ .kind = .release, .code = keys.escape }, .{ .kind = .press, .code = keys.enter, .mods = .{ .shift = true } } };
    const in: Input = .{ .events = &evs };
    try testing.expect(!keyPressed(&in, keys.escape));
    try testing.expect(keyPressed(&in, keys.enter));
    try testing.expectEqual(@as(u32, 0), keyCount(&in, keys.enter, .{}, true));
    try testing.expectEqual(@as(u32, 1), keyCount(&in, keys.enter, .{ .shift = true }, true));
}

/// Where a step of a scripted run points: the centre of a part's rect last frame, or a point.
const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null, open: bool };

/// Runs `script` through both front ends in theme `th`, aiming at last frame's rects, and
/// requires the open state after every step in both.
fn expectScript(comptime th: Theme, script: []const Step) !void {
    const S = struct {
        var h: Page(th).Run = .{};
    };
    const h = &S.h;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    for (script) |st| {
        in.pointer = switch (st.aim) {
            .at => |p| p,
            .part => |name| blk: {
                const r = last.rect(last.find(.hash(name)));
                break :blk .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
            },
        };
        in.buttons.left = st.left;
        in.events = &.{};
        if (st.key) |k| {
            ev[0] = .{ .kind = .press, .code = k };
            in.events = &ev;
        }
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(st.open, h.app.open);
        try testing.expectEqual(st.open, h.ui.signals.state.open);
    }
}

test "Popover: click opens; a press inside keeps it; a press outside or Escape closes" {
    try expectScript(.default, &.{
        .{ .aim = .{ .part = "details" }, .open = false }, // hover
        .{ .aim = .{ .part = "details" }, .left = true, .open = false }, // hold
        .{ .aim = .{ .part = "details" }, .open = true }, // click: open
        .{ .aim = .{ .part = "details_panel" }, .open = true },
        .{ .aim = .{ .part = "details_panel" }, .left = true, .open = true }, // press inside
        .{ .aim = .{ .part = "details_panel" }, .open = true },
        .{ .aim = .{ .at = .{ 380, 280 } }, .left = true, .open = false }, // press outside: closed
        .{ .aim = .{ .at = .{ 380, 280 } }, .open = false },
        .{ .aim = .{ .part = "details" }, .left = true, .open = false },
        .{ .aim = .{ .part = "details" }, .open = true }, // open again
        .{ .aim = .{ .part = "details" }, .left = true, .open = false }, // the trigger is under the scrim: closes
        .{ .aim = .{ .part = "details" }, .open = false }, // and its release is no click
        .{ .aim = .{ .part = "details" }, .left = true, .open = false },
        .{ .aim = .{ .part = "details" }, .open = true },
        .{ .aim = .{ .part = "details" }, .key = keys.escape, .open = false }, // Escape
        .{ .aim = .{ .part = "details" }, .key = keys.escape, .open = false }, // Escape when closed: nothing
    });
}

/// The export row of tree row `node`; `none` if it is not exported.
pub fn exportRow(e: *const a11y.Export, node: u32) u32 {
    for (0..e.len) |k| if (e.c.node[k] == node) return @intCast(k);
    return none;
}

var sem: [2]Semantic(64) = .{ .{}, .{} };

/// The accessibility export of the harness's last frame in each front end, with popover
/// `name`'s semantics.
fn exports(h: anytype, comptime name: []const u8, pair: anytype) [2]*const a11y.Export {
    const rt = pair.runtime;
    const cp = pair.comptime_;
    semantics(rt.tree, sem[0].begin(), name);
    semantics(cp.tree, sem[1].begin(), name);
    return .{
        sem[0].finish(rt.tree, rt.texts, h.ctx.strings[h.ctx.cur].buf),
        sem[1].finish(cp.tree, &h.ui.tables.tx, h.ui.tables.strings.buf),
    };
}

test "Popover: the panel is a dialog named by its trigger, which is expanded while it is open" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    var pair = try h.frame(&in);
    var e = exports(h, "details", pair);
    try testing.expect(sameSemantics(e[0], e[1]));
    var trig = exportRow(e[0], pair.runtime.tree.find(.from("details")));
    const trig_closed = e[0].c.state[trig];
    try testing.expectEqual(@backingInt(a11y.Role.button), e[0].c.role[trig]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true }), trig_closed);
    h.app.open = true;
    h.ui.signals.set(.open, true);
    _ = try h.frame(&in);
    pair = try h.frame(&in);
    e = exports(h, "details", pair);
    try testing.expect(sameSemantics(e[0], e[1]));
    trig = exportRow(e[0], pair.runtime.tree.find(.from("details")));
    const dialog = exportRow(e[0], pair.runtime.tree.find(.from("details_panel")));
    try testing.expectEqual(@backingInt(a11y.Role.dialog), e[0].c.role[dialog]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true, .expanded = true }), e[0].c.state[trig]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Details"), e[0].c.name_hash[dialog]);
    try testing.expectEqual(@as(f32, 0), e[0].c.value[dialog]);
    // Its two labels are its children; the scrim (no role) is not exported.
    try testing.expectEqual(@as(u32, 2), e[0].c.kids[dialog]);
    try testing.expectEqual(e[0].c.parent[dialog + 1], dialog);
}

test "check: a popover's open field must be a bool" {
    try testing.expectEqual(null, comptime checkOpen(Default.State, "details", "open"));
    const Bad = struct { open: u8 = 0 };
    try testing.expectEqualStrings("popover 'details': field 'open' must be a bool, not u8", comptime checkOpen(Bad, "details", "open").?);
    try testing.expect(comptime checkOpen(struct {}, "details", "shown") != null);
    try testing.expectEqual(null, comptime checkLabels(Default.State, Default.spec));
    const NoText = struct { open: bool = false };
    try testing.expect(comptime checkLabels(NoText, Default.spec) != null);
}

test "Popover: spec rows and the parts' ids" {
    try testing.expectEqual(9, comptime flatten.count(Default.spec));
    try testing.expectEqual(5, comptime rowOf(Default.spec, "details_scrim"));
    try testing.expectEqual(6, comptime rowOf(Default.spec, "details_panel"));
    try testing.expectEqualStrings("details_panel", Default.P.panel_name);
}

test {
    std.testing.refAllDecls(@This());
}
