//! A UI spec as a `.zon` file: what C++ and Rust programs write where Zig writes a comptime
//! `Spec` with the `ct.*` builders. `lcgf-gen` (tools/lcgf-gen/) reads it at run time, expands
//! each widget exactly as `ct.*` does, and runs the same `plan` (src/abi/plan.zig):
//!
//!     .{
//!         .name = "toolbar",
//!         .state = .{
//!             .{ .name = "reset_text", .str = "Reset" },
//!             .{ .name = "wireframe", .bool = false },
//!             .{ .name = "exposure", .f32 = 0.25 },
//!         },
//!         .ui = .{ .row = .{
//!             .style = .{ .size = .{ .fill, .fit }, .pad = .{ 8, 8, 8, 8 }, .gap = 8, .cross = .center, .fill = .{ .theme = .panel } },
//!             .children = .{
//!                 .{ .button = .{ .id = "reset", .text = "reset_text" } },
//!                 .{ .checkbox = .{ .id = "wire", .bind = "wireframe", .text = "wire_text" } },
//!                 .{ .slider = .{ .id = "exposure", .bind = "exposure" } },
//!                 .{ .label = "layer" },
//!             },
//!         } },
//!     }
//!
//! Rows and columns can be live only sometimes, as spec.zig's `when`, `list` and `choice`:
//!
//!     .{ .row = .{ .when = "show", .children = .{ ... } } }                 while a bool holds
//!     .{ .list = .{ .count = "len", .max = 8, .template = .{ .{ .row = ... } } } }  first `len` copies
//!     .{ .choice = .{ .select = "mode", .children = .{ compact, detailed } } }       one alternative
//!
//! A static UI (`lcgf-gen --static`, comptime pipeline) also takes a windowed list, as
//! spec.zig's `virtualList`, and a fixed screen (`.viewport = .{ 320, 240 }`):
//!
//!     .{ .virtual_list = .{ .count = "n", .scroll = "y", .visible = 4, .height = 12, .template = .{ ... } } }
//!
//! A node the host draws itself (`ct.custom`): `.{ .custom = .{ .id = "view", .data = 7 } }`.
//! Fields are `.str`, `.bool`, `.f32`, `.u32` (a list's count) or `.u8` (a choice's selector);
//! an f32 or bool field can spring: `.{ .name = "volume", .f32 = 0.5, .spring = .{} }`.
//!
//! Lengths are `.fit`, `.fill`, `.{ .px = 8 }`, `.{ .pct = 0.5 }` or `.{ .grow = 2 }`.
//! Colours are `.{ .rgb = .{ 30, 31, 36 } }`, `.{ .rgba = .{ 0, 0, 0, 128 } }` or a theme
//! token, `.{ .theme = .panel }`.

const std = @import("std");
const fmt = @import("../core/fmt.zig");
const plan = @import("plan.zig");
const abi_ct = @import("ct.zig");
const types = @import("../core/types.zig");
const base = @import("../widgets/base.zig");
const Style = types.Style;
const Theme = base.Theme;

pub const Length = union(enum) { fit, fill, px: f32, pct: f32, grow: f32 };

pub const ThemeColor = enum { text, panel, control, control_hot, control_held, accent };

pub const ZColor = union(enum) {
    rgb: [3]u8,
    rgba: [4]u8,
    theme: ThemeColor,

    fn color(c: ZColor, th: *const Theme) types.Color {
        return switch (c) {
            .rgb => |v| .rgb(v[0], v[1], v[2]),
            .rgba => |v| .rgba(v[0], v[1], v[2], v[3]),
            .theme => |t| switch (t) {
                inline else => |tag| @field(th, @tagName(tag)),
            },
        };
    }
};

/// A colour field's default, as rgba bits (`Color.bitsOf`).
pub fn fieldColor(z: ZField) u32 {
    const th: Theme = .default;
    return @bitCast(z.color.?.color(&th));
}

