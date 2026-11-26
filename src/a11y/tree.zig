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
const Span = @import("../core/strings.zig").Span;
const Interaction = @import("../interact/interaction.zig").Interaction;

/// What a node is to assistive technology: the roles the WAI-ARIA Authoring Practices patterns
/// use. One byte, stored in `Tree.Columns.role`. Each role exposed by `types.Role` has the same
/// value here, so a `Style.role` reads back as the same role; additional widget roles
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
    // ---- live regions (a status bar): `status` is a polite live region (`live`)
    status,
    // ---- added after the patterns above, so their bytes stay put
    /// A button that stays down until pressed again: ARIA's button with `aria-pressed`. Its
    /// value is the pressed state, as a checkbox's is its checked state (`checkable`).
    toggle_button,
    /// A clipped viewport whose content scrolls (AccessKit's ScrollView; ARIA has none and
    /// leaves it a group).
    scroll_view,
    /// A text input for a search query (ARIA's searchbox; AccessKit's SearchInput).
    search_box,
};

/// The name of the role in a raw role byte, as in `Role` (`"tab"`, `"toggle_button"`), or
/// `"unknown"` for a byte no role has. For tools that print a tree's role column: the column
/// holds every `Role`, beyond `types.Role`, so reading it as `types.Role` is invalid.
pub fn roleName(byte: u8) []const u8 {
    const table = comptime blk: {
        var m: [256][]const u8 = @splat("unknown");
        for (@typeInfo(Role).@"enum".field_names, @typeInfo(Role).@"enum".field_values) |name, v| m[v] = name;
        break :blk m;
    };
    return table[byte];
}

comptime {
    // The roles exposed directly in Style retain their platform-neutral export bytes.
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
        .label,         .button, .checkbox,  .link,               .radio,           .@"switch",
        .heading,       .option, .menu_item, .menu_item_checkbox, .menu_item_radio, .tab,
        .tree_item,     .row,    .cell,      .column_header,      .row_header,      .tooltip,
        .toggle_button,
    }) |r| m[@backingInt(r)] = 0xffff_ffff;
    break :blk m;
};

/// How a live region's changes are announced (`aria-live`).
pub const Live = enum(u8) { off, polite, assertive };

/// The politeness each role implies, as ARIA's roles do: `status` polite, `alert` assertive,
/// off for the rest. Indexed by the raw role byte.
// ponytail: by role only; add a per-node `aria-live` input to `Semantics` when a widget needs
// a politeness its role does not imply.
pub const live: [256]Live = blk: {
    var m: [256]Live = @splat(.off);
    m[@backingInt(Role.status)] = .polite;
    m[@backingInt(Role.alert)] = .assertive;
    break :blk m;
};

/// States a node reports, one bit each, in `Semantics.Columns.state`. `checked`, `pressed`,
/// `mixed` and `expanded` are meaningful only on roles that have them: `checked` and `pressed`
/// on the checkable roles (`checkable`), `mixed` on those too, `expanded` where `expandable` is
/// set (a disclosure button, a tree item, a combobox), so a bridge can tell "collapsed" from
/// "cannot expand", and "not checked" from "cannot be checked".
pub const State = bitpack struct(u16) {
    checked: bool = false,
    expandable: bool = false,
    expanded: bool = false,
    selected: bool = false,
    disabled: bool = false,
    /// Neither on nor off (`aria-checked` or `aria-pressed` "mixed"): a checkable role whose
    /// value is strictly between 0 and 1, as a tri-state checkbox stores it (0.5). Set
    /// instead of `checked` or `pressed`.
    mixed: bool = false,
    /// A toggle button that is down (`aria-pressed="true"`), from its value.
    pressed: bool = false,
    /// The current item of a set (`aria-current`), such as a breadcrumb's page. The
    /// application's to set.
    current: bool = false,
    /// A text input of several lines (`aria-multiline`), such as a text area. The
    /// application's (the widget's `semantics`) to set.
    multiline: bool = false,
    /// The node has keyboard focus. Set by `focused` from the interaction state.
    focused: bool = false,
    /// Shown but not editable (`aria-readonly`). The application's to set.
    read_only: bool = false,
    /// The value fails the application's validation (`aria-invalid`).
    invalid: bool = false,
    /// A value is required before the related action can complete (`aria-required`).
    required: bool = false,
    /// Content is being updated; independent from whether input is disabled (`aria-busy`).
    busy: bool = false,
    _: u2 = 0,

    pub inline fn bitsOf(st: State) u16 {
        return @bitCast(st);
    }
};

/// The state bit a role's `value` turns on (as the core's checkbox stores it: 1 on, 0 off,
/// between them mixed): `checked` for the checkable roles, `pressed` for a toggle button, zero
/// for the rest. Indexed by the raw role byte.
pub const checkable: [256]u16 = blk: {
    var m: [256]u16 = @splat(0);
    for ([_]Role{ .checkbox, .radio, .@"switch", .menu_item_checkbox, .menu_item_radio }) |r|
        m[@backingInt(r)] = State.bitsOf(.{ .checked = true });
    m[@backingInt(Role.toggle_button)] = State.bitsOf(.{ .pressed = true });
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
        /// A name that is shown nowhere (`aria-label`): bytes the application added to the
        /// frame's `Strings`, `.{}` for none. `labelled_by` wins over it, as ARIA has it; it
        /// wins over the node's content and own text.
        label: []Span,
        /// An editable node's text, as a span in the frame's `Strings` (a text field's value,
        /// which the value column, one number, cannot hold); `.{}` for none.
        text: []Span,
        /// What an empty editable node shows instead (`aria-placeholder`), a span in the
        /// frame's `Strings`; `.{}` for none.
        hint: []Span,
        /// A hash of `text` and `hint`, 0 for neither, so `flatten` compares them across
        /// frames without hashing bytes per row. `setText` writes all three.
        text_hash: []u32,
        /// `State` bits the application sets; `states` adds what follows from the tree.
        state: []u16,
        /// The value's range, as `aria-valuemin`, `aria-valuemax` and the step a screen
        /// reader's increment and decrement move by, in the value's units. `hi <= lo` is no
        /// range (the cleared 0, 0); `step` 0 is none.
        range: [3][]f32,

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
        @memset(s.c.label, .{});
        @memset(s.c.text, .{});
        @memset(s.c.hint, .{});
        @memset(s.c.text_hash, 0);
        @memset(s.c.state, 0);
        inline for (s.c.range) |col| @memset(col, 0);
    }
};

