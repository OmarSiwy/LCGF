//! The page IR lowered to the C seam's spec language (`zon.ZSpec`, src/abi/zon.zig): what
//! `--lang zon` prints and what `--lang cpp|rust` hands to lcgf-gen's table emitters. The seam
//! has rows, columns, labels, formatted text, buttons, checkboxes, 0-to-1 sliders and their
//! `when`, `list` and `choice` regions, on the default theme. Anything else on the page is an
//! error at its HTML location, so nothing is dropped on the way.

const std = @import("std");
const lcgf = @import("lcgf");
const diag = @import("diag.zig");
const ir = @import("ir.zig");
const zon = lcgf.abi_zon;
const types = lcgf.types;

const Lower = struct {
    arena: std.mem.Allocator,
    ds: *diag.Diags,
    page: *const ir.Page,
    fields: std.ArrayList(zon.ZField) = .empty,

    const not_in_tables = "is not in the seam's widget tables (C++/Rust); use the Zig frontend";

    fn refuse(l: *Lower, i: u32, comptime what: []const u8, args: anytype) ?zon.ZNode {
        l.ds.err(l.page.nodes.items(.loc)[i], what ++ " " ++ not_in_tables, args);
        return null;
    }

    /// A literal caption as a string field of its own (the seam's buttons and checkboxes show
    /// a field): `<id>_text`, defaulting to the literal.
    fn captionField(l: *Lower, n: ir.Node) ?[]const u8 {
        if (n.text_kind == .field) return n.text;
        if (n.text_kind == .format) {
            l.ds.err(n.loc, "a formatted caption on a button or checkbox " ++ not_in_tables, .{});
            return null;
        }
        const name = std.fmt.allocPrint(l.arena, "{s}_text", .{n.id}) catch @panic("out of memory");
        for (l.page.fields.items) |f| if (std.mem.eql(u8, f.name, name))
            l.ds.err(n.loc, "the seam names this caption's field '{s}', which the page already binds; rename one", .{name});
        l.fields.append(l.arena, .{ .name = name, .str = n.text }) catch @panic("out of memory");
        return name;
    }

    /// `s` as the seam's style, or null (after an error) when the seam cannot say all of it.
    fn style(l: *Lower, i: u32, s: types.Style) ?zon.ZStyle {
        var z: zon.ZStyle = .{ .min = s.min, .max = s.max, .pad = s.pad, .gap = s.gap, .main = s.main, .cross = s.cross, .shrink = s.shrink, .clip = s.clip, .border = s.border, .radius = s.radius, .opacity = s.opacity };
        for (s.size, &z.size) |in, *out| out.* = switch (in.kind) {
            .fit => .fit,
            .px => .{ .px = in.v },
            .pct => .{ .pct = in.v },
            .grow => if (in.v == 1) .fill else .{ .grow = in.v },
        };
        if (!std.meta.eql(s.fill, types.Color.transparent)) z.fill = .{ .rgba = .{ s.fill.r, s.fill.g, s.fill.b, s.fill.a } };
        if (!std.meta.eql(s.border_color, types.Color.transparent)) z.border_color = .{ .rgba = .{ s.border_color.r, s.border_color.g, s.border_color.b, s.border_color.a } };
        // Round trip: whatever `Style` field the seam has no word for shows up as a difference.
        const th: lcgf.widgets_base.Theme = .default;
        if (std.meta.eql(z.style(&th, s.dir), s)) return z;
        _ = l.refuse(i, "a style property (transform, offset, scroll, per-corner radii, cursor, a texture)", .{});
        return null;
    }

    /// Node `i`'s children, in order. ponytail: a scan of the rows after it per node, fine for
    /// pages of hundreds of nodes; keep a first-child column if pages grow.
    fn children(l: *Lower, i: u32) []const zon.ZNode {
        var out: std.ArrayList(zon.ZNode) = .empty;
        const parents = l.page.nodes.items(.parent);
        for (parents[i + 1 ..], i + 1..) |p, j| if (p == i) {
            if (l.node(@intCast(j))) |z| out.append(l.arena, z) catch @panic("out of memory");
        };
        return out.items;
    }

    fn node(l: *Lower, i: u32) ?zon.ZNode {
        const n = l.page.nodes.get(i);
        const what: []const u8 = switch (n.kind) {
            .landmark => "a landmark (<main>, <nav>, <header>, ...; use a <div>)",
            .heading => "a heading (<h1>..<h6>)",
            .@"switch" => "<input type=checkbox switch>",
            .toggle => "<button aria-pressed>",
            .progress => "<progress>",
            .spinner => "a spinner",
            .separator => "<hr>",
            .radio => "<input type=radio>",
            .textfield => "<input type=text>",
            .search => "<input type=search>",
            .textarea => "<textarea>",
            .number => "<input type=number>",
            .spacer => "justify-content: space-*",
            .each => "<template lcgf-each=\"x in xs\">",
            .component => "an app component",
            .link => "<a href>",
            .section => "<details> and <summary>",
            .select, .select_list => "<select>",
            .dialog => "<dialog>",
            .image => "<img>",
            .tooltip => "a title= tooltip",
            .popover_button, .popover => "a popover",
            .menu_button, .menu_list => "<menu popover>",
            // lcgf-if with lcgf-else: a choice over a bool, which the seam's plan refuses (its
            // selectors are u8 and u32).
            .choice => "<template lcgf-else>",
            .scroll => "overflow: auto or scroll",
            .container, .label, .text, .button, .checkbox, .slider, .when, .list => "",
        };
        if (what.len > 0) {
            // Its content is still checked, so one run reports all of the page.
            _ = l.children(i);
            return l.refuse(i, "{s}", .{what});
        }
        if (n.name.len > 0) return l.refuse(i, "an accessible name (aria-label, a <label> naming a control)", .{});
        if (n.margin != null) return l.refuse(i, "a margin", .{});
        if (n.placed.grid != null or n.placed.cell != null) return l.refuse(i, "display: grid, a table or columns", .{});
        if (n.placed.anchor != null or n.placed.sticky != null or n.placed.layer != 0 or n.placed.below != 0) return l.refuse(i, "position: absolute, fixed or sticky, or z-index", .{});
        if (n.uses.len > 0 or n.text_uses.px != ir.none or n.text_uses.color != ir.none) return l.refuse(i, "a run-time theme token", .{});
        if (n.params_expr.len > 0) return l.refuse(i, "a gradient or dashed border", .{});
        switch (n.kind) {
            .label, .text, .button, .checkbox => if (!std.meta.eql(n.text_style, n.base_text))
                return l.refuse(i, "a text style (font-size, color, font on text)", .{}),
            else => {},
        }
        switch (n.kind) {
            .label, .text, .button, .checkbox, .slider => if (!std.meta.eql(n.style, n.base_style))
                return l.refuse(i, "CSS on a <{s}>", .{switch (n.kind) {
                    .button => "button",
                    .checkbox, .slider => "input",
                    else => "span",
                }}),
            else => {},
        }
        return switch (n.kind) {
            .container => {
                const kids = l.children(i);
                const b: zon.Box = .{ .style = l.style(i, n.style) orelse return null, .children = kids };
                return if (n.dir == .x) .{ .row = b } else .{ .col = b };
            },
            .label => switch (n.text_kind) {
                .field => .{ .label = n.text },
                else => .{ .text = .{ .format = escape(l.arena, n.text) } },
            },
            .text => .{ .text = .{ .format = n.text, .args = n.args } },
            .button => .{ .button = .{ .id = n.id, .text = l.captionField(n) orelse return null } },
            .checkbox => .{ .checkbox = .{ .id = n.id, .bind = n.bind, .text = l.captionField(n) orelse return null } },
            .slider => {
                if (n.range[0] != 0 or n.range[1] != 1) return l.refuse(i, "a range other than min=0 max=1", .{});
                return .{ .slider = .{ .id = n.id, .bind = n.bind } };
            },
            .when => {
                var child = l.only(i) orelse return null;
                switch (child) {
                    .row, .col => |*b| b.when = n.bind,
                    else => return l.refuse(i, "lcgf-if over a lone text or widget (wrap it in a <div>)", .{}),
                }
                return child;
            },
            .list => {
                const s = l.style(i, n.style) orelse return null;
                const t = l.children(i);
                if (t.len != 1) return l.refuse(i, "an lcgf-each template of more than one element (wrap them in a <div>)", .{});
                return .{ .list = .{ .count = n.bind, .max = n.max, .dir = n.style.dir, .style = s, .template = t } };
            },
            else => unreachable,
        };
    }

    fn only(l: *Lower, i: u32) ?zon.ZNode {
        const c = l.children(i);
        return if (c.len == 1) c[0] else null;
    }
};