/// The parts of `Style` a spec sets; defaults are `Style`'s.
pub const ZStyle = struct {
    size: [2]Length = .{ .fit, .fit },
    min: [2]f32 = .{ 0, 0 },
    max: [2]f32 = .{ types.inf, types.inf },
    pad: [4]f32 = .{ 0, 0, 0, 0 },
    gap: f32 = 0,
    main: types.Align = .start,
    cross: types.Align = .start,
    shrink: bool = false,
    clip: bool = false,
    fill: ?ZColor = null,
    border_color: ?ZColor = null,
    border: f32 = 0,
    radius: f32 = 0,
    opacity: f32 = 1,
    /// A static UI: the colour field whose rgb the quad's fill (border) takes each patch, its
    /// alpha kept (ct_paint.Patches, `fill_rgb` and `border_rgb`).
    fill_bind: ?[]const u8 = null,
    border_bind: ?[]const u8 = null,

    fn style(z: ZStyle, th: *const Theme, dir: types.Axis) Style {
        var s: Style = .{
            .dir = dir,
            .min = z.min,
            .max = z.max,
            .pad = z.pad,
            .gap = z.gap,
            .main = z.main,
            .cross = z.cross,
            .shrink = z.shrink,
            .clip = z.clip,
            .border = z.border,
            .radius = z.radius,
            .opacity = z.opacity,
        };
        for (z.size, &s.size) |l, *out| out.* = switch (l) {
            .fit => .fit,
            .fill => .fill,
            .px => |v| .px(v),
            .pct => |v| .pct(v),
            .grow => |v| .grow(v),
        };
        if (z.fill) |c| s.fill = c.color(th);
        if (z.border_color) |c| s.border_color = c.color(th);
        return s;
    }
};

pub const Box = struct { style: ZStyle = .{}, children: []const ZNode = &.{}, when: ?[]const u8 = null };

pub const List = struct { count: []const u8, max: u32, dir: types.Axis = .y, style: ZStyle = .{}, template: []const ZNode };
pub const Choice = struct { select: []const u8, dir: types.Axis = .y, style: ZStyle = .{}, children: []const ZNode };

pub const ZNode = union(enum) {
    row: Box,
    col: Box,
    /// A string field shown as text.
    label: []const u8,
    /// Fields written into a format (src/core/fmt.zig): `.{ .text = .{ .format = "Volume {.1}",
    /// .args = .{"volume"} } }`.
    text: ZText,
    button: struct { id: []const u8, text: []const u8 },
    /// `text` is the string field it shows; a static UI's checkbox (`--static`) is one row and
    /// shows none.
    checkbox: struct { id: []const u8, bind: []const u8, text: ?[]const u8 = null, style: ZStyle = .{} },
    /// `style` sizes a static UI's checkbox or slider (one row, spec.zig's); the widgets' front
    /// end draws them with the theme's.
    slider: struct { id: []const u8, bind: []const u8, style: ZStyle = .{} },
    list: List,
    choice: Choice,
    /// A clipped list of `visible` fixed-height items over `count` (spec.zig's `virtualList`),
    /// scrolled by the f32 field `scroll`. Static UIs only.
    virtual_list: struct { count: []const u8, scroll: []const u8, visible: u32, height: f32, template: []const ZNode },
    custom: struct { id: []const u8, data: u64 = 0, style: ZStyle = .{} },
};

pub const ZText = struct { format: []const u8, args: []const []const u8 = &.{} };

pub const ZField = struct {
    name: []const u8,
    str: ?[]const u8 = null,
    bool: ?bool = null,
    f32: ?f32 = null,
    u32: ?u32 = null,
    u8: ?u8 = null,
    /// A colour a static UI's quads take (`fill_bind`, `border_bind`): rgba bits in the state.
    color: ?ZColor = null,
    spring: ?struct { stiffness: f32 = 170, damping: f32 = 26 } = null,
};

pub const ThemeName = enum { default };

pub const ZSpec = struct {
    name: []const u8,
    theme: ThemeName = .default,
    /// The fixed screen a static UI runs on, in px: its rects are kept in the smallest integer
    /// type that holds it (ct_layout's `Options.viewport`). Null for a resizable window.
    viewport: ?[2]f32 = null,
    state: []const ZField,
    ui: ZNode,
};

pub const Error = error{ OutOfMemory, ParseZon, UnknownField, FieldWithoutType, BadList, MissingText, NotStatic, BadField, BadFormat };

