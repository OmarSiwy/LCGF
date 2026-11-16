//! The semantic tree: what assistive technology sees of the node tree. It reads the tree's
//! `role` and `value` columns, adds its own column set beside them (rows are tree rows), and
//! exports a flat, platform-neutral tree for a bridge (AccessKit) outside the tiers to hand to
//! the OS. Tier 0: no allocator, no I/O; the caller carves every column.

const std = @import("std");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const none = types.none;
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;

/// What a node is to assistive technology: the roles the WAI-ARIA Authoring Practices patterns
/// use. One byte, stored in `Tree.Columns.role`. The first eight are `types.Role` with the same
/// values, so a `Style.role` written by a front end reads back as the same role here; the rest
/// are written to the column directly (`t.c.role[i] = @backingInt(Role.tab)`).
pub const Role = enum(u8) {
    // ---- types.Role: none is presentational (not exported), label is static text,
    //      image is ARIA img, text_input is ARIA textbox.
    none,
    group,
    label,
    button,
    checkbox,
    slider,
    image,
    text_input,
    // ---- simple widgets (button, link, checkbox, radio group, switch, slider, spinbutton,
    //      meter, window splitter patterns)
    link,
    radio,
    radio_group,
    @"switch",
    spin_button,
    meter,
    progress_bar,
    scroll_bar,
    separator,
    // ---- document structure (accordion, feed, disclosure patterns)
    heading,
    article,
    feed,
    list,
    list_item,
    // ---- composite widgets (combobox, listbox, menu, tabs, toolbar, tree view patterns)
    combobox,
    listbox,
    option,
    menu,
    menu_bar,
    menu_item,
    menu_item_checkbox,
    menu_item_radio,
    tab_list,
    tab,
    tab_panel,
    toolbar,
    tree,
    tree_item,
    // ---- grids and tables (grid, table, treegrid patterns)
    grid,
    tree_grid,
    table,
    row_group,
    row,
    cell,
    column_header,
    row_header,
    // ---- windows and messages (dialog, alert, alertdialog, tooltip patterns)
    dialog,
    alert_dialog,
    alert,
    tooltip,
    // ---- landmarks (landmark regions pattern; carousel and accordion use region)
    region,
    banner,
    navigation,
    main,
    complementary,
    content_info,
    form,
    search,
};

comptime {
    // `types.Role` is a prefix of `Role`, value for value.
    const core = @typeInfo(types.Role).@"enum";
    for (core.field_names, core.field_values) |name, v| {
        std.debug.assert(@backingInt(@field(Role, name)) == v);
    }
}

/// All ones for the roles that take their name from their content (WAI-ARIA 1.2 "name from
/// content", plus `label`, which is static text), zero for the rest. Indexed by the raw role
/// byte, so a stray byte reads zero instead of going out of bounds.
pub const from_content: [256]u32 = blk: {
    var m: [256]u32 = @splat(0);
    for ([_]Role{
        .label,     .button, .checkbox,  .link,               .radio,           .@"switch",
        .heading,   .option, .menu_item, .menu_item_checkbox, .menu_item_radio, .tab,
        .tree_item, .row,    .cell,      .column_header,      .row_header,      .tooltip,
    }) |r| m[@backingInt(r)] = 0xffff_ffff;
    break :blk m;
};

/// States a node reports, one bit each, in `Semantics.Columns.state`. `checked` and
/// `expanded` are meaningful only on roles that have them: `checked` on the checkable roles
/// (`checkable`), `expanded` where `expandable` is set (a disclosure button, a tree item, a
/// combobox), so a bridge can tell "collapsed" from "cannot expand".
pub const State = bitpack struct(u8) {
    checked: bool = false,
    expandable: bool = false,
    expanded: bool = false,
    selected: bool = false,
    disabled: bool = false,
    _: u3 = 0,

    pub inline fn bitsOf(st: State) u8 {
        return @bitCast(st);
    }
};

/// `State.checked` for the roles whose checked state is their `value` (as the core's checkbox
/// stores it: 1 checked, 0 not), zero for the rest. Indexed by the raw role byte.
pub const checkable: [256]u8 = blk: {
    var m: [256]u8 = @splat(0);
    for ([_]Role{ .checkbox, .radio, .@"switch", .menu_item_checkbox, .menu_item_radio }) |r|
        m[@backingInt(r)] = State.bitsOf(.{ .checked = true });
    break :blk m;
};

