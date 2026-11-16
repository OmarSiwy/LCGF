//! Table (tier 2): a grid of text cells under a row of column headers, in both front ends.
//! Follows the five-commit recipe of widgets/base.zig and is written against the public API of
//! tiers 0 and 1 only.
//!
//! State lives in the application: the header strings, the cell strings (row-major, `cols` per
//! row) and a `State(cols)` value: the active cell, the sort column and direction, and every
//! column's width. Clicking a header sorts by it (again: the other way), dragging the handle at
//! a header's right edge resizes its column, and with the body focused the arrow keys, Home
//! and End move the active cell (WAI-ARIA APG grid). Rows have the list box's fixed height, so
//! the cell under the pointer is index arithmetic, not a hit test per cell.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Mono = @import("../text/protocol.zig").Mono;
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
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// What a table keeps between frames, owned by the application: the active cell (as shown,
/// after sorting), the sort column (`none` for data order) and direction, and each column's
/// width in logical pixels.
pub fn State(comptime cols: usize) type {
    return struct {
        row: u32 = 0,
        col: u32 = 0,
        sort: u32 = none,
        descending: bool = false,
        widths: [cols]f32 = @splat(96),
    };
}

/// Why `S` cannot back a comptime table bound to the state field `state`, with header strings
/// in `headers` and cell strings in `cells`, `cols` columns by `rows` rows; null when it can.
pub fn check(comptime S: type, comptime state: []const u8, comptime headers: []const u8, comptime cells: []const u8, comptime cols: u32, comptime rows: u32) ?[]const u8 {
    comptime {
        if (cols == 0 or rows == 0) return "table: a table has at least one column and one row";
        if (!@hasField(S, state)) return "table: state has no field '" ++ state ++ "' for the table state";
        if (@FieldType(S, state) != State(cols)) return std.fmt.comptimePrint("table: field '{s}' must be a table.State({d})", .{ state, cols });
        for ([_][]const u8{ headers, cells }) |f| {
            if (!@hasField(S, f)) return "table: state has no field '" ++ f ++ "' for strings";
            if (@FieldType(S, f) != []const []const u8) return "table: strings field '" ++ f ++ "' must be a []const []const u8";
        }
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime S: type, comptime state: []const u8, comptime headers: []const u8, comptime cells: []const u8, comptime cols: u32, comptime rows: u32) void {
    if (comptime check(S, state, headers, cells, cols, rows)) |msg| @compileError(msg);
}

/// Ids of a table's parts, all derived from the table's id: the body is the table's id itself,
/// header `k` and its resize handle are numbered after it.
pub fn headerId(id: Id, k: usize) Id {
    return id.with(@intCast(1 + k));
}
pub fn handleId(id: Id, cols: usize, k: usize) Id {
    return id.with(@intCast(1 + cols + k));
}

// ---- look: one function per part, called by both front ends -------------------------------

/// Height of the header row and of every body row: the list box's row height.
pub fn rowHeight(th: *const Theme) f32 {
    return list_zig.rowHeight(th);
}

/// Width of a resize handle at a header's right edge.
pub const handle_px: f32 = 4;
/// Narrowest and widest a column can be dragged.
pub const min_width: f32 = 24;
pub const max_width: f32 = 400;

pub fn tableStyle(th: *const Theme) Style {
    return .{ .dir = .y, .fill = th.control_held, .border = 1, .border_color = th.control_hot, .role = .group };
}

pub fn headerRowStyle(th: *const Theme) Style {
    return .{ .dir = .x, .fill = th.control };
}

pub fn headerStyle(th: *const Theme, width: f32) Style {
    return .{ .dir = .x, .size = .{ .px(width), .px(rowHeight(th)) }, .pad = .{ th.pad, 0, 0, 0 }, .cross = .center, .clip = true };
}

/// A header's fill by state, indexed by `hovered | held << 1` (`base.stateIndex`).
pub fn headerFill(th: *const Theme, r: Response) Color {
    return th.controlFills()[base.stateIndex(r)];
}

/// The sort mark in a header: a dot before the handle, the accent ascending, the text colour
/// descending, nothing when the column is not the sort column.
pub fn markStyle(th: *const Theme, width: f32, sorted: bool, descending: bool) Style {
    const fills = [4]Color{ .transparent, .transparent, th.accent, th.text };
    return .{
        .size = .{ .px(6), .px(6) },
        .float = true,
        .offset = .{ width - th.pad - handle_px - 12, (rowHeight(th) - 6) / 2 },
        .radius = 3,
        .fill = fills[@as(u2, @intFromBool(descending)) | (@as(u2, @intFromBool(sorted)) << 1)],
    };
}

/// The resize handle, flush with the header's right edge; lit while under the pointer or held.
pub fn handleStyle(th: *const Theme, width: f32, r: Response) Style {
    const fills = base.StateColors{ .transparent, th.control_hot, th.accent, th.accent };
    return .{ .size = .{ .px(handle_px), .px(rowHeight(th)) }, .float = true, .offset = .{ width - th.pad - handle_px, 0 }, .fill = fills[base.stateIndex(r)] };
}

pub fn bodyStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y };
}