/// A `.text`'s format over `fields`: its segments and its arguments' field indices, in `arena`.
fn formatOf(arena: std.mem.Allocator, fields: []const plan.Field, t: ZText) Error!plan.Format {
    const args = try arena.alloc(u32, t.args.len);
    const kinds = try arena.alloc(fmt.Kind, t.args.len);
    for (t.args, args, kinds) |name, *a, *k| {
        a.* = for (fields, 0..) |f, j| {
            if (std.mem.eql(u8, f.name, name)) break @intCast(j);
        } else {
            if (!@import("builtin").is_test) std.log.err("lcgf-gen: the state has no field '{s}'", .{name});
            return error.UnknownField;
        };
        k.* = plan.argKind(fields[a.*].type) orelse {
            if (!@import("builtin").is_test) std.log.err("lcgf-gen: text argument '{s}' is a colour; a format writes strings, bools, numbers", .{name});
            return error.BadFormat;
        };
    }
    const segs = try arena.alloc(fmt.Seg, fmt.maxSegs(t.format));
    const n = fmt.parse(t.format, kinds, segs) catch |e| {
        if (!@import("builtin").is_test) std.log.err("lcgf-gen: text \"{s}\": {s} (use {{}}, {{.N}} for an f32, {{{{ and }}}})", .{ t.format, @errorName(e) });
        return error.BadFormat;
    };
    return .{ .text = t.format, .segs = segs[0..n], .args = args };
}

/// A spec read and expanded: the nodes and fields `plan` takes.
pub const Expanded = struct {
    spec: ZSpec,
    theme: Theme,
    fields: []plan.Field,
    nodes: []plan.Node,
    springs: []plan.Spring,
};

/// Reads `source`. Strings and slices live in `arena`; parse errors are logged against `path`.
pub fn read(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8, path: []const u8) Error!Expanded {
    return expand(arena, try parse(gpa, arena, source, path));
}

/// Parses `source` without expanding it.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8, path: []const u8) Error!ZSpec {
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(ZSpec, .{ .gpa = gpa, .arena = arena, .source = source, .diagnostics = &diag }) catch |e| {
        if (e == error.ParseZon) diag.log(path);
        return e;
    };
}

fn themeOf(spec: ZSpec) Theme {
    return switch (spec.theme) {
        .default => .default,
    };
}

/// The state's fields, in order, not yet laid out.
pub fn fieldsOf(arena: std.mem.Allocator, spec: ZSpec) Error![]plan.Field {
    const fields = try arena.alloc(plan.Field, spec.state.len);
    for (spec.state, fields) |z, *f| f.* = .{
        .name = z.name,
        .type = if (z.str != null) .str else if (z.bool != null) .bool else if (z.f32 != null) .f32 else if (z.u32 != null) .u32 else if (z.u8 != null) .u8 else if (z.color != null) .color else return error.FieldWithoutType,
    };
    return fields;
}

pub fn expand(arena: std.mem.Allocator, spec: ZSpec) Error!Expanded {
    const th = themeOf(spec);
    const fields = try fieldsOf(arena, spec);
    var springs: std.ArrayList(plan.Spring) = .empty;
    for (spec.state, 0..) |z, k| if (z.spring) |sp| try springs.append(arena, .{ .field = @intCast(k), .stiffness = sp.stiffness, .damping = sp.damping });
    var nodes: std.ArrayList(plan.Node) = .empty;
    var e: Expander = .{ .arena = arena, .th = &th, .fields = fields, .nodes = &nodes };
    try e.node(spec.ui, plan.none);
    return .{ .spec = spec, .theme = th, .fields = fields, .nodes = nodes.items, .springs = springs.items };
}

