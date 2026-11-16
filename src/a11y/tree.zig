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

/// The accessibility column set: one row per tree row, beside `Tree.Columns`. Inputs are
/// written by the front end or the application after `push`; outputs by the passes below.
pub const Semantics = struct {
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        // ---- inputs, cleared by `clear` each frame
        /// Row of the node whose text names this one (`aria-labelledby`), or `none`.
        labelled_by: []u32,

        // ---- outputs of `names`
        /// First text run (row in `Texts`) in the node's subtree, or `none`.
        first_text: []u32,
        /// Text run that names the node, or `none`.
        name: []u32,
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