pub fn rowStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x };
}

/// A body cell; the active one is lit, in the accent while the body has focus.
pub fn cellStyle(th: *const Theme, width: f32, active: bool, focused: bool) Style {
    const fills = [4]Color{ .transparent, .transparent, th.control, th.accent };
    return .{
        .dir = .x,
        .size = .{ .px(width), .px(rowHeight(th)) },
        .pad = .{ th.pad, 0, 0, 0 },
        .cross = .center,
        .clip = true,
        .fill = fills[@as(u2, @intFromBool(focused)) | (@as(u2, @intFromBool(active)) << 1)],
    };
}

/// The column at `x`, for a body whose last rect starts at `left`: clamped into the columns.
pub fn colAt(widths: []const f32, left: f32, x: f32) u32 {
    var edge = left;
    for (widths, 0..) |w, k| {
        edge += w;
        if (x < edge) return @intCast(k);
    }
    return @intCast(widths.len - 1);
}

/// The body row at `y`, for a body whose last rect starts at `top`: clamped into `rows`.
pub fn rowAt(th: *const Theme, top: f32, y: f32, rows: u32) u32 {
    const k = @floor((y - top) / rowHeight(th));
    return @intFromFloat(std.math.clamp(k, 0, @as(f32, @floatFromInt(rows -| 1))));
}

/// Rows of a table as both front ends build them, from the table's row `box`: what the
/// accessibility passes and the tests need to find each part.
pub const Rows = struct {
    box: u32,
    cols: u32,
    rows: u32,
    /// A header cell is itself, its label, its sort mark and its handle.
    pub fn header(r: Rows, k: usize) u32 {
        return r.box + 2 + 4 * @as(u32, @intCast(k));
    }
    pub fn handle(r: Rows, k: usize) u32 {
        return r.header(k) + 3;
    }
    pub fn body(r: Rows) u32 {
        return r.header(r.cols);
    }
    /// Row `i` of the body is itself and two rows (cell, label) per column.
    pub fn row(r: Rows, i: usize) u32 {
        return r.body() + 1 + @as(u32, @intCast(i)) * (1 + 2 * r.cols);
    }
    pub fn cell(r: Rows, i: usize, k: usize) u32 {
        return r.row(i) + 1 + 2 * @as(u32, @intCast(k));
    }
};

// ---- behaviour: pure functions of the value and what happened -------------------------------

/// The data row shown at each position, for `cells` (row-major, `cols` per row) sorted by
/// column `sort` (data order for `none`), into `out` (one entry per row). Stable: equal cells
/// keep data order either way.
// ponytail: insertion sort, O(rows^2) per frame; a table of thousands of rows wants the order
// kept by the application and recomputed only when the sort or the data change.
pub fn order(cells: []const []const u8, cols: usize, sort: u32, descending: bool, out: []u32) void {
    for (out, 0..) |*o, k| o.* = @intCast(k);
    if (sort == none) return;
    for (1..out.len) |i| {
        const v = out[i];
        var j = i;
        while (j > 0 and before(cells[v * cols + sort], cells[out[j - 1] * cols + sort], descending)) : (j -= 1) out[j] = out[j - 1];
        out[j] = v;
    }
}

