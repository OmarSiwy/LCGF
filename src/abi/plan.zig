//! plan(): what the widgets' comptime front end (`ComptimeUi`, src/widgets/base.zig) decides
//! while compiling, as a pure function over arrays. It runs in two places:
//!
//! - in the Zig compiler, at comptime, over `fromSpec(spec)`;
//! - in `lcgf-gen` (tools/lcgf-gen/), at run time, over a spec read from a `.zon` file.
//!
//! Both feed the same `encode`, so the tables a C++ or Rust program links are the bytes Zig
//! would have made (the B2 gate, tools/lcgf-gen/main.zig's test). The tables are read by the
//! prebuilt frame behind the C seam (src/abi/seam.zig).
//!
//! A row is a tree row the frame pushes, after the runtime front end's root. Every row has an
//! `Op` that says what of it is decided at run time:
//!
//! - container: nothing, a constant row;
//! - button: its fill, one of four by the pointer;
//! - label: its text, a string field;
//! - checkbox and box: the value and the box's look, from a bool field;
//! - slider and thumb: the value and the thumb's width, from an f32 field.
//!
//! Everything else is constant: the style (a table of styles), the parent, the id hash and
//! where the row's subtree ends.
//!
//! The format is words (u32, little-endian). Every type that crosses it is written field by
//! field (`Words`), so padding never reaches the bytes and the layout hash is a hash of the
//! field list, not of a compiler's struct layout.

const std = @import("std");
const types = @import("../core/types.zig");
const base = @import("../widgets/base.zig");
const spec_zig = @import("../comptime/spec.zig");
const simd = @import("../core/simd.zig");
const fmt = @import("../core/fmt.zig");
const Span = @import("../core/strings.zig").Span;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Color = types.Color;
const Theme = base.Theme;
const Spec = spec_zig.Spec;

pub const magic: u32 = 0x4647_434C; // "LCGF"
pub const version: u32 = 1;

/// Appended to every C name liblcgf exports: empty in liblcgf_l{4,8,16}.a; `__l4`, `__l8` and
/// `__l16` in liblcgf_auto.a's three copies, which src/abi/auto.zig dispatches between.
pub const symbol_suffix: []const u8 = blk: {
    const o = @import("build_options");
    break :blk if (@hasDecl(o, "symbol_suffix")) o.symbol_suffix else "";
};
pub const none: u32 = std.math.maxInt(u32);

/// What a state field holds, as the generated state structs lay it out (C rules): `str` is a
/// pointer and a length (16 bytes on 64-bit targets), `bool` and `u8` one byte (`u8` is an
/// enum's tag, a `choice` selector), `f32`, `u32` and `color` (rgba bits) four. `other` is a field only Zig code
/// reads (a custom widget's own state, in `ComptimeUi`): it never crosses the seam.
pub const FieldType = enum(u8) { str, bool, f32, u32, u8, other, color };

pub const Field = struct {
    name: []const u8,
    type: FieldType,
    /// Byte offset in the state struct.
    offset: u32 = 0,
};

/// The reference widgets' spec kinds, after `ct.*` built them (a button is a row with an id).
pub const Kind = enum(u8) { container, button, label, checkbox, slider, custom, widget };

/// What makes a node's rows live only sometimes (spec.zig's `when`, `list`, `choice`).
pub const RegionKind = enum(u8) { none, when, list, choice };

/// A spring on an f32 or bool field: the slider bound to it shows the sprung value.
pub const Spring = struct { field: u32, stiffness: f32, damping: f32 };

/// One spec node, depth-first. Parents come before their children.
pub const Node = struct {
    kind: Kind,
    style: Style = .{},
    /// The widget's name (buttons, checkboxes, sliders).
    id: ?[]const u8 = null,
    /// Index into the fields.
    bind: u32 = none,
    /// Index of the parent node, `none` for the top node.
    parent: u32 = none,
    /// A `when` node is live while the bool field `region_field` holds; a `list` or `choice`
    /// node's children are live by their index and the field (a count, a selector).
    region: RegionKind = .none,
    region_field: u32 = none,
    /// A custom draw node's data (`ct.custom`).
    data: u64 = 0,
    /// Inside a Zig custom widget (`Spec.widget`, `ComptimeUi` only): the widget's own `push`
    /// draws these nodes, so a bind or an id the reference widgets would refuse is not an error.
    lenient: bool = false,
    /// A formatted label's format (`spec.text`, a `.zon` `.text`); `bind` is `none` then.
    format: ?Format = null,
};

/// A formatted label: its text, its segments (src/core/fmt.zig; a segment's `arg` indexes
/// `args`) and the fields its arguments are, by index.
pub const Format = struct { text: []const u8, segs: []const fmt.Seg, args: []const u32 };

/// The format kind a field of type `t` is written as, or null when it cannot be an argument.
pub fn argKind(t: FieldType) ?fmt.Kind {
    return switch (t) {
        .str => .str,
        .bool => .bool,
        .f32 => .f32,
        .u32 => .u32,
        .u8 => .u8,
        .other, .color => null,
    };
}

/// What a row pushes. `widget` is a Zig custom widget's root (`ComptimeUi` only): its own
/// `push` draws it and its subtree, so `emit` never sees one.
pub const Op = enum(u8) { container, button, label, checkbox, box, slider, thumb, custom, widget };

