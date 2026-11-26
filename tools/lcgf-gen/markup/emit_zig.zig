//! The Zig emitter, `spec` frontend: a `Spec` built from `spec.*` and the widgets' `ct.*`
//! builders, exactly as a hand-written comptime page is, plus the generated view state, the
//! theme, `ComptimeUi`, and `Page(H)`: a frame function that dispatches the page's events to
//! the app's handler type after the draw list is final. Each builder call carries a
//! `// file:line:col` comment; the check block's messages start with the HTML location.

const std = @import("std");
const lcgf = @import("lcgf");
const ir = @import("ir.zig");
const diag = @import("diag.zig");
const types = lcgf.types;

const none = diag.none;

pub const Emit = struct {
    arena: std.mem.Allocator,
    ds: *const diag.Diags,
    page: *const ir.Page,
    out: std.ArrayList(u8) = .empty,
    /// The widget modules the spec uses, for the imports.
    modules: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn print(e: *Emit, comptime format: []const u8, args: anytype) void {
        e.out.print(e.arena, format, args) catch @panic("out of memory");
    }

    fn write(e: *Emit, s: []const u8) void {
        e.out.appendSlice(e.arena, s) catch @panic("out of memory");
    }

    fn where(e: *Emit, loc: diag.Loc) []const u8 {
        const w = e.ds.where(loc);
        return std.fmt.allocPrint(e.arena, "{s}:{d}:{d}", .{ std.fs.path.basename(w.path), w.line, w.col }) catch @panic("out of memory");
    }

    fn whereFull(e: *Emit, loc: diag.Loc) []const u8 {
        const w = e.ds.where(loc);
        return std.fmt.allocPrint(e.arena, "{s}:{d}:{d}", .{ w.path, w.line, w.col }) catch @panic("out of memory");
    }

    fn use(e: *Emit, module: []const u8) []const u8 {
        e.modules.put(e.arena, module, {}) catch @panic("out of memory");
        return module;
    }

    // ---- values ---------------------------------------------------------------------------

    /// Zig source of `v` as a literal of its type, relative to its type's default for structs.
    fn value(e: *Emit, v: anytype) void {
        const T = @TypeOf(v);
        if (T == types.Color) return e.color(v);
        if (T == types.Size) return switch (v.kind) {
            .fit => e.write(".fit"),
            .px => e.print(".px({d})", .{v.v}),
            .grow => if (v.v == 1) e.write(".fill") else e.print(".grow({d})", .{v.v}),
            .pct => e.print(".pct({d})", .{v.v}),
        };
        if (T == types.Participation) {
            if (std.meta.eql(v, types.Participation.hidden)) return e.write(".hidden");
            if (std.meta.eql(v, types.Participation.collapsed)) return e.write(".collapsed");
            return e.structure(v, types.Participation{});
        }
        switch (@typeInfo(T)) {
            .float => if (std.math.isInf(v)) e.write("lcgf.types.inf") else e.print("{d}", .{v}),
            .int, .comptime_int => e.print("{d}", .{v}),
            .bool => e.write(if (v) "true" else "false"),
            .@"enum" => e.print(".{f}", .{std.zig.fmtId(@tagName(v))}),
            .optional => if (v) |x| e.value(x) else e.write("null"),
            .array => |a| {
                var same = a.len > 1;
                for (v[1..]) |x| same = same and std.meta.eql(x, v[0]);
                if (same) {
                    e.write("@splat(");
                    e.value(v[0]);
                    e.write(")");
                    return;
                }
                e.write(".{ ");
                for (v, 0..) |x, i| {
                    if (i > 0) e.write(", ");
                    e.value(x);
                }
                e.write(" }");
            },
            .@"struct" => e.structure(v, T{}),
            else => @compileError("no literal for " ++ @typeName(T)),
        }
    }

    fn color(e: *Emit, c: types.Color) void {
        if (std.meta.eql(c, types.Color.transparent)) return e.write(".transparent");
        if (c.a == 255) return e.print(".rgb({d}, {d}, {d})", .{ c.r, c.g, c.b });
        e.print(".rgba({d}, {d}, {d}, {d})", .{ c.r, c.g, c.b, c.a });
    }

    /// `.{ .field = value, … }` with the fields of `v` that differ from `default`.
    fn structure(e: *Emit, v: anytype, default: @TypeOf(v)) void {
        e.fields(v, default, &.{}, "");
    }

    /// As `structure`, leaving out the fields named in `skip`; `params` replaces
    /// `Style.params` when it is not "".
    fn fields(e: *Emit, v: anytype, default: @TypeOf(v), comptime skip: []const []const u8, params: []const u8) void {
        var any = false;
        e.write(".{");
        inline for (comptime @typeInfo(@TypeOf(v)).@"struct".field_names) |name| {
            const skipped = comptime for (skip) |s| {
                if (std.mem.eql(u8, s, name)) break true;
            } else false;
            const is_params = comptime std.mem.eql(u8, name, "params");
            if ((!skipped and !std.meta.eql(@field(v, name), @field(default, name))) or (is_params and params.len > 0)) {
                e.write(if (any) ", ." else " .");
                e.write(name);
                e.write(" = ");
                if (is_params and params.len > 0) e.write(params) else e.value(@field(v, name));
                any = true;
            }
        }
        e.write(if (any) " }" else "}");
    }

    fn string(e: *Emit, s: []const u8) void {
        e.print("\"{f}\"", .{std.zig.fmtString(s)});
    }

    /// A caption argument: a string literal or an enum literal naming the field.
    fn caption(e: *Emit, kind: ir.TextKind, text: []const u8) void {
        switch (kind) {
            .none => e.write("\"\""),
            .literal => e.string(text),
            .field => e.print(".{f}", .{std.zig.fmtId(text)}),
            .format => e.string(text),
        }
    }

    // ---- the spec -------------------------------------------------------------------------

    /// The builder call of node `i` up to where its children go (or whole, for a leaf), and
    /// what closes it after them.
    fn open(e: *Emit, i: u32) []const u8 {
        const n = e.page.nodes.get(i);
        var close: std.ArrayList(u8) = .empty;
        // Wrappers, outermost first: named, textStyled, styled.
        if (n.name.len > 0) {
            e.write("s.named(");
            close.print(e.arena, ", \"{f}\")", .{std.zig.fmtString(n.name)}) catch unreachable;
        }
        // Flex item margins: engine spec F2, `spec.flexed(s, Flex.Style)`.
        var margin_close: []const u8 = "";
        if (n.margin) |m| {
            e.write("s.flexed(");
            var buf: std.ArrayList(u8) = .empty;
            std.mem.swap(std.ArrayList(u8), &buf, &e.out);
            e.write(", .{ .margin = ");
            e.value(m);
            e.write(" })");
            std.mem.swap(std.ArrayList(u8), &buf, &e.out);
            margin_close = buf.items;
        }
        const restyle = !std.meta.eql(n.style, n.base_style) or n.params_expr.len > 0;
        const has_children = switch (n.kind) {
            .container, .landmark, .when, .choice, .list => true,
            else => false,
        };
        var inner_close: std.ArrayList(u8) = .empty;
        const text_styled = switch (n.kind) {
            .label, .text, .heading => !std.meta.eql(n.text_style, n.base_text),
            else => false,
        };
        if (text_styled) e.write("s.textStyled(");
        if (restyle and !has_children) e.write("s.styled(");
        switch (n.kind) {
            .container => {
                e.write(if (n.dir == .x) "s.row(" else "s.col(");
                e.fields(n.style, types.Style{}, &.{"dir"}, n.params_expr);
                e.write(", .{");
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
            .landmark => {
                e.print("s.landmark(.{s}, ", .{n.landmark});
                var st = n.style;
                st.role = .none; // the landmark sets it
                e.fields(st, types.Style{}, &.{}, n.params_expr);
                e.write(", .{");
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
            .label => {
                e.print("{s}.ct.label(theme, ", .{e.use("label")});
                e.caption(n.text_kind, n.text);
                e.write(")");
            },
            .text => {
                e.write("s.text(");
                e.string(n.text);
                e.write(", .{");
                for (n.args, 0..) |a, k| e.print("{s}.{f}", .{ if (k == 0) " " else ", ", std.zig.fmtId(a) });
                e.write(if (n.args.len > 0) " })" else "})");
            },
            .heading => {
                e.print("s.heading({d}, ", .{n.level});
                e.caption(n.text_kind, n.text);
                e.write(")");
            },
            .button => {
                e.print("{s}.ct.button(theme, .{f}, ", .{ e.use("button"), std.zig.fmtId(n.id) });
                e.caption(n.text_kind, n.text);
                e.write(")");
            },
            .checkbox, .@"switch", .toggle => {
                const m = switch (n.kind) {
                    .checkbox => "checkbox",
                    .@"switch" => "switch_",
                    else => "toggle",
                };
                const f = switch (n.kind) {
                    .checkbox => "checkbox",
                    .@"switch" => "@\"switch\"",
                    else => "toggle",
                };
                e.print("{s}.ct.{s}(theme, .{f}, .{f}, ", .{ e.use(m), f, std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(n.text_kind, n.text);
                e.write(")");
            },
            .slider => {
                e.print("{s}.ct.slider(theme, .{f}, .{f}, ", .{ e.use("slider"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.structure(lcgf.widgets_slider.Range{ .lo = n.range[0], .hi = n.range[1] }, .{});
                e.write(")");
            },
            .progress => e.print("{s}.ct.progress(theme, .{f})", .{ e.use("progress"), std.zig.fmtId(n.bind) }),
            .separator => e.print("{s}.ct.separator(theme, .{s})", .{ e.use("separator"), if (n.level == 1) "vertical" else "horizontal" }),
            .spacer => e.print("{s}.ct.spacer(.{s})", .{ e.use("spacer"), if (n.dir == .x) "x" else "y" }),
            .when, .choice, .list, .spinner, .radio, .textfield, .search, .textarea, .number => unreachable,
        }
        if (restyle and !has_children) {
            e.write(", ");
            e.fields(n.style, types.Style{}, &.{}, n.params_expr);
            e.write(")");
        }
        if (text_styled) {
            e.write(", ");
            e.structure(n.text_style, types.TextStyle{});
            e.write(")");
        }
        var all: std.ArrayList(u8) = .empty;
        all.appendSlice(e.arena, inner_close.items) catch unreachable;
        all.appendSlice(e.arena, margin_close) catch unreachable;
        all.appendSlice(e.arena, close.items) catch unreachable;
        if (!has_children) {
            e.write(all.items);
            return "";
        }
        return all.items;
    }

    fn indent(e: *Emit, depth: usize) void {
        for (0..depth) |_| e.write("    ");
    }

    /// The spec: node 0 and its subtree, children inside their parent's tuple. The nodes are
    /// depth-first, so a stack of open parents closes each one when the walk leaves it.
    fn spec(e: *Emit) void {
        const nodes = e.page.nodes.slice();
        if (nodes.len == 0) {
            e.write("pub const spec = s.col(.{}, .{});\n");
            return;
        }
        var stack: std.ArrayList(struct { node: u32, close: []const u8 }) = .empty;
        e.write("pub const spec = ");
        for (0..nodes.len) |i_| {
            const i: u32 = @intCast(i_);
            const parent = nodes.items(.parent)[i];
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].node != parent) {
                const top = stack.pop().?;
                e.indent(stack.items.len);
                e.write(top.close);
                e.write(if (stack.items.len > 0) ",\n" else "");
            }
            if (i > 0) e.indent(stack.items.len);
            const close = e.open(i);
            if (close.len > 0) {
                e.print(" // {s}\n", .{e.where(nodes.items(.loc)[i])});
                stack.append(e.arena, .{ .node = i, .close = close }) catch unreachable;
            } else e.print(", // {s}\n", .{e.where(nodes.items(.loc)[i])});
        }
        while (stack.pop()) |top| {
            e.indent(stack.items.len);
            e.write(top.close);
            e.write(if (stack.items.len > 0) ",\n" else "");
        }
        e.write(";\n");
    }

    fn fieldType(t: ir.FieldType) []const u8 {
        return switch (t) {
            .str => "[]const u8",
            .bool => "bool",
            .f32 => "f32",
            .u32 => "u32",
            .text => "lcgf.widgets_textfield.Text(256)",
            .number => "lcgf.widgets_number.Number",
            .pair => "[2]f32",
        };
    }

    fn defaultOf(f: ir.Field) []const u8 {
        if (f.default.len > 0) return f.default;
        return switch (f.type) {
            .str => "\"\"",
            .bool => "false",
            .f32, .u32 => "0",
            .text, .number, .pair => ".{}",
        };
    }

    /// The handler's function type, as the app writes it.
    fn signature(e: *Emit, h: ir.Handler, comptime H: []const u8) []const u8 {
        const extra = if (h.payload) |p| std.fmt.allocPrint(e.arena, ", value: {s}", .{fieldType(p)}) catch unreachable else "";
        return std.fmt.allocPrint(e.arena, "pub fn {s}(h: *{s}, ui: *Ui{s}) void", .{ h.name, H, extra }) catch unreachable;
    }

    fn fnType(e: *Emit, h: ir.Handler) []const u8 {
        return std.fmt.allocPrint(e.arena, "fn (*H, *Ui{s}{s}) void", .{ if (h.payload != null) ", " else "", if (h.payload) |p| fieldType(p) else "" }) catch unreachable;
    }

    pub fn file(e: *Emit, source: []const u8) []const u8 {
        const page = e.page;
        var body: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        e.spec();
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        e.print("//! Generated from {s} by lcgf-gen; do not edit.\n\n", .{std.fs.path.basename(source)});
        e.write("const lcgf = @import(\"lcgf\");\nconst s = lcgf.spec;\nconst w = lcgf.widgets_base;\n");
        var it = e.modules.iterator();
        var names: std.ArrayList([]const u8) = .empty;
        while (it.next()) |m| names.append(e.arena, m.key_ptr.*) catch unreachable;
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        for (names.items) |m| e.print("const {s} = lcgf.widgets_{s};\n", .{ m, if (std.mem.eql(u8, m, "switch_")) "switch" else m });
        e.write("\n");
        if (page.title.len > 0) {
            e.write("pub const title = ");
            e.string(page.title);
            e.write(";\n\n");
        }
        e.write("/// The view state: one field per name the page binds, typed by where it is bound.\n");
        e.write("pub const State = struct {");
        if (page.fields.items.len == 0) e.write("};\n\n") else {
            e.write("\n");
            for (page.fields.items) |f| e.print("    {f}: {s} = {s}, // {s}\n", .{ std.zig.fmtId(f.name), fieldType(f.type), defaultOf(f), e.where(f.loc) });
            e.write("};\n\n");
        }
        e.write("pub const theme: w.Theme = ");
        e.structure(page.theme, ir.Theme{});
        e.write(";\n\n");
        e.write(body.items);
        e.write("\npub const Ui = w.ComptimeUi(State, spec, theme);\npub const Widget = Ui.Events.Widget;\n\n");
        e.page_fn();
        return e.out.items;
    }

    fn page_fn(e: *Emit) void {
        const page = e.page;
        const hs = page.handlers.items;
        e.write(
            \\/// The page driven by the app's handler type `H`: `frame` builds and draws, then calls
            \\/// the handlers of this frame's events, after the draw list is final.
            \\pub fn Page(comptime H: type) type {
            \\    comptime check(H);
            \\    return struct {
            \\        ui: Ui = .{},
            \\
            \\        pub fn frame(p: *@This(), h: *H, in: *const lcgf.input.Input) Ui.Output {
            \\
        );
        var changes = false;
        var clicks: u32 = 0;
        for (hs) |h| {
            changes = changes or h.event == .change;
            clicks += @intFromBool(h.event == .click);
        }
        if (hs.len == 0) e.write("            _ = h;\n");
        if (changes) e.write("            const before = p.ui.signals.state;\n");
        e.write("            const out = p.ui.frame(in);\n");
        // Clicks: one prong per widget with a click handler.
        if (clicks > 0) {
            e.write("            if (out.event) |event| switch (event) {\n");
            for (hs) |h| if (h.event == .click) e.print("                .{f} => h.{f}(&p.ui), // {s}\n", .{ std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
            var widgets: u32 = 0;
            for (e.page.nodes.items(.id)) |id| widgets += @intFromBool(id.len > 0);
            if (widgets > clicks) e.write("                else => {},\n");
            e.write("            };\n");
        }
        for (hs) |h| if (h.event == .change)
            e.print("            if (p.ui.signals.state.{f} != before.{f}) h.{f}(&p.ui, p.ui.signals.state.{f}); // {s}\n", .{ std.zig.fmtId(h.field), std.zig.fmtId(h.field), std.zig.fmtId(h.name), std.zig.fmtId(h.field), e.where(h.loc) });
        e.write("            return out;\n        }\n    };\n}\n\n");
        // The check block: each handler the markup names, with the signature it must have.
        e.write("/// Checks the handler type against the markup; every message starts at the HTML that\n/// names the handler.\nfn check(comptime H: type) void {\n");
        if (hs.len == 0) e.write("    _ = H;\n");
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (hs) |h| {
            if (seen.contains(h.name)) continue;
            seen.put(e.arena, h.name, {}) catch unreachable;
            const at = e.whereFull(h.loc);
            e.print("    if (!@hasDecl(H, \"{s}\")) @compileError(\"{s}: handler '{s}' is missing: add `{s}`\");\n", .{ h.name, at, h.name, e.signature(h, "\" ++ @typeName(H) ++ \"") });
            // The found type would spell out `Ui`, the whole spec; the expected one is enough.
            e.print("    if (@TypeOf(H.{f}) != {s}) @compileError(\"{s}: handler '{s}' must be `{s}`\");\n", .{ std.zig.fmtId(h.name), e.fnType(h), at, h.name, e.signature(h, "H") });
        }
        e.write("}\n");
    }
};