fn before(a: []const u8, b: []const u8, descending: bool) bool {
    const o = std.mem.order(u8, a, b);
    return if (descending) o == .gt else o == .lt;
}

/// A click on header `k`: sort by it ascending, or flip the direction if it already sorts.
pub fn sortBy(st: anytype, k: u32) void {
    st.descending = st.sort == k and !st.descending;
    st.sort = k;
}

/// Column `k`'s width while its handle is held: the pointer's distance from the header's left
/// edge `x0`, clamped. The press itself moves the edge to the pointer, by at most
/// `handle_px`.
pub fn resize(width: f32, held: bool, x0: f32, x: f32) f32 {
    return if (held) std.math.clamp(x - x0, min_width, max_width) else width;
}

/// The active cell after this frame's key events (press and repeat), clamped at the edges:
/// arrows move by one, Home and End go to the first and last column of the row.
pub fn keys(st: anytype, rows: u32, in: *const Input) void {
    const km = &list_zig.default_keys;
    const last_col: u32 = @intCast(st.widths.len - 1);
    for (in.events) |e| {
        if (e.kind != .press and e.kind != .repeat) continue;
        if (e.code == km.down) st.row = @min(st.row + 1, rows - 1);
        if (e.code == km.up) st.row -|= 1;
        if (e.code == km.right) st.col = @min(st.col + 1, last_col);
        if (e.code == km.left) st.col -|= 1;
        if (e.code == km.home) st.col = 0;
        if (e.code == km.end) st.col = last_col;
    }
}

/// One frame of input for a table: header clicks sort, held handles resize, a body click sets
/// the active cell, keys move it while the body is focused. `headers[k]` and `handles[k]` are
/// the responses of header and handle `k`, `header_x0[k]` its header's last left edge, `body`
/// the body's response and `body_rect` its last rect.
pub fn update(st: anytype, th: *const Theme, rows: u32, headers: []const Response, handles: []const Response, header_x0: []const f32, body: Response, body_rect: types.Rect, in: *const Input) void {
    for (headers, handles, header_x0, 0..) |h, g, x0, k| {
        if (h.clicked) sortBy(st, @intCast(k));
        st.widths[k] = resize(st.widths[k], g.held, x0, in.pointer[0]);
    }
    if (body.clicked) {
        st.row = rowAt(th, body_rect.y0, in.pointer[1], rows);
        st.col = colAt(&st.widths, body_rect.x0, in.pointer[0]);
    }
    if (body.focused) keys(st, rows, in);
}

// ---- accessibility ---------------------------------------------------------------------------

/// A header's `value`: its sort direction, 1 ascending, -1 descending, 0 when it does not sort
/// (ARIA `aria-sort`).
pub fn sortValue(sorted: bool, descending: bool) f32 {
    const v = [4]f32{ 0, 0, 1, -1 };
    return v[@as(u2, @intFromBool(descending)) | (@as(u2, @intFromBool(sorted)) << 1)];
}

/// Roles past `types.Role`, written to the tree's `role` column: the table a grid, the header
/// row a row of column headers, each resize handle a separator (its value is the width), the
/// body a row group of rows of cells.
pub fn setRoles(t: *Tree, r: Rows) void {
    const role = t.c.role;
    role[r.box] = @backingInt(a11y.Role.grid);
    role[r.box + 1] = @backingInt(a11y.Role.row);
    for (0..r.cols) |k| {
        role[r.header(k)] = @backingInt(a11y.Role.column_header);
        role[r.handle(k)] = @backingInt(a11y.Role.separator);
    }
    role[r.body()] = @backingInt(a11y.Role.row_group);
    for (0..r.rows) |i| {
        role[r.row(i)] = @backingInt(a11y.Role.row);
        for (0..r.cols) |k| role[r.cell(i, k)] = @backingInt(a11y.Role.cell);
    }
}

/// The `selected` state of the active cell, for the bridge; run before `a11y.states`.
pub fn setStates(s: *a11y.Semantics, r: Rows, row: u32, col: u32) void {
    s.c.state[r.cell(row, col)] |= a11y.State.bitsOf(.{ .selected = true });
}

// ---- runtime front end ----------------------------------------------------------------------