/// One tree row the frame pushes.
pub const Row = struct {
    op: Op,
    /// Tree row of the parent: 0 is the root the frame pushes first.
    parent: u32,
    style: u32,
    id: u32,
    field: u32 = none,
    /// Widget slot (buttons, checkboxes, sliders), else `none`.
    widget: u32 = none,
    /// Spec row one past this row's subtree (plus one): the frame seals the row there, and
    /// skips to it when the row is not live.
    end: u32,
    sealed: bool,
    /// The row is live while the bool field `when` holds (`none`: always).
    when: u32 = none,
    /// The row is child `gate_index` of a `list` (live while the index is under the count
    /// field) or a `choice` (live while it equals the selector field).
    gate: RegionKind = .none,
    gate_field: u32 = none,
    gate_index: u32 = 0,
    /// A custom draw row's data.
    data: u64 = 0,
    /// A formatted label's index in `Plan.formats`, else `none`.
    format: u32 = none,
};

pub const Widget = struct { row: u32, kind: Kind, focusable: bool };

/// What `plan` produces. Slices are the caller's (`Buffers`).
pub const Plan = struct {
    rows: []Row,
    styles: []Style,
    widgets: []Widget,
    /// The formatted labels' formats, in row order.
    formats: []const Format,
    fields: []const Field,
    springs: []const Spring,
    label: TextStyle,
    fills: [4]Color,
    /// Style indices of the checkbox box, off and on.
    box: [2]u32,
    thumb: u32,
    runs: u32,
    state_size: u32,
    state_align: u32,
};

/// Room for a plan of `n` nodes: one row, one style and at most one widget per node, plus the
/// three theme styles.
pub fn Buffers(comptime n: comptime_int) type {
    return struct { rows: [n]Row = undefined, styles: [n + 3]Style = undefined, widgets: [n]Widget = undefined, formats: [n]Format = undefined };
}

pub const Error = error{ BadTree, BadBind, BadKind, BadRegion, BadSpring };

/// Lays out the state struct as C lays out the generated one: writes each field's `offset`.
pub fn layoutState(fields: []Field) struct { size: u32, alignment: u32 } {
    var at: u32 = 0;
    var alignment_: u32 = 1;
    for (fields) |*f| {
        const size: u32, const alignment: u32 = switch (f.type) {
            .str => .{ 2 * @sizeOf(usize), @alignOf(usize) },
            .bool, .u8 => .{ 1, 1 },
            .f32, .u32, .color => .{ 4, 4 },
            .other => .{ 0, 1 },
        };
        at = std.mem.alignForward(u32, at, alignment);
        f.offset = at;
        at += size;
        alignment_ = @max(alignment_, alignment);
    }
    return .{ .size = std.mem.alignForward(u32, at, alignment_), .alignment = alignment_ };
}