/// Sets row `row`'s text and placeholder (`Semantics.Columns.text`, `hint`), copying the bytes
/// into the frame's strings `str`, and their hash. For an editable node, after building; an
/// empty `hint` is none.
pub fn setText(s: *Semantics, row: u32, str: *Strings, text: []const u8, hint: []const u8) void {
    s.c.text[row] = str.add(text);
    s.c.hint[row] = str.add(hint);
    var h = std.hash.Fnv1a_32.init();
    h.update(text);
    h.update(&.{0}); // "ab" + "c" is not "a" + "bc"
    h.update(hint);
    s.c.text_hash[row] = h.final();
}

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
    for (0..n) |k| first[k] = simd.selU(t.participation(@intCast(k)).semantics, c.text[k], none);
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
        // A mask or an address select here compiles to a branch around the load (`pick`).
        const via = first[@min(lb, last)];
        s.c.name[k] = pick(u32, lb != none, via, self);
    }
}

/// Completes `state` from the tree: a checkable role is mixed when its `value` is strictly
/// between 0 and 1, else checked (a toggle button pressed) when it is not 0, and a node inside a
/// disabled node is disabled (as `aria-disabled` applies to descendants). Adds bits, never
/// clears them, so running it twice changes nothing.
pub fn states(t: *const Tree, s: *Semantics) void {
    const c = &t.c;
    const st = s.c.state;
    const disabled = State.bitsOf(.{ .disabled = true });
    const mixed = State.bitsOf(.{ .mixed = true });
    // Parents come before children, so a parent's state is final when its children read it.
    // The root is its own parent: reading it back changes nothing.
    for (0..t.len) |k| {
        const v = c.value[k];
        const bit = checkable[c.role[k]];
        const half = -%(@as(u16, @intFromBool(v > 0)) & @intFromBool(v < 1));
        const on = -%@as(u16, @intFromBool(v != 0)) & ~half;
        const can = -%@as(u16, @intFromBool(bit != 0));
        st[k] |= (bit & on) | (mixed & half & can) | (st[c.parent[k]] & disabled);
    }
}

/// Marks the node with id `focus` (`Interaction.focus`, 0 for none) `focused`. Run it with
/// `states`, before `flatten`; a focus on no node of `t` marks nothing.
pub fn focused(t: *const Tree, s: *Semantics, focus: u32) void {
    const r = t.find(@fromBackingInt(focus));
    if (focus == 0 or r == none) return;
    s.c.state[r] |= State.bitsOf(.{ .focused = true });
}

/// The semantic tree as flat arrays, the form a bridge hands to the platform: one row per
/// node with a role, in tree order (parents before children), parents as export rows.
/// Presentational nodes (`Role.none`) are left out and their children move up to the nearest
/// exported ancestor. Names are byte ranges in the frame's `Strings`: the named text run's, or
/// the node's `label`.
pub const Export = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    /// Semantic rank of an HTML-style heading. Other roles reuse the value
    /// column for control values; a heading with no specified rank stores 0.
    pub fn headingLevel(e: *const Export, row: usize) ?usize {
        if (e.c.role[row] != @backingInt(Role.heading)) return null;
        const rank = e.c.value[row];
        if (!(rank >= 1 and rank <= 6 and @floor(rank) == rank)) return null;
        return @intFromFloat(rank);
    }

    pub const Columns = struct {
        /// Stable across frames: the node's `Id`, or for an anonymous node one derived from its
        /// exported parent's id and its position among that parent's exported children.
        id: []u32,
        /// Row in the tree.
        node: []u32,
        /// Export row of the parent; `none` for the root.
        parent: []u32,
        role: []u8,
        state: []u16,
        value: []f32,
        /// `Semantics.Columns.range`: lo, hi, step.
        range: [3][]f32,
        /// The name's bytes in the frame's `Strings`; 0 bytes when the node has no name.
        name_start: []u32,
        name_bytes: []u32,
        /// `Semantics.Columns.text` and `hint`: spans in the frame's `Strings`.
        text: []Span,
        hint: []Span,
        /// FNV-1a of the name's bytes, xor `Semantics.Columns.text_hash`, so a later frame
        /// compares name, text and placeholder without this frame's `Strings`. A node with no
        /// text or placeholder hashes its name alone.
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
        const keep = (c.role[k] != 0) and t.participation(@intCast(k)).semantics;
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
        const rr = @min(run, last_run);
        // The name's span: the node's `label` when set and it is not labelled by another
        // node, else its run's, else empty. Selected by address, then loaded: masks and
        // selects over the loaded spans compiled to a branch around the run's loads.
        const lab = &s.c.label[k];
        const own = simd.andB(lab.bytes != 0, s.c.labelled_by[k] == none);
        const empty: Span = .{};
        const from_run = [2]*const Span{ &empty, &.{ .start = tx.c.start[rr], .bytes = tx.c.bytes[rr] } };
        const span = ([2]*const Span{ from_run[@intFromBool(run != none)], lab })[@intFromBool(own)].*;
        const start = span.start;
        const bytes = span.bytes;

        o.id[w] = id;
        o.node[w] = @intCast(k);
        o.parent[w] = par;
        o.role[w] = c.role[k];
        o.state[w] = s.c.state[k];
        o.value[w] = c.value[k];
        inline for (0..3) |e| o.range[e][w] = s.c.range[e][k];
        o.name_start[w] = start;
        o.name_bytes[w] = bytes;
        o.text[w] = s.c.text[k];
        o.hint[w] = s.c.hint[k];
        o.name_hash[w] = std.hash.Fnv1a_32.hash(strings[start..][0..bytes]) ^ s.c.text_hash[k];
        const screen = @import("../draw/geometry.zig").transformRect(t.rect(@intCast(k)).array(), t.x.row[c.scope[k]].world);
        inline for (0..4) |e| o.rect[e][w] = screen[e];
        o.kids[w] = 0;
        o.kids_hash[w] = 0;
        w += @intFromBool(keep);
    }
    out.len = w;
}