/// A table of `cols` columns: `headers` (one per column) above `cells` (row-major), with `st`
/// its state and `order_buf` (one entry per row) the caller's scratch for the sort order.
/// Returns the body's response.
pub fn table(f: *Frame, th: *const Theme, id: Id, comptime cols: usize, headers: []const []const u8, cells: []const []const u8, st: *State(cols), order_buf: []u32) Response {
    const rows: u32 = @intCast(cells.len / cols);
    // Input first: it moves widths and the sort the rows below show. Responses come from last
    // frame's interaction; `interact` marks the nodes and reports the same responses.
    var hr: [cols]Response = undefined;
    var gr: [cols]Response = undefined;
    var x0: [cols]f32 = undefined;
    for (0..cols) |k| {
        hr[k] = f.ctx.inter.response(headerId(id, k));
        gr[k] = f.ctx.inter.response(handleId(id, cols, k));
        x0[k] = f.lastRect(headerId(id, k)).x0;
    }
    const br = f.ctx.inter.response(id);
    update(st, th, rows, &hr, &gr, &x0, br, f.lastRect(id), f.in);
    order(cells, cols, st.sort, st.descending, order_buf[0..rows]);

    const box = f.open(.none, tableStyle(th));
    _ = f.open(.none, headerRowStyle(th));
    for (headers, 0..) |s, k| {
        var hs = headerStyle(th, st.widths[k]);
        hs.fill = headerFill(th, hr[k]);
        hs.value = sortValue(st.sort == k, st.descending);
        const h = f.open(headerId(id, k), hs);
        _ = f.interact(h, .button);
        _ = base.label(f, th, s);
        _ = f.leaf(.none, markStyle(th, st.widths[k], st.sort == k, st.descending));
        var gs = handleStyle(th, st.widths[k], gr[k]);
        gs.value = st.widths[k];
        const g = f.leaf(handleId(id, cols, k), gs);
        _ = f.interact(g, .any);
        f.setCursor(.resize_h, gr[k].hovered or gr[k].held);
        f.close();
    }
    f.close();
    var bs = bodyStyle(th);
    bs.value = @floatFromInt(st.row);
    const body = f.open(id, bs);
    const r = f.interact(body, .button);
    for (order_buf[0..rows], 0..) |data_row, i| {
        _ = f.open(.none, rowStyle(th));
        for (0..cols) |k| {
            _ = f.open(.none, cellStyle(th, st.widths[k], st.row == i and st.col == k, r.focused));
            _ = base.label(f, th, cells[data_row * cols + k]);
            f.close();
        }
        f.close();
    }
    f.close();
    f.close();
    setRoles(f.tree(), .{ .box = box.ix(), .cols = cols, .rows = rows });
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A table named `id` (its body; headers and handles are named after it), bound to the
    /// `State(cols)` field `table`, showing the strings fields `headers` (one per column) and
    /// `cells` (row-major), `cols` columns by `rows` rows. Every header and handle is a widget
    /// of its own.
    pub fn table(comptime th: Theme, comptime id: @EnumLiteral(), comptime state: @EnumLiteral(), comptime headers: @EnumLiteral(), comptime cells: @EnumLiteral(), comptime cols: u32, comptime rows: u32) Spec {
        @setEvalBranchQuota(10_000 + 100 * cols * rows);
        // The rows are styled when pushed, from the state's widths and sort, so the spec
        // carries only the structure.
        const name = @tagName(id);
        var hs: [cols]Spec = undefined;
        for (&hs, 0..) |*h, k| {
            h.* = spec_zig.row(.{}, .{
                base.ct.label(th, headers),
                Spec{ .kind = .col },
                Spec{ .kind = .col, .id = std.fmt.comptimePrint("{s}_r{d}", .{ name, k }) },
            });
            h.id = std.fmt.comptimePrint("{s}_h{d}", .{ name, k });
        }
        var cell_row: [cols]Spec = undefined;
        for (&cell_row) |*c| c.* = spec_zig.row(.{}, .{base.ct.label(th, cells)});
        var body_rows: [rows]Spec = undefined;
        for (&body_rows) |*r| r.* = spec_zig.row(.{}, cell_row);
        var body = spec_zig.col(.{}, body_rows);
        body.id = name;
        var s = spec_zig.col(.{}, .{ spec_zig.row(.{}, hs), body });
        s.bind = @tagName(state);
        return s;
    }

    /// The fields and size a `ct.table` node was built with.
    pub fn fields(comptime n: Spec) struct { name: [:0]const u8, state: []const u8, headers: []const u8, cells: []const u8, cols: u32, rows: u32 } {
        const head = n.children[0];
        const body = n.children[1];
        return .{
            .name = body.id.?,
            .state = n.bind.?,
            .headers = head.children[0].children[0].bind.?,
            .cells = body.children[0].children[0].children[0].bind.?,
            .cols = head.children.len,
            .rows = body.children.len,
        };
    }
};

