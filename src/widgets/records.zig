//! Records (tier 2): a frame built from a node table, as an application that keeps its UI as
//! data (Schemify's `ui.records`) builds it every frame through the runtime front end. One row
//! per node in depth-first order, in columns the caller owns: its kind, its depth, its text and
//! the index of its look (a `Style` and a `TextStyle`) in a table of looks the caller derives
//! from its theme or its run-time tokens. `build` walks the rows once, opening and closing the
//! containers as the depth moves, and calls each kind's widget, its `…Face` variant taking the
//! row's look. Per-node state is columns too, indexed by row.
//!
//! The tests here and the benchmark scene bench/scenes/data.zig run `scene`, a 450-node editor
//! of every kind, in a dock.

const std = @import("std");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const base = @import("base.zig");
const button = @import("button.zig");
const toggle = @import("toggle.zig");
const textfield = @import("textfield.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");
const tabs = @import("tabs.zig");
const dock = @import("dock.zig");
const dialog = @import("dialog.zig");
const popover = @import("popover.zig");
const icon = @import("icon.zig");
const checkbox = @import("checkbox.zig");
const switch_zig = @import("switch.zig");
const slider = @import("slider.zig");
const radio = @import("radio.zig");
const progress = @import("progress.zig");
const separator = @import("separator.zig");
const toolbar = @import("toolbar.zig");
const statusbar = @import("statusbar.zig");
const splitter = @import("splitter.zig");
const menu = @import("menu.zig");
const menubar = @import("menubar.zig");
const label = @import("label.zig");
const Id = types.Id;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Theme = base.Theme;

/// What a row builds. Containers hold the rows after them that are deeper; a `split` puts its
/// first child in the first pane and the rest in the second, `tabs` gives each child a tab
/// (titled by the child's text) and a panel, a `dock` gives its children the panes in
/// `dock.Pane` order (one child: the centre; two: left and centre; and so on). A `dialog` and
/// a `popup` build their children in an overlay after the rest of the page, while the row's
/// `on` is set; a `popup` row also builds its trigger in place, a `menu` its trigger (and its
/// list in the overlay pass), a `menubar` its bar (and its menus).
pub const Kind = enum(u8) {
    row,
    col,
    split,
    menu,
    menubar,
    button,
    toggle,
    field,
    list,
    tree,
    tabs,
    dock,
    dialog,
    popup,
    label,
    icon,
    prose,
    checkbox,
    switch_,
    slider,
    radio,
    progress,
    separator,
    toolbar,
    statusbar,

    /// Whether rows deeper than this one are its children.
    pub fn container(k: Kind) bool {
        return switch (k) {
            .row, .col, .split, .tabs, .dock, .dialog, .popup => true,
            else => false,
        };
    }
};
pub const kind_count = @typeInfo(Kind).@"enum".field_names.len;

/// One look: a node's style and, where it draws text, the text's.
pub const Look = struct { style: Style = .{}, text: TextStyle = .{} };

/// The node table, one row per node in depth-first order. Row `r`'s id is `base.with(r)`
/// (`build`'s `base`), so the rows keep their ids while the table keeps its shape.
pub const Table = struct {
    kind: []const Kind,
    /// 0 for the rows at the top; a child is one deeper than its container.
    depth: []const u8,
    /// A label's, button's or tab's text, a field's hint; "" for none.
    text: []const []const u8,
    /// An index into `build`'s `looks`.
    look: []const u8,

    pub fn len(t: Table) u32 {
        return @intCast(t.kind.len);
    }

    /// The row after the last of row `r`'s descendants.
    pub fn subtreeEnd(t: Table, r: u32) u32 {
        var e = r + 1;
        while (e < t.len() and t.depth[e] > t.depth[r]) e += 1;
        return e;
    }
};

/// The text field each `field` row edits.
pub const Field = textfield.Text(32);
/// The tree view each `tree` row shows: `tree_labels` at `tree_depths`.
pub const TreeState = tree.State(tree_labels.len);

