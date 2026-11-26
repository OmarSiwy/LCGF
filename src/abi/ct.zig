//! Static UIs across the seam: the comptime pipeline (ct_layout, ct_paint) for programs written
//! in C++ or Rust. A static UI's structure and style are fixed by its spec, so what Zig folds at
//! comptime is made once by `make` and shipped as read-only words:
//!
//! - the constant columns of the tree `Tree.push` builds from the spec, each padded for 16
//!   lanes, so any lane count reads them in place;
//! - the fold: the skeleton tree the passes run over, and the tables that expand its layout to
//!   every row (`tables.expand`);
//! - the paint templates, their order, batch keys and the labels' places among them.
//!
//! `make` runs at comptime in Zig's tests and at run time in lcgf-gen (tools/lcgf-gen/), over
//! the same `tables` functions `ct_layout.Layout` and `ct_paint.Paint` call (src/comptime/
//! tables.zig). The prebuilt `Ui` below reads the words: the tier-0 passes over a view whose
//! constant columns point into them and whose written columns into the caller's buffer, then
//! the expand, finalize and the template copy. Its draw lists equal Zig's comptime pipeline's
//! for the same spec, viewport and label text (the tests below, and bindings/check/run.sh).
//!
//! Dynamic regions (`when`, `list`, `choice`, windowed lists) are the comptime pipeline's too:
//! their rows are reserved, and each frame reads the selector fields from the state, masks the
//! dead rows out (ct_dynamic.Regions) and keeps choice alternatives in shared slots. Custom
//! widgets build rows at run time, so a spec with one is not a static UI. Checkboxes and
//! sliders are the comptime pipeline's: rows a host hit-tests itself.