/// The accessibility column set: one row per tree row, beside `Tree.Columns`. Inputs are
/// written by the front end or the application after `push`; outputs by the passes below.
pub const Semantics = struct {
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        // ---- inputs, cleared by `clear` each frame
        /// Row of the node whose text names this one (`aria-labelledby`), or `none`.
        labelled_by: []u32,
        /// `State` bits the application sets; `states` adds what follows from the tree.
        state: []u8,

        // ---- outputs of `names`
        /// First text run (row in `Texts`) in the node's subtree, or `none`.
        first_text: []u32,
        /// Text run that names the node, or `none`.
        name: []u32,

        // ---- scratch of `flatten`
        /// Export row of the node, or of its nearest exported ancestor, or `none`.
        ix: []u32,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each. With a counting carver
    /// this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Semantics {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Resets the inputs for a new frame: no node is labelled by another.
    pub fn clear(s: *Semantics) void {
        @memset(s.c.labelled_by, none);
        @memset(s.c.state, 0);
    }
};

/// Accessible names, as text runs. A node is named by, in order: the text of the node it is
/// labelled by (its first text run), else its content (the first text run in its subtree) when
/// its role takes the name from content, else its own text run, else nothing.
///
/// Runs are pushed in tree order, so the smallest run index in a subtree is its first run; one
/// bottom-up sweep finds it. The bridge reads the run's bytes from `Texts` and `Strings`.
pub fn names(t: *const Tree, s: *Semantics) void {
    const c = &t.c;
    const n = t.len;
    const first = s.c.first_text;
    @memcpy(first[0..n], c.text[0..n]);
    // ponytail: the first run only; ARIA joins every text run of the content. Join spans in the
    // bridge if a name made of several runs is ever needed.
    var i = n;
    while (i > 1) {
        i -= 1;
        const p = c.parent[i];
        first[p] = @min(first[p], first[i]);
    }
    const last = s.cap - 1;
    for (0..n) |k| {
        const content = from_content[c.role[k]];
        const self = (first[k] & content) | (c.text[k] & ~content);
        const lb = s.c.labelled_by[k];
        // A mask, or an address select, between `self` and `first[lb]` compiles to a branch
        // around the load on Zig 0.18; the unpredictable hint keeps it a cmov (docs/CHECKS.md).
        const via = first[@min(lb, last)];
        s.c.name[k] = if (lb != none) blk: {
            @branchHint(.unpredictable);
            break :blk via;
        } else self;
    }
}

/// Completes `state` from the tree: a checkable role is checked when its `value` is not 0, and
/// a node inside a disabled node is disabled (as `aria-disabled` applies to descendants).
/// Adds bits, never clears them, so running it twice changes nothing.
pub fn states(t: *const Tree, s: *Semantics) void {
    const c = &t.c;
    const st = s.c.state;
    const disabled = State.bitsOf(.{ .disabled = true });
    // Parents come before children, so a parent's state is final when its children read it.
    // The root is its own parent: reading it back changes nothing.
    for (0..t.len) |k| {
        const on = -%@as(u8, @intFromBool(c.value[k] != 0));
        st[k] |= (checkable[c.role[k]] & on) | (st[c.parent[k]] & disabled);
    }
}

/// The semantic tree as flat arrays, the form a bridge hands to the platform: one row per
/// node with a role, in tree order (parents before children), parents as export rows.
/// Presentational nodes (`Role.none`) are left out and their children move up to the nearest
/// exported ancestor. Names are byte ranges in the frame's `Strings`.
pub const Export = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        /// Stable across frames: the node's `Id`, or for an anonymous node one derived from its
        /// exported parent's id and its position among that parent's exported children.
        id: []u32,
        /// Row in the tree.
        node: []u32,
        /// Export row of the parent; `none` for the root.
        parent: []u32,
        role: []u8,
        state: []u8,
        value: []f32,
        /// The name's bytes in the frame's `Strings`; 0 bytes when the node has no name.
        name_start: []u32,
        name_bytes: []u32,
        /// FNV-1a of the name's bytes, so a later frame compares names without this frame's
        /// `Strings`.
        name_hash: []u32,
        /// Snapped layout rect x0, y0, x1, y1, in logical pixels.
        rect: [4][]f32,
        /// Number of exported children.
        kids: []u32,
        /// Order-sensitive hash of the children's ids: changes when a child is added, removed
        /// or moved.
        kids_hash: []u32,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each, for a tree of `cap`
    /// nodes. With a counting carver this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Export {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
};