/// Per-row state, each column as long as the table (a row uses the columns its kind reads):
/// `on` for a toggle, checkbox, switch, dialog or popup; `value` for a slider, progress bar or
/// split; `sel` for a list, radio group, tab set or toolbar. The menus are one of each per
/// page (their names are comptime), so their state is one value.
pub const State = struct {
    on: []bool,
    value: []f32,
    sel: []u32,
    fields: []Field,
    trees: []TreeState,
    docks: []dock.State,
    menu: *menu.MenuState,
    bar: *menubar.BarState,
};

pub const list_items = [_][]const u8{ "Resistor", "Capacitor", "Inductor", "Diode" };
pub const tree_labels = [_][]const u8{ "top", "amp", "bias", "out" };
pub const tree_depths = [_]u8{ 0, 1, 2, 1 };
pub const radio_captions = [_][]const u8{ "DC", "AC", "Transient" };
pub const tool_titles = [_][]const u8{ "Wire", "Probe", "Run" };
pub const menu_def: menu.Def = .{ .items = &.{ "copy", "paste", "delete" } };
pub const menu_texts = [_][]const u8{ "Copy", "Paste", "Delete" };
pub const bar_def: menubar.BarDef = .{ .names = &.{ "file", "edit" }, .menus = &.{ menu.file_menu, menubar.edit_menu } };
pub const bar_texts = [_][]const u8{ "File", "Edit" };
pub const bar_items = [_][]const []const u8{ &menu.file_texts, &.{ "Undo", "Redo" } };

/// Each kind's look in theme `th`: the style and text its theme function uses. A table whose
/// `look` column is the kind's index draws each widget as its theme function does.
pub fn kindLooks(th: *const Theme) [kind_count]Look {
    const text = base.labelText(th);
    var out: [kind_count]Look = @splat(.{ .text = text });
    const at = struct {
        fn f(o: *[kind_count]Look, k: Kind) *Style {
            return &o[@backingInt(k)].style;
        }
    }.f;
    at(&out, .row).* = .{ .dir = .x, .size = .{ .fill, .fit }, .gap = th.gap, .cross = .center };
    at(&out, .col).* = .{ .size = .{ .fill, .fit }, .gap = th.gap, .pad = @splat(th.gap), .fill = th.panel };
    at(&out, .split).* = splitter.containerStyle(th, .x);
    at(&out, .menu).* = base.buttonStyle(th);
    at(&out, .menubar).* = menubar.barStyle(th);
    at(&out, .button).* = base.buttonStyle(th);
    at(&out, .toggle).* = base.buttonStyle(th);
    at(&out, .field).* = textfield.fieldStyle(th, false, 0);
    at(&out, .list).* = list.listStyle(th);
    at(&out, .tree).* = tree.treeStyle(th);
    at(&out, .tabs).* = tabs.setStyle(th);
    at(&out, .dock).* = dock.rootStyle(th);
    at(&out, .dialog).* = dialog.panelStyle(th);
    at(&out, .popup).* = popover.panelStyle(th, .{});
    at(&out, .label).* = label.labelStyle(th);
    at(&out, .icon).* = icon.style(th, .{});
    at(&out, .prose).* = .{ .size = .{ .fill, .fit }, .role = .label };
    out[@backingInt(Kind.prose)].text.wrap = true;
    at(&out, .checkbox).* = base.checkboxStyle(th);
    at(&out, .switch_).* = switch_zig.switchStyle(th);
    at(&out, .slider).* = base.sliderTrack(th);
    at(&out, .radio).* = radio.groupStyle(th);
    at(&out, .progress).* = progress.trackStyle(th);
    at(&out, .separator).* = separator.style(th, .horizontal);
    at(&out, .toolbar).* = toolbar.barStyle(th);
    at(&out, .statusbar).* = statusbar.barStyle(th);
    return out;
}

