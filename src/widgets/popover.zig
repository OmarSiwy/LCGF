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
pub const Part = struct { style: Style, role: ?a11y.Role = null };

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
        const f = spec.bind orelse return "a label without a field";
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
        pub fn button(comptime text: @EnumLiteral()) Spec {
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

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
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
            if (comptime is.named(panel)) return .{ .style = panelStyle(&th, v.last.of(id)) };
            return plainPart(th, n, v.response);
        }
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The scrim: a transparent float over the whole viewport.
pub fn scrimStyle(viewport: [2]f32) Style {
    return .{ .float = true, .size = .{ .px(viewport[0]), .px(viewport[1]) } };
}

/// The panel, floating below the trigger's rect `at` (last frame's).
pub fn panelStyle(th: *const Theme, at: Rect) Style {
    _ = th;
    return .{ .float = true, .offset = .{ at.x0, at.y1 } };
}

/// The style of a row no overlay hook claims: a label as specified, a container with an id
/// (a button) filled by its state, anything else as specified.
pub fn plainPart(comptime th: Theme, comptime n: Spec, r: Response) Part {
    var s = n.style;
    if (n.kind != .label and n.id != null) s.fill = base.buttonFill(&th, r);
    return .{ .style = s };
}

// ---- runtime front end ------------------------------------------------------------------------

/// The trigger: a button named `name` showing `text`.
pub fn trigger(f: *Frame, th: *const Theme, comptime name: []const u8, open: *bool, text: []const u8) Response {
    _ = open;
    return base.button(f, th, .from(name), text);
}

/// Opens the scrim and the panel of popover `name` if it is open, and returns whether it did;
/// the caller then adds the content and calls `end`. Call it at the root's depth, after the
/// rest of the page, so the panel is drawn on top.
pub fn begin(f: *Frame, th: *const Theme, comptime name: []const u8, open: *bool) bool {
    if (!open.*) return false;
    _ = f.open(.from(partName(name, "scrim")), scrimStyle(f.in.viewport));
    const p = f.open(.from(partName(name, "panel")), panelStyle(th, f.lastRect(.from(name))));
    _ = p;
    return true;
}

/// Closes the panel and the scrim `begin` opened.
pub fn end(f: *Frame) void {
    f.close();
    f.close();
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
        const string_bytes = 1024;
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
            var v: View = .{ .in = in, .last = &ui.last, .event = event, .pressed = pressed };
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
                    const span = tb.strings.add(@field(ui.signals.state, n.bind.?));
                    tb.t.c.text[i] = tb.tx.push(i, span, &base.labelText(&th));
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

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// The test page: a toolbar with the trigger and a label, and the popover's panel with two
/// labels, in both front ends.
fn Page(comptime th: Theme) type {
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
            details_text: []const u8 = "Details",
            layer: []const u8 = "Layer 0",
            exposure: []const u8 = "Exposure 0.25",
            gamma: []const u8 = "Gamma 2.2",
        };
        pub const P = Popover(th, .details, .open);
        pub const spec = spec_zig.col(.{}, .{
            spec_zig.row(toolbar_style, .{ P.button(.details_text), base.ct.label(th, .layer) }),
            P.layer(.{ base.ct.label(th, .exposure), base.ct.label(th, .gamma) }),
        });
        pub const Ui = ComptimePage(State, spec, th, P);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

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
    try testing.expectEqual(at.y1, panel.y0);
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