/// The plan of `nodes` with theme `th`. `fields` get their offsets here; `rows`, `styles` and
/// `widgets` are written. Pure: the same nodes give the same plan wherever it runs.
pub fn plan(nodes: []const Node, fields: []Field, springs: []const Spring, th: *const Theme, rows: []Row, styles: []Style, widgets: []Widget, formats: []Format) Error!Plan {
    var p: Plan = .{
        .rows = rows[0..nodes.len],
        .styles = styles[0 .. nodes.len + 3],
        .widgets = widgets[0..0],
        .formats = formats[0..0],
        .fields = fields,
        .springs = springs,
        .label = base.labelText(th),
        .fills = th.controlFills(),
        .box = .{ @intCast(nodes.len), @intCast(nodes.len + 1) },
        .thumb = @intCast(nodes.len + 2),
        .runs = 0,
        .state_size = 0,
        .state_align = 1,
    };
    const st = layoutState(fields);
    p.state_size = st.size;
    p.state_align = st.alignment;
    for (springs) |sp| {
        if (sp.field >= fields.len or (fields[sp.field].type != .f32 and fields[sp.field].type != .bool)) return error.BadSpring;
    }

    // The theme's own looks: the box off and on, the thumb at zero width.
    styles[p.box[0]] = base.checkboxBox(th, false);
    styles[p.box[1]] = base.checkboxBox(th, true);
    styles[p.thumb] = base.sliderThumb(th, 0);

    var nw: usize = 0;
    var nf: usize = 0;
    for (nodes, 0..) |n, i| {
        if (n.parent != none and n.parent >= i) return error.BadTree;
        const parent_kind: ?Kind = if (n.parent == none) null else nodes[n.parent].kind;
        // The first child of a checkbox is its box and the only child of a slider its thumb:
        // `ComptimeUi.push` draws them from the theme, not from their spec node.
        const first_child = n.parent != none and n.parent + 1 == i;
        const op: Op = if (parent_kind == .checkbox and first_child) .box else if (parent_kind == .slider) .thumb else switch (n.kind) {
            .container => .container,
            .button => .button,
            .label => .label,
            .checkbox => .checkbox,
            .slider => .slider,
            .custom => .custom,
            .widget => .widget,
        };
        const owner: u32 = switch (op) {
            .box, .thumb => n.parent,
            else => @intCast(i),
        };
        const field = nodes[owner].bind;
        const want: ?FieldType = switch (op) {
            .label => .str,
            .checkbox, .box => .bool,
            .slider, .thumb => .f32,
            .container, .button, .custom, .widget => null,
        };
        var format: u32 = none;
        if (op == .label and n.format != null) {
            // A formatted label: each argument a field its segment can write.
            const f = n.format.?;
            for (f.segs) |g| if (g.kind != .literal) {
                if (g.arg >= f.args.len or f.args[g.arg] >= fields.len) return error.BadBind;
                if (argKind(fields[f.args[g.arg]].type) != g.kind) return error.BadBind;
            };
            formats[nf] = f;
            format = @intCast(nf);
            nf += 1;
        } else if (want) |t| {
            if (field == none or field >= fields.len or fields[field].type != t) if (!n.lenient) return error.BadBind;
        }
        styles[i] = switch (op) {
            .box => styles[p.box[0]],
            .thumb => styles[p.thumb],
            else => n.style,
        };
        var widget: u32 = none;
        if (n.id != null and (op == .button or op == .checkbox or op == .slider or op == .custom)) {
            widget = @intCast(nw);
            widgets[nw] = .{ .row = @intCast(i), .kind = n.kind, .focusable = op == .checkbox or op == .slider };
            nw += 1;
        } else if ((n.id != null and op != .widget) or op == .custom) {
            if (!n.lenient) return error.BadKind;
        }
        // Regions: a `when` gates this row; a `list` or `choice` parent gates it by its index
        // among the parent's children.
        if (n.region == .when and (n.region_field >= fields.len or fields[n.region_field].type != .bool)) if (!n.lenient) return error.BadRegion;
        var gate: RegionKind = .none;
        var gate_field: u32 = none;
        var gate_index: u32 = 0;
        if (n.parent != none and (nodes[n.parent].region == .list or nodes[n.parent].region == .choice)) {
            const pr = nodes[n.parent];
            if (pr.region_field >= fields.len or (fields[pr.region_field].type != .u32 and fields[pr.region_field].type != .u8)) if (!n.lenient) return error.BadRegion;
            gate = pr.region;
            gate_field = pr.region_field;
            for (nodes[n.parent + 1 .. i]) |sib| gate_index += @intFromBool(sib.parent == n.parent);
        }
        p.runs += @intFromBool(op == .label);
        rows[i] = .{
            .op = op,
            .parent = if (n.parent == none) 0 else n.parent + 1,
            .style = switch (op) {
                .box => p.box[0],
                .thumb => p.thumb,
                else => @intCast(i),
            },
            .id = if (n.id) |name| @backingInt(types.Id.hash(name)) else 0,
            .field = if (want != null and format == none) field else none,
            .widget = widget,
            .end = 0,
            .sealed = switch (op) {
                .container, .button, .checkbox, .slider => true,
                .label, .box, .thumb, .custom, .widget => false,
            },
            .when = if (n.region == .when) n.region_field else none,
            .gate = gate,
            .gate_field = gate_field,
            .gate_index = gate_index,
            .data = n.data,
            .format = format,
        };
    }
    // Where each subtree ends, as tree rows (spec row + 1).
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        if (rows[i].end == 0) rows[i].end = @intCast(i + 2);
        if (nodes[i].parent != none) {
            const parent = nodes[i].parent;
            rows[parent].end = @max(rows[parent].end, rows[i].end);
        }
    }
    p.widgets = widgets[0..nw];
    p.formats = formats[0..nf];
    return p;
}

// ---- comptime: a spec built with `ct.*` --------------------------------------------------

/// Nodes in `spec`, itself included.
pub fn count(comptime spec: Spec) comptime_int {
    var n: comptime_int = 1;
    for (spec.children) |c| n += count(c);
    return n;
}

/// The fields of `State`, in declaration order: strings, bools and f32s.
pub fn fieldsOf(comptime State: type) [@typeInfo(State).@"struct".field_names.len]Field {
    return fieldsIn(State, false);
}

/// `fieldsOf` for `ComptimeUi`: a field of another type is `other`, for Zig code only.
pub fn fieldsOfZig(comptime State: type) [@typeInfo(State).@"struct".field_names.len]Field {
    return fieldsIn(State, true);
}

fn fieldsIn(comptime State: type, comptime zig: bool) [@typeInfo(State).@"struct".field_names.len]Field {
    const info = @typeInfo(State).@"struct";
    var out: [info.field_names.len]Field = undefined;
    for (info.field_names, info.field_types, &out) |name, T, *f| {
        f.* = .{ .name = name, .type = switch (T) {
            []const u8 => .str,
            bool => .bool,
            f32 => .f32,
            u32 => .u32,
            types.Color => .color,
            else => if (@typeInfo(T) == .@"enum" and @typeInfo(T).@"enum".tag_type == u8)
                .u8
            else if (zig)
                .other
            else
                @compileError("lcgf seam: state field '" ++ name ++ "' must be []const u8, bool, f32, u32 or an enum(u8)"),
        } };
    }
    return out;
}

/// The springs `State` declares (`pub const springs = .{ .volume = Spring{} }`), in that order.
pub fn springsOf(comptime State: type) [springCount(State)]Spring {
    const decl = if (@hasDecl(State, "springs")) State.springs else .{};
    var out: [springCount(State)]Spring = undefined;
    for (@typeInfo(@TypeOf(decl)).@"struct".field_names, &out) |name, *sp| {
        const c = @field(decl, name);
        sp.* = .{ .field = fieldIndex(State, name), .stiffness = c.stiffness, .damping = c.damping };
    }
    return out;
}