/// Writes the semantic tree of `t` to `out`. Run `names` and `states` first; `tx` and `strings`
/// are the frame's text runs and bytes the names point into. One forward sweep that writes
/// every row and advances by 0 or 1; `s.c.ix` maps tree rows to export rows on the way.
pub fn flatten(t: *const Tree, tx: *const Texts, strings: []const u8, s: *Semantics, out: *Export) void {
    std.debug.assert(out.cap >= t.len and s.cap >= t.len);
    const c = &t.c;
    const o = &out.c;
    const ix = s.c.ix;
    // Row `out.cap` is never a kept row (w < len <= cap). It stands in as the parent of nodes
    // with no exported parent, so their anonymous ids are numbered like any siblings'.
    const spare = out.cap;
    o.id[spare] = 0;
    o.kids[spare] = 0;
    o.kids_hash[spare] = 0;
    const last_run = tx.cap - 1;
    ix[0] = none; // the root's parent is itself: it reads `none` before writing its own row
    var w: u32 = 0;
    for (0..t.len) |k| {
        const keep = c.role[k] != 0;
        const par = ix[c.parent[k]];
        ix[k] = simd.selU(keep, w, par);
        const pi = @min(par, spare);
        const counts = keep;

        const tid = c.id[k];
        const derived = @backingInt(@as(types.Id, @fromBackingInt(o.id[pi])).with(o.kids[pi]));
        const id = simd.selU(tid != 0, tid, derived);
        const old_hash = o.kids_hash[pi];
        o.kids_hash[pi] = simd.selU(counts, (old_hash ^ id) *% 0x0100_0193, old_hash);
        o.kids[pi] += @intFromBool(counts);

        const run = s.c.name[k];
        const named = -%@as(u32, @intFromBool(run != none));
        const rr = @min(run, last_run);
        const start = tx.c.start[rr] & named;
        const bytes = tx.c.bytes[rr] & named;

        o.id[w] = id;
        o.node[w] = @intCast(k);
        o.parent[w] = par;
        o.role[w] = c.role[k];
        o.state[w] = s.c.state[k];
        o.value[w] = c.value[k];
        o.name_start[w] = start;
        o.name_bytes[w] = bytes;
        o.name_hash[w] = std.hash.Fnv1a_32.hash(strings[start..][0..bytes]);
        inline for (0..4) |e| o.rect[e][w] = c.rect[e][k];
        o.kids[w] = 0;
        o.kids_hash[w] = 0;
        w += @intFromBool(keep);
    }
    out.len = w;
}

const testing = std.testing;

/// A semantic column set of `cap` rows in a caller-owned buffer, for tests.
fn SemFixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Semantics.init(&counter, cap);
            break :blk counter.off;
        };
        fn init(f: *@This()) Semantics {
            var carver: mem.Carver = .{ .buf = &f.buf };
            var s = Semantics.init(&carver, cap);
            s.clear();
            return s;
        }
    };
}

/// A tree of `cap` rows in a caller-owned buffer, for tests.
fn TreeFixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tree.init(&counter, cap);
            break :blk counter.off;
        };
        fn init(f: *@This()) Tree {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return Tree.init(&carver, cap);
        }
    };
}