/// What changed in the semantic tree since last frame, in the form a bridge sends to the
/// platform (an AccessKit `TreeUpdate`): the rows to send again and the ids to drop.
pub const Changes = struct {
    /// Export rows of this frame that are new or differ from last frame, in tree order, so a
    /// parent is sent before its children.
    updated: []u32,
    updated_len: u32 = 0,
    /// Ids of last frame's rows that are gone.
    removed: []u32,
    removed_len: u32 = 0,

    /// Room for a tree of `cap` nodes, plus the spare row that filtering writes to.
    pub fn init(carver: *mem.Carver, cap: u32) Changes {
        return .{ .updated = carver.slice(u32, cap + 1), .removed = carver.slice(u32, cap + 1) };
    }
};

/// Compares this frame's export with last frame's by id. A row is updated when it is new or
/// any of its role, state, value, range, name, rect, parent or child list differ; a child added or
/// removed changes its parent's `kids_hash`, so the parent is sent with its new child list.
/// Each row is written to the output and the cursor advances by 0 or 1.
pub fn diff(cur: *const Export, prev: *const Export, ch: *Changes) void {
    const a = &cur.c;
    const b = &prev.c;
    // ponytail: one SIMD `find` per row, O(n * m / lanes) compares. Index last frame's ids in a
    // caller-owned hash table if trees of many thousand nodes need this every frame.
    var w: u32 = 0;
    for (0..cur.len) |r| {
        const m = simd.find(b.id, prev.len, a.id[r]);
        const q = @min(m, prev.cap); // the spare row when absent; `m == none` decides then
        var same = m != none;
        same = simd.andB(same, a.role[r] == b.role[q]);
        same = simd.andB(same, a.state[r] == b.state[q]);
        same = simd.andB(same, @as(u32, @bitCast(a.value[r])) == @as(u32, @bitCast(b.value[q])));
        same = simd.andB(same, a.name_hash[r] == b.name_hash[q]);
        same = simd.andB(same, a.kids_hash[r] == b.kids_hash[q]);
        same = simd.andB(same, a.id[@min(a.parent[r], cur.cap)] == b.id[@min(b.parent[q], prev.cap)]);
        inline for (0..4) |e|
            same = simd.andB(same, @as(u32, @bitCast(a.rect[e][r])) == @as(u32, @bitCast(b.rect[e][q])));
        inline for (0..3) |e|
            same = simd.andB(same, @as(u32, @bitCast(a.range[e][r])) == @as(u32, @bitCast(b.range[e][q])));
        w = simd.emit(u32, ch.updated, w, @intCast(r), !same);
    }
    ch.updated_len = w;
    w = 0;
    for (0..prev.len) |r| {
        const gone = simd.find(a.id, cur.len, b.id[r]) == none;
        w = simd.emit(u32, ch.removed, w, b.id[r], gone);
    }
    ch.removed_len = w;
}

/// A request from assistive technology, as data: the bridge turns each platform action
/// (AccessKit `ActionRequest`) into one row and the host passes the slice in with the frame's
/// input. Nothing is called back; the frame reads the rows like any other input.
pub const Action = extern struct {
    kind: Kind,
    _pad: [3]u8 = @splat(0),
    /// Export id of the node (`Export.Columns.id`), which is the widget's `Id`.
    target: u32,
    /// For `set_value`: the new value, in the node's own units (as `Tree.Columns.value`).
    value: f32 = 0,

    pub const Kind = enum(u8) {
        /// The default action: a click on the node.
        press,
        /// Move keyboard focus to the node.
        focus,
        /// Set the node's value (a slider, a spin button).
        set_value,
        /// Move the value up or down by its range's step. `steps` turns these into
        /// `set_value` rows; until then `apply` and `setValue` skip them.
        increment,
        decrement,
    };
};