fn springCount(comptime State: type) comptime_int {
    const decl = if (@hasDecl(State, "springs")) State.springs else .{};
    return @typeInfo(@TypeOf(decl)).@"struct".field_names.len;
}

/// `spec`'s nodes, depth-first, binding the fields of `State`.
pub fn fromSpec(comptime State: type, comptime spec: Spec) [count(spec)]Node {
    return fromSpecIn(State, spec, false);
}

/// `fromSpec` for `ComptimeUi`: a Zig custom widget (`Spec.widget`) is a `widget` node and its
/// subtree is lenient (its `push` draws it).
pub fn fromSpecZig(comptime State: type, comptime spec: Spec) [count(spec)]Node {
    return fromSpecIn(State, spec, true);
}

fn fromSpecIn(comptime State: type, comptime spec: Spec, comptime zig: bool) [count(spec)]Node {
    comptime {
        @setEvalBranchQuota(10_000 + 100 * count(spec));
        var out: [count(spec)]Node = undefined;
        var next: u32 = 0;
        walk(State, spec, none, &next, &out, zig, false);
        return out;
    }
}

fn walk(comptime State: type, comptime s: Spec, comptime parent: u32, comptime next: *u32, comptime out: anytype, comptime zig: bool, comptime lenient: bool) void {
    const custom = s.custom != null;
    const zig_widget = s.widget != null;
    if (zig_widget and !zig) @compileError("lcgf seam: a custom widget (Spec.widget) has Zig code to run; only ct.custom draw nodes cross the seam");
    if (s.region) |r| if (r.window != null and !zig) @compileError("lcgf seam: a windowed list (virtualList) does not cross the seam");
    const i = next.*;
    next.* += 1;
    const bindOf = if (lenient) fieldIndexOr else fieldIndex;
    out[i] = .{
        .kind = if (custom) .custom else if (zig_widget) .widget else switch (s.kind) {
            .col, .row => if (s.id != null) .button else .container,
            .label => .label,
            .checkbox => .checkbox,
            .slider => .slider,
        },
        .style = s.style,
        .id = if (s.id) |id| id else null,
        .bind = if (s.bind) |b| bindOf(State, b) else none,
        .parent = parent,
        .region = if (s.region) |r| switch (r.kind) {
            .when => .when,
            .list => .list,
            .choice => .choice,
        } else .none,
        .region_field = if (s.region) |r| bindOf(State, r.bind) else none,
        .data = s.custom orelse 0,
        .lenient = lenient,
        .format = if (s.format) |f| blk: {
            var args: [f.args.len]u32 = undefined;
            for (f.args, &args) |name, *a| a.* = bindOf(State, name);
            const final = args;
            break :blk .{ .text = f.text, .segs = fmt.compile(State, f.text, f.args), .args = &final };
        } else null,
    };
    for (s.children) |c| walk(State, c, i, next, out, zig, lenient or zig_widget);
}

fn fieldIndexOr(comptime State: type, comptime name: []const u8) u32 {
    for (@typeInfo(State).@"struct".field_names, 0..) |f, k| if (std.mem.eql(u8, f, name)) return k;
    return none;
}

fn fieldIndex(comptime State: type, comptime name: []const u8) u32 {
    for (@typeInfo(State).@"struct".field_names, 0..) |f, k| if (std.mem.eql(u8, f, name)) return k;
    @compileError("lcgf seam: the state has no field '" ++ name ++ "'");
}

/// The encoded tables of `ComptimeUi(State, spec, th)`'s UI, made while compiling.
pub fn tablesOf(comptime State: type, comptime spec: Spec, comptime th: Theme) [encodedWords(count(spec), fieldsOf(State).len, springCount(State), formatSize(&fromSpec(State, spec)))]u32 {
    comptime {
        @setEvalBranchQuota(100_000 + 1_000 * count(spec));
        const nodes = fromSpec(State, spec);
        var fields = fieldsOf(State);
        const springs = springsOf(State);
        var b: Buffers(nodes.len) = .{};
        const p = plan(&nodes, &fields, &springs, &th, &b.rows, &b.styles, &b.widgets, &b.formats) catch |e| @compileError("lcgf seam: " ++ @errorName(e));
        var out: [encodedWords(nodes.len, fields.len, springs.len, formatSize(&nodes))]u32 = undefined;
        const used = encode(&p, &out);
        // Widgets use fewer words than the bound: zero the rest so the bytes are deterministic.
        for (out[used..]) |*w| w.* = 0;
        const final = out;
        return final;
    }
}

/// The theme's parts `emit` adds to a row's own style.
pub const Looks = struct {
    label: TextStyle,
    fills: [4]Color,
    /// The checkbox box, off and on.
    box: [2]Style,
};

/// `ComptimeUi(State, spec, th)`'s plan, made while compiling: the rows and styles it pushes,
/// the same `plan` the seam's tables are encoded from. A Zig custom widget is a `widget` row.
pub fn PlanOf(comptime spec: Spec) type {
    @setEvalBranchQuota(100_000);
    const n = count(spec);
    return struct { rows: [n]Row, styles: [n + 3]Style, looks: Looks, formats: []const Format };
}