/// Whether spec node `n` is a table made by `ct.table`: a column bound to a field.
fn isTable(comptime n: Spec) bool {
    return n.kind == .col and n.bind != null;
}

/// The comptime front end for a page of tables: rows, columns and labels as in
/// `base.ComptimeUi`, every column bound to a field a table made by `ct.table`.
pub fn ComptimeTable(comptime S: type, comptime spec: Spec, comptime th: Theme) type {
    const E = events.Events(spec);
    const Sig = signals.Signals(S, spec);
    inline for (comptime tablesOf(spec)) |n| {
        const v = ct.fields(n);
        validate(S, v.state, v.headers, v.cells, v.cols, v.rows);
    }
    const Tables = list_zig.CtFrame(flatten.count(spec) + 1, @max(list_zig.labelCount(spec), 1));
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = Sig;

        page: Tables = .{},
        signals: Sig.Runtime = .{},
        pointer: list_zig.CtPointer(E) = .{},
        font: Mono = .{},
        order_buf: [maxRows(spec)]u32 = undefined,

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        fn widgetOf(comptime name: []const u8) E.Widget {
            return comptime std.meta.stringToEnum(E.Widget, name).?;
        }

        pub fn frame(ui: *Self, in: *const Input) Output {
            const event = ui.pointer.step(in);
            inline for (comptime tablesOf(spec)) |n| {
                const v = comptime ct.fields(n);
                var hr: [v.cols]Response = undefined;
                var gr: [v.cols]Response = undefined;
                var x0: [v.cols]f32 = undefined;
                inline for (0..v.cols) |k| {
                    const hw = comptime widgetOf(std.fmt.comptimePrint("{s}_h{d}", .{ v.name, k }));
                    const gw = comptime widgetOf(std.fmt.comptimePrint("{s}_r{d}", .{ v.name, k }));
                    hr[k] = ui.pointer.response(hw, in);
                    hr[k].clicked = if (event) |e| e == hw else false;
                    gr[k] = ui.pointer.response(gw, in);
                    x0[k] = ui.pointer.rectOf(hw).x0;
                }
                const bw = comptime widgetOf(v.name);
                var br = ui.pointer.response(bw, in);
                br.clicked = if (event) |e| e == bw else false;
                var st = @field(ui.signals.state, v.state);
                update(&st, &th, v.rows, &hr, &gr, &x0, br, ui.pointer.rectOf(bw), in);
                ui.signals.set(comptime field(v.state), st);
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
            next.* += 1;
            if (n.kind == .label) {
                list_zig.pushLabel(tb, parent, &n.style, @field(state, n.bind.?), &th);
                return;
            }
            if (comptime !isTable(n)) {
                const i = tb.t.push(parent, if (n.id) |name| .hash(name) else .none, &n.style);
                inline for (n.children) |c| ui.push(c, i, next, in);
                tb.t.seal(i);
                return;
            }
            // A table (`ct.table`): rows as `table` builds them.
            next.* += comptime flatten.count(n) - 1;
            const v = comptime ct.fields(n);
            const id: Id = .hash(v.name);
            const st = @field(state, v.state);
            const headers: []const []const u8 = @field(state, v.headers);
            const cells: []const []const u8 = @field(state, v.cells);
            const order_buf = ui.order_buf[0..v.rows];
            order(cells, v.cols, st.sort, st.descending, order_buf);
            const box = tb.t.push(parent, .none, &tableStyle(&th));
            const head = tb.t.push(box, .none, &headerRowStyle(&th));
            inline for (0..v.cols) |k| {
                const hw = comptime widgetOf(std.fmt.comptimePrint("{s}_h{d}", .{ v.name, k }));
                const gw = comptime widgetOf(std.fmt.comptimePrint("{s}_r{d}", .{ v.name, k }));
                var hs = headerStyle(&th, st.widths[k]);
                hs.fill = headerFill(&th, ui.pointer.response(hw, in));
                hs.value = sortValue(st.sort == k, st.descending);
                const h = tb.t.push(head, headerId(id, k), &hs);
                list_zig.pushLabel(tb, h, &.{ .role = .label }, headers[k], &th);
                _ = tb.t.push(h, .none, &markStyle(&th, st.widths[k], st.sort == k, st.descending));
                var gs = handleStyle(&th, st.widths[k], ui.pointer.response(gw, in));
                gs.value = st.widths[k];
                _ = tb.t.push(h, handleId(id, v.cols, k), &gs);
                tb.t.seal(h);
            }
            tb.t.seal(head);
            const focused = ui.pointer.response(comptime widgetOf(v.name), in).focused;
            var bs = bodyStyle(&th);
            bs.value = @floatFromInt(st.row);
            const body = tb.t.push(box, id, &bs);
            for (order_buf, 0..) |data_row, i| {
                const row = tb.t.push(body, .none, &rowStyle(&th));
                for (0..v.cols) |k| {
                    const c = tb.t.push(row, .none, &cellStyle(&th, st.widths[k], st.row == i and st.col == k, focused));
                    list_zig.pushLabel(tb, c, &.{ .role = .label }, cells[data_row * v.cols + k], &th);
                    tb.t.seal(c);
                }
                tb.t.seal(row);
            }
            tb.t.seal(body);
            tb.t.seal(box);
            setRoles(&tb.t, .{ .box = box, .cols = v.cols, .rows = v.rows });
        }

        fn field(comptime name: []const u8) Sig.Field {
            return comptime std.meta.stringToEnum(Sig.Field, name).?;
        }
    };
}