test "tree export: every role fits the tree's role column and the core roles keep their values" {
    try testing.expectEqual(1, @sizeOf(Role));
    try testing.expectEqual(@as(u8, 0), @backingInt(Role.none));
    try testing.expectEqual(@backingInt(types.Role.text_input), @backingInt(Role.text_input));
    try testing.expect(@typeInfo(Role).@"enum".field_names.len <= 256);

    var fx: TreeFixture(8) = .{};
    var t = fx.init();
    // A front end writes a core role through Style; a pattern role goes to the column.
    const root = t.push(0, .none, &.{ .role = .group });
    const tabs = t.push(root, .none, &.{});
    t.c.role[tabs] = @backingInt(Role.tab_list);
    const box = t.push(tabs, .none, &.{ .role = .checkbox });
    try testing.expectEqual(Role.group, @as(Role, @fromBackingInt(t.c.role[root])));
    try testing.expectEqual(Role.tab_list, @as(Role, @fromBackingInt(t.c.role[tabs])));
    try testing.expectEqual(Role.checkbox, @as(Role, @fromBackingInt(t.c.role[box])));
    // Every role survives a round trip through the u8 column.
    inline for (@typeInfo(Role).@"enum".field_values) |v| {
        t.c.role[box] = v;
        try testing.expectEqual(v, @backingInt(@as(Role, @fromBackingInt(t.c.role[box]))));
    }
}

test "tree export: names come from labels, from content for the roles that take it, else own text" {
    var fx: TreeFixture(16) = .{};
    var t = fx.init();
    var sx: SemFixture(16) = .{};
    var s = sx.init();
    // root(group) { button { icon, label "Save" }, checkbox { box, label "Bold" },
    //               label "Volume", slider { thumb }, group { label "Hint" }, label "Lone" }
    // Text runs are numbered in push order, as a front end pushes them.
    const root = t.push(0, .none, &.{ .role = .group });
    const button = t.push(root, .none, &.{ .role = .button });
    t.seal(t.push(button, .none, &.{ .role = .image }));
    const save = t.push(button, .none, &.{ .role = .label });
    t.c.text[save] = 0;
    t.seal(save);
    t.seal(button);
    const check = t.push(root, .none, &.{ .role = .checkbox });
    t.seal(t.push(check, .none, &.{}));
    const bold = t.push(check, .none, &.{ .role = .label });
    t.c.text[bold] = 1;
    t.seal(bold);
    t.seal(check);
    const volume = t.push(root, .none, &.{ .role = .label });
    t.c.text[volume] = 2;
    t.seal(volume);
    const slider = t.push(root, .none, &.{ .role = .slider });
    t.seal(t.push(slider, .none, &.{}));
    t.seal(slider);
    const group = t.push(root, .none, &.{ .role = .group });
    const hint = t.push(group, .none, &.{ .role = .label });
    t.c.text[hint] = 3;
    t.seal(hint);
    t.seal(group);
    const lone = t.push(root, .none, &.{ .role = .label });
    t.c.text[lone] = 4;
    t.seal(lone);
    t.seal(root);
    try t.check();

    s.c.labelled_by[slider] = volume;
    names(&t, &s);
    const n = s.c.name;
    try testing.expectEqual(0, n[button]); // from its label child
    try testing.expectEqual(0, n[save]);
    try testing.expectEqual(1, n[check]);
    try testing.expectEqual(2, n[slider]); // labelled by "Volume"
    try testing.expectEqual(2, n[volume]);
    try testing.expectEqual(4, n[lone]);
    // A group does not take its name from content; nor does an image without text.
    try testing.expectEqual(none, n[group]);
    try testing.expectEqual(none, n[root]);
    try testing.expectEqual(none, n[button + 1]);
    // The first run of every subtree, the root's included.
    try testing.expectEqual(0, s.c.first_text[root]);
    try testing.expectEqual(3, s.c.first_text[group]);
    try testing.expectEqual(none, s.c.first_text[slider]);

    // A pattern role written to the column follows its table entry: a tab takes its content.
    t.c.role[group] = @backingInt(Role.tab);
    s.clear();
    names(&t, &s);
    try testing.expectEqual(3, s.c.name[group]);
    try testing.expectEqual(none, s.c.name[slider]); // cleared: no longer labelled
}