pub fn planOf(comptime State: type, comptime spec: Spec, comptime th: Theme) PlanOf(spec) {
    comptime {
        @setEvalBranchQuota(100_000 + 1_000 * count(spec));
        const nodes = fromSpecZig(State, spec);
        var fields = fieldsOfZig(State);
        var b: Buffers(nodes.len) = .{};
        const p = plan(&nodes, &fields, &.{}, &th, &b.rows, &b.styles, &b.widgets, &b.formats) catch |e| @compileError("lcgf plan: " ++ @errorName(e));
        const formats = p.formats[0..p.formats.len].*;
        return .{ .rows = b.rows, .styles = b.styles, .looks = .{ .label = p.label, .fills = p.fills, .box = .{ b.styles[p.box[0]], b.styles[p.box[1]] } }, .formats = &formats };
    }
}

/// Pushes row `r` under tree row `parent` and returns its tree row: the one place a row's op
/// becomes a tree row, for both front ends of the tables (`ComptimeUi.push` and the seam's
/// frame). `style` is the row's style; `host` reads the state and the pointer:
///
///     host.response(r, widget) Response   a button's hover and press
///     host.flag(field) bool                a checkbox's value
///     host.animated(field) f32             a slider's value, sprung if it has a spring
///     host.text(field) []const u8          a label's text
///     host.formatted(format, *fmt.Sink)    a formatted label's text, written to the sink
///
/// `c` holds the tree, text runs, custom draws and strings (`t`, `tx`, `cu`, `strings`).
pub inline fn emit(host: anytype, c: anytype, looks: *const Looks, r: u32, row: Row, style: Style, parent: u32) u32 {
    var s = style;
    switch (row.op) {
        .container, .label, .custom, .widget => {},
        .button => s.fill = looks.fills[base.stateIndex(host.response(r, row.widget))],
        .checkbox => s.value = simd.b2f(host.flag(row.field)),
        .box => s = looks.box[@intFromBool(host.flag(row.field))],
        .slider => s.value = host.animated(row.field),
        .thumb => s.size[0] = .pct(base.fraction(host.animated(row.field), 0, 1)),
    }
    const i = c.t.push(parent, @fromBackingInt(row.id), &s);
    switch (row.op) {
        .label => {
            const span = if (row.format == none) c.strings.add(host.text(row.field)) else blk: {
                var sink: fmt.Sink = .{ .buf = c.strings.buf[c.strings.len..] };
                host.formatted(row.format, &sink);
                const sp: Span = .{ .start = c.strings.len, .bytes = @intCast(sink.len) };
                c.strings.len += sp.bytes;
                c.strings.overflow = simd.orB(c.strings.overflow, sink.cut);
                break :blk sp;
            };
            c.t.c.text[i] = c.tx.push(i, span, &looks.label);
        },
        .custom => c.t.c.custom[i] = c.cu.push(i, @fromBackingInt(row.id), row.data),
        else => {},
    }
    return i;
}

// ---- the format -----------------------------------------------------------------------------

/// Words of a value of `T` written field by field (`Words.put`).
pub fn wordsOf(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .float, .int, .bool, .@"enum" => 1,
        .array => |a| a.len * wordsOf(a.child),
        .@"struct" => |s| if (s.backing_integer != null) 1 else blk: {
            var n: comptime_int = 0;
            for (s.field_types) |F| n += wordsOf(F);
            break :blk n;
        },
        else => @compileError("lcgf tables: cannot write " ++ @typeName(T)),
    };
}

/// A value as words and back: f32 as its bits, ints, bools and enums as u32, packed structs as
/// their backing integer, arrays and structs element by element.
pub fn put(comptime T: type, v: T, out: []u32) void {
    switch (@typeInfo(T)) {
        .float => out[0] = @bitCast(v),
        .int => out[0] = @intCast(v),
        .bool => out[0] = @intFromBool(v),
        .@"enum" => out[0] = @intCast(@backingInt(v)),
        .array => |a| for (v, 0..) |e, k| put(a.child, e, out[k * wordsOf(a.child) ..]),
        .@"struct" => |s| if (s.backing_integer != null) {
            out[0] = @as(s.backing_integer.?, @bitCast(v));
        } else {
            var at: usize = 0;
            inline for (s.field_names, s.field_types) |name, F| {
                put(F, @field(v, name), out[at..]);
                at += wordsOf(F);
            }
        },
        else => comptime unreachable,
    }
}

pub fn get(comptime T: type, in: []const u32) T {
    switch (@typeInfo(T)) {
        .float => return @bitCast(in[0]),
        .int => return @intCast(in[0]),
        .bool => return in[0] != 0,
        .@"enum" => |e| return @fromBackingInt(@as(e.tag_type, @intCast(in[0]))),
        .array => |a| {
            var v: T = undefined;
            for (&v, 0..) |*e, k| e.* = get(a.child, in[k * wordsOf(a.child) ..]);
            return v;
        },
        .@"struct" => |s| if (s.backing_integer != null) {
            return @bitCast(@as(s.backing_integer.?, @intCast(in[0])));
        } else {
            var v: T = undefined;
            var at: usize = 0;
            inline for (s.field_names, s.field_types) |name, F| {
                @field(v, name) = get(F, in[at..]);
                at += wordsOf(F);
            }
            return v;
        },
        else => comptime unreachable,
    }
}

/// The layout hash: FNV-1a of the field names and kinds of every type the tables carry, and of
/// the row encoding. Two builds agree on it exactly when they read and write the same words.
pub const layout_hash: u32 = blk: {
    @setEvalBranchQuota(100_000);
    var h = std.hash.Fnv1a_32.init();
    for (.{ Style, TextStyle, Color, RowWords, Header, Dir }) |T| hashType(T, &h);
    break :blk h.final();
};