const Expander = struct {
    arena: std.mem.Allocator,
    th: *const Theme,
    fields: []const plan.Field,
    nodes: *std.ArrayList(plan.Node),

    fn field(e: *Expander, name: []const u8) Error!u32 {
        for (e.fields, 0..) |f, k| if (std.mem.eql(u8, f.name, name)) return @intCast(k);
        if (!@import("builtin").is_test) std.log.err("lcgf-gen: the state has no field '{s}'", .{name});
        return error.UnknownField;
    }

    fn add(e: *Expander, n: plan.Node) Error!u32 {
        try e.nodes.append(e.arena, n);
        return @intCast(e.nodes.items.len - 1);
    }

    /// What `ct.label` makes.
    fn label(e: *Expander, bind: []const u8, parent: u32) Error!void {
        _ = try e.add(.{ .kind = .label, .style = .{ .role = .label }, .bind = try e.field(bind), .parent = parent });
    }

    /// One node and its subtree, as the `ct.*` builder of the same name makes it.
    fn node(e: *Expander, z: ZNode, parent: u32) Error!void {
        const th = e.th;
        switch (z) {
            .row, .col => |b| {
                const i = try e.add(.{
                    .kind = .container,
                    .style = b.style.style(th, if (z == .row) .x else .y),
                    .parent = parent,
                    .region = if (b.when != null) .when else .none,
                    .region_field = if (b.when) |w| try e.field(w) else plan.none,
                });
                for (b.children) |c| try e.node(c, i);
            },
            .list => |l| {
                // spec.zig's `list`: `max` copies of the template, the first `count` live.
                if (l.template.len != 1) return error.BadList;
                const i = try e.add(.{ .kind = .container, .style = l.style.style(th, l.dir), .parent = parent, .region = .list, .region_field = try e.field(l.count) });
                for (0..l.max) |_| try e.node(l.template[0], i);
            },
            .choice => |ch| {
                const i = try e.add(.{ .kind = .container, .style = ch.style.style(th, ch.dir), .parent = parent, .region = .choice, .region_field = try e.field(ch.select) });
                for (ch.children) |c| try e.node(c, i);
            },
            .virtual_list => {
                if (!@import("builtin").is_test) std.log.err("lcgf-gen: a windowed list needs --static", .{});
                return error.NotStatic;
            },
            .custom => |cu| {
                _ = try e.add(.{ .kind = .custom, .style = cu.style.style(th, .y), .id = cu.id, .parent = parent, .data = cu.data });
            },
            .label => |bind| try e.label(bind, parent),
            .text => |t| _ = try e.add(.{ .kind = .label, .style = .{ .role = .label }, .parent = parent, .format = try formatOf(e.arena, e.fields, t) }),
            .button => |b| {
                var s = base.buttonStyle(th);
                s.dir = .x;
                const i = try e.add(.{ .kind = .button, .style = s, .id = b.id, .parent = parent });
                try e.label(b.text, i);
            },
            .checkbox => |c| {
                var s = base.checkboxStyle(th);
                s.dir = .x;
                const i = try e.add(.{ .kind = .checkbox, .style = s, .id = c.id, .bind = try e.field(c.bind), .parent = parent });
                _ = try e.add(.{ .kind = .container, .parent = i });
                try e.label(c.text orelse {
                    if (!@import("builtin").is_test) std.log.err("lcgf-gen: checkbox '{s}' needs a `text` field", .{c.id});
                    return error.MissingText;
                }, i);
            },
            .slider => |sl| {
                var s = base.sliderTrack(th);
                s.dir = .x;
                const i = try e.add(.{ .kind = .slider, .style = s, .id = sl.id, .bind = try e.field(sl.bind), .parent = parent });
                _ = try e.add(.{ .kind = .container, .parent = i });
            },
        }
    }
};

// ---- static UIs (`lcgf-gen --static`, src/abi/ct.zig) -----------------------------------------

/// A spec read as a static UI: the rows `abi_ct.make` takes and the laid-out state.
pub const Static = struct {
    spec: ZSpec,
    fields: []plan.Field,
    nodes: []abi_ct.Node,
    state_size: u32,
    state_align: u32,
    /// The widgets (nodes with an id), in row order, as ct_events numbers them.
    widgets: []const StaticWidget,
};

pub const StaticWidget = struct { name: []const u8, row: u32, slider: bool };

/// Reads `source` as a static UI: spec.zig's `col`, `row`, `label`, `checkbox` and `slider`,
/// one row each, and its regions `when`, `list`, `choice` and `virtual_list` (comptime UIs,
/// ct_layout and ct_paint). Buttons and custom draws are refused (`error.NotStatic`).
pub fn readStatic(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8, path: []const u8) Error!Static {
    return expandStatic(arena, try parse(gpa, arena, source, path));
}