test "tree export: states come from the application, checkable values and disabled ancestors" {
    var fx: TreeFixture(16) = .{};
    var t = fx.init();
    var sx: SemFixture(16) = .{};
    var s = sx.init();
    // root { checkbox(on), checkbox(off), switch(on), slider(0.5), panel(disabled) { button,
    //        row { radio(on) } }, tree_item(expandable, expanded, selected) }
    const root = t.push(0, .none, &.{ .role = .group });
    const on = t.push(root, .none, &.{ .role = .checkbox, .value = 1 });
    const off = t.push(root, .none, &.{ .role = .checkbox, .value = 0 });
    const sw = t.push(root, .none, &.{ .value = 1 });
    t.c.role[sw] = @backingInt(Role.@"switch");
    const slider = t.push(root, .none, &.{ .role = .slider, .value = 0.5 });
    const panel = t.push(root, .none, &.{ .role = .group });
    const button = t.push(panel, .none, &.{ .role = .button });
    const row = t.push(panel, .none, &.{});
    const radio = t.push(row, .none, &.{ .value = 1 });
    t.c.role[radio] = @backingInt(Role.radio);
    t.seal(row);
    t.seal(panel);
    const item = t.push(root, .none, &.{});
    t.c.role[item] = @backingInt(Role.tree_item);
    t.seal(root);
    try t.check();

    s.c.state[panel] = State.bitsOf(.{ .disabled = true });
    s.c.state[item] = State.bitsOf(.{ .expandable = true, .expanded = true, .selected = true });
    states(&t, &s);
    const got = struct {
        fn of(sem: *const Semantics, k: u32) State {
            return @bitCast(sem.c.state[k]);
        }
    }.of;
    try testing.expectEqual(State{ .checked = true }, got(&s, on));
    try testing.expectEqual(State{}, got(&s, off));
    try testing.expectEqual(State{ .checked = true }, got(&s, sw));
    // A slider's value is not a checked state.
    try testing.expectEqual(State{}, got(&s, slider));
    try testing.expectEqual(State{ .disabled = true }, got(&s, panel));
    try testing.expectEqual(State{ .disabled = true }, got(&s, button));
    try testing.expectEqual(State{ .disabled = true }, got(&s, row));
    try testing.expectEqual(State{ .disabled = true, .checked = true }, got(&s, radio));
    try testing.expectEqual(State{ .expandable = true, .expanded = true, .selected = true }, got(&s, item));
    try testing.expectEqual(State{}, got(&s, root));
    // Idempotent; and `clear` drops what the application set last frame.
    const before: [10]u8 = s.c.state[0..10].*;
    try testing.expectEqual(10, t.len);
    states(&t, &s);
    try testing.expectEqualSlices(u8, &before, s.c.state[0..t.len]);
    s.clear();
    states(&t, &s);
    try testing.expectEqual(State{}, got(&s, button));
    try testing.expectEqual(State{}, got(&s, item));
    try testing.expectEqual(State{ .checked = true }, got(&s, on));
}

/// A whole frame's worth of columns for the export tests: tree, text runs, bytes, the semantic
/// columns and two exports (this frame's and last frame's).
fn FrameFixture(comptime cap: u32) type {
    return struct {
        const Self = @This();
        buf: [bytes]u8 align(mem.column_align) = undefined,
        bytes_buf: [1024]u8 = undefined,
        t: Tree = undefined,
        tx: Texts = undefined,
        str: Strings = undefined,
        s: Semantics = undefined,
        out: [2]Export = undefined,

        fn carve(f: ?*Self, carver: *mem.Carver) void {
            const t = Tree.init(carver, cap);
            const tx = Texts.init(carver, cap);
            const s = Semantics.init(carver, cap);
            const out = [2]Export{ Export.init(carver, cap), Export.init(carver, cap) };
            if (f) |x| {
                x.t = t;
                x.tx = tx;
                x.s = s;
                x.out = out;
                x.str = .{ .buf = &x.bytes_buf };
            }
        }
        const bytes = blk: {
            @setEvalBranchQuota(40_000);
            var counter: mem.Carver = .{ .buf = null };
            carve(null, &counter);
            break :blk counter.off;
        };
        fn init(f: *Self) void {
            var carver: mem.Carver = .{ .buf = &f.buf };
            carve(f, &carver);
            f.s.clear();
        }
        /// Starts a new frame, as a front end does.
        fn reset(f: *Self) void {
            f.t.reset();
            f.tx.reset();
            f.str.reset();
            f.s.clear();
        }
        /// A text leaf with role label, as `Frame.text` makes one.
        fn text(f: *Self, parent: u32, str: []const u8) u32 {
            const n = f.t.push(parent, .none, &.{ .role = .label });
            f.t.c.text[n] = f.tx.push(n, f.str.add(str), &.{});
            f.t.seal(n);
            return n;
        }
        fn run(f: *Self, gen: u1) *Export {
            names(&f.t, &f.s);
            states(&f.t, &f.s);
            flatten(&f.t, &f.tx, f.str.buf[0..f.str.len], &f.s, &f.out[gen]);
            return &f.out[gen];
        }
        fn name(f: *const Self, e: *const Export, r: u32) []const u8 {
            return f.str.buf[e.c.name_start[r]..][0..e.c.name_bytes[r]];
        }
    };
}