const std = @import("std");
const fmt = @import("../core/fmt.zig");
const simd = @import("../core/simd.zig");
const tree = @import("../core/tree.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const layout = @import("../layout/layout.zig");
const tables = @import("../comptime/tables.zig");
const spec_zig = @import("../comptime/spec.zig");
const draw_list = @import("../draw/draw_list.zig");
const encode = @import("../draw/paint.zig").encode;
const Mono = @import("../text/protocol.zig").Mono;
const Texts = @import("../core/texts.zig").Texts;
const plan = @import("plan.zig");
const Style = types.Style;
const TextStyle = types.TextStyle;
const Id = types.Id;
const Quad = draw_list.Quad;
const DrawList = draw_list.DrawList;
const Columns = tree.Tree.Columns;
const Extra = tree.Extra;
pub const none = types.none;

pub const magic: u32 = 0x5443_434C; // "LCCT"
pub const version: u32 = 1;
/// Lanes every column is padded for: the widest build reads them too.
pub const pad_lanes = 16;
/// Bytes of label text one frame holds, by default.
pub const default_string_cap = 1024;

/// Rows of a column of `n` rows for any lane count up to `pad_lanes`: whole vectors plus one
/// spare, as `simd.rows` gives for the widest.
pub fn rowsMax(n: usize) usize {
    return std.mem.alignForward(usize, n, pad_lanes) + pad_lanes;
}

/// One array of `Tree.Columns`: a `[]T` field, or one axis of a `[k][]T` field.
pub const ColumnArray = struct { field: []const u8, axis: u32, size: u32 };

/// Every array of `Tree.Columns`, in declaration order.
pub const column_arrays: []const ColumnArray = blk: {
    var out: []const ColumnArray = &.{};
    const info = @typeInfo(Columns).@"struct";
    for (info.field_names, info.field_types) |name, FT| switch (@typeInfo(FT)) {
        .pointer => |p| out = out ++ [_]ColumnArray{.{ .field = name, .axis = 0, .size = @sizeOf(p.child) }},
        .array => |a| for (0..a.len) |k| {
            out = out ++ [_]ColumnArray{.{ .field = name, .axis = k, .size = @sizeOf(@typeInfo(a.child).pointer.child) }};
        },
        else => unreachable,
    };
    break :blk out;
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Whether a static UI's frame writes column `name` (ct_layout.Plain's `writes` for a UI with
/// no regions): the layout scratch but the precomputed gap totals, the outputs, `sense`
/// (finalize clears its padding rows, so it is copied in each frame) and `value` when a
/// checkbox or slider shows a state field.
/// With dynamic regions (`live`) also the columns the live mask is ANDed into and the gap
/// totals, which then follow the live child count; with a windowed list, `scroll`.
pub fn written(name: []const u8, shows: bool, live: bool, windows: bool) bool {
    const outputs = [_][]const u8{ "size", "pos", "rect", "vis", "child_clip", "visible", "sense" };
    const masked = [_][]const u8{ "max", "flow", "nkids", "gap_total" };
    return (contains(&tree.Tree.scratch, name) and !std.mem.eql(u8, name, "gap_total")) or
        contains(&outputs, name) or (shows and std.mem.eql(u8, name, "value")) or
        (live and contains(&masked, name)) or (windows and std.mem.eql(u8, name, "scroll"));
}

/// One tree of the words: the whole UI, or the skeleton its passes run over.
pub const Block = extern struct {
    n: u32 = 0,
    xlen: u32 = 0,
    /// Word offset of `column_arrays.len` words: each array's word offset, or `none` for an
    /// array the frame writes.
    cols: u32 = 0,
    /// `rowsMax(n + 1)` `Extra` rows.
    extras: u32 = 0,
    /// `rowsMax(n)` u8: the `sense` column, copied in each frame.
    sense: u32 = 0,
    /// `labels` u32: each label's row in this tree.
    label_rows: u32 = 0,
    /// `regions` `Region`s, in this tree's rows.
    regions: u32 = 0,
    /// With regions: the `max` (x, y) and `flow` columns the live mask is ANDed into, and
    /// with a windowed list `scroll` (x, y), each `rowsMax(n)` rows.
    max_src: [2]u32 = @splat(0),
    flow_src: u32 = 0,
    scroll_src: [2]u32 = @splat(0),
};

/// One dynamic region (ct_dynamic.Info) and where its selector is in the state.
pub const Region = extern struct {
    kind: u32,
    row: u32,
    end: u32,
    /// Rows of one list copy; 0 for other kinds.
    stride: u32,
    /// List copies or choice alternatives; 0 for a `when`.
    max: u32,
    /// A choice's `max + 1` windows (first row, row count), the last empty.
    alts: u32,
    /// The selector field: its byte offset in the state and its `plan.FieldType`.
    field_offset: u32,
    field_type: u32,
    /// A windowed list's scroll field (f32), or `none`, and its item height.
    scroll_offset: u32,
    height: f32,
};

/// The first words.
pub const Header = extern struct {
    magic: u32 = magic,
    version: u32 = version,
    /// `layout_hash` (set by `make`; the hash covers this struct).
    layout_hash: u32 = 0,
    /// Total words, header included.
    words: u32 = 0,
    /// The coordinate type rects are kept in: 0 for f32, else the bits of a signed integer.
    coord: u32 = 0,
    /// Some row clips its children (else `child_clip` is "no clip" everywhere).
    has_child_clip: u32 = 0,
    state_size: u32 = 0,
    state_align: u32 = 1,
    string_cap: u32 = default_string_cap,
    labels: u32 = 0,
    quads: u32 = 0,
    batches: u32 = 0,
    /// Rows laid out while compiling; 0: no skeleton, the passes run over `full`.
    folded: u32 = 0,
    regions: u32 = 0,
    has_windows: u32 = 0,
    /// The root itself is a `when`: its viewport goes when it is dead.
    root_when: u32 = 0,
    /// Retained geometry rows (ct_dynamic.Slots): `n` unless choice alternatives share them.
    slot_count: u32 = 0,
    /// `n` u32: each row's slot; `slot_count` u32: a row for each slot when none is live.
    slots: u32 = 0,
    slot_defaults: u32 = 0,
    full: Block = .{},
    skel: Block = .{},
    /// `labels` u32: each label's state field, as a byte offset of its `Str` in the state;
    /// `none` for a formatted label.
    label_offsets: u32 = 0,
    /// `labels` x (first segment, segments, text start, text bytes): each label's format in
    /// `segs` and `format_text`; `none` first for a label that shows a string field.
    label_formats: u32 = 0,
    /// `seg_count` x (kind | precision << 8, the argument's byte offset in the state, text
    /// start, text bytes): src/core/fmt.zig's segments, `fmt.Kind` values.
    seg_count: u32 = 0,
    segs: u32 = 0,
    /// The formats' text, `format_bytes` bytes.
    format_bytes: u32 = 0,
    format_text: u32 = 0,
    /// base (u32), rel x, rel y, size x, size y, keep_size (f32): n rows each.
    expand: [6]u32 = @splat(0),
    /// The state's fields; `fields` x (first, last): the rows a field's labels move
    /// (ct_layout's `dirtySpan`), `none` twice when no label shows it.
    fields: u32 = 0,
    spans: u32 = 0,
    /// `patch_count` x (field, template, target 0 fill / 1 border, the field's byte offset in the
    /// state): ct_paint.Patches' entries, by template.
    patch_count: u32 = 0,
    patches: u32 = 0,
    paint_node: u32 = 0,
    clip_node: u32 = 0,
    templates: u32 = 0,
    keys: u32 = 0,
    batch_first: u32 = 0,
    batch_count: u32 = 0,
    batch_key: u32 = 0,
    label_plans: u32 = 0,
};

/// FNV-1a of every type the words carry and of the column list: lcgf.h's `LCGF_CT_LAYOUT`.
pub const layout_hash: u32 = blk: {
    @setEvalBranchQuota(200_000);
    var h = std.hash.Fnv1a_32.init();
    h.update(std.mem.asBytes(&@as(u32, version)));
    for (column_arrays) |c| {
        h.update(c.field);
        h.update(std.mem.asBytes(&c.axis));
        h.update(std.mem.asBytes(&c.size));
    }
    h.update(std.mem.asBytes(&plan.layoutHashOf(.{ Header, Block, Region, Extra, tree.Look, Quad, tables.Label, draw_list.TextRun })));
    break :blk h.final();
};

// ---- the spec, as rows -------------------------------------------------------------------------

/// One row of a static UI, in `Tree.push` order (depth-first, parents first).
pub const Node = struct {
    style: Style = .{},
    parent: u32 = 0,
    /// One past the last row of the node's subtree.
    end: u32 = 1,
    id: Id = .none,
    /// The state field a label shows, or `none`: not a label, or a formatted one.
    label_field: u32 = none,
    /// A formatted label's format (`spec.text`, a `.zon` `.text`): its arguments are fields.
    format: ?plan.Format = null,
    /// A checkbox or slider showing a state field (its `value` column is written).
    shows: bool = false,
    /// A dynamic region on this node, its selector field, and for a windowed list its scroll
    /// field and item height.
    region: RegionKind = .none,
    region_field: u32 = none,
    scroll_field: u32 = none,
    height: f32 = 0,
    /// Colour fields whose rgb the node's quad takes in a patch (ct_paint.Patches `fill_rgb`,
    /// `border_rgb`), or `none`.
    fill_bind: u32 = none,
    border_bind: u32 = none,

    pub fn isLabel(nd: Node) bool {
        return nd.label_field != none or nd.format != null;
    }

    /// The label shows field `k`: it is its field, or one of its format's arguments.
    pub fn labelShows(nd: Node, k: u32) bool {
        if (nd.label_field == k) return true;
        if (nd.format) |f| return std.mem.indexOfScalar(u32, f.args, k) != null;
        return false;
    }
};

pub const RegionKind = enum(u32) { none, list, when, choice };

pub const Error = error{ OutOfMemory, BadTree, BadLabel, BadRegion, BadBind, Transform };

/// The rows of a comptime spec, with labels bound to `State`'s fields.
pub fn nodesOf(comptime State: type, comptime spec: spec_zig.Spec) [@import("../comptime/flatten.zig").count(spec)]Node {
    const n = @import("../comptime/flatten.zig").count(spec);
    @setEvalBranchQuota(10_000 + 1_000 * n);
    var out: [n]Node = undefined;
    var next: u32 = 0;
    walkSpec(State, spec, 0, &next, &out);
    return out;
}

fn walkSpec(comptime State: type, comptime s: spec_zig.Spec, comptime parent: u32, comptime next: *u32, comptime out: anytype) void {
    if (s.widget != null) @compileError("a custom widget builds its rows at run time: not a static UI");
    const i = next.*;
    next.* += 1;
    out[i] = .{
        .style = s.style,
        .parent = parent,
        .id = if (s.id) |name| .hash(name) else .none,
        .label_field = if (s.kind == .label and s.format == null) std.meta.fieldIndex(State, s.bind.?).? else none,
        .shows = s.bind != null and (s.kind == .checkbox or s.kind == .slider),
        .format = if (s.format) |f| blk: {
            var args: [f.args.len]u32 = undefined;
            for (f.args, &args) |name, *a| a.* = std.meta.fieldIndex(State, name).?;
            const final = args;
            break :blk .{ .text = f.text, .segs = fmt.compile(State, f.text, f.args), .args = &final };
        } else null,
    };
    if (s.region) |r| {
        out[i].region = switch (r.kind) {
            .list => .list,
            .when => .when,
            .choice => .choice,
        };
        out[i].region_field = std.meta.fieldIndex(State, r.bind).?;
        if (r.window) |w| {
            out[i].scroll_field = std.meta.fieldIndex(State, w.scroll).?;
            out[i].height = w.height;
        }
    }
    for (s.children) |c| walkSpec(State, c, i, next, out);
    out[i].end = next.*;
}

/// The coordinate bits for a fixed screen (columns.Coord): 0 (f32) without one.
pub fn coordBits(viewport: ?[2]f32) u32 {
    const vp = viewport orelse return 0;
    const m = @ceil(@max(vp[0], vp[1]));
    return if (m <= 127) 8 else if (m <= 32767) 16 else 32;
}

// ---- making the words --------------------------------------------------------------------------

const Writer = struct {
    arena: std.mem.Allocator,
    words: std.ArrayList(u32) = .empty,
    /// Every section written, for sharing equal ones.
    sections: std.ArrayList([2]u32) = .empty,

    /// Appends `bytes` at a 64-byte boundary (16 words), padded to whole words; an earlier
    /// section with the same bytes is shared instead. Returns its word offset.
    fn section(w: *Writer, bytes: []const u8) Error!u32 {
        const len: u32 = @intCast((bytes.len + 3) / 4);
        for (w.sections.items) |s| {
            if (s[1] == len and std.mem.eql(u8, std.mem.sliceAsBytes(w.words.items[s[0]..][0..len])[0..bytes.len], bytes)) return s[0];
        }
        while (w.words.items.len % 16 != 0) try w.words.append(w.arena, 0);
        const start: u32 = @intCast(w.words.items.len);
        try w.words.appendNTimes(w.arena, 0, len);
        @memcpy(std.mem.sliceAsBytes(w.words.items[start..][0..len])[0..bytes.len], bytes);
        try w.sections.append(w.arena, .{ start, len });
        return start;
    }

    /// `n` rows of `src`, zero-padded to `rows` rows.
    fn rows(w: *Writer, comptime T: type, src: []const T, rows_: usize) Error!u32 {
        const buf = try w.arena.alloc(T, rows_);
        @memset(std.mem.sliceAsBytes(buf), 0);
        @memcpy(buf[0..src.len], src);
        return w.section(std.mem.sliceAsBytes(buf));
    }
};

/// The array of `t`'s column `c`, as a slice of its element type.
fn columnArray(t: anytype, comptime c: ColumnArray) []u8 {
    const col = @field(t.c, c.field);
    const s = if (comptime @typeInfo(@TypeOf(col)) == .array) col[c.axis] else col;
    return std.mem.sliceAsBytes(s);
}

/// A tree pushed from `nodes` in the caller's arena, as `Tree.push` builds it at run time.
fn push(arena: std.mem.Allocator, nodes: []const Node) Error!tree.Tree {
    const n: u32 = @intCast(nodes.len);
    var counter: mem.Carver = .{ .buf = null };
    _ = tree.Tree.init(&counter, n);
    const buf = try arena.alignedAlloc(u8, .fromByteUnits(mem.column_align), counter.off);
    var carver: mem.Carver = .{ .buf = buf };
    var t = tree.Tree.init(&carver, n);
    for (nodes, 0..) |nd, i| {
        if (nd.parent >= @max(i, 1) and i != 0) return error.BadTree;
        _ = t.push(nd.parent, nd.id, &nd.style);
    }
    for (nodes, 0..) |nd, i| t.c.end[i] = nd.end;
    if (t.overflow) return error.BadTree;
    return t;
}

/// What a block's frame writes besides the outputs (`written`).
const Flags = struct { shows: bool, live: bool, windows: bool };

/// The regions of `nodes` (one tree's rows), as `Region`s with their choice windows written.
fn regionsOf(w: *Writer, nodes: []const Node, fields: []const plan.Field) Error![]Region {
    var out: std.ArrayList(Region) = .empty;
    for (nodes, 0..) |nd, i| if (nd.region != .none) {
        const row: u32 = @intCast(i);
        var kids: u32 = 0;
        var c = row + 1;
        while (c < nd.end) : (c = nodes[c].end) kids += 1;
        if (nd.region_field >= fields.len) return error.BadRegion;
        const f = fields[nd.region_field];
        const ok = switch (nd.region) {
            .list => f.type == .u32,
            .when => f.type == .bool,
            .choice => f.type == .u8 or f.type == .u32,
            .none => unreachable,
        };
        if (!ok) return error.BadRegion;
        var scroll: u32 = none;
        if (nd.scroll_field != none) {
            if (nd.scroll_field >= fields.len or fields[nd.scroll_field].type != .f32 or nd.region != .list or kids == 0) return error.BadRegion;
            scroll = fields[nd.scroll_field].offset;
        }
        // A choice's alternatives: each child's rows, then an empty window past the last.
        const alts = try w.arena.alloc([2]u32, kids + 1);
        var cur = row + 1;
        for (alts[0..kids]) |*win| {
            win.* = .{ cur, nodes[cur].end - cur };
            cur = nodes[cur].end;
        }
        alts[kids] = .{ 0, 0 };
        try out.append(w.arena, .{
            .kind = @backingInt(nd.region),
            .row = row,
            .end = nd.end,
            .stride = if (nd.region == .list and kids > 0) nodes[row + 1].end - (row + 1) else 0,
            .max = if (nd.region == .when) 0 else kids,
            .alts = if (nd.region == .choice) try w.section(std.mem.sliceAsBytes(alts)) else 0,
            .field_offset = f.offset,
            .field_type = @backingInt(f.type),
            .scroll_offset = scroll,
            .height = nd.height,
        });
    };
    return out.items;
}

/// Writes one tree's block: its constant columns (`gap_total` with `prepare`'s values, made
/// here), extras, sense, labels and regions, and the sources of the masked columns.
fn writeBlock(w: *Writer, t: *const tree.Tree, nodes: []const Node, fields: []const plan.Field, flags: Flags, label_rows: []const u32) Error!Block {
    const n = t.len;
    const gap = try w.arena.alloc(f32, n);
    tables.gapTotal(t, n, gap);
    var offs: [column_arrays.len]u32 = undefined;
    inline for (column_arrays, 0..) |c, k| {
        if (written(c.field, flags.shows, flags.live, flags.windows)) {
            offs[k] = none;
        } else {
            const own = columnArray(t, c)[0 .. n * c.size];
            const bytes = if (comptime std.mem.eql(u8, c.field, "gap_total")) std.mem.sliceAsBytes(gap) else own;
            const padded = try w.arena.alloc(u8, rowsMax(n) * c.size);
            @memset(padded, 0);
            @memcpy(padded[0..bytes.len], bytes);
            offs[k] = try w.section(padded);
        }
    }
    var b: Block = .{
        .n = n,
        .xlen = t.xlen,
        .cols = try w.section(std.mem.sliceAsBytes(&offs)),
        .extras = try w.rows(Extra, t.x.row[0..t.xlen], rowsMax(n + 1)),
        .sense = try w.rows(u8, t.c.sense[0..n], rowsMax(n)),
        .label_rows = try w.section(std.mem.sliceAsBytes(label_rows)),
        .regions = try w.section(std.mem.sliceAsBytes(try regionsOf(w, nodes, fields))),
    };
    if (flags.live) {
        for (0..2) |a| b.max_src[a] = try w.rows(f32, t.c.max[a][0..n], rowsMax(n));
        b.flow_src = try w.rows(f32, t.c.flow[0..n], rowsMax(n));
    }
    if (flags.windows) for (0..2) |a| {
        b.scroll_src[a] = try w.rows(f32, t.c.scroll[a][0..n], rowsMax(n));
    };
    return b;
}

/// ct_dynamic.Slots: each row's retained geometry row. Choice alternatives start at the same
/// row, and the next sibling follows the largest. Returns the slot count.
fn assignSlots(nodes: []const Node, i: u32, base: u32, slots: []u32) u32 {
    slots[i] = base;
    var end = base + 1;
    var c = i + 1;
    while (c < nodes[i].end) : (c = nodes[c].end) {
        const child = if (nodes[i].region == .choice) base + 1 else end;
        end = @max(end, assignSlots(nodes, c, child, slots));
    }
    return end;
}

/// What a static UI's spec gives `make` besides its rows.
pub const Options = struct {
    /// The state struct's fields, laid out (`plan.layoutState`).
    fields: []const plan.Field,
    state_size: u32,
    state_align: u32,
    /// Bits of the coordinate type (`coordBits`).
    coord: u32 = 0,
    string_cap: u32 = default_string_cap,
};

/// The words of the static UI of `nodes`, in `arena`.
pub fn make(arena: std.mem.Allocator, nodes: []const Node, o: Options) Error![]u32 {
    const n: u32 = @intCast(nodes.len);
    if (n == 0) return error.BadTree;
    var w: Writer = .{ .arena = arena };
    var h: Header = .{ .layout_hash = layout_hash, .coord = o.coord, .state_size = o.state_size, .state_align = o.state_align, .string_cap = o.string_cap };
    const header_words = std.mem.alignForward(usize, @sizeOf(Header) / 4, 16);
    try w.words.appendNTimes(arena, 0, header_words);

    const t = try push(arena, nodes);
    var flags: Flags = .{ .shows = false, .live = false, .windows = false };
    var labels: std.ArrayList(u32) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    var label_formats: std.ArrayList([4]u32) = .empty;
    var segs: std.ArrayList([4]u32) = .empty;
    var format_text: std.ArrayList(u8) = .empty;
    const volatile_rows = try arena.alloc(bool, n);
    @memset(volatile_rows, false);
    for (nodes, 0..) |nd, i| {
        flags.shows = flags.shows or nd.shows;
        if (nd.format) |f| {
            // Each argument a field its segment writes (fmt.Kind against the field's type).
            try labels.append(arena, @intCast(i));
            try offsets.append(arena, none);
            try label_formats.append(arena, .{ @intCast(segs.items.len), @intCast(f.segs.len), @intCast(format_text.items.len), @intCast(f.text.len) });
            for (f.segs) |g| {
                var off: u32 = 0;
                if (g.kind != .literal) {
                    if (g.arg >= f.args.len or f.args[g.arg] >= o.fields.len) return error.BadLabel;
                    const field = o.fields[f.args[g.arg]];
                    if (plan.argKind(field.type) != g.kind) return error.BadLabel;
                    off = field.offset;
                }
                try segs.append(arena, .{ @as(u32, @backingInt(g.kind)) | (@as(u32, g.prec) << 8), off, g.start, g.len });
            }
            try format_text.appendSlice(arena, f.text);
        } else if (nd.label_field != none) {
            if (nd.label_field >= o.fields.len or o.fields[nd.label_field].type != .str) return error.BadLabel;
            try labels.append(arena, @intCast(i));
            try offsets.append(arena, o.fields[nd.label_field].offset);
            try label_formats.append(arena, .{ none, 0, 0, 0 });
        }
        if (nd.region != .none) {
            h.regions += 1;
            flags.live = true;
            flags.windows = flags.windows or nd.scroll_field != none;
            // ct_dynamic's `volatile_rows`: the region's rows and every ancestor.
            @memset(volatile_rows[i..nd.end], true);
            var p: u32 = @intCast(i);
            while (p != 0) : (p = nodes[p].parent) volatile_rows[nodes[p].parent] = true;
        }
    }
    h.has_windows = @intFromBool(flags.windows);
    h.root_when = @intFromBool(nodes[0].region == .when);
    const L = labels.items;
    h.labels = @intCast(L.len);
    h.full = try writeBlock(&w, &t, nodes, o.fields, flags, L);
    h.label_offsets = try w.section(std.mem.sliceAsBytes(offsets.items));
    h.label_formats = try w.section(std.mem.sliceAsBytes(label_formats.items));
    h.seg_count = @intCast(segs.items.len);
    h.segs = try w.section(std.mem.sliceAsBytes(segs.items));
    h.format_bytes = @intCast(format_text.items.len);
    h.format_text = try w.section(format_text.items);
    for (0..n) |i| h.has_child_clip |= t.c.clips[i];
    h.has_child_clip = @intFromBool(h.has_child_clip != 0);
    const slots = try arena.alloc(u32, n);
    h.slot_count = assignSlots(nodes, 0, 0, slots);
    const defaults = try arena.alloc(u32, h.slot_count);
    for (slots, 0..) |slot, i| defaults[slot] = @intCast(i);
    h.slots = try w.section(std.mem.sliceAsBytes(slots));
    h.slot_defaults = try w.section(std.mem.sliceAsBytes(defaults));

    // The compiler's layout of the whole tree, in a 1000 px square with every region at its
    // first selection: with the labels measured empty (the skeleton's fold sizes,
    // `Layout.reference`) and without text (the paint sort).
    const ref_text = try reference(arena, w.words.items, &h, true);
    const ref_bare = try reference(arena, w.words.items, &h, false);

    // The fold.
    const has_label = try arena.alloc(bool, n);
    const indep = try arena.alloc(bool, n);
    const root = try arena.alloc(bool, n);
    const inside = try arena.alloc(bool, n);
    const fold = tables.foldPlan(&t, n, L, volatile_rows, has_label, indep, root, inside);
    h.folded = @intCast(fold.folded_rows);
    if (fold.folded_rows > 0) {
        const skel_row = try arena.alloc(u32, n);
        const k = tables.skeletonRows(n, inside, skel_row);
        // Skeleton rows before row j, for each row (`end` maps through it).
        const before = try arena.alloc(u32, n + 1);
        var c: u32 = 0;
        for (0..n) |j| {
            before[j] = c;
            c += @intFromBool(!inside[j]);
        }
        before[n] = c;
        const skel = try arena.alloc(Node, k);
        for (nodes, 0..) |nd, j| if (!inside[j]) {
            var sn = nd;
            sn.style = if (root[j]) tables.foldedLeaf(nd.style, .{ ref_text.size[0][j], ref_text.size[1][j] }) else nd.style;
            sn.parent = skel_row[nd.parent];
            sn.end = before[nd.end];
            skel[skel_row[j]] = sn;
        };
        const st = try push(arena, skel);
        const skel_labels = try arena.alloc(u32, L.len);
        for (skel_labels, L) |*sl, l| sl.* = skel_row[l];
        h.skel = try writeBlock(&w, &st, skel, o.fields, flags, skel_labels);

        const base = try arena.alloc(u32, n);
        var rel: [2][]f32 = undefined;
        var size: [2][]f32 = undefined;
        for (0..2) |a| {
            rel[a] = try arena.alloc(f32, n);
            size[a] = try arena.alloc(f32, n);
        }
        const keep = try arena.alloc(f32, n);
        const got = tables.expand(n, root, inside, .{ ref_text.pos[0], ref_text.pos[1] }, .{ ref_text.size[0], ref_text.size[1] }, base, rel, size, keep);
        std.debug.assert(got == k);
        h.expand = .{
            try w.section(std.mem.sliceAsBytes(base)),
            try w.section(std.mem.sliceAsBytes(rel[0])),
            try w.section(std.mem.sliceAsBytes(rel[1])),
            try w.section(std.mem.sliceAsBytes(size[0])),
            try w.section(std.mem.sliceAsBytes(size[1])),
            try w.section(std.mem.sliceAsBytes(keep)),
        };
    }

    // Paint.
    const alpha = try arena.alloc(f32, t.xlen);
    const clip_radii = try arena.alloc([4]f32, t.xlen);
    tables.inherit(&t, alpha, clip_radii) catch return error.Transform;
    const in_rows = try arena.alloc(u32, n);
    const m = tables.paintRows(&t, n, alpha, in_rows);
    const group = try arena.alloc(u32, n);
    tables.foldGroups(&t, n, root, group);
    const painted = try arena.alloc(u32, m);
    const done = try arena.alloc(bool, m);
    tables.sortByKey(&t, in_rows[0..m], group, .{ ref_bare.pos[0], ref_bare.pos[1] }, .{ ref_bare.size[0], ref_bare.size[1] }, painted, done);
    const order = try arena.alloc(u32, n);
    tables.paintOrder(n, in_rows[0..m], painted, order);
    const plans = try arena.alloc(tables.Label, L.len);
    tables.labelPlans(&t, order, painted, L, alpha, plans);
    const quads = try arena.alloc(Quad, m);
    tables.templates(&t, painted, alpha, clip_radii, quads);
    const keys = try arena.alloc(u32, m);
    const bfirst = try arena.alloc(u32, m);
    const bcount = try arena.alloc(u32, m);
    const bkey = try arena.alloc(u32, m);
    const nb = tables.batches(&t, painted, keys, bfirst, bcount, bkey);
    const clip_node = try arena.alloc(u32, m);
    for (clip_node, painted) |*cn, i| cn.* = t.c.parent[i];
    h.quads = @intCast(m);
    h.batches = @intCast(nb);
    h.paint_node = try w.section(std.mem.sliceAsBytes(painted));
    h.clip_node = try w.section(std.mem.sliceAsBytes(clip_node));
    h.templates = try w.section(std.mem.sliceAsBytes(quads));
    h.keys = try w.section(std.mem.sliceAsBytes(keys));
    h.batch_first = try w.section(std.mem.sliceAsBytes(bfirst[0..nb]));
    h.batch_count = try w.section(std.mem.sliceAsBytes(bcount[0..nb]));
    h.batch_key = try w.section(std.mem.sliceAsBytes(bkey[0..nb]));
    h.label_plans = try w.section(std.mem.sliceAsBytes(plans));

    // Each field's dirty span: the labels showing it, through their relayout boundaries.
    const bounds = try arena.alloc(u32, L.len);
    tables.boundaries(&t, L, bounds);
    const changed = try arena.alloc(bool, L.len);
    const spans = try arena.alloc([2]u32, o.fields.len);
    for (spans, 0..) |*sp, k| {
        for (changed, L) |*ch, l| ch.* = nodes[l].labelShows(@intCast(k));
        sp.* = tables.dirtySpan(&t, bounds, changed) orelse .{ none, none };
    }
    h.fields = @intCast(o.fields.len);
    h.spans = try w.section(std.mem.sliceAsBytes(spans));
    // The patches, by template, as Patches.list orders them: fill, then border.
    var patches: std.ArrayList([4]u32) = .empty;
    for (nodes) |nd| for ([_]u32{ nd.fill_bind, nd.border_bind }) |b| {
        if (b != none and (b >= o.fields.len or o.fields[b].type != .color)) return error.BadBind;
    };
    for (nodes, 0..) |nd, i| if (nd.fill_bind != none or nd.border_bind != none) {
        if (std.mem.indexOfScalar(u32, painted, @intCast(i)) == null) return error.BadBind;
    };
    for (painted, 0..) |i, k| {
        if (nodes[i].fill_bind != none) try patches.append(arena, .{ nodes[i].fill_bind, @intCast(k), 0, o.fields[nodes[i].fill_bind].offset });
        if (nodes[i].border_bind != none) try patches.append(arena, .{ nodes[i].border_bind, @intCast(k), 1, o.fields[nodes[i].border_bind].offset });
    }
    h.patch_count = @intCast(patches.items.len);
    h.patches = try w.section(std.mem.sliceAsBytes(patches.items));

    while (w.words.items.len % 16 != 0) try w.words.append(arena, 0);
    h.words = @intCast(w.words.items.len);
    @memcpy(w.words.items[0 .. @sizeOf(Header) / 4], std.mem.bytesAsSlice(u32, std.mem.asBytes(&h)));
    return w.words.items;
}

const Reference = struct { pos: [2][]f32, size: [2][]f32 };

/// The passes (not finalize) over the whole tree of `words` in a 1000 px square, every region
/// at its first selection, labels measured with no bytes when `text`: what ct_layout runs
/// while compiling.
fn reference(arena: std.mem.Allocator, words: []const u32, h: *const Header, text: bool) Error!Reference {
    var counter: mem.Carver = .{ .buf = null };
    _ = Run.carve(&counter, words, h, &h.full);
    _ = Run.carveTexts(&counter, h.labels);
    const buf = try arena.alignedAlloc(u8, .fromByteUnits(mem.column_align), counter.off);
    var carver: mem.Carver = .{ .buf = buf };
    var run = Run.carve(&carver, words, h, &h.full);
    var tx = Run.carveTexts(&carver, h.labels);
    const spans = try arena.alloc([2]u32, h.labels);
    @memset(spans, .{ 0, 0 });
    const sel = try arena.alloc(Select, h.regions);
    @memset(sel, .{});
    run.passes(&tx, spans, sel, .{ 1000, 1000 }, text);
    var out: Reference = undefined;
    for (0..2) |a| {
        out.pos[a] = try arena.dupe(f32, run.v.c.pos[a][0..h.full.n]);
        out.size[a] = try arena.dupe(f32, run.v.c.size[a][0..h.full.n]);
    }
    return out;
}

// ---- the frame ---------------------------------------------------------------------------------

/// One region's selection this frame (ct_dynamic.Select).
pub const Select = struct { n: u32 = 0, first: u32 = 0, offset: f32 = 0 };

/// ct_dynamic's `selectWindow`: the live copies of a windowed list scrolled `scroll` px.
fn selectWindow(count: u32, visible: u32, height: f32, scroll: f32) Select {
    const h: f64 = height;
    const max_scroll = @as(f64, @floatFromInt(count -| visible)) * h;
    const px = @min(@max(@as(f64, scroll), 0), max_scroll);
    const first: u32 = @intFromFloat(@floor(px / h));
    const offset: f32 = @floatCast(px - @as(f64, @floatFromInt(first)) * h);
    return .{ .first = first, .offset = offset, .n = @min(count - first, visible + @intFromBool(offset > 0)) };
}

/// What the tier-0 passes take as their tree: constant columns in the words, written ones in
/// the caller's buffer (ct_layout.Plain's `View` with a run-time row count).
const View = struct {
    len: u32,
    c: Columns,
    x: struct { row: []const Extra },
};

/// One block over its words and its share of the buffer.
const Run = struct {
    v: View,
    sense: []const u8,
    label_rows: []const u32,
    regions: []const Region,
    words: []const u32,
    max_src: [2][]const f32,
    flow_src: []const f32,
    scroll_src: [2][]const f32,
    /// This frame's live mask, one word per row (ct_dynamic.Regions.mask).
    mask: []u32,
    root_when: bool,

    fn carve(carver: *mem.Carver, words: []const u32, h: *const Header, b: *const Block) Run {
        const n = b.n;
        const rows = rowsMax(n);
        const offs: *const [column_arrays.len]u32 = @ptrCast(words[b.cols..][0..column_arrays.len]);
        const live = h.regions > 0;
        const windows = h.has_windows != 0;
        var r: Run = .{
            .v = .{ .len = n, .c = undefined, .x = .{ .row = at(Extra, words, b.extras, rowsMax(n + 1)) } },
            .sense = at(u8, words, b.sense, rows),
            .label_rows = at(u32, words, b.label_rows, h.labels),
            .regions = at(Region, words, b.regions, h.regions),
            .words = words,
            .max_src = if (live) .{ at(f32, words, b.max_src[0], rows), at(f32, words, b.max_src[1], rows) } else .{ &.{}, &.{} },
            .flow_src = if (live) at(f32, words, b.flow_src, rows) else &.{},
            .scroll_src = if (windows) .{ at(f32, words, b.scroll_src[0], rows), at(f32, words, b.scroll_src[1], rows) } else .{ &.{}, &.{} },
            .mask = carver.slice(u32, if (live) rows else 0),
            .root_when = h.root_when != 0,
        };
        inline for (column_arrays, 0..) |c, k| {
            const FT = @FieldType(Columns, c.field);
            const T = switch (@typeInfo(FT)) {
                .pointer => |p| p.child,
                .array => |a| @typeInfo(a.child).pointer.child,
                else => unreachable,
            };
            const s: []T = if (offs[k] == none) carver.slice(T, rows) else @constCast(at(T, words, offs[k], rows));
            if (comptime @typeInfo(FT) == .array) {
                @field(r.v.c, c.field)[c.axis] = s;
            } else @field(r.v.c, c.field) = s;
        }
        return r;
    }

    fn carveTexts(carver: *mem.Carver, labels: usize) Texts {
        const cap: u32 = @intCast(@max(labels, 1));
        return .{ .len = @intCast(labels), .cap = cap, .c = carver.columns(Texts.Columns, rowsMax(cap)) };
    }

    /// The live mask of `sel` (ct_dynamic.Regions.mask): rows outside every region live, a row
    /// inside regions live when each of them keeps it.
    fn liveMask(r: *Run, sel: []const Select) void {
        const rows = simd.rows(r.v.len);
        const m = r.mask[0..rows];
        @memset(m, ~@as(u32, 0));
        for (r.regions, sel) |g, s| {
            const kind: RegionKind = @fromBackingInt(@intCast(g.kind));
            const first = if (kind == .when) g.row else g.row + 1;
            var lo: u32 = first;
            var len: u32 = undefined;
            switch (kind) {
                .list => len = @min(s.n, g.max) * g.stride,
                .when => len = @min(s.n, 1) * (g.end - g.row),
                .choice => {
                    const win = at([2]u32, r.words, g.alts, g.max + 1)[@min(s.n, g.max)];
                    lo = win[0];
                    len = win[1];
                },
                .none => unreachable,
            }
            for (first..g.end) |j| m[j] &= 0 -% @as(u32, @intFromBool(@as(u32, @intCast(j)) -% lo < len));
        }
    }

    /// `Plain.passesLiveText`: every pass but finalize.
    fn passes(r: *Run, tx: *Texts, spans: []const [2]u32, sel: []const Select, viewport: [2]f32, text: bool) void {
        const c = &r.v.c;
        const n = r.v.len;
        // The rows this build's lanes reach, as Plain's scratch has them.
        const rows = simd.rows(n);
        @memcpy(c.sense[0..rows], r.sense[0..rows]);
        const measure = text and r.label_rows.len > 0;
        if (measure) {
            const ts: TextStyle = .{};
            for (r.label_rows, spans, 0..) |row, sp, k| {
                tx.c.node[k] = row;
                tx.c.start[k] = sp[0];
                tx.c.bytes[k] = sp[1];
                tx.c.px[k] = ts.px;
                tx.c.color[k] = ts.color.bitsOf();
                tx.c.font[k] = @backingInt(ts.font);
                tx.c.wrap[k] = @floatFromInt(@intFromBool(ts.wrap));
                tx.c.w[k] = 0;
                tx.c.h[k] = 0;
                tx.c.avail[k] = 0;
            }
            (Mono{}).measure(tx);
        }
        if (r.regions.len > 0) {
            // `applyMask`: a dead row gets `max` 0 on both axes, `flow` 0 and `sense` 0, and
            // `nkids` counts in-flow live children only.
            r.liveMask(sel);
            const m = r.mask;
            for (0..rows) |i| {
                inline for (0..2) |a| c.max[a][i] = @bitCast(@as(u32, @bitCast(r.max_src[a][i])) & m[i]);
                c.flow[i] = @bitCast(@as(u32, @bitCast(r.flow_src[i])) & m[i]);
                c.sense[i] &= @truncate(m[i]);
            }
            @memset(c.nkids[0..rows], 0);
            for (1..n) |j| c.nkids[c.parent[j]] += c.flow[j];
            if (r.scroll_src[0].len > 0) {
                inline for (0..2) |a| @memcpy(c.scroll[a][0..rows], r.scroll_src[a][0..rows]);
                for (r.regions, sel) |g, s| if (g.scroll_offset != none) {
                    c.scroll[1][g.row] = s.offset;
                };
            }
            layout.prepare(&r.v);
        } else {
            // `clear`: the accumulators fit, resolve and place add into.
            inline for (0..2) |a| {
                @memset(c.fit[a][0..rows], 0);
                @memset(c.grow_sum[a][0..rows], 0);
                @memset(c.used[a][0..rows], 0);
            }
            @memset(c.cursor[0..rows], 0);
        }
        // resolve assigns the viewport directly to the root, bypassing its masked maximum.
        const shown = if (r.root_when) sel[0].n != 0 else true;
        const wrap = comptime (TextStyle{}).wrap;
        if (measure) layout.applyText(&r.v, tx, .x);
        layout.fit(&r.v, .x);
        layout.resolve(&r.v, .x, simd.selF(shown, viewport[0], 0));
        if (measure and wrap) layout.textAvail(&r.v, tx);
        if (measure and wrap) (Mono{}).wrap(tx);
        if (measure) layout.applyText(&r.v, tx, .y);
        layout.fit(&r.v, .y);
        layout.resolve(&r.v, .y, simd.selF(shown, viewport[1], 0));
        layout.place(&r.v);
    }
};

fn at(comptime T: type, words: []const u32, off: u32, n: usize) []const T {
    const p: [*]const T = @ptrCast(@alignCast(words.ptr + off));
    return p[0..n];
}

/// A static UI, placed at the start of the caller's buffer by `init`.
pub const Ui = struct {
    words: []const u32,
    h: *const Header,
    full: Run,
    skel: Run,
    tx: Texts,
    spans: [][2]u32,
    strings: []u8,
    sel: []Select,
    /// Each slot's live row this frame (ct_layout's `slot_source`), when slots are shared.
    slot_source: []u32,
    d: DrawList,

    pub const InitError = error{ NotTables, Version, LayoutHash, Truncated, BufferTooSmall, Unaligned };

    /// Checks the header of `words`.
    pub fn check(words: []const u32) InitError!*const Header {
        if (words.len < @sizeOf(Header) / 4) return error.NotTables;
        if (@intFromPtr(words.ptr) % 4 != 0) return error.Unaligned;
        const h: *const Header = @ptrCast(words.ptr);
        if (h.magic != magic) return error.NotTables;
        if (h.version != version) return error.Version;
        if (h.layout_hash != layout_hash) return error.LayoutHash;
        if (h.words > words.len) return error.Truncated;
        return h;
    }

    fn carve(carver: *mem.Carver, words: []const u32, h: *const Header) Ui {
        const full = Run.carve(carver, words, h, &h.full);
        const skel = if (h.folded > 0) Run.carve(carver, words, h, &h.skel) else full;
        return .{
            .words = words,
            .h = h,
            .full = full,
            .skel = skel,
            .tx = Run.carveTexts(carver, h.labels),
            .spans = carver.slice([2]u32, @max(h.labels, 1)),
            .strings = carver.slice(u8, h.string_cap),
            .sel = carver.slice(Select, h.regions),
            .slot_source = carver.slice(u32, if (h.slot_count != h.full.n) h.slot_count else 0),
            .d = DrawList.init(carver, h.quads, h.labels, 0),
        };
    }

    fn start() usize {
        return std.mem.alignForward(usize, @sizeOf(Ui), mem.column_align);
    }

    /// Bytes one UI of `words` needs, for any lane count.
    pub fn bytes(words: []const u32) InitError!usize {
        const h = try check(words);
        var counter: mem.Carver = .{ .buf = null, .off = start() };
        _ = carve(&counter, words, h);
        return counter.off;
    }

    /// Checks `words` and places a UI at the start of `buf` (aligned to `mem.column_align`).
    pub fn init(words: []const u32, buf: []u8) InitError!*Ui {
        const h = try check(words);
        if (@intFromPtr(buf.ptr) % mem.column_align != 0) return error.Unaligned;
        if (buf.len < try bytes(words)) return error.BufferTooSmall;
        var carver: mem.Carver = .{ .buf = @alignCast(buf), .off = start() };
        const ui: *Ui = @ptrCast(@alignCast(buf.ptr));
        ui.* = carve(&carver, words, h);
        return ui;
    }

    fn get(ui: *const Ui, comptime T: type, off: u32, n: usize) []const T {
        return at(T, ui.words, off, n);
    }

    fn getBytes(ui: *const Ui, off: u32, n: usize) []const u8 {
        return std.mem.sliceAsBytes(ui.words[off..])[0..n];
    }

    /// ct_dynamic.Regions.select: each region's selector field as a number (`state` laid out
    /// as `plan.layoutState` says), a windowed list's live copies from its scroll field.
    fn select(ui: *Ui, state: [*]const u8) void {
        for (ui.full.regions, ui.sel) |g, *s| {
            const p = state + g.field_offset;
            const v: u32 = switch (@as(plan.FieldType, @fromBackingInt(@intCast(g.field_type)))) {
                .bool, .u8 => p[0],
                .u32 => std.mem.readInt(u32, p[0..4], .little),
                else => 0,
            };
            s.* = if (g.scroll_offset != none)
                selectWindow(v, g.max - 1, g.height, @bitCast(std.mem.readInt(u32, (state + g.scroll_offset)[0..4], .little)))
            else
                .{ .n = v };
        }
    }

    /// One frame: the labels' text and the regions' selectors from `state`, laid out in a
    /// `viewport`-sized area and painted. The draw list is read in place until the next frame.
    pub fn frame(ui: *Ui, state: [*]const u8, viewport: [2]f32) *const DrawList {
        const h = ui.h;
        // The labels' text, gathered into the frame's strings in label order.
        var at_: u32 = 0;
        for (ui.get(u32, h.label_offsets, h.labels), ui.get([4]u32, h.label_formats, h.labels), ui.spans[0..h.labels]) |off, lf, *sp| {
            var sink: fmt.Sink = .{ .buf = ui.strings[at_..] };
            if (lf[0] == none) {
                const s: *align(1) const [2]usize = @ptrCast(state + off);
                if (s[1] > 0) sink.put(@as([*]const u8, @ptrFromInt(s[0]))[0..s[1]]);
            } else {
                const text = ui.getBytes(h.format_text, h.format_bytes)[lf[2]..][0..lf[3]];
                for (ui.get([4]u32, h.segs, h.seg_count)[lf[0]..][0..lf[1]]) |g| {
                    const p = state + g[1];
                    switch (@as(fmt.Kind, @fromBackingInt(@as(u8, @truncate(g[0]))))) {
                        .literal => sink.put(text[g[2]..][0..g[3]]),
                        .str => {
                            const s: *align(1) const [2]usize = @ptrCast(p);
                            if (s[1] > 0) sink.put(@as([*]const u8, @ptrFromInt(s[0]))[0..s[1]]);
                        },
                        .bool => sink.putBool(p[0] != 0),
                        .u32 => sink.putUint(std.mem.readInt(u32, p[0..4], .little)),
                        .u8 => sink.putUint(p[0]),
                        .f32 => sink.putF32(@bitCast(std.mem.readInt(u32, p[0..4], .little)), @truncate(g[0] >> 8)),
                    }
                }
            }
            sp.* = .{ at_, @intCast(sink.len) };
            at_ += @intCast(sink.len);
        }
        ui.select(state);
        const spans = ui.spans[0..h.labels];
        const n = h.full.n;
        const full = &ui.full;
        if (h.folded == 0) {
            full.passes(&ui.tx, spans, ui.sel, viewport, true);
        } else {
            ui.skel.passes(&ui.tx, spans, ui.sel, viewport, true);
            const sk = &ui.skel.v.c;
            const base = ui.get(u32, h.expand[0], n);
            const rel = [2][]const f32{ ui.get(f32, h.expand[1], n), ui.get(f32, h.expand[2], n) };
            const size = [2][]const f32{ ui.get(f32, h.expand[3], n), ui.get(f32, h.expand[4], n) };
            const keep = ui.get(f32, h.expand[5], n);
            const c = &full.v.c;
            for (0..n) |j| {
                const b = base[j];
                inline for (0..2) |a| {
                    c.pos[a][j] = sk.pos[a][b] + rel[a][j];
                    c.size[a][j] = sk.size[a][b] * keep[j] + size[a][j];
                }
            }
            @memcpy(c.sense[0..simd.rows(n)], full.sense[0..simd.rows(n)]);
            if (h.regions > 0) {
                full.liveMask(ui.sel);
                for (c.sense[0..simd.rows(n)], full.mask[0..simd.rows(n)]) |*x, k| x.* &= @truncate(k);
            }
        }
        // `setSlotSources`: each shared slot shows its live row, else its default.
        if (ui.slot_source.len > 0) {
            @memcpy(ui.slot_source, ui.get(u32, h.slot_defaults, h.slot_count));
            for (ui.get(u32, h.slots, n), full.mask[0..n], 0..) |slot, live, i| {
                ui.slot_source[slot] = simd.selU(live != 0, @intCast(i), ui.slot_source[slot]);
            }
        }
        layout.finalize(&full.v);
        ui.paint(ui.strings[0..at_]);
        ui.patchAll(state);
        return &ui.d;
    }

    /// The bound colours' rgb into their quads (ct_paint.Patches.apply for every field), the
    /// alpha the quad's style gave kept. A template whose quad is not drawn this frame is skipped.
    fn patchAll(ui: *Ui, state: [*]const u8) void {
        const h = ui.h;
        if (h.patch_count == 0) return;
        const all = ui.d.quad_len == h.quads;
        const visible = ui.full.v.c.visible;
        const paint_node = ui.get(u32, h.paint_node, h.quads);
        var cursor: u32 = 0;
        var seen: u32 = 0;
        for (ui.get([4]u32, h.patches, h.patch_count)) |p| {
            const k = p[1];
            var row = k;
            if (!all) {
                for (cursor..k) |j| seen += @intFromBool(visible[paint_node[j]] != 0);
                cursor = k;
                if (visible[paint_node[k]] == 0) continue;
                row = seen;
            }
            const bits = std.mem.readInt(u32, state[p[3]..][0..4], .little) & 0xffffff;
            const q = &ui.d.quads[row];
            if (p[2] == 0) q.fill = (q.fill & 0xff000000) | bits else q.border_color = (q.border_color & 0xff000000) | bits;
        }
    }

    const V4 = @Vector(4, f32);
    const sign: V4 = .{ 1, 1, -1, -1 };

    /// The row whose geometry descriptor `i` reads: its slot's live row when slots are shared.
    inline fn geometryRow(ui: *const Ui, i: u32) u32 {
        if (ui.slot_source.len == 0) return i;
        return ui.slot_source[ui.get(u32, ui.h.slots, ui.h.full.n)[i]];
    }

    /// Rect of row i as the comptime UI keeps it: in its coordinate type.
    inline fn rectOf(ui: *const Ui, i: u32) V4 {
        const c = &ui.full.v.c;
        const g = ui.geometryRow(i);
        var r: V4 = .{ c.rect[0][g], c.rect[1][g], c.rect[2][g], c.rect[3][g] };
        if (ui.h.coord != 0) {
            const hi: f32 = @floatFromInt((@as(i64, 1) << @intCast(ui.h.coord - 1)) - 1);
            const lo: f32 = -hi - 1;
            inline for (0..4) |k| r[k] = @floatFromInt(@as(i32, @intFromFloat(@min(@max(r[k], lo), hi))));
        }
        return r;
    }

    inline fn clipOf(ui: *const Ui, i: u32) [4]f32 {
        if (ui.h.has_child_clip == 0) return @as(V4, @splat(-std.math.inf(f32))) * sign;
        return @as(V4, ui.full.v.c.child_clip[ui.geometryRow(i)]) * sign;
    }

    const Cursor = struct { quad: u32 = 0, op: u32 = 0 };

    fn emitQuads(ui: *Ui, first: usize, end: usize, cursor: *Cursor) void {
        const h = ui.h;
        const m = h.quads;
        const node = ui.get(u32, h.paint_node, m);
        const clip_node = ui.get(u32, h.clip_node, m);
        const templates = ui.get(Quad, h.templates, m);
        const keys = ui.get(u32, h.keys, m);
        const visible = ui.full.v.c.visible;
        const d = &ui.d;
        for (first..end) |k| {
            const i = node[k];
            var quad = templates[k];
            quad.rect = ui.rectOf(i);
            quad.clip = ui.clipOf(clip_node[k]);
            d.quads[cursor.quad] = quad;
            d.op.kind[cursor.op] = @backingInt(DrawList.Kind.quads);
            d.op.key[cursor.op] = keys[k];
            d.op.ref[cursor.op] = cursor.quad;
            cursor.quad += visible[i];
            cursor.op += visible[i];
        }
    }

    /// ct_paint's `emit` and `emitLiveText`.
    fn paint(ui: *Ui, strings: []const u8) void {
        const h = ui.h;
        const m = h.quads;
        const d = &ui.d;
        var cursor: Cursor = .{};
        if (h.labels == 0) {
            ui.emitQuads(0, m, &cursor);
            d.quad_len = cursor.quad;
            d.op_len = cursor.op;
            d.run_len = 0;
            d.custom_len = 0;
            if (cursor.quad == m) {
                const nb = h.batches;
                @memset(d.cmd.kind[0..nb], @backingInt(DrawList.Kind.quads));
                @memcpy(d.cmd.first[0..nb], ui.get(u32, h.batch_first, nb));
                @memcpy(d.cmd.count[0..nb], ui.get(u32, h.batch_count, nb));
                @memcpy(d.cmd.key[0..nb], ui.get(u32, h.batch_key, nb));
                d.cmd_len = nb;
            } else encode(d);
            d.strings = strings;
            return;
        }
        const style: TextStyle = .{};
        const visible = ui.full.v.c.visible;
        // In the folded frame the whole tree's mask was made for sense; unfolded, by the passes.
        const live = h.regions > 0;
        var first: u32 = 0;
        var r: u32 = 0;
        for (ui.get(tables.Label, h.label_plans, h.labels), ui.spans[0..h.labels]) |label, span| {
            ui.emitQuads(first, label.quad_end, &cursor);
            first = label.quad_end;
            d.runs[r] = .{
                .rect = ui.rectOf(label.node) + @as(V4, label.padding),
                .clip = ui.clipOf(label.parent),
                .start = span[0],
                .bytes = span[1],
                .px = style.px,
                .color = label.color,
                .font = @backingInt(style.font),
            };
            d.op.kind[cursor.op] = @backingInt(DrawList.Kind.text);
            d.op.key[cursor.op] = 0;
            d.op.ref[cursor.op] = r;
            cursor.op += visible[label.node];
            r += @intFromBool(!live or ui.full.mask[label.node] != 0);
        }
        ui.emitQuads(first, m, &cursor);
        d.quad_len = cursor.quad;
        d.op_len = cursor.op;
        d.run_len = r;
        d.custom_len = 0;
        d.strings = strings;
        encode(d);
    }
};

// ---- the C functions ---------------------------------------------------------------------------

const seam = @import("seam.zig");

fn status(e: Ui.InitError) c_int {
    return @backingInt(@as(seam.Status, switch (e) {
        error.NotTables => .not_tables,
        error.Version => .version,
        error.LayoutHash => .layout_hash,
        error.Truncated => .truncated,
        error.BufferTooSmall => .buffer_too_small,
        error.Unaligned => .unaligned,
    }));
}

pub const frame_symbol = std.fmt.comptimePrint("lcgf_ct_frame_u32_f32_l{d}", .{simd.lanes});

/// The C functions, by the names lcgf.h declares.
pub const exports = .{
    .{ "lcgf_ct_check", &cCheck },
    .{ "lcgf_ct_bytes", &cBytes },
    .{ "lcgf_ct_init", &cInit },
    .{ "lcgf_ct_layout", &cLayout },
    .{ frame_symbol, &cFrame },
};

pub fn exportAll() void {
    inline for (0..exports.len) |k| @export(exports[k][1], .{ .name = exports[k][0] ++ plan.symbol_suffix });
}

fn cCheck(words: [*]const u32, len: usize) callconv(.c) c_int {
    _ = Ui.check(words[0..len]) catch |e| return status(e);
    return 0;
}

fn cBytes(words: [*]const u32, len: usize) callconv(.c) usize {
    return Ui.bytes(words[0..len]) catch 0;
}

fn cInit(words: [*]const u32, len: usize, buf: [*]u8, buf_len: usize) callconv(.c) c_int {
    _ = Ui.init(words[0..len], buf[0..buf_len]) catch |e| return status(e);
    return 0;
}

fn cLayout() callconv(.c) u32 {
    return layout_hash;
}

fn cFrame(buf: [*]u8, state: [*]const u8, width: f32, height: f32, out: *seam.CDraw) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(buf));
    out.* = seam.cDraw(ui.frame(state, .{ width, height }));
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const examples = @import("../comptime/examples.zig");
const ct_layout = @import("../comptime/layout.zig");
const ct_paint = @import("../comptime/paint.zig");
const Span = @import("../core/strings.zig").Span;

/// Sized controls, for the events gate: the examples' checkboxes and sliders have no size of
/// their own, so nothing can hit them.
pub const Controls = struct { title: []const u8 = "Volume", muted: bool = false, volume: f32 = 0.5, pan: f32 = 0 };
pub const controls = blk: {
    const box: Style = .{ .size = .{ .px(16), .px(16) }, .fill = .rgb(200, 200, 200) };
    const track: Style = .{ .size = .{ .fill, .px(12) }, .fill = .rgb(90, 90, 90) };
    const short: Style = .{ .size = .{ .px(100), .px(10) }, .fill = .rgb(90, 90, 90) };
    break :blk spec_zig.col(.{ .pad = @splat(4), .gap = 4 }, .{
        spec_zig.row(.{ .gap = 8 }, .{ spec_zig.Spec{ .kind = .checkbox, .id = "mute", .bind = "muted", .name = "Mute", .style = box }, spec_zig.label(.title) }),
        spec_zig.Spec{ .kind = .slider, .id = "volume", .bind = "volume", .name = "Volume", .style = track },
        spec_zig.Spec{ .kind = .slider, .id = "pan", .bind = "pan", .name = "Pan", .style = short },
    });
};

/// Colours patched into quads, for the patch gate: a swatch filled with `accent` and a bar
/// filled with `accent` and bordered with `edge` (ct_paint.Patches).
pub const Palette = struct { title: []const u8 = "Palette", accent: types.Color = .rgb(200, 40, 40), edge: types.Color = .rgb(40, 40, 200) };
pub const palette = spec_zig.col(.{ .pad = @splat(4), .gap = 4, .fill = .rgb(20, 20, 20) }, .{
    spec_zig.row(.{ .gap = 6 }, .{ spec_zig.label(.title), spec_zig.col(.{ .size = .{ .px(20), .px(20) }, .fill = .rgb(1, 2, 3) }, .{}) }),
    spec_zig.col(.{ .size = .{ .fill, .px(8) }, .fill = .rgb(9, 9, 9), .border = 1, .border_color = .rgb(4, 5, 6) }, .{}),
});

/// Formatted labels, for the format gate: every argument kind (string, f32 at two precisions,
/// u32, bool), braces, and a slider in the options form.
pub const Meter = struct { name: []const u8 = "Gain", level: f32 = 0.5, count: u32 = 3, on: bool = true, peak: f32 = 0 };
pub const meter = spec_zig.col(.{ .pad = @splat(6), .gap = 4 }, .{
    spec_zig.text("{}: {.1} dB", .{ .name, .level }),
    spec_zig.row(.{ .gap = 8 }, .{ spec_zig.text("{} clips", .{.count}), spec_zig.text("on={} {{peak {.3}}}", .{ .on, .peak }) }),
    spec_zig.styled(spec_zig.slider(.level, .{ .name = "Level" }), .{ .size = .{ .px(60), .px(8) } }),
});

/// A patch binding (ct_paint.Patches' `Binding`), by field name.
pub const Bind = struct { field: []const u8, node: u32, border: bool = false };
/// The bindings of a static example.
pub fn bindingsOf(comptime name: []const u8) []const Bind {
    return if (std.mem.eql(u8, name, "palette"))
        &.{ .{ .field = "accent", .node = 3 }, .{ .field = "accent", .node = 4 }, .{ .field = "edge", .node = 4, .border = true } }
    else
        &.{};
}

/// ct_paint.Patches over `e`'s bindings (`bindingsOf`): what the static UI's frame paints
/// through.
pub fn Patched(comptime e: anytype) type {
    const P = ct_paint.Paint(e.spec, e.options);
    const Field = std.meta.FieldEnum(e.State);
    const bindings = comptime blk: {
        const bs = bindingsOf(e.name);
        var out: [bs.len]P.Binding(e.State) = undefined;
        for (bs, &out) |b, *o| o.* = .{ .field = @field(Field, b.field), .node = b.node, .target = if (b.border) .border_rgb else .fill_rgb };
        const final = out;
        break :blk &final;
    };
    return P.Patches(e.State, bindings);
}

/// The static examples: all but the custom widget, the two with dynamic regions, sized
/// controls, patched colours and formatted labels.
pub const static_examples = blk: {
    var out: []const examples.Example = &.{};
    for (examples.all) |e| if (!std.mem.eql(u8, e.name, "custom")) {
        out = out ++ [_]examples.Example{e};
    };
    out = out ++ examples.dynamic ++ [_]examples.Example{ .{ .name = "controls", .State = Controls, .spec = controls }, .{ .name = "palette", .State = Palette, .spec = palette }, .{ .name = "meter", .State = Meter, .spec = meter } };
    break :blk out[0..out.len].*;
};

/// The labels' text of `state`, as the static UI's frame gathers it: each label's string field,
/// or its format written (src/core/fmt.zig), in label order into `buf`, cut where `buf` ends.
/// Each label's bytes go to `spans`; returns the bytes used.
pub fn gatherText(comptime State: type, comptime nodes: []const Node, state: *const State, buf: []u8, spans: []Span) u32 {
    const names = @typeInfo(State).@"struct".field_names;
    var used: u32 = 0;
    var k: usize = 0;
    inline for (nodes) |nd| if (comptime nd.isLabel()) {
        var sink: fmt.Sink = .{ .buf = buf[used..] };
        if (comptime nd.format) |f| {
            const args = comptime blk: {
                var out: [f.args.len][]const u8 = undefined;
                for (f.args, &out) |a, *o| o.* = names[a];
                const final = out;
                break :blk &final;
            };
            fmt.write(f.segs, f.text, fmt.Fields(State, args){ .state = state }, &sink);
        } else sink.put(@field(state, names[nd.label_field]));
        spans[k] = .{ .start = used, .bytes = @intCast(sink.len) };
        used += @intCast(sink.len);
        k += 1;
    };
    return used;
}

/// The state of frame `f` of the gates (here and bindings/check/): string field k shows
/// `texts[(f + 3k) mod len]`, a bool is `(f + k) mod 3 != 0`, a count alternates between small
/// (`(f + k) mod 11`) and large (`(7919f + k) mod 200000`), an enum(u8) is `(f + k) mod 2`,
/// an f32 (a slider's value, a list's scroll) `((131f + 17k) mod 5000) * 0.75` and a colour
/// `colorFor(f, k)`.
pub fn stateFor(comptime State: type, f: u32, text: []const []const u8) State {
    var s: State = .{};
    inline for (@typeInfo(State).@"struct".field_names, 0..) |name, k_| {
        const k: u32 = k_;
        const T = @FieldType(State, name);
        @field(s, name) = switch (T) {
            []const u8 => text[(f + 3 * k) % text.len],
            bool => (f + k) % 3 != 0,
            u32 => if (f % 2 == 0) (f + k) % 11 else (7919 * f + k) % 200000,
            f32 => @as(f32, @floatFromInt((131 * f + 17 * k) % 5000)) * 0.75,
            types.Color => @bitCast(colorFor(f, k)),
            else => @fromBackingInt(@intCast((f + k) % 2)),
        };
    }
    return s;
}

/// Colour field k of frame f's state (rgba bits): r (13f + 40k) mod 256, g 7f mod 256, b 90k mod
/// 256, opaque.
pub fn colorFor(f: u32, k: u32) u32 {
    return ((13 * f + 40 * k) % 256) | (((7 * f) % 256) << 8) | (((90 * k) % 256) << 16) | (255 << 24);
}

/// `s` as C lays out the generated state struct (`plan.layoutState`).
pub fn cStateOf(comptime State: type, s: *const State, fields: []const plan.Field, buf: []align(8) u8) void {
    @memset(buf, 0);
    inline for (@typeInfo(State).@"struct".field_names, 0..) |name, k| {
        const v = @field(s, name);
        const p = buf.ptr + fields[k].offset;
        switch (@FieldType(State, name)) {
            []const u8 => @as(*align(1) [2]usize, @ptrCast(p)).* = .{ @intFromPtr(v.ptr), v.len },
            bool => p[0] = @intFromBool(v),
            u32 => std.mem.writeInt(u32, p[0..4], v, .little),
            f32 => std.mem.writeInt(u32, p[0..4], @bitCast(v), .little),
            types.Color => std.mem.writeInt(u32, p[0..4], @bitCast(v), .little),
            else => p[0] = @backingInt(v),
        }
    }
}

const ss = spec_zig;
const ListState = struct { x: []const u8 = "" };
const NoState = struct {};
/// ct-layout-bench's static lists: labels and bars (folds nothing), and bars only (every row
/// folds).
fn listOf(comptime k: usize, comptime text: bool) ss.Spec {
    @setEvalBranchQuota(1000 + 200 * k);
    var kids: [k]ss.Spec = undefined;
    for (&kids) |*r| r.* = ss.row(.{ .gap = 4, .size = .{ .fill, .px(20) } }, .{
        if (text) ss.label(.x) else ss.col(.{ .size = .{ .px(40), .px(8) }, .fill = .rgb(200, 10, 10) }, .{}),
        ss.col(.{ .size = .{ .fill, .px(8) }, .fill = .rgb(10, 200, 10), .radius = 2 }, .{}),
    });
    return ss.col(.{ .pad = @splat(4), .gap = 2, .fill = .rgb(0, 0, 0) }, kids);
}
/// ct-paint-bench's clipped row of tiles on two textures.
fn tilesOf(comptime count: usize) ss.Spec {
    @setEvalBranchQuota(1000 + 20 * count);
    var kids: [count]ss.Spec = undefined;
    for (&kids, 0..) |*k, i| k.* = ss.col(.{ .size = .{ .px(12), .px(12) }, .fill = .white, .texture = @fromBackingInt(i % 2) }, .{});
    return ss.row(.{ .clip = true, .gap = 3 }, kids);
}

/// The to-do page and the feed with fills, borders and clips under their regions, so dead rows'
/// quads, shared slots and scrolled copies are painted too.
const PaintedTodo = struct { title: []const u8 = "", len: u32 = 0, footer: bool = false, mode: examples.Mode = .brief, level: f32 = 0 };
const painted_todo = blk: {
    const red: types.Color = .rgb(200, 20, 20);
    const grey: types.Color = .rgb(90, 90, 90);
    break :blk ss.col(.{ .pad = @splat(4), .gap = 4, .fill = .rgb(10, 10, 10) }, .{
        ss.row(.{ .gap = 8 }, .{ ss.label(.title), ss.col(.{ .size = .{ .px(30), .px(10) }, .fill = red }, .{}) }),
        ss.list(.len, 6, .{ .gap = 2, .clip = true }, ss.row(.{ .gap = 4, .size = .{ .fill, .px(20) }, .fill = grey, .radius = 3 }, .{ ss.label(.title), ss.col(.{ .size = .{ .fill, .px(8) }, .fill = red }, .{}) })),
        ss.when(.footer, ss.row(.{ .gap = 8, .pad = @splat(2), .fill = red, .border = 1, .border_color = grey }, .{ ss.label(.title), ss.col(.{ .size = .{ .px(40), .px(12) }, .fill = grey }, .{}) })),
        ss.choice(.mode, .{}, .{
            ss.col(.{ .size = .{ .px(16), .px(16) }, .fill = red }, .{}),
            ss.row(.{ .gap = 4, .size = .{ .fill, .fit }, .fill = grey }, .{ ss.label(.title), ss.col(.{ .size = .{ .fill, .px(6) }, .fill = red }, .{}), ss.col(.{ .size = .{ .px(24), .px(24) } }, .{}) }),
        }),
        ss.named(ss.slider(.level, .level), "Level"),
        // Fixed-size and outside every region: folds, beside the regions.
        ss.row(.{ .gap = 2 }, .{ ss.col(.{ .size = .{ .px(10), .px(10) }, .fill = red }, .{}), ss.col(.{ .size = .{ .px(12), .px(10) }, .fill = grey, .radius = 2 }, .{}) }),
    });
};
const PaintedFeed = struct { title: []const u8 = "", count: u32 = 0, scroll: f32 = 0 };
const painted_feed = ss.col(.{ .fill = .rgb(0, 0, 40) }, .{
    ss.label(.title),
    ss.virtualList(.count, .scroll, 4, 12, ss.row(.{ .size = .{ .fill, .fit }, .fill = .rgb(40, 140, 40), .gap = 2 }, .{ ss.label(.title), ss.col(.{ .size = .{ .px(6), .px(6) }, .fill = .white }, .{}) })),
});

/// The static examples and the bench scenes: folds, the batch sort, clips and palettes, and
/// regions over painted rows.
pub const gate_examples = static_examples ++ [_]examples.Example{
    .{ .name = "list-16", .State = ListState, .spec = listOf(16, true) },
    .{ .name = "bars-16", .State = ListState, .spec = listOf(16, false) },
    .{ .name = "tiles", .State = NoState, .spec = ct_paint.tiles },
    .{ .name = "tiles-16", .State = NoState, .spec = tilesOf(16) },
    .{ .name = "painted-todo", .State = PaintedTodo, .spec = painted_todo },
    .{ .name = "painted-feed", .State = PaintedFeed, .spec = painted_feed },
};

/// The words of example `e`, as lcgf-gen makes them from its `.zon`.
pub fn wordsOf(arena: std.mem.Allocator, comptime e: examples.Example) ![]u32 {
    const fields = try arena.dupe(plan.Field, &comptime plan.fieldsOf(e.State));
    const st = plan.layoutState(fields);
    var nodes = comptime nodesOf(e.State, e.spec);
    inline for (comptime bindingsOf(e.name)) |b| {
        const k = comptime std.meta.fieldIndex(e.State, b.field).?;
        if (b.border) nodes[b.node].border_bind = k else nodes[b.node].fill_bind = k;
    }
    return make(arena, &nodes, .{ .fields = fields, .state_size = st.size, .state_align = st.alignment, .coord = coordBits(e.options.viewport) });
}

test "ct: a static UI's frames equal Zig's comptime pipeline, draw list for draw list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = [_][]const u8{ "", "Mixer", "Battery 82%", "x", "a much longer title than fits", "Settings", "0123456789" };
    inline for (gate_examples) |e| {
        const L = ct_layout.Layout(e.spec, e.options);
        const P = ct_paint.Paint(e.spec, e.options);
        const fields = try arena.dupe(plan.Field, &comptime plan.fieldsOf(e.State));
        const st = plan.layoutState(fields);
        const words = try wordsOf(arena, e);
        const buf = try arena.alignedAlloc(u8, .fromByteUnits(mem.column_align), try Ui.bytes(words));
        const ui = try Ui.init(words, buf);
        const state = try arena.alignedAlloc(u8, .@"8", @max(st.size, 1));
        // Zig's pipeline.
        var scratch: L.Scratch = undefined;
        var ram: L.Cols.Dynamic = undefined;
        var dbuf: [1 << 16]u8 align(64) = undefined;
        var carver: mem.Carver = .{ .buf = &dbuf };
        var zd = DrawList.init(&carver, P.quad_count, P.label_count, 0);
        var dirty: P.Dirty = .empty;
        const nodes = comptime nodesOf(e.State, e.spec);
        for (0..24) |fi| {
            const f: u32 = @intCast(fi);
            const zs = stateFor(e.State, f, &text);
            cStateOf(e.State, &zs, fields, state);
            const sel = L.Regions.select(e.State, &zs);
            // The labels' text, concatenated in label order, as the frame gathers it.
            var text_buf: [default_string_cap]u8 = undefined;
            var spans_buf: [@max(L.label_count, 1)]Span = undefined;
            const spans = spans_buf[0..L.label_count];
            const used = gatherText(e.State, &nodes, &zs, &text_buf, spans);
            const strings: struct { items: []const u8 } = .{ .items = text_buf[0..used] };
            const vps = [_][2]f32{ .{ 800, 600 }, .{ 320, 240 }, .{ 96, 64 }, .{ 1, 1 }, .{ 333.5, 21.25 }, .{ 50.5, 63 } };
            const vp = vps[f % vps.len];
            L.runLiveText(&scratch, &ram, vp, sel, spans, Mono{});
            Patched(e).rebuildLiveText(&zs, &ram, sel, spans, strings.items, &zd, &dirty);
            const d = ui.frame(state.ptr, vp);
            errdefer std.debug.print("{s}, frame {d} at {any}\n", .{ e.name, f, vp });
            try testing.expectEqual(zd.quad_len, d.quad_len);
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(zd.quads[0..zd.quad_len]), std.mem.sliceAsBytes(d.quads[0..d.quad_len]));
            try testing.expectEqual(zd.run_len, d.run_len);
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(zd.runs[0..zd.run_len]), std.mem.sliceAsBytes(d.runs[0..d.run_len]));
            try testing.expectEqualStrings(zd.strings, d.strings);
            try testing.expectEqual(zd.cmd_len, d.cmd_len);
            inline for (.{ "kind", "first", "count", "key" }) |col|
                try testing.expectEqualSlices(@typeInfo(@TypeOf(@field(zd.cmd, col))).pointer.child, @field(zd.cmd, col)[0..zd.cmd_len], @field(d.cmd, col)[0..d.cmd_len]);
        }
    }
}