/// A literal as a format with no arguments: braces doubled.
fn escape(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        out.append(arena, ch) catch @panic("out of memory");
        if (ch == '{' or ch == '}') out.append(arena, ch) catch @panic("out of memory");
    }
    return out.items;
}

/// The page as a `ZSpec`, or null after reporting what the seam cannot carry.
pub fn lower(arena: std.mem.Allocator, ds: *diag.Diags, page: *const ir.Page) ?zon.ZSpec {
    const errors = ds.errors;
    var l: Lower = .{ .arena = arena, .ds = ds, .page = page };
    const html = page.nodes.items(.loc)[0];
    if (!std.meta.eql(page.theme, ir.Theme{})) ds.err(html, "a theme override (--lcgf-* on :root) " ++ Lower.not_in_tables, .{});
    for (page.fields.items) |f| {
        var z: zon.ZField = .{ .name = f.name };
        switch (f.type) {
            .str => z.str = if (f.default.len > 0) std.zig.string_literal.parseAlloc(arena, f.default) catch "" else "",
            .bool => z.bool = std.mem.eql(u8, f.default, "true"),
            .f32 => z.f32 = if (f.default.len > 0) std.fmt.parseFloat(f32, f.default) catch 0 else 0,
            .u32 => z.u32 = if (f.default.len > 0) std.fmt.parseInt(u32, f.default, 10) catch 0 else 0,
            else => ds.err(f.loc, "the {t} field '{s}' " ++ Lower.not_in_tables, .{ f.type, f.name }),
        }
        l.fields.append(arena, z) catch @panic("out of memory");
    }
    const ui = l.node(0);
    if (ds.errors > errors) return null;
    return .{ .name = page.name, .state = l.fields.items, .ui = ui.? };
}

/// `spec` as `.zon` text, defaults left out, a tuple of numbers on one line.
pub fn text(arena: std.mem.Allocator, spec: zon.ZSpec) []const u8 {
    var raw: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serializeArbitraryDepth(spec, .{ .emit_default_optional_fields = false }, &raw.writer) catch @panic("out of memory");
    const s = raw.written();
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], ".{")) {
            const end = std.mem.indexOfScalarPos(u8, s, i, '}').?;
            const body = s[i + 2 .. end];
            if (std.mem.indexOfNone(u8, body, "0123456789.-, \n") == null and std.mem.indexOfAny(u8, body, "0123456789") != null) {
                out.appendSlice(arena, ".{ ") catch @panic("out of memory");
                var it = std.mem.tokenizeAny(u8, body, ", \n");
                var first = true;
                while (it.next()) |num| : (first = false) out.print(arena, "{s}{s}", .{ if (first) "" else ", ", num }) catch @panic("out of memory");
                out.appendSlice(arena, " }") catch @panic("out of memory");
                i = end + 1;
                continue;
            }
        }
        out.append(arena, s[i]) catch @panic("out of memory");
        i += 1;
    }
    out.append(arena, '\n') catch @panic("out of memory");
    return out.items;
}