/// The table nodes of `n`'s subtree.
fn tablesOf(comptime n: Spec) []const Spec {
    if (isTable(n)) return &.{n};
    var out: []const Spec = &.{};
    for (n.children) |c| out = out ++ tablesOf(c);
    return out;
}

/// The most rows any table in `n` has (at least 1): the comptime sort order's scratch.
fn maxRows(comptime n: Spec) usize {
    var m: usize = 1;
    for (tablesOf(n)) |t| m = @max(m, ct.fields(t).rows);
    return m;
}

// ---- example page -----------------------------------------------------------------------------

const file_headers = [_][]const u8{ "Name", "Kind", "Size" };
const file_cells = [_][]const u8{
    "notes.txt", "text",   "12",
    "photo.png", "image",  "2048",
    "app.zig",   "source", "730",
    "build.zig", "source", "95",
    "logo.svg",  "image",  "5",
};

/// The example page: a caption and a table of five files in three columns on a panel, in both
/// front ends, in theme `th`. Its tests and golden images (tools/widgetgolden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };

        /// Runtime front end: the application owns the strings, the table state and the
        /// sort order's scratch.
        pub const App = struct {
            table: State(3) = .{},
            order: [5]u32 = undefined,
            clicked: bool = false,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = base.label(f, &th, "Files");
                app.clicked = table(f, &th, .from("files"), 3, &file_headers, &file_cells, &app.table, &app.order).clicked;
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const PageState = struct {
            title: []const u8 = "Files",
            headers: []const []const u8 = &file_headers,
            cells: []const []const u8 = &file_cells,
            table: State(3) = .{},
        };
        pub const spec = spec_zig.col(panel, .{
            base.ct.label(th, .title),
            ct.table(th, .files, .table, .headers, .cells, 3, 5),
        });
        pub const Ui = ComptimeTable(PageState, spec, th);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 32, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

var harness: Example(theme).Run = .{};

/// The shown text of body cell (i, k) in `out`'s runtime tree.
fn cellText(h: anytype, t: *const Tree, r: Rows, i: usize, k: usize) []const u8 {
    const run = t.c.text[r.cell(i, k) + 1];
    const tx = &h.ctx.texts[h.ctx.cur];
    return h.ctx.strings[h.ctx.cur].buf[tx.c.start[run]..][0..tx.c.bytes[run]];
}

fn rowsOf(t: *const Tree) Rows {
    // The body carries the table's id; the table and its header row come before it.
    const body = t.find(.from("files"));
    return .{ .box = body - 2 - 4 * 3, .cols = 3, .rows = 5 };
}

test "table: roles, values and the active cell's state" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try h.frame(&in);
    h.app.table.sort = 2;
    h.app.table.row = 1;
    h.app.table.col = 2;
    h.ui.signals.state.table = h.app.table;
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const r = rowsOf(t);
    try testing.expectEqual(t.find(.from("files")), r.body());
    try testing.expectEqual(@backingInt(a11y.Role.grid), t.c.role[r.box]);
    try testing.expectEqual(@backingInt(a11y.Role.row), t.c.role[r.box + 1]);
    for (0..3) |k| {
        try testing.expectEqual(@backingInt(a11y.Role.column_header), t.c.role[r.header(k)]);
        try testing.expectEqual(@backingInt(a11y.Role.separator), t.c.role[r.handle(k)]);
        try testing.expectEqual(sortValue(k == 2, false), t.c.value[r.header(k)]);
        try testing.expectEqual(@as(f32, 96), t.c.value[r.handle(k)]);
    }
    try testing.expectEqual(@backingInt(a11y.Role.row_group), t.c.role[r.body()]);
    try testing.expectEqual(@backingInt(a11y.Role.cell), t.c.role[r.cell(4, 2)]);
    try testing.expectEqual(@as(f32, 1), t.c.value[r.body()]);
    try testing.expectEqual(@as(f32, 1), sortValue(true, false));
    try testing.expectEqual(@as(f32, -1), sortValue(true, true));

    var sbuf: [8192]u8 align(@import("../core/mem.zig").column_align) = undefined;
    var carver: @import("../core/mem.zig").Carver = .{ .buf = &sbuf };
    var sem = a11y.Semantics.init(&carver, t.cap);
    sem.clear();
    setStates(&sem, r, 1, 2);
    a11y.names(t, &sem);
    const sel = a11y.State.bitsOf(.{ .selected = true });
    try testing.expect(sem.c.state[r.cell(1, 2)] & sel != 0);
    try testing.expect(sem.c.state[r.cell(1, 1)] & sel == 0);
    // Cells and column headers are named by their text.
    try testing.expectEqual(t.c.text[r.cell(1, 2) + 1], sem.c.name[r.cell(1, 2)]);
    try testing.expectEqual(t.c.text[r.header(0) + 1], sem.c.name[r.header(0)]);
}