/// `layout_hash` over other types: the runtime front end's (src/abi/runtime.zig).
pub fn layoutHashOf(comptime list: anytype) u32 {
    @setEvalBranchQuota(100_000);
    var h = std.hash.Fnv1a_32.init();
    inline for (list) |T| hashType(T, &h);
    return h.final();
}

fn hashType(comptime T: type, h: *std.hash.Fnv1a_32) void {
    h.update(@typeName(T));
    switch (@typeInfo(T)) {
        .array => |a| {
            h.update(std.mem.asBytes(&@as(u32, a.len)));
            hashType(a.child, h);
        },
        .@"struct" => |s| for (s.field_names, s.field_types) |name, F| {
            h.update(name);
            hashType(F, h);
        },
        .@"enum" => |e| for (e.field_names) |name| h.update(name),
        else => {},
    }
}

/// The header: the first words of the tables.
pub const Header = extern struct {
    magic: u32 = magic,
    version: u32 = version,
    layout_hash: u32,
    /// Total words, header included.
    words: u32,
    /// Bits of a row index the passes use, and the coordinate type (0: f32).
    index_bits: u32 = 32,
    coord: u32 = 0,
    /// Lanes the columns are padded for; 0: the prebuilt frame pads them itself.
    lanes: u32 = 0,
    /// Features the frame needs (reserved; 0 for the reference widgets).
    features: u32 = 0,
    rows: u32,
    runs: u32,
    widgets: u32,
    fields: u32,
    styles: u32,
    springs: u32,
    state_size: u32,
    state_align: u32,
    columns: u32 = column_count,
};

/// One entry of the column directory: where a column's words are.
pub const Dir = extern struct { id: u32, class: u32, words_per_row: u32, offset: u32, len: u32 };

pub const Column = enum(u32) { rows, styles, widgets, fields, springs, theme, formats, segs, text };
pub const column_count = @typeInfo(Column).@"enum".field_names.len;
/// Every column is constant (rodata): the caller's buffer holds the frame's working columns.
pub const Class = enum(u32) { dynamic, constant, dropped };

const RowWords = struct { op: u32, parent: u32, style: u32, id: u32, field: u32, widget: u32, end: u32, sealed: u32, when: u32, gate: u32, gate_field: u32, gate_index: u32, data: [2]u32, format: u32 };
/// A format: its segments (`first_seg`, `segs` in the segs column) and its text (`text_at`,
/// `text_len` bytes in the text column).
const FormatWords = struct { first_seg: u32, segs: u32, text_at: u32, text_len: u32 };
/// A segment: its kind and precision (`kind | prec << 8`), the field of its argument, and the
/// text it copies (`start`, `len` in its format's text).
const SegWords = struct { kind: u32, field: u32, start: u32, len: u32 };
const ThemeWords = struct { label: TextStyle, fills: [4]Color, box: [2]u32, thumb: u32 };
const WidgetWords = struct { row: u32, kind: u32, focusable: u32 };
const SpringWords = struct { field: u32, stiffness: f32, damping: f32 };
const FieldWords = struct { type: u32, offset: u32 };

pub const header_words = wordsOf(Header);
const dir_words = column_count * wordsOf(Dir);

/// An upper bound on the words of a plan of `n` nodes and `f` fields, and of formats `fm`
/// (`formatSize`).
pub fn encodedWords(n: usize, f: usize, springs: usize, fm: FormatSize) usize {
    return header_words + dir_words + n * wordsOf(RowWords) + (n + 3) * wordsOf(Style) + n * wordsOf(WidgetWords) + f * wordsOf(FieldWords) + springs * wordsOf(SpringWords) + wordsOf(ThemeWords) +
        fm.formats * wordsOf(FormatWords) + fm.segs * wordsOf(SegWords) + textWords(fm.text);
}

/// What the formatted labels of some nodes take in the tables.
pub const FormatSize = struct { formats: usize = 0, segs: usize = 0, text: usize = 0 };

pub fn formatSize(nodes: []const Node) FormatSize {
    var out: FormatSize = .{};
    for (nodes) |n| if (n.format) |f| {
        out.formats += 1;
        out.segs += f.segs.len;
        out.text += f.text.len;
    };
    return out;
}

/// Words that hold `bytes` bytes, four to a word, little-endian.
fn textWords(bytes: usize) usize {
    return (bytes + 3) / 4;
}