pub fn expandStatic(arena: std.mem.Allocator, spec: ZSpec) Error!Static {
    const th = themeOf(spec);
    const fields = try fieldsOf(arena, spec);
    const st = plan.layoutState(fields);
    var nodes: std.ArrayList(abi_ct.Node) = .empty;
    var widgets: std.ArrayList(StaticWidget) = .empty;
    var e: StaticExpander = .{ .arena = arena, .th = &th, .fields = fields, .nodes = &nodes, .widgets = &widgets };
    try e.node(spec.ui, 0);
    return .{ .spec = spec, .fields = fields, .nodes = nodes.items, .state_size = st.size, .state_align = st.alignment, .widgets = widgets.items };
}

/// The words of a static UI, in `arena` (`abi_ct.make`).
pub fn staticTables(arena: std.mem.Allocator, x: *const Static) (Error || abi_ct.Error)![]u32 {
    return abi_ct.make(arena, x.nodes, .{ .fields = x.fields, .state_size = x.state_size, .state_align = x.state_align, .coord = abi_ct.coordBits(x.spec.viewport) });
}

const StaticExpander = struct {
    arena: std.mem.Allocator,
    th: *const Theme,
    fields: []const plan.Field,
    nodes: *std.ArrayList(abi_ct.Node),
    widgets: *std.ArrayList(StaticWidget),

    fn field(e: *StaticExpander, name: []const u8, want: plan.FieldType) Error!u32 {
        for (e.fields, 0..) |f, k| if (std.mem.eql(u8, f.name, name)) {
            if (f.type != want) {
                if (!@import("builtin").is_test) std.log.err("lcgf-gen: field '{s}' is {t}, not {t}", .{ name, f.type, want });
                return error.BadField;
            }
            return @intCast(k);
        };
        if (!@import("builtin").is_test) std.log.err("lcgf-gen: the state has no field '{s}'", .{name});
        return error.UnknownField;
    }

    /// The colour fields a node's quad takes in a patch (`fill_bind`, `border_bind`).
    fn binds(e: *StaticExpander, i: u32, z: ZStyle) Error!void {
        if (z.fill_bind) |f| e.nodes.items[i].fill_bind = try e.field(f, .color);
        if (z.border_bind) |f| e.nodes.items[i].border_bind = try e.field(f, .color);
    }

    /// A choice's selector: an enum's tag (u8) or an integer.
    fn choiceField(e: *StaticExpander, name: []const u8) Error!u32 {
        for (e.fields, 0..) |f, k| if (std.mem.eql(u8, f.name, name) and (f.type == .u8 or f.type == .u32)) return @intCast(k);
        return e.field(name, .u8);
    }

    fn notStatic(what: []const u8) Error {
        if (!@import("builtin").is_test) std.log.err("lcgf-gen: a static UI has no {s}: build it without --static", .{what});
        return error.NotStatic;
    }

    /// One node and its subtree, as the spec.zig builder of the same name makes it.
    fn node(e: *StaticExpander, z: ZNode, parent: u32) Error!void {
        const i: u32 = @intCast(e.nodes.items.len);
        try e.nodes.append(e.arena, .{ .parent = parent });
        const out = &e.nodes.items[i];
        switch (z) {
            .row, .col => |b| {
                out.style = b.style.style(e.th, if (z == .row) .x else .y);
                try e.binds(i, b.style);
                if (b.when) |w| {
                    out.region = .when;
                    out.region_field = try e.field(w, .bool);
                }
                for (b.children) |c| try e.node(c, i);
            },
            .list => |l| {
                if (l.template.len != 1) return error.BadList;
                out.style = l.style.style(e.th, l.dir);
                try e.binds(i, l.style);
                out.region = .list;
                out.region_field = try e.field(l.count, .u32);
                for (0..l.max) |_| try e.node(l.template[0], i);
            },
            .choice => |ch| {
                out.style = ch.style.style(e.th, ch.dir);
                try e.binds(i, ch.style);
                out.region = .choice;
                out.region_field = try e.choiceField(ch.select);
                for (ch.children) |c| try e.node(c, i);
            },
            .virtual_list => |v| {
                // spec.zig's `virtualList`: `visible + 1` fixed-height copies in a clipped
                // column `visible` items tall, the copy's root a fixed-height item (a `when`
                // template wrapped in a column first, so its item still takes its row).
                if (v.template.len != 1 or v.visible == 0 or !(v.height > 0)) return error.BadList;
                const view_height = @as(f32, @floatFromInt(v.visible)) * v.height;
                out.style = .{ .clip = true, .size = .{ .fill, .px(view_height) } };
                out.region = .list;
                out.region_field = try e.field(v.count, .u32);
                out.scroll_field = try e.field(v.scroll, .f32);
                out.height = v.height;
                const conditional = switch (v.template[0]) {
                    .row, .col => |b| b.when != null,
                    else => false,
                };
                for (0..v.visible + 1) |_| {
                    const item: u32 = @intCast(e.nodes.items.len);
                    if (conditional) {
                        try e.nodes.append(e.arena, .{ .parent = i, .style = .{ .dir = .y, .size = .{ .fill, .fit } } });
                        try e.node(v.template[0], item);
                        e.nodes.items[item].end = @intCast(e.nodes.items.len);
                    } else try e.node(v.template[0], i);
                    const st = &e.nodes.items[item].style;
                    st.size[1] = .px(v.height);
                    st.min[1] = v.height;
                    st.max[1] = v.height;
                    st.float = false;
                }
            },
            .label => |bind| out.label_field = try e.field(bind, .str),
            .text => |t| {
                out.style = .{ .role = .label };
                out.format = try formatOf(e.arena, e.fields, t);
            },
            .checkbox => |c| {
                if (c.text != null) return notStatic("checkbox text (put a `label` beside it)");
                _ = try e.field(c.bind, .bool);
                out.style = c.style.style(e.th, .y);
                try e.binds(i, c.style);
                out.id = .hash(c.id);
                out.shows = true;
                try e.widgets.append(e.arena, .{ .name = c.id, .row = i, .slider = false });
            },
            .slider => |sl| {
                _ = try e.field(sl.bind, .f32);
                out.style = sl.style.style(e.th, .y);
                try e.binds(i, sl.style);
                out.id = .hash(sl.id);
                out.shows = true;
                try e.widgets.append(e.arena, .{ .name = sl.id, .row = i, .slider = true });
            },
            .button => return notStatic("buttons"),
            .custom => return notStatic("custom draws"),
        }
        e.nodes.items[i].end = @intCast(e.nodes.items.len);
    }
};