/// The deepest nesting `build` follows.
pub const max_depth = 32;

/// An open container while the rows are walked.
const Open = struct {
    row: u32,
    kind: Kind,
    children: u8 = 0,
    dk: dock.Dock = undefined,
    panes: [5]dock.Pane = undefined,
};

/// Builds the table's rows into `f`, at the depth `f` is open at (the page's root, so the
/// overlays float over everything): one pass over the rows, then one over the overlays.
pub fn build(f: *Frame, th: *const Theme, id: Id, t: Table, looks: []const Look, st: State) void {
    walk(f, th, id, t, looks, st, 0, t.len());
    for (0..t.len()) |i| {
        const r: u32 = @intCast(i);
        const look = looks[t.look[r]];
        switch (t.kind[r]) {
            // The row's look styles the trigger or the bar; the lists keep the theme's.
            .menu => _ = menu.showFace(f, th, "menu", menu_def, st.menu, &menu_texts, menu.listStyle(th, .{}), look.text),
            .menubar => menubar.menusFace(f, th, "bar", bar_def, st.bar, &bar_items, menu.listStyle(th, .{}), look.text),
            .dialog => if (dialog.beginFace(f, th, "dialog", &st.on[r], look.style, dialog.dim)) {
                walk(f, th, id, t, looks, st, r + 1, t.subtreeEnd(r));
                dialog.end(f);
            },
            .popup => if (popover.beginFace(f, th, "popup", &st.on[r], look.style)) {
                walk(f, th, id, t, looks, st, r + 1, t.subtreeEnd(r));
                popover.end(f);
            },
            else => {},
        }
    }
}