/// Writes `p` into `out` (at least `encodedWords` long); returns the words used.
pub fn encode(p: *const Plan, out: []u32) usize {
    var at: usize = header_words + dir_words;
    var fsize: FormatSize = .{ .formats = p.formats.len };
    for (p.formats) |f| {
        fsize.segs += f.segs.len;
        fsize.text += f.text.len;
    }
    const Section = struct { id: Column, per: usize, len: usize };
    const sections = [_]Section{
        .{ .id = .rows, .per = wordsOf(RowWords), .len = p.rows.len },
        .{ .id = .styles, .per = wordsOf(Style), .len = p.styles.len },
        .{ .id = .widgets, .per = wordsOf(WidgetWords), .len = p.widgets.len },
        .{ .id = .fields, .per = wordsOf(FieldWords), .len = p.fields.len },
        .{ .id = .springs, .per = wordsOf(SpringWords), .len = p.springs.len },
        .{ .id = .theme, .per = wordsOf(ThemeWords), .len = 1 },
        .{ .id = .formats, .per = wordsOf(FormatWords), .len = p.formats.len },
        .{ .id = .segs, .per = wordsOf(SegWords), .len = fsize.segs },
        .{ .id = .text, .per = 1, .len = textWords(fsize.text) },
    };
    for (sections, 0..) |s, k| {
        put(Dir, .{ .id = @backingInt(s.id), .class = @backingInt(Class.constant), .words_per_row = @intCast(s.per), .offset = @intCast(at), .len = @intCast(s.len) }, out[header_words + k * wordsOf(Dir) ..]);
        switch (s.id) {
            .rows => for (p.rows, 0..) |r, i| put(RowWords, .{
                .op = @backingInt(r.op),
                .parent = r.parent,
                .style = r.style,
                .id = r.id,
                .field = r.field,
                .widget = r.widget,
                .end = r.end,
                .sealed = @intFromBool(r.sealed),
                .when = r.when,
                .gate = @backingInt(r.gate),
                .gate_field = r.gate_field,
                .gate_index = r.gate_index,
                .data = .{ @truncate(r.data), @truncate(r.data >> 32) },
                .format = r.format,
            }, out[at + i * s.per ..]),
            .styles => for (p.styles, 0..) |st, i| put(Style, st, out[at + i * s.per ..]),
            .widgets => for (p.widgets, 0..) |w, i| put(WidgetWords, .{ .row = w.row, .kind = @backingInt(w.kind), .focusable = @intFromBool(w.focusable) }, out[at + i * s.per ..]),
            .springs => for (p.springs, 0..) |sp, i| put(SpringWords, .{ .field = sp.field, .stiffness = sp.stiffness, .damping = sp.damping }, out[at + i * s.per ..]),
            .fields => for (p.fields, 0..) |f, i| put(FieldWords, .{ .type = @backingInt(f.type), .offset = f.offset }, out[at + i * s.per ..]),
            .theme => put(ThemeWords, .{ .label = p.label, .fills = p.fills, .box = p.box, .thumb = p.thumb }, out[at..]),
            .formats => {
                var seg: u32 = 0;
                var text: u32 = 0;
                for (p.formats, 0..) |f, i| {
                    put(FormatWords, .{ .first_seg = seg, .segs = @intCast(f.segs.len), .text_at = text, .text_len = @intCast(f.text.len) }, out[at + i * s.per ..]);
                    seg += @intCast(f.segs.len);
                    text += @intCast(f.text.len);
                }
            },
            .segs => {
                var i: usize = 0;
                for (p.formats) |f| for (f.segs) |g| {
                    put(SegWords, .{
                        .kind = @as(u32, @backingInt(g.kind)) | (@as(u32, g.prec) << 8),
                        .field = if (g.kind == .literal) none else f.args[g.arg],
                        .start = g.start,
                        .len = g.len,
                    }, out[at + i * s.per ..]);
                    i += 1;
                };
            },
            .text => {
                @memset(out[at..][0..s.len], 0);
                var b: usize = 0;
                for (p.formats) |f| for (f.text) |c| {
                    out[at + b / 4] |= @as(u32, c) << @intCast(8 * (b % 4));
                    b += 1;
                };
            },
        }
        at += s.per * s.len;
    }
    put(Header, .{
        .layout_hash = layout_hash,
        .words = @intCast(at),
        .rows = @intCast(p.rows.len),
        .runs = p.runs,
        .widgets = @intCast(p.widgets.len),
        .fields = @intCast(p.fields.len),
        .styles = @intCast(p.styles.len),
        .springs = @intCast(p.springs.len),
        .state_size = p.state_size,
        .state_align = p.state_align,
    }, out);
    return at;
}