/// Applies this frame's actions to the interaction state as the user's own input would:
/// `press` makes the target this frame's click and `focus` gives it focus, so widgets that read
/// `Interaction.response` act on them with no code of their own. Run after `Interaction.step`
/// and `Focus.step`, before building the frame. A later action on the same field wins.
pub fn apply(it: *Interaction, actions: []const Action) void {
    // The last row of each kind, as a max over 1-based row numbers (0: none). A running
    // select on the target was vectorized into a find-last that branches on the kinds.
    var press: u32 = 0;
    var focus: u32 = 0;
    std.debug.assert(actions.len < none);
    for (actions, 1..) |a, k| {
        const row: u32 = @intCast(k);
        press = @max(press, row & -%@as(u32, @intFromBool(a.kind == .press)));
        focus = @max(focus, row & -%@as(u32, @intFromBool(a.kind == .focus)));
    }
    // Rows are read through a clamped index, then the address is selected (see `pick`).
    if (actions.len == 0) return;
    const keep = [2]*const u32{ &it.clicked, &actions[@max(press, 1) - 1].target };
    const move = [2]*const u32{ &it.focus, &actions[@max(focus, 1) - 1].target };
    it.clicked = keep[@intFromBool(press != 0)].*;
    it.focus = move[@intFromBool(focus != 0)].*;
}

/// The value assistive technology set for `id` this frame, or `current` when none did. The last
/// `set_value` for `id` wins. A widget calls it where it reads its value:
/// `value.* = a11y.setValue(actions, id, value.*)`.
pub fn setValue(actions: []const Action, id: types.Id, current: f32) f32 {
    // Selected as bits: x86 has no cmov for floats.
    var v: u32 = @bitCast(current);
    for (actions) |a| v = pick(u32, simd.andB(a.kind == .set_value, a.target == @backingInt(id)), @bitCast(a.value), v);
    return @bitCast(v);
}

/// Turns each `increment` and `decrement` row into the `set_value` it means: the value before
/// it (last frame's export `e`, or an earlier row's `set_value` for the same node) moved by the
/// node's step and kept in its range. Rows for a node not in `e`, or with no step, are left
/// as they are, which `apply` and `setValue` skip. Run it before `setValue` reads the rows (a
/// bridge does, as it drains them).
pub fn steps(actions: []Action, e: *const Export) void {
    for (actions, 0..) |*a, k| {
        const up = a.kind == .increment;
        if (!up and a.kind != .decrement) continue;
        const r = simd.find(e.c.id, e.len, a.target);
        if (r == none or !(e.c.range[2][r] > 0)) continue;
        const v = setValue(actions[0..k], @fromBackingInt(a.target), e.c.value[r]);
        const d = if (up) e.c.range[2][r] else -e.c.range[2][r];
        a.* = .{ .kind = .set_value, .target = a.target, .value = std.math.clamp(v + d, e.c.range[0][r], @max(e.c.range[0][r], e.c.range[1][r])) };
    }
}