test "ct: the words carry Zig's tables: templates, expand and the constant columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var folded: usize = 0;
    inline for (gate_examples) |e| {
        const P = ct_paint.Paint(e.spec, e.options);
        const L = ct_layout.Layout(e.spec, e.options);
        const C = P.Cols;
        const words = try wordsOf(arena, e);
        const h = try Ui.check(words);
        try testing.expectEqual(@as(u32, P.quad_count), h.quads);
        try testing.expectEqual(@as(u32, P.batch_count), h.batches);
        try testing.expectEqual(@as(u32, L.folded_rows), h.folded);
        folded += L.folded_rows;
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&P.templates), std.mem.sliceAsBytes(at(Quad, words, h.templates, h.quads)));
        try testing.expectEqualSlices(u32, &P.node, at(u32, words, h.paint_node, h.quads));
        try testing.expectEqualSlices(u32, &P.keys, at(u32, words, h.keys, h.quads));
        // Every constant column of the whole tree, row for row.
        const offs = at(u32, words, h.full.cols, column_arrays.len);
        inline for (column_arrays, 0..) |c, k| if (offs[k] != none and comptime !std.mem.eql(u8, c.field, "gap_total")) {
            const col = @field(C.pushed.c, c.field);
            const rows = if (comptime @typeInfo(@FieldType(Columns, c.field)) == .array) col[c.axis] else col;
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(rows[0..C.node_count]), std.mem.sliceAsBytes(at(u8, words, offs[k], C.node_count * c.size)));
        };
    }
    // Some of them fold, so the skeleton and the expand are covered, one beside regions.
    try testing.expect(folded > 0);
    try testing.expect(ct_layout.Layout(painted_todo, .{}).folded_rows > 0);
}

test "ct: lcgf.h's LCGF_CT_LAYOUT and format version are the library's" {
    const h = @embedFile("lcgf.h");
    const at_ = std.mem.indexOf(u8, h, "#define LCGF_CT_LAYOUT 0x").? + "#define LCGF_CT_LAYOUT 0x".len;
    errdefer std.debug.print("LCGF_CT_LAYOUT should be 0x{x:0>8}u\n", .{layout_hash});
    try testing.expectEqual(layout_hash, try std.fmt.parseInt(u32, h[at_..][0..8], 16));
    const v = std.mem.indexOf(u8, h, "#define LCGF_CT_FORMAT_VERSION ").? + "#define LCGF_CT_FORMAT_VERSION ".len;
    try testing.expectEqual(version, try std.fmt.parseInt(u32, std.mem.sliceTo(h[v..], 'u'), 10));
}

test "ct: the header refuses foreign words" {
    var w: [@sizeOf(Header) / 4]u32 = @splat(0);
    try testing.expectError(error.NotTables, Ui.check(&w));
    w[0] = magic;
    w[1] = version + 1;
    try testing.expectError(error.Version, Ui.check(&w));
    w[1] = version;
    try testing.expectError(error.LayoutHash, Ui.check(&w));
}