test "tree export: flat arrays in tree order, presentational nodes skipped, parents remapped" {
    var f: FrameFixture(32) = .{};
    f.init();
    const t = &f.t;
    // root "app" { box { button "save" { label "Save" } }, checkbox "bold" (on) { mark, label "Bold" },
    //              label "Volume", slider "vol" (0.25, labelled by "Volume") }
    const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
    const box = t.push(root, .none, &.{});
    const save = t.push(box, types.Id.from("save"), &.{ .role = .button });
    _ = f.text(save, "Save");
    t.seal(save);
    t.seal(box);
    const bold = t.push(root, types.Id.from("bold"), &.{ .role = .checkbox, .value = 1 });
    t.seal(t.push(bold, .none, &.{}));
    _ = f.text(bold, "Bold");
    t.seal(bold);
    const volume = f.text(root, "Volume");
    const vol = t.push(root, types.Id.from("vol"), &.{ .role = .slider, .value = 0.25 });
    t.seal(vol);
    t.seal(root);
    try t.check();
    t.c.rect[2][vol] = 120;
    f.s.c.labelled_by[vol] = volume;

    const e = f.run(0);
    const o = &e.c;
    // Tree rows: 0 root, 1 box, 2 save, 3 "Save", 4 bold, 5 mark, 6 "Bold", 7 "Volume", 8 vol.
    try testing.expectEqual(7, e.len);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 4, 6, 7, 8 }, o.node[0..7]);
    try testing.expectEqualSlices(u32, &.{ none, 0, 1, 0, 3, 0, 0 }, o.parent[0..7]);
    const R = struct {
        fn b(r: Role) u8 {
            return @backingInt(r);
        }
    };
    try testing.expectEqualSlices(u8, &.{ R.b(.group), R.b(.button), R.b(.label), R.b(.checkbox), R.b(.label), R.b(.label), R.b(.slider) }, o.role[0..7]);
    try testing.expectEqualSlices(u32, &.{ 4, 1, 0, 1, 0, 0, 0 }, o.kids[0..7]);
    try testing.expectEqualStrings("", f.name(e, 0));
    try testing.expectEqualStrings("Save", f.name(e, 1));
    try testing.expectEqualStrings("Save", f.name(e, 2));
    try testing.expectEqualStrings("Bold", f.name(e, 3));
    try testing.expectEqualStrings("Volume", f.name(e, 5));
    try testing.expectEqualStrings("Volume", f.name(e, 6));
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Save"), o.name_hash[1]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash(""), o.name_hash[0]);
    try testing.expectEqual(State{ .checked = true }, @as(State, @bitCast(o.state[3])));
    try testing.expectEqual(0.25, o.value[6]);
    try testing.expectEqual(120, o.rect[2][6]);
    // Ids: the node's own, else derived from the exported parent and the position among its
    // exported children: "Save" is child 0 of save, "Volume" child 2 of the root.
    try testing.expectEqual(@backingInt(types.Id.from("app")), o.id[0]);
    try testing.expectEqual(@backingInt(types.Id.from("save")), o.id[1]);
    try testing.expectEqual(@backingInt(types.Id.from("save").with(0)), o.id[2]);
    try testing.expectEqual(@backingInt(types.Id.from("bold").with(0)), o.id[4]);
    try testing.expectEqual(@backingInt(types.Id.from("app").with(2)), o.id[5]);
    // Ids are unique, and every parent is an earlier row.
    for (0..e.len) |a| {
        for (0..a) |b| try testing.expect(o.id[a] != o.id[b]);
        try testing.expect(a == 0 or o.parent[a] < a);
    }
}