/// Builds rows `lo` to `hi` (a whole number of subtrees), skipping the overlays' children.
fn walk(f: *Frame, th: *const Theme, id: Id, t: Table, looks: []const Look, st: State, lo: u32, hi: u32) void {
    var stack: [max_depth]Open = undefined;
    var top: u32 = 0;
    var r = lo;
    while (r < hi) {
        const d = t.depth[r];
        while (top > 0 and t.depth[stack[top - 1].row] >= d) {
            top -= 1;
            closeOpen(f, &stack[top]);
        }
        if (top > 0) beforeChild(f, th, id, st, &stack[top - 1]);
        const k = t.kind[r];
        const look = looks[t.look[r]];
        const rid = id.with(r);
        const str = t.text[r];
        switch (k) {
            .row, .col => _ = f.open(rid, look.style),
            .split => splitter.openFace(f, th, rid, .x, &st.value[r], look.style),
            .tabs => {
                var ids: [8]Id = undefined;
                var titles: [8][]const u8 = undefined;
                var n: u32 = 0;
                var c = r + 1;
                const end = t.subtreeEnd(r);
                while (c < end and n < ids.len) : (c = t.subtreeEnd(c)) {
                    ids[n] = id.with(c).with(1);
                    titles[n] = t.text[c];
                    n += 1;
                }
                tabs.openFace(f, th, ids[0..n], &st.sel[r], titles[0..n], look.style, look.text);
            },
            .dock => {
                var n: u32 = 0;
                var c = r + 1;
                const end = t.subtreeEnd(r);
                while (c < end) : (c = t.subtreeEnd(c)) n += 1;
                const panes: dock.Panes = .{ .left = n > 1, .right = n > 2, .top = n > 3, .bottom = n > 4 };
                stack[top] = .{ .row = r, .kind = k, .dk = dock.openFace(f, th, rid, &st.docks[r], panes, look.style) };
                var p: u32 = 0;
                inline for (0..5) |q| if (dock.has(panes, @fromBackingInt(@intCast(q)))) {
                    stack[top].panes[p] = @fromBackingInt(@intCast(q));
                    p += 1;
                };
            },
            .dialog => {},
            .popup => _ = popover.trigger(f, th, "popup", &st.on[r], str),
            .menu => _ = button.buttonFace(f, th, .from("menu"), str, look.text, look.style),
            .menubar => menubar.barFace(f, th, "bar", bar_def, st.bar, &bar_texts, look.style, look.text),
            .button => _ = button.buttonFace(f, th, rid, str, look.text, look.style),
            .toggle => _ = toggle.toggleFace(f, th, rid, &st.on[r], str, look.style),
            .field => _ = textfield.textfieldFace(f, th, rid, &st.fields[r], str, look.style),
            .list => _ = list.listFace(f, th, rid, &list_items, &st.sel[r], look.style, look.text),
            .tree => _ = tree.treeFace(f, th, rid, tree_labels.len, &tree_labels, &tree_depths, &st.trees[r], look.style, look.text),
            .label, .prose => _ = f.textStyled(str, look.text, look.style),
            .icon => _ = icon.iconFace(f, look.style),
            .checkbox => _ = checkbox.checkboxFace(f, th, rid, &st.on[r], str, look.style),
            .switch_ => _ = switch_zig.switchFace(f, th, rid, &st.on[r], str, look.style),
            .slider => _ = slider.sliderFace(f, th, rid, &st.value[r], 0, 1, look.style),
            .radio => _ = radio.radioFace(f, th, rid, &st.sel[r], &radio_captions, look.style),
            .progress => _ = progress.progressFace(f, th, st.value[r], look.style),
            .separator => _ = separator.separatorFace(f, look.style),
            .toolbar => {
                const ids = [_]Id{ rid.with(1), rid.with(2), rid.with(3) };
                _ = toolbar.barFace(f, th, &ids, &tool_titles, &st.sel[r], look.style, look.text);
            },
            .statusbar => _ = statusbar.barFace(f, &.{str}, look.style, look.text),
        }
        if (k.container() and k != .dialog and k != .popup) {
            std.debug.assert(top < max_depth);
            if (k != .dock) stack[top] = .{ .row = r, .kind = k };
            top += 1;
        }
        // An overlay's children are built in `build`'s second pass.
        r = if (k == .dialog or k == .popup) t.subtreeEnd(r) else r + 1;
    }
    while (top > 0) {
        top -= 1;
        closeOpen(f, &stack[top]);
    }
}

/// What a container does before each child: a split's handle before its second, a tab's panel
/// and a dock's pane before each.
fn beforeChild(f: *Frame, th: *const Theme, id: Id, st: State, o: *Open) void {
    defer o.children +|= 1;
    switch (o.kind) {
        .split => if (o.children == 1) splitter.handle(f, th, id.with(o.row), .x, st.value[o.row]),
        .tabs => {
            if (o.children > 0) f.close();
            _ = tabs.panel(f, th, st.sel[o.row], o.children);
        },
        .dock => o.dk.pane(f, o.panes[@min(o.children, 4)]),
        else => {},
    }
}

fn closeOpen(f: *Frame, o: *Open) void {
    switch (o.kind) {
        .split => splitter.close(f),
        .tabs => {
            if (o.children > 0) f.close();
            tabs.close(f);
        },
        .dock => o.dk.close(f),
        else => f.close(),
    }
}

// ---- the scene -------------------------------------------------------------------------------

const Rec = struct { Kind, u8, []const u8 };