/// The tables of an expanded spec, in `arena`.
pub fn tables(arena: std.mem.Allocator, x: *const Expanded) (Error || plan.Error)![]u32 {
    const n = x.nodes.len;
    const rows = try arena.alloc(plan.Row, n);
    const styles = try arena.alloc(Style, n + 3);
    const widgets = try arena.alloc(plan.Widget, n);
    const formats = try arena.alloc(plan.Format, n);
    const p = try plan.plan(x.nodes, x.fields, x.springs, &x.theme, rows, styles, widgets, formats);
    const out = try arena.alloc(u32, plan.encodedWords(n, x.fields.len, x.springs.len, plan.formatSize(x.nodes)));
    const used = plan.encode(&p, out);
    return out[0..used];
}

// ---- tests: the gate ------------------------------------------------------------------------

const testing = std.testing;

test "zon: tables read from toolbar.zon are the bytes Zig makes at compile time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const x = try read(testing.allocator, arena, @embedFile("testdata/toolbar.zon"), "toolbar.zon");
    const got = try tables(arena, &x);
    const Ref = base.Reference(.default);
    const want = comptime plan.tablesOf(Ref.State, Ref.spec, .default);
    const used = (try plan.Tables.decode(&want)).header.words;
    try testing.expectEqualSlices(u32, want[0..used], got);
}

test "zon: tables read from mixer.zon are the bytes Zig makes at compile time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const x = try read(testing.allocator, arena, @embedFile("testdata/mixer.zon"), "mixer.zon");
    const got = try tables(arena, &x);
    const want = comptime plan.tablesOf(MixerState, mixer_spec, .default);
    const used = (try plan.Tables.decode(&want)).header.words;
    try testing.expectEqualSlices(u32, want[0..used], got);
}

test "zon: static UIs read from .zon are the words Zig makes from the comptime examples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (abi_ct.static_examples) |e| {
        const src = @embedFile("testdata/static/" ++ e.name ++ ".zon");
        const x = try readStatic(testing.allocator, arena, src, e.name ++ ".zon");
        const got = try staticTables(arena, &x);
        const want = try abi_ct.wordsOf(arena, e);
        errdefer std.debug.print("{s}.zon\n", .{e.name});
        try testing.expectEqualSlices(u32, want, got);
    }
}