test "check: what a comptime table's state must have" {
    const Good = struct { t: State(2) = .{}, h: []const []const u8 = &.{}, c: []const []const u8 = &.{} };
    try testing.expectEqual(null, comptime check(Good, "t", "h", "c", 2, 3));
    try testing.expectEqualStrings("table: a table has at least one column and one row", comptime check(Good, "t", "h", "c", 0, 3).?);
    try testing.expectEqualStrings("table: state has no field 'x' for the table state", comptime check(Good, "x", "h", "c", 2, 3).?);
    try testing.expectEqualStrings("table: field 't' must be a table.State(3)", comptime check(Good, "t", "h", "c", 3, 3).?);
    try testing.expectEqualStrings("table: state has no field 'y' for strings", comptime check(Good, "t", "y", "c", 2, 3).?);
    const Bad = struct { t: State(2) = .{}, h: []const []const u8 = &.{}, c: []const u8 = "" };
    try testing.expectEqualStrings("table: strings field 'c' must be a []const []const u8", comptime check(Bad, "t", "h", "c", 2, 3).?);
}

test "ct.table: headers and handles are widgets, then the body" {
    const spec = comptime ct.table(theme, .files, .table, .headers, .cells, 3, 5);
    const E = events.Events(spec);
    try testing.expectEqual(7, E.widget_count);
    try testing.expectEqualSlices(E.Widget, &.{ .files_h0, .files_r0, .files_h1, .files_r1, .files_h2, .files_r2, .files }, &.{ E.widget(0), E.widget(1), E.widget(2), E.widget(3), E.widget(4), E.widget(5), E.widget(6) });
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("files", v.name);
    try testing.expectEqualStrings("table", v.state);
    try testing.expectEqualStrings("headers", v.headers);
    try testing.expectEqualStrings("cells", v.cells);
    try testing.expectEqual(3, v.cols);
    try testing.expectEqual(5, v.rows);
    // Table, header row, 3 x (header, label, mark, handle), body, 5 x (row + 3 x (cell, label)).
    try testing.expectEqual(2 + 12 + 1 + 35, flatten.count(spec));
}