/// Tables read back, as the frame uses them: slices into the caller's words.
pub const Tables = struct {
    header: Header,
    words: []const u32,
    rows: Section,
    styles: Section,
    widgets: Section,
    fields: Section,
    springs: Section,
    formats: Section,
    segs: Section,
    text: Section,
    label: TextStyle,
    fills: [4]Color,
    box: [2]u32,
    thumb: u32,

    pub const Section = struct {
        at: u32,
        per: u32,
        len: u32,
        fn slot(s: Section, words: []const u32, i: u32) []const u32 {
            return words[s.at + i * s.per ..][0..s.per];
        }
    };

    pub const DecodeError = error{ NotTables, Version, LayoutHash, Truncated };

    /// Checks the header (magic, version, layout hash, length) and finds the columns.
    pub fn decode(words: []const u32) DecodeError!Tables {
        if (words.len < header_words + dir_words) return error.Truncated;
        const h = get(Header, words);
        if (h.magic != magic) return error.NotTables;
        if (h.version != version) return error.Version;
        if (h.layout_hash != layout_hash) return error.LayoutHash;
        if (h.words > words.len or h.columns != column_count) return error.Truncated;
        var t: Tables = undefined;
        t.header = h;
        t.words = words[0..h.words];
        inline for (.{ "rows", "styles", "widgets", "fields", "springs", "theme", "formats", "segs", "text" }, 0..) |name, k| {
            const d = get(Dir, words[header_words + k * wordsOf(Dir) ..]);
            if (d.offset + d.words_per_row * d.len > h.words) return error.Truncated;
            const s: Section = .{ .at = d.offset, .per = d.words_per_row, .len = d.len };
            if (comptime std.mem.eql(u8, name, "theme")) {
                const th = get(ThemeWords, words[d.offset..]);
                t.label = th.label;
                t.fills = th.fills;
                t.box = th.box;
                t.thumb = th.thumb;
            } else @field(t, name) = s;
        }
        return t;
    }

    pub fn row(t: *const Tables, i: u32) Row {
        const r = get(RowWords, t.rows.slot(t.words, i));
        return .{
            .op = @fromBackingInt(@as(u8, @intCast(r.op))),
            .parent = r.parent,
            .style = r.style,
            .id = r.id,
            .field = r.field,
            .widget = r.widget,
            .end = r.end,
            .sealed = r.sealed != 0,
            .when = r.when,
            .gate = @fromBackingInt(@as(u8, @intCast(r.gate))),
            .gate_field = r.gate_field,
            .gate_index = r.gate_index,
            .data = (@as(u64, r.data[1]) << 32) | r.data[0],
            .format = r.format,
        };
    }

    /// Format `k`: its segments are `seg(first ..< first + count)`, its text is `textByte(at
    /// ..< at + len)`.
    pub fn format(t: *const Tables, k: u32) struct { first: u32, count: u32, at: u32, len: u32 } {
        const f = get(FormatWords, t.formats.slot(t.words, k));
        return .{ .first = f.first_seg, .count = f.segs, .at = f.text_at, .len = f.text_len };
    }
    /// Segment `i` of the segs column: what it writes, with the field of its argument.
    pub fn seg(t: *const Tables, i: u32) struct { kind: fmt.Kind, prec: u8, field: u32, start: u32, len: u32 } {
        const g = get(SegWords, t.segs.slot(t.words, i));
        return .{ .kind = @fromBackingInt(@as(u8, @truncate(g.kind))), .prec = @truncate(g.kind >> 8), .field = g.field, .start = g.start, .len = g.len };
    }
    /// Byte `b` of the text column.
    pub fn textByte(t: *const Tables, b: u32) u8 {
        return @truncate(t.words[t.text.at + b / 4] >> @intCast(8 * (b % 4)));
    }
    pub fn style(t: *const Tables, i: u32) Style {
        return get(Style, t.styles.slot(t.words, i));
    }
    pub fn widget(t: *const Tables, k: u32) Widget {
        const w = get(WidgetWords, t.widgets.slot(t.words, k));
        return .{ .row = w.row, .kind = @fromBackingInt(@as(u8, @intCast(w.kind))), .focusable = w.focusable != 0 };
    }
    pub fn spring(t: *const Tables, k: u32) Spring {
        const sp = get(SpringWords, t.springs.slot(t.words, k));
        return .{ .field = sp.field, .stiffness = sp.stiffness, .damping = sp.damping };
    }
    pub fn field(t: *const Tables, k: u32) struct { type: FieldType, offset: u32 } {
        const f = get(FieldWords, t.fields.slot(t.words, k));
        return .{ .type = @fromBackingInt(@as(u8, @intCast(f.type))), .offset = f.offset };
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const ct = base.ct;

const TestState = struct { go_text: []const u8 = "Go", on: bool = false, on_text: []const u8 = "On", level: f32 = 0.5 };
const test_spec = spec_zig.row(.{ .gap = 4 }, .{
    ct.button(.default, .go, .go_text),
    ct.checkbox(.default, .on, .on, .on_text),
    ct.slider(.default, .level, .level),
});

test "plan: rows follow ComptimeUi's pushes" {
    const t = comptime tablesOf(TestState, test_spec, .default);
    const tb = try Tables.decode(&t);
    try testing.expectEqual(@as(u32, 8), tb.header.rows);
    const ops = [_]Op{ .container, .button, .label, .checkbox, .box, .label, .slider, .thumb };
    for (ops, 0..) |op, i| try testing.expectEqual(op, tb.row(@intCast(i)).op);
    try testing.expectEqual(@as(u32, 3), tb.header.widgets);
    try testing.expectEqual(@as(u32, 2), tb.header.runs);
    // The button's subtree is itself and its caption: tree rows 2 and 3, so it ends at 4.
    try testing.expectEqual(@as(u32, 4), tb.row(1).end);
    try testing.expectEqual(@as(u32, 9), tb.row(0).end);
    try testing.expectEqual(@backingInt(types.Id.hash("go")), tb.row(1).id);
}

test "plan: a value written as words reads back the same" {
    const s: Style = .{ .dir = .x, .size = .{ .px(3), .fill }, .fill = .rgb(1, 2, 3), .clip = true, .role = .slider, .value = 0.25 };
    var w: [wordsOf(Style)]u32 = undefined;
    put(Style, s, &w);
    try testing.expectEqual(s, get(Style, &w));
}

test "plan: tables from another layout or version are refused" {
    var t = comptime tablesOf(TestState, test_spec, .default);
    t[2] +%= 1;
    try testing.expectError(error.LayoutHash, Tables.decode(&t));
    t[2] -%= 1;
    t[1] = 99;
    try testing.expectError(error.Version, Tables.decode(&t));
    t[0] = 0;
    try testing.expectError(error.NotTables, Tables.decode(&t));
}