/// An editor of every kind in a dock under a menu bar and a toolbar, 450 nodes in all.
pub const scene: Table = blk: {
    @setEvalBranchQuota(100_000);
    var recs: []const Rec = &.{
        .{ .col, 0, "" },
        .{ .menubar, 1, "" },
        .{ .toolbar, 1, "" },
        .{ .dock, 1, "" },
        // left: the library
        .{ .col, 2, "Library" },
        .{ .tree, 3, "" },
        .{ .list, 3, "" },
    };
    for (0..10) |i| recs = recs ++ &[_]Rec{
        .{ .row, 3, "" },
        .{ .icon, 4, "" },
        .{ .label, 4, std.fmt.comptimePrint("{c}{d}", .{ "RCLDQV"[i % 6], i / 6 + 1 }) },
        .{ .toggle, 4, "Show" },
    };
    // top: tabs of open schematics
    recs = recs ++ &[_]Rec{.{ .tabs, 2, "" }};
    for ([_][]const u8{ "amp.sch", "bias.sch", "top.sch" }) |name| recs = recs ++ &[_]Rec{
        .{ .col, 3, name },
        .{ .label, 4, name },
    };
    // centre: the properties split from the notes
    recs = recs ++ &[_]Rec{
        .{ .split, 2, "" },
        .{ .col, 3, "" },
        .{ .label, 4, "Properties" },
        .{ .separator, 4, "" },
    };
    for (0..12) |i| recs = recs ++ &[_]Rec{
        .{ .row, 4, "" },
        .{ .label, 5, ([_][]const u8{ "Name", "Value", "Model", "Width", "Length", "Fingers", "Temp", "Corner", "Mult", "Area", "Perim", "Seed" })[i] },
        .{ .field, 5, "value" },
        .{ .checkbox, 5, "Lock" },
        .{ .slider, 5, "" },
    };
    recs = recs ++ &[_]Rec{
        .{ .row, 4, "" },
        .{ .button, 5, "Apply" },
        .{ .button, 5, "Reset" },
        .{ .switch_, 5, "Live" },
        .{ .col, 3, "" },
        .{ .prose, 4, "Notes: the amplifier is biased at half the supply, and its output drives the next stage through a coupling capacitor." },
        .{ .radio, 4, "" },
        .{ .progress, 4, "" },
        .{ .separator, 4, "" },
        .{ .row, 4, "" },
        .{ .menu, 5, "Actions" },
        .{ .popup, 5, "Info" },
        .{ .label, 6, "Simulator idle" },
        .{ .dialog, 4, "" },
        .{ .label, 5, "Discard changes?" },
        .{ .button, 5, "Discard" },
    };
    // bottom: the log
    recs = recs ++ &[_]Rec{.{ .col, 2, "" }};
    for (0..20) |i| recs = recs ++ &[_]Rec{.{ .label, 3, std.fmt.comptimePrint("[{d:0>2}] {s}", .{ i, ([_][]const u8{ "netlist written", "ngspice started", "op converged", "tran 0..1ms", "step 1e-6", "probe out", "probe in", "done", "0 warnings", "0 errors" })[i % 10] }) }};
    // right: the inspector
    recs = recs ++ &[_]Rec{.{ .col, 2, "" }};
    for (0..14) |i| recs = recs ++ &[_]Rec{
        .{ .row, 3, "" },
        .{ .label, 4, ([_][]const u8{ "Vdd", "Vss", "Ibias", "Vout", "Vin", "Gain", "BW", "PM", "GM", "THD", "PSRR", "CMRR", "Noise", "Slew" })[i] },
        .{ .progress, 4, "" },
        .{ .button, 4, "Plot" },
    };
    recs = recs ++ &[_]Rec{.{ .statusbar, 1, "Ready" }};
    var kinds: [recs.len]Kind = undefined;
    var depths: [recs.len]u8 = undefined;
    var texts: [recs.len][]const u8 = undefined;
    var looks: [recs.len]u8 = undefined;
    for (recs, 0..) |rec, i| {
        kinds[i] = rec[0];
        depths[i] = rec[1];
        texts[i] = rec[2];
        looks[i] = @backingInt(rec[0]);
    }
    const k = kinds;
    const d = depths;
    const x = texts;
    const l = looks;
    break :blk .{ .kind = &k, .depth = &d, .text = &x, .look = &l };
};