test "zon: a static UI refuses what only the widgets' front end has" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fields: []const ZField = &.{ .{ .name = "on", .bool = false }, .{ .name = "t", .str = "x" } };
    const bad = [_]ZNode{
        .{ .button = .{ .id = "b", .text = "t" } },
        .{ .checkbox = .{ .id = "c", .bind = "on", .text = "t" } },
        .{ .custom = .{ .id = "v" } },
    };
    for (bad) |z| try testing.expectError(error.NotStatic, expandStatic(arena, .{ .name = "x", .state = fields, .ui = z }));
    try testing.expectError(error.BadField, expandStatic(arena, .{ .name = "x", .state = fields, .ui = .{ .label = "on" } }));
}

/// src/comptime/mixed.zig's panel, with a title and a pan slider in a column around it.
pub const MixerState = struct { title: []const u8 = "Mixer", mute_text: []const u8 = "Mute", muted: bool = false, volume: f32 = 0.5, pan: f32 = 0 };
pub const mixer_spec = blk: {
    const s = @import("../comptime/spec.zig");
    const ct = base.ct;
    const th: Theme = .default;
    break :blk s.col(.{ .pad = @splat(8), .gap = 4, .fill = th.panel }, .{
        ct.label(th, .title),
        s.row(.{ .size = .{ .fill, .fit }, .gap = 8, .cross = .center }, .{
            ct.checkbox(th, .mute, .muted, .mute_text),
            ct.slider(th, .volume, .volume),
        }),
        s.row(.{ .gap = 8 }, .{ ct.label(th, .title), ct.slider(th, .pan, .pan) }),
    });
};

test "zon: tables read from panel.zon are the bytes Zig makes at compile time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const x = try read(testing.allocator, arena, @embedFile("testdata/panel.zon"), "panel.zon");
    const got = try tables(arena, &x);
    const want = comptime plan.tablesOf(PanelState, panel_spec, .default);
    const used = (try plan.Tables.decode(&want)).header.words;
    try testing.expectEqualSlices(u32, want[0..used], got);
}

/// Every feature that crosses the seam besides the reference widgets: a `when`, a `list`, a
/// `choice`, a custom draw node, a sprung slider, a formatted label and keyboard focus.
pub const PanelState = struct {
    title: []const u8 = "Panel",
    show: bool = true,
    show_text: []const u8 = "Details",
    len: u32 = 2,
    mode: Mode = .compact,
    level: f32 = 0.25,

    pub const Mode = enum(u8) { compact, detailed };
    pub const springs = .{ .level = @import("../anim/anims.zig").Spring{} };
};
pub const panel_spec = blk: {
    const s = @import("../comptime/spec.zig");
    const ct = base.ct;
    const th: Theme = .default;
    break :blk s.col(.{ .pad = @splat(8), .gap = 4, .fill = th.panel }, .{
        s.row(.{ .gap = 8, .cross = .center }, .{ ct.checkbox(th, .show_box, .show, .show_text), ct.slider(th, .level, .level) }),
        s.when(.show, s.col(.{ .gap = 2 }, .{ ct.label(th, .title), s.text("{} at {.2}, {} rows", .{ .title, .level, .len }), ct.custom(.view, .{ .size = .{ .px(60), .px(20) } }, 7) })),
        s.list(.len, 4, .{ .gap = 2 }, s.row(.{ .gap = 4 }, .{ ct.label(th, .title), s.col(.{ .size = .{ .px(12), .px(8) }, .fill = th.accent }, .{}) })),
        s.choice(.mode, .{}, .{
            s.col(.{ .size = .{ .px(16), .px(16) }, .fill = th.control }, .{}),
            s.row(.{ .gap = 4 }, .{ ct.label(th, .title), ct.button(th, .more, .title) }),
        }),
    });
};

test "zon: a spec binding a missing field is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const src =
        \\.{ .name = "x", .state = .{ .{ .name = "a", .bool = true } }, .ui = .{ .label = "b" } }
    ;
    try testing.expectError(error.UnknownField, read(testing.allocator, arena_state.allocator(), src, "x.zon"));
}