/// `c ? a : b` as a cmov. Zig 0.18's LLVM turns a select whose operand is loaded only for it
/// into a branch around the load, through `simd.selU` masks and address selects alike; the
/// `.unpredictable` hint keeps it a select (as `pick` in src/interact/interaction.zig).
inline fn pick(comptime T: type, c: bool, a: T, b: T) T {
    return if (c) blk: {
        @branchHint(.unpredictable);
        break :blk a;
    } else b;
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

test "roleName: every role byte names its role; others are unknown" {
    try testing.expectEqualStrings("none", roleName(0));
    try testing.expectEqualStrings("button", roleName(@backingInt(Role.button)));
    try testing.expectEqualStrings("toggle_button", roleName(@backingInt(Role.toggle_button)));
    try testing.expectEqualStrings("scroll_view", roleName(@backingInt(Role.scroll_view)));
    try testing.expectEqualStrings("unknown", roleName(255));
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

test "tree export: a live region's politeness follows its role" {
    try testing.expectEqual(Live.polite, live[@backingInt(Role.status)]);
    try testing.expectEqual(Live.assertive, live[@backingInt(Role.alert)]);
    try testing.expectEqual(Live.off, live[@backingInt(Role.group)]);
    try testing.expectEqual(Live.off, live[@backingInt(Role.scroll_view)]);
    try testing.expectEqual(Live.off, live[255]);
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
    // A tri-state checkbox half way, a toggle button down, one up and one mixed, and a
    // breadcrumb page the application marks current. (The slider at 0.5 is not mixed.)
    const all = t.push(root, .none, &.{ .role = .checkbox, .value = 0.5 });
    const bold = t.push(root, .none, &.{ .value = 1 });
    const italic = t.push(root, .none, &.{ .value = 0 });
    const some = t.push(root, .none, &.{ .value = 0.5 });
    for ([_]u32{ bold, italic, some }) |k| t.c.role[k] = @backingInt(Role.toggle_button);
    const page = t.push(root, .none, &.{ .role = .label });
    t.seal(root);
    try t.check();
    s.c.state[page] = State.bitsOf(.{ .current = true });

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
    try testing.expectEqual(State{ .mixed = true }, got(&s, all));
    try testing.expectEqual(State{ .pressed = true }, got(&s, bold));
    try testing.expectEqual(State{}, got(&s, italic));
    try testing.expectEqual(State{ .mixed = true }, got(&s, some));
    try testing.expectEqual(State{ .current = true }, got(&s, page));
    // Idempotent; and `clear` drops what the application set last frame.
    const before: [15]u16 = s.c.state[0..15].*;
    try testing.expectEqual(15, t.len);
    states(&t, &s);
    try testing.expectEqualSlices(u16, &before, s.c.state[0..t.len]);
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
        ch: Changes = undefined,

        fn carve(f: ?*Self, carver: *mem.Carver) void {
            const t = Tree.init(carver, cap);
            const tx = Texts.init(carver, cap);
            const s = Semantics.init(carver, cap);
            const out = [2]Export{ Export.init(carver, cap), Export.init(carver, cap) };
            const ch = Changes.init(carver, cap);
            if (f) |x| {
                x.ch = ch;
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

test "tree export: diff against last frame emits only the rows that changed and the ids that went" {
    var f: FrameFixture(32) = .{};
    f.init();
    const Scene = struct {
        checked: bool = false,
        label: []const u8 = "Save",
        extra: bool = false,
        x1: f32 = 50,

        fn build(sc: @This(), fx: *FrameFixture(32)) void {
            fx.reset();
            const t = &fx.t;
            const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
            const save = t.push(root, types.Id.from("save"), &.{ .role = .button });
            _ = fx.text(save, sc.label);
            t.seal(save);
            t.c.rect[2][save] = sc.x1;
            const bold = t.push(root, types.Id.from("bold"), &.{ .role = .checkbox, .value = simd.b2f(sc.checked) });
            _ = fx.text(bold, "Bold");
            t.seal(bold);
            if (sc.extra) t.seal(t.push(root, types.Id.from("extra"), &.{ .role = .button }));
            t.seal(root);
        }
    };
    const id = struct {
        fn of(e: *const Export, r: u32) u32 {
            return e.c.id[r];
        }
    }.of;
    const updated = struct {
        fn ids(e: *const Export, ch: *const Changes, out: []u32) []u32 {
            for (ch.updated[0..ch.updated_len], 0..) |r, k| out[k] = e.c.id[r];
            return out[0..ch.updated_len];
        }
    }.ids;
    var buf: [32]u32 = undefined;

    // First frame against an empty last frame: everything is new.
    var gen: u1 = 0;
    f.out[1].len = 0;
    (Scene{}).build(&f);
    var e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqual(e.len, f.ch.updated_len);
    try testing.expectEqual(0, f.ch.removed_len);

    // The same scene again: nothing.
    gen ^= 1;
    (Scene{}).build(&f);
    e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqual(0, f.ch.updated_len);
    try testing.expectEqual(0, f.ch.removed_len);

    // Checking the box changes its state only.
    gen ^= 1;
    (Scene{ .checked = true }).build(&f);
    e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqualSlices(u32, &.{@backingInt(types.Id.from("bold"))}, updated(e, &f.ch, &buf));

    // A new label text renames the button and its text leaf; a wider button sends the button.
    gen ^= 1;
    (Scene{ .checked = true, .label = "Store", .x1 = 60 }).build(&f);
    e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqualSlices(u32, &.{ id(e, 1), id(e, 2) }, updated(e, &f.ch, &buf));
    try testing.expectEqual(@backingInt(types.Id.from("save")), id(e, 1));

    // A new child: the child and its parent, whose child list changed.
    gen ^= 1;
    (Scene{ .checked = true, .label = "Store", .x1 = 60, .extra = true }).build(&f);
    e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqualSlices(u32, &.{ @backingInt(types.Id.from("app")), @backingInt(types.Id.from("extra")) }, updated(e, &f.ch, &buf));
    try testing.expectEqual(0, f.ch.removed_len);

    // And removing it: the parent again, and the child's id to drop.
    gen ^= 1;
    (Scene{ .checked = true, .label = "Store", .x1 = 60 }).build(&f);
    e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqualSlices(u32, &.{@backingInt(types.Id.from("app"))}, updated(e, &f.ch, &buf));
    try testing.expectEqualSlices(u32, &.{@backingInt(types.Id.from("extra"))}, f.ch.removed[0..f.ch.removed_len]);
}

test "tree export: actions from assistive technology arrive as input the widgets already read" {
    var f: FrameFixture(32) = .{};
    f.init();
    const save = types.Id.from("save");
    const bold = types.Id.from("bold");
    const vol = types.Id.from("vol");
    var it: Interaction = .{};
    var checked = false;
    var volume: f32 = 0.25;
    // One frame of a checkbox and a slider, written as the core's widgets are: they read the
    // interaction state and their value, and know nothing of actions beyond `setValue`.
    const Ui = struct {
        fn frame(fx: *FrameFixture(32), in: *const Interaction, acts: []const Action, on: *bool, v: *f32) *Export {
            fx.reset();
            const t = &fx.t;
            const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
            const b = t.push(root, types.Id.from("bold"), &.{ .role = .checkbox });
            on.* = on.* != in.response(types.Id.from("bold")).clicked;
            t.c.value[b] = simd.b2f(on.*);
            _ = fx.text(b, "Bold");
            t.seal(b);
            const s = t.push(root, types.Id.from("vol"), &.{ .role = .slider });
            v.* = setValue(acts, types.Id.from("vol"), v.*);
            t.c.value[s] = v.*;
            t.seal(s);
            t.seal(root);
            return fx.run(0);
        }
    };

    // The bridge read the export and the screen reader asked to press "Bold", focus the slider
    // and set it to 0.75, then to 0.5 (the last one wins); a press on another id does nothing here.
    const acts = [_]Action{
        .{ .kind = .press, .target = @backingInt(bold) },
        .{ .kind = .focus, .target = @backingInt(vol) },
        .{ .kind = .set_value, .target = @backingInt(vol), .value = 0.75 },
        .{ .kind = .set_value, .target = @backingInt(vol), .value = 0.5 },
        .{ .kind = .set_value, .target = @backingInt(save), .value = 9 },
    };
    apply(&it, &acts);
    try testing.expect(it.response(bold).clicked);
    try testing.expect(it.response(vol).focused);
    try testing.expect(!it.response(vol).clicked);
    const e = Ui.frame(&f, &it, &acts, &checked, &volume);
    try testing.expect(checked);
    try testing.expectEqual(0.5, volume);
    // The export shows the result: the checkbox checked, the slider at 0.5.
    try testing.expectEqual(State{ .checked = true }, @as(State, @bitCast(e.c.state[1])));
    try testing.expectEqual(0.5, e.c.value[3]);

    // Next frame, no actions: the click does not repeat and the value stays.
    it = .{ .focus = it.focus };
    _ = Ui.frame(&f, &it, &.{}, &checked, &volume);
    try testing.expect(checked);
    try testing.expectEqual(0.5, volume);
    try testing.expectEqual(0.25, setValue(&.{}, vol, 0.25));
}

test "tree export: a range is exported, sent again when it moves, and steps actions within it" {
    var f: FrameFixture(16) = .{};
    f.init();
    const Scene = struct {
        fn build(fx: *FrameFixture(16), gen: u1, hi: f32) *Export {
            fx.reset();
            const t = &fx.t;
            const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
            const vol = t.push(root, types.Id.from("vol"), &.{ .role = .slider, .value = 3 });
            t.seal(vol);
            t.seal(root);
            fx.s.c.range[0][vol] = 0;
            fx.s.c.range[1][vol] = hi;
            fx.s.c.range[2][vol] = 1;
            return fx.run(gen);
        }
    };
    const e = Scene.build(&f, 0, 4);
    try testing.expectEqual([3]f32{ 0, 4, 1 }, [3]f32{ e.c.range[0][1], e.c.range[1][1], e.c.range[2][1] });
    // The group has none.
    try testing.expectEqual([3]f32{ 0, 0, 0 }, [3]f32{ e.c.range[0][0], e.c.range[1][0], e.c.range[2][0] });
    // The same range: nothing to send. A new top: the slider again.
    diff(Scene.build(&f, 1, 4), e, &f.ch);
    try testing.expectEqual(0, f.ch.updated_len);
    const wider = Scene.build(&f, 1, 8);
    diff(wider, e, &f.ch);
    try testing.expectEqualSlices(u32, &.{1}, f.ch.updated[0..f.ch.updated_len]);

    // An increment steps up; past the top it stops there. A node that is not exported is
    // left alone, and `apply` skips it.
    const vol = @backingInt(types.Id.from("vol"));
    var acts = [_]Action{
        .{ .kind = .increment, .target = vol },
        .{ .kind = .increment, .target = @backingInt(types.Id.from("gone")) },
    };
    steps(&acts, e);
    try testing.expectEqual(Action{ .kind = .set_value, .target = vol, .value = 4 }, acts[0]);
    try testing.expectEqual(Action.Kind.increment, acts[1].kind);
    var it: Interaction = .{};
    apply(&it, acts[1..]);
    try testing.expectEqual(0, it.clicked);
    try testing.expectEqual(0, it.focus);
    // Several in one frame step from each other: up, up (held at 4), down.
    var more = [_]Action{
        .{ .kind = .increment, .target = vol },
        .{ .kind = .increment, .target = vol },
        .{ .kind = .decrement, .target = vol },
    };
    steps(&more, e);
    try testing.expectEqual(3, setValue(&more, .from("vol"), 3));
    try testing.expectEqual(4, more[1].value);
    // Down twice, then a set_value, which wins.
    more = .{ .{ .kind = .decrement, .target = vol }, .{ .kind = .decrement, .target = vol }, .{ .kind = .set_value, .target = vol, .value = 0.5 } };
    steps(&more, e);
    try testing.expectEqual(1, more[1].value);
    try testing.expectEqual(0.5, setValue(&more, .from("vol"), 3));
}

test "tree export: a label names a node with no text, unless it is labelled by another" {
    var f: FrameFixture(16) = .{};
    f.init();
    const t = &f.t;
    // root { label "Volume", slider vol (labelled by "Volume", and a label: labelled_by wins),
    //        radio group "quality" (a label only), button "ok" { "OK" } (a label over content) }
    const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
    const volume = f.text(root, "Volume");
    const vol = t.push(root, types.Id.from("vol"), &.{ .role = .slider });
    t.seal(vol);
    const group = t.push(root, types.Id.from("quality"), &.{});
    t.c.role[group] = @backingInt(Role.radio_group);
    t.seal(group);
    const ok = t.push(root, types.Id.from("ok"), &.{ .role = .button });
    _ = f.text(ok, "OK");
    t.seal(ok);
    t.seal(root);
    f.s.c.labelled_by[vol] = volume;
    f.s.c.label[vol] = f.str.add("Loudness");
    f.s.c.label[group] = f.str.add("Quality");
    f.s.c.label[ok] = f.str.add("Accept");
    const e = f.run(0);
    try testing.expectEqualStrings("Volume", f.name(e, 2));
    try testing.expectEqualStrings("Quality", f.name(e, 3));
    try testing.expectEqualStrings("Accept", f.name(e, 4));
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Quality"), e.c.name_hash[3]);
    // The button's text leaf keeps its own.
    try testing.expectEqualStrings("OK", f.name(e, 5));
    try testing.expectEqualStrings("", f.name(e, 0));
}

test "tree export: a text field's text and placeholder are exported, and a change sends it again" {
    var f: FrameFixture(8) = .{};
    f.init();
    const Scene = struct {
        fn build(fx: *FrameFixture(8), gen: u1, text: []const u8) *Export {
            fx.reset();
            const t = &fx.t;
            const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
            const field = t.push(root, types.Id.from("name"), &.{ .role = .text_input });
            t.seal(field);
            t.seal(root);
            setText(&fx.s, field, &fx.str, text, "Your name");
            return fx.run(gen);
        }
        fn bytes(fx: *const FrameFixture(8), sp: Span) []const u8 {
            return fx.str.buf[sp.start..][0..sp.bytes];
        }
    };
    var e = Scene.build(&f, 0, "Ada");
    try testing.expectEqualStrings("Ada", Scene.bytes(&f, e.c.text[1]));
    try testing.expectEqualStrings("Your name", Scene.bytes(&f, e.c.hint[1]));
    try testing.expectEqual(Span{}, e.c.text[0]);
    // The group has neither: its hash is its name's alone.
    try testing.expectEqual(std.hash.Fnv1a_32.hash(""), e.c.name_hash[0]);
    const prev = e;
    e = Scene.build(&f, 1, "Ada");
    diff(e, prev, &f.ch);
    try testing.expectEqual(0, f.ch.updated_len);
    e = Scene.build(&f, 1, "Adam");
    diff(e, prev, &f.ch);
    try testing.expectEqualSlices(u32, &.{1}, f.ch.updated[0..f.ch.updated_len]);
}

test "tree export: the focused node is marked focused; multiline and read-only are exported" {
    var f: FrameFixture(8) = .{};
    f.init();
    const t = &f.t;
    const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
    const notes = t.push(root, types.Id.from("notes"), &.{ .role = .text_input });
    t.seal(notes);
    const log = t.push(root, types.Id.from("log"), &.{ .role = .text_input });
    t.seal(log);
    t.seal(root);
    f.s.c.state[notes] = State.bitsOf(.{ .multiline = true });
    f.s.c.state[log] = State.bitsOf(.{ .multiline = true, .read_only = true });
    focused(t, &f.s, @backingInt(types.Id.from("notes")));
    // No focus, or a focus on a node not in the tree, marks nothing.
    focused(t, &f.s, 0);
    focused(t, &f.s, @backingInt(types.Id.from("gone")));
    const e = f.run(0);
    try testing.expectEqual(State{ .multiline = true, .focused = true }, @as(State, @bitCast(e.c.state[1])));
    try testing.expectEqual(State{ .multiline = true, .read_only = true }, @as(State, @bitCast(e.c.state[2])));
    try testing.expectEqual(State{}, @as(State, @bitCast(e.c.state[0])));
}

test "tree export: validation requirement and busy state retain the existing compact state ABI" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(State));
    try testing.expectEqual(@as(u16, 1 << 10), State.bitsOf(.{ .read_only = true }));
    try testing.expectEqual(@as(u16, (1 << 11) | (1 << 12) | (1 << 13)), State.bitsOf(.{ .invalid = true, .required = true, .busy = true }));
    var f: FrameFixture(8) = .{};
    f.init();
    const root = f.t.push(0, types.Id.from("app"), &.{ .role = .group });
    const field = f.t.push(root, types.Id.from("email"), &.{ .role = .text_input });
    f.t.seal(field);
    f.t.seal(root);
    f.s.c.state[field] = State.bitsOf(.{ .invalid = true, .required = true, .busy = true });
    const output = f.run(0);
    const semantic_state: State = @bitCast(output.c.state[1]);
    try testing.expect(semantic_state.invalid and semantic_state.required and semantic_state.busy);
    try testing.expect(!semantic_state.disabled and !semantic_state.read_only);
}

test "tree export: a presentational root leaves several top-level rows with distinct ids" {
    var f: FrameFixture(8) = .{};
    f.init();
    const t = &f.t;
    const root = t.push(0, .none, &.{});
    const a = f.text(root, "A");
    const b = f.text(root, "B");
    t.seal(root);
    const e = f.run(0);
    try testing.expectEqual(2, e.len);
    try testing.expectEqualSlices(u32, &.{ a, b }, e.c.node[0..2]);
    try testing.expectEqualSlices(u32, &.{ none, none }, e.c.parent[0..2]);
    try testing.expect(e.c.id[0] != e.c.id[1]);
    try testing.expect(e.c.id[0] != 0 and e.c.id[1] != 0);
    try testing.expectEqualStrings("B", f.name(e, 1));
}

test "tree export: a full tree exports every row; the spare row only counts top-level rows" {
    const cap = 12;
    var f: FrameFixture(cap) = .{};
    f.init();
    const t = &f.t;
    const root = t.push(0, types.Id.from("r"), &.{ .role = .group });
    for (1..cap) |k| t.seal(t.push(root, types.Id.from("i").with(@intCast(k)), &.{ .role = .label }));
    t.seal(root);
    try testing.expect(!t.overflow);
    const e = f.run(0);
    try testing.expectEqual(cap, e.len);
    try testing.expectEqual(cap - 1, e.c.kids[0]);
    try testing.expectEqual(0, e.c.id[e.cap]);
    try testing.expectEqual(1, e.c.kids[e.cap]);
}

test "tree export: reordering or moving children sends their parents again" {
    var f: FrameFixture(16) = .{};
    f.init();
    const Scene = struct {
        swap: bool = false,
        moved: bool = false,

        fn build(sc: @This(), fx: *FrameFixture(16)) void {
            fx.reset();
            const t = &fx.t;
            const root = t.push(0, types.Id.from("app"), &.{ .role = .group });
            const l = t.push(root, types.Id.from("left"), &.{ .role = .group });
            const ids = [2]types.Id{ types.Id.from("x"), types.Id.from("y") };
            const first = @intFromBool(sc.swap);
            t.seal(t.push(l, ids[first], &.{ .role = .button }));
            if (!sc.moved) t.seal(t.push(l, ids[first ^ 1], &.{ .role = .button }));
            t.seal(l);
            const r = t.push(root, types.Id.from("right"), &.{ .role = .group });
            if (sc.moved) t.seal(t.push(r, ids[first ^ 1], &.{ .role = .button }));
            t.seal(r);
            t.seal(root);
        }
    };
    var gen: u1 = 0;
    (Scene{}).build(&f);
    _ = f.run(gen);

    // Swapping two children: their parent's child list changed; the children themselves did not.
    gen ^= 1;
    (Scene{ .swap = true }).build(&f);
    var e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    try testing.expectEqual(1, f.ch.updated_len);
    try testing.expectEqual(@backingInt(types.Id.from("left")), e.c.id[f.ch.updated[0]]);

    // Moving "x" from left to right: both parents, and "x" for its new parent.
    gen ^= 1;
    (Scene{ .swap = true, .moved = true }).build(&f);
    e = f.run(gen);
    diff(e, &f.out[gen ^ 1], &f.ch);
    var got: [3]u32 = undefined;
    for (f.ch.updated[0..f.ch.updated_len], 0..) |r, k| got[k] = e.c.id[r];
    try testing.expectEqual(3, f.ch.updated_len);
    try testing.expectEqualSlices(u32, &.{ @backingInt(types.Id.from("left")), @backingInt(types.Id.from("right")), @backingInt(types.Id.from("x")) }, &got);
    try testing.expectEqual(0, f.ch.removed_len);
}

test "tree export: random trees agree with a parent-walking reference" {
    const cap = 64;
    var f: FrameFixture(cap) = .{};
    f.init();
    var prng = std.Random.DefaultPrng.init(0xa11);
    const rnd = prng.random();
    for (0..200) |_| {
        f.reset();
        const t = &f.t;
        // Random depth-first tree: each new node opens under a random still-open node.
        var open: [cap]u32 = undefined;
        var depth: usize = 1;
        const n = rnd.intRangeAtMost(u32, 1, cap);
        open[0] = t.push(0, .none, &.{});
        t.c.role[0] = rnd.uintLessThan(u8, 4); // 0 is presentational
        for (1..n) |_| {
            depth = rnd.intRangeAtMost(usize, 1, depth);
            const id: types.Id = if (rnd.boolean()) .none else types.Id.hash(&std.mem.toBytes(rnd.int(u32)));
            const k = t.push(open[depth - 1], id, &.{});
            t.c.role[k] = rnd.uintLessThan(u8, 4);
            t.c.value[k] = @floatFromInt(rnd.uintLessThan(u8, 2));
            open[depth] = k;
            depth += 1;
        }
        // Set every row's end to one past its last descendant, found by walking parent links.
        var r = t.len;
        while (r > 0) {
            r -= 1;
            var end = r + 1;
            for (r + 1..t.len) |j| {
                var a = t.c.parent[j];
                while (a > r) a = t.c.parent[a];
                if (a == r) end = @intCast(j + 1);
            }
            t.c.end[r] = end;
        }
        try t.check();
        const e = f.run(0);

        // Reference: walk parent links to the nearest kept ancestor; count kept rows.
        var w: u32 = 0;
        var row_of: [cap]u32 = @splat(none);
        var kids: [cap]u32 = @splat(0);
        for (0..t.len) |k| {
            if (t.c.role[k] == 0) continue;
            var a: u32 = @intCast(k);
            var par: u32 = none;
            while (a != 0) {
                a = t.c.parent[a];
                if (t.c.role[a] != 0) {
                    par = row_of[a];
                    break;
                }
            }
            try testing.expectEqual(@as(u32, @intCast(k)), e.c.node[w]);
            try testing.expectEqual(par, e.c.parent[w]);
            if (par != none) kids[par] += 1;
            const checked = t.c.role[k] == @backingInt(Role.checkbox) and t.c.value[k] != 0;
            try testing.expectEqual(checked, (State{ .checked = true }).bitsOf() & e.c.state[w] != 0);
            row_of[k] = w;
            w += 1;
        }
        try testing.expectEqual(w, e.len);
        try testing.expectEqualSlices(u32, kids[0..w], e.c.kids[0..w]);
        // Every exported id is unique (anonymous ones derived), and diffing a frame against
        // itself reports nothing.
        for (0..e.len) |a| for (0..a) |b| try testing.expect(e.c.id[a] != e.c.id[b]);
        diff(e, e, &f.ch);
        try testing.expectEqual(0, f.ch.updated_len);
        try testing.expectEqual(0, f.ch.removed_len);
    }
}

test "tree export: counting carvers size what the carvers cut" {
    inline for (.{ Semantics, Export, Changes }) |T| {
        var counter: mem.Carver = .{ .buf = null };
        _ = T.init(&counter, 37);
        var buf: [16384]u8 align(mem.column_align) = undefined;
        var carver: mem.Carver = .{ .buf = &buf };
        _ = T.init(&carver, 37);
        try testing.expectEqual(counter.off, carver.off);
    }
    try testing.expectEqual(12, @sizeOf(Action));
    try testing.expectEqual(2, @sizeOf(State));
}