/// State for `scene`, in static memory (the scene's rows, at their defaults; splits at half).
pub fn SceneState(comptime n: usize) type {
    return struct {
        on: [n]bool = @splat(false),
        value: [n]f32 = @splat(0.5),
        sel: [n]u32 = @splat(0),
        fields: [n]Field = @splat(.{}),
        trees: [n]TreeState = @splat(.{ .expanded = .{ true, true, false, false } }),
        docks: [n]dock.State = @splat(.{}),
        menu: menu.MenuState = .{},
        bar: menubar.BarState = .{},

        pub fn state(s: *@This()) State {
            return .{ .on = &s.on, .value = &s.value, .sel = &s.sel, .fields = &s.fields, .trees = &s.trees, .docks = &s.docks, .menu = &s.menu, .bar = &s.bar };
        }
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const context = @import("../runtime/context.zig");
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;
const a11y = @import("../a11y/tree.zig");
const theme_zig = @import("../theme/theme.zig");
const ThemeTable = @import("../theme/table.zig").ThemeTable;

const scene_limits: context.Limits = .{ .nodes = 640, .texts = 400, .customs = 1, .strings = 16 * 1024, .depth = max_depth };
const page_id: Id = .from("page");

/// The scene in a static context, its state at the defaults.
const Page = struct {
    buf: [context.Context.requiredBytes(scene_limits)]u8 align(mem.column_align) = undefined,
    ctx: context.Context = undefined,
    st: SceneState(scene.kind.len) = .{},

    fn init(p: *Page) !void {
        p.st = .{};
        p.ctx = try .init(&p.buf, scene_limits);
    }

    fn frame(p: *Page, in: *const Input, th: *const Theme, looks: []const Look) context.Output {
        var f = p.ctx.begin(in);
        build(&f, th, page_id, scene, looks, p.st.state());
        return f.end(.{});
    }
};

var test_page: Page = .{};

test "scene: about 450 nodes of all 25 kinds, every limit kept" {
    var seen: [kind_count]bool = @splat(false);
    for (scene.kind) |k| seen[@backingInt(k)] = true;
    try testing.expect(std.mem.allEqual(bool, &seen, true));
    const p = &test_page;
    try p.init();
    const th: Theme = .default;
    const looks = kindLooks(&th);
    const out = p.frame(&.{ .viewport = .{ 1280, 800 } }, &th, &looks);
    try testing.expect(out.status.ok());
    try testing.expect(out.tree.len >= 400 and out.tree.len <= 500);
}

test "build: a token changed at run time shows on the next frame, nothing else rebuilt" {
    const p = &test_page;
    try p.init();
    var tokens: ThemeTable(theme_zig.Tokens) = .{};
    var in: Input = .{ .viewport = .{ 1280, 800 } };
    var seen = tokens.generation;
    var out: context.Output = undefined;
    var frames: u32 = 0;
    // The host's loop: a frame when the input, a signal or the table changed.
    for (0..4) |_| {
        in.redraw = tokens.changedSince(seen);
        if (!p.ctx.needsFrame(&in)) continue;
        seen = tokens.generation;
        const th = theme_zig.widgets(&tokens.values);
        const looks = kindLooks(&th);
        out = p.frame(&in, &th, &looks);
        frames += 1;
    }
    try testing.expectEqual(2, frames); // the first frame and its settle frame, then idle
    const len = out.tree.len;
    const root = out.tree.find(page_id.with(0));
    const root_fill = out.tree.c.look[root].fill;
    const dock_x = out.tree.rect(out.tree.find(page_id.with(3))).x0;
    var palette = tokens.values.palette;
    palette[@backingInt(theme_zig.Role.surface)] = .rgb(200, 30, 30);
    tokens.set(.palette, palette);
    var space = tokens.values.space;
    space[@backingInt(theme_zig.Step.md)] = 20;
    tokens.set(.space, space);
    in.redraw = tokens.changedSince(seen);
    try testing.expect(p.ctx.needsFrame(&in));
    const th = theme_zig.widgets(&tokens.values);
    const looks = kindLooks(&th);
    out = p.frame(&in, &th, &looks);
    try testing.expectEqual(types.Color.rgb(200, 30, 30).bitsOf(), out.tree.c.look[root].fill);
    try testing.expect(out.tree.c.look[root].fill != root_fill);
    // The root column's padding is the gap, `space.md`: 6 then 20.
    try testing.expectEqual(dock_x + 14, out.tree.rect(out.tree.find(page_id.with(3))).x0);
    try testing.expectEqual(len, out.tree.len);
}

test "build: the data-built tree names its widgets and gives them their roles" {
    const p = &test_page;
    try p.init();
    const th: Theme = .default;
    const looks = kindLooks(&th);
    const out = p.frame(&.{ .viewport = .{ 1280, 800 } }, &th, &looks);
    const S = struct {
        const Parts = struct { s: a11y.Semantics, e: a11y.Export };
        fn carve(c: *mem.Carver) Parts {
            return .{ .s = .init(c, scene_limits.nodes), .e = .init(c, scene_limits.nodes) };
        }
        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = carve(&counter);
            break :blk counter.off;
        };
        var buf: [bytes]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &S.buf };
    var parts = S.carve(&carver);
    const strings = &p.ctx.strings[p.ctx.cur];
    parts.s.clear();
    a11y.names(out.tree, &parts.s);
    a11y.states(out.tree, &parts.s);
    a11y.flatten(out.tree, &p.ctx.texts[p.ctx.cur], strings.buf[0..strings.len], &parts.s, &parts.e);
    const e = &parts.e;
    const Want = struct { a11y.Role, bool };
    var checked: u32 = 0;
    // The closed dialog's and popup's children are not built.
    var closed: [scene.kind.len]bool = @splat(false);
    for (0..scene.len()) |i| if (scene.kind[i] == .dialog or scene.kind[i] == .popup) {
        for (i + 1..scene.subtreeEnd(@intCast(i))) |c| closed[c] = true;
    };
    for (0..scene.len()) |i| {
        if (closed[i]) continue;
        const r: u32 = @intCast(i);
        const want: ?Want = switch (scene.kind[r]) {
            .button => .{ .button, true },
            .toggle => .{ .toggle_button, true },
            .checkbox => .{ .checkbox, true },
            .switch_ => .{ .@"switch", true },
            .field => .{ .text_input, false },
            .list => .{ .listbox, false },
            .tree => .{ .tree, false },
            .slider => .{ .slider, false },
            .radio => .{ .radio_group, false },
            else => null,
        };
        const w = want orelse continue;
        const id = @backingInt(page_id.with(r));
        const row = for (0..e.len) |k| {
            if (e.c.id[k] == id) break k;
        } else return error.NotExported;
        try testing.expectEqual(@backingInt(w[0]), e.c.role[row]);
        if (w[1]) try testing.expectEqualStrings(scene.text[r], strings.buf[e.c.name_start[row]..][0..e.c.name_bytes[row]]);
        checked += 1;
    }
    // And each tab is a tab named by its title.
    const tab_row = std.mem.indexOfScalar(Kind, scene.kind, .tabs).?;
    var c: u32 = @intCast(tab_row + 1);
    while (scene.depth[c] > scene.depth[tab_row]) : (c = scene.subtreeEnd(c)) {
        const id = @backingInt(page_id.with(c).with(1));
        const row = for (0..e.len) |k| {
            if (e.c.id[k] == id) break k;
        } else return error.NotExported;
        try testing.expectEqual(@backingInt(a11y.Role.tab), e.c.role[row]);
        try testing.expectEqualStrings(scene.text[c], strings.buf[e.c.name_start[row]..][0..e.c.name_bytes[row]]);
        checked += 1;
    }
    try testing.expect(checked > 50);
}