test "order: a stable sort of the rows by one column" {
    var out: [5]u32 = undefined;
    order(&file_cells, 3, none, false, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, &out);
    order(&file_cells, 3, 1, false, &out);
    try testing.expectEqualSlices(u32, &.{ 1, 4, 2, 3, 0 }, &out);
    order(&file_cells, 3, 1, true, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 1, 4 }, &out);
    order(&file_cells, 3, 0, false, &out);
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4, 0, 1 }, &out);
}

test "sortBy, resize, keys: the behaviour as pure functions" {
    var st: State(3) = .{};
    sortBy(&st, 1);
    try testing.expectEqual(@as(u32, 1), st.sort);
    try testing.expect(!st.descending);
    sortBy(&st, 1);
    try testing.expect(st.descending);
    sortBy(&st, 2);
    try testing.expectEqual(@as(u32, 2), st.sort);
    try testing.expect(!st.descending);
    try testing.expectEqual(@as(f32, 50), resize(50, false, 0, 300));
    try testing.expectEqual(@as(f32, 120), resize(50, true, 30, 150));
    try testing.expectEqual(min_width, resize(50, true, 30, 31));
    try testing.expectEqual(max_width, resize(50, true, 30, 1e6));
    const km = list_zig.default_keys;
    const presses = [_]Input.Event{
        .{ .kind = .press, .code = km.down },    .{ .kind = .repeat, .code = km.down }, .{ .kind = .press, .code = km.right },
        .{ .kind = .release, .code = km.right }, .{ .kind = .press, .code = km.down },  .{ .kind = .press, .code = km.end },
    };
    st = .{};
    keys(&st, 3, &.{ .events = &presses });
    try testing.expectEqual(@as(u32, 2), st.row);
    try testing.expectEqual(@as(u32, 2), st.col);
    const back = [_]Input.Event{ .{ .kind = .press, .code = km.up }, .{ .kind = .press, .code = km.home }, .{ .kind = .press, .code = km.left } };
    keys(&st, 3, &.{ .events = &back });
    try testing.expectEqual(@as(u32, 1), st.row);
    try testing.expectEqual(@as(u32, 0), st.col);
}

test "table: both front ends agree, and columns follow their widths" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try h.frame(&in);
    h.app.table.widths = .{ 60, 120, 80 };
    h.app.table.sort = 1;
    h.ui.signals.state.table = h.app.table;
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const r = rowsOf(t);
    for (0..3) |k| try testing.expectApproxEqAbs(h.app.table.widths[k], t.rect(r.header(k)).w(), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 120), t.rect(r.cell(4, 1)).w(), 0.5);
    try testing.expectEqualStrings("photo.png", cellText(h, t, r, 0, 0));
    // The header under the pointer lights up; the cell at (0, 0) is active.
    in.pointer = .{ t.rect(r.header(1)).x0 + 10, t.rect(r.header(1)).y0 + 10 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(theme.control_hot.bitsOf(), t.c.look[r.header(1)].fill);
    try testing.expectEqual(theme.control.bitsOf(), t.c.look[r.header(0)].fill);
    try testing.expectEqual(theme.control.bitsOf(), t.c.look[r.cell(0, 0)].fill);
    try testing.expectEqual(@as(u32, 1), colAt(&h.app.table.widths, 16, 16 + 60));
    try testing.expectEqual(@as(u32, 2), colAt(&h.app.table.widths, 16, 1000));
    try testing.expectEqual(@as(u32, 0), colAt(&h.app.table.widths, 16, 0));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
