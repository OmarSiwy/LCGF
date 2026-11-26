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
    /// Emit the runtime frontend (`Context`/`Frame` and widget calls) instead of a `Spec` page.
    runtime: bool = false,
    /// The token uses of the node being written (runtime frontend), read by `tokenField`.
    uses: []const ir.TokenUse = &.{},
    text_uses: ir.TextTokens = .{},

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
            const token = if (comptime skipped) null else e.tokenField(@TypeOf(v), name, @field(v, name));
            if (token) |expr| {
                e.write(if (any) ", ." else " .");
                e.write(name);
                e.write(" = ");
                e.write(expr);
                any = true;
            } else if ((!skipped and !std.meta.eql(@field(v, name), @field(default, name))) or (is_params and params.len > 0)) {
                e.write(if (any) ", ." else " .");
                e.write(name);
                e.write(" = ");
                if (is_params and params.len > 0) e.write(params) else e.value(@field(v, name));
                any = true;
            }
        }
        e.write(if (any) " }" else "}");
    }

    /// `ui.tokens.values.<field>` of token `t`.
    fn tokenExpr(e: *Emit, t: u32) []const u8 {
        return std.fmt.allocPrint(e.arena, "ui.tokens.values.{f}", .{std.zig.fmtId(e.page.tokens.items[t].field)}) catch unreachable;
    }

    /// The expression of a style field that reads run-time tokens (`uses`, `text_uses` of
    /// the node being written), or null when it is a constant.
    fn tokenField(e: *Emit, comptime T: type, comptime name: []const u8, v: anytype) ?[]const u8 {
        if (T == types.TextStyle) {
            if (comptime std.mem.eql(u8, name, "px")) if (e.text_uses.px != none) return e.tokenExpr(e.text_uses.px);
            if (comptime std.mem.eql(u8, name, "color")) if (e.text_uses.color != none) return e.tokenExpr(e.text_uses.color);
            return null;
        }
        if (T != types.Style or e.uses.len == 0) return null;
        const Tg = ir.Target;
        const scalar = [_]struct { []const u8, Tg }{ .{ "gap", .gap }, .{ "border", .border }, .{ "radius", .radius }, .{ "fill", .fill }, .{ "border_color", .border_color } };
        inline for (scalar) |sc| if (comptime std.mem.eql(u8, name, sc[0])) {
            for (e.uses) |u| if (u.target == sc[1]) return e.tokenExpr(u.token);
            return null;
        };
        const arrays = [_]struct { []const u8, []const Tg }{
            .{ "pad", &.{ .pad_left, .pad_top, .pad_right, .pad_bottom } },
            .{ "size", &.{ .width, .height } },
            .{ "min", &.{ .min_width, .min_height } },
            .{ "max", &.{ .max_width, .max_height } },
        };
        inline for (arrays) |ar| if (comptime std.mem.eql(u8, name, ar[0])) {
            var any = false;
            var out: std.ArrayList(u8) = .empty;
            out.appendSlice(e.arena, ".{ ") catch unreachable;
            for (ar[1], 0..) |target, k| {
                if (k > 0) out.appendSlice(e.arena, ", ") catch unreachable;
                const tok = for (e.uses) |u| {
                    if (u.target == target) break u.token;
                } else none;
                if (tok != none) {
                    any = true;
                    if (comptime std.mem.eql(u8, name, "size")) out.print(e.arena, ".px({s})", .{e.tokenExpr(tok)}) catch unreachable else out.appendSlice(e.arena, e.tokenExpr(tok)) catch unreachable;
                } else {
                    // The constant element, printed by the generic printer into `out`.
                    std.mem.swap(std.ArrayList(u8), &out, &e.out);
                    e.value(v[k]);
                    std.mem.swap(std.ArrayList(u8), &out, &e.out);
                }
            }
            out.appendSlice(e.arena, " }") catch unreachable;
            return if (any) out.items else null;
        };
        return null;
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
        // Run-time theme tokens: `spec.tokened(s, uses)` (T-CT), read when the row is pushed.
        var tokens_close: []const u8 = "";
        const texty = n.kind == .label or n.kind == .text or n.kind == .heading;
        const text_uses: ir.TextTokens = if (texty) n.text_uses else .{};
        if (n.uses.len > 0 or text_uses.px != none or text_uses.color != none) {
            e.write("s.tokened(");
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(e.arena, ", &.{") catch unreachable;
            var k: usize = 0;
            for (n.uses) |u| {
                buf.print(e.arena, "{s}.{{ .target = .{s}, .token = \"{s}\" }}", .{ if (k == 0) " " else ", ", @tagName(u.target), e.page.tokens.items[u.token].field }) catch unreachable;
                k += 1;
            }
            inline for (.{ .{ "px", "text_px" }, .{ "color", "text_color" } }) |tu| if (@field(text_uses, tu[0]) != none) {
                buf.print(e.arena, "{s}.{{ .target = .{s}, .token = \"{s}\" }}", .{ if (k == 0) " " else ", ", tu[1], e.page.tokens.items[@field(text_uses, tu[0])].field }) catch unreachable;
                k += 1;
            };
            buf.appendSlice(e.arena, " })") catch unreachable;
            tokens_close = buf.items;
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
            .when => {
                e.print("s.when(.{f},", .{std.zig.fmtId(n.bind)});
                inner_close.appendSlice(e.arena, ")") catch unreachable;
            },
            .list => {
                e.print("s.list(.{f}, {d}, ", .{ std.zig.fmtId(n.bind), n.max });
                e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                e.write(",");
                inner_close.appendSlice(e.arena, ")") catch unreachable;
            },
            .choice => {
                e.print("s.choice(.{f}, .{{}}, .{{", .{std.zig.fmtId(n.bind)});
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
            .number => {
                e.print("{s}.ct.number(theme, .{f}, .{f}, ", .{ e.use("number"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.structure(lcgf.widgets_number.Range{ .lo = n.range[0], .hi = n.range[1], .step = n.range[2] }, .{});
                e.write(")");
            },
            .radio => {
                e.print("{s}.ct.radio(theme, .{f}, .{f}, .{{", .{ e.use("radio"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                for (n.captions, 0..) |c, k| {
                    e.write(if (k == 0) " " else ", ");
                    e.string(c);
                }
                e.write(" })");
            },
            .textfield, .search => {
                const m = if (n.kind == .search) "search" else "textfield";
                e.print("{s}.ct.{s}(theme, .{f}, .{f}, ", .{ e.use(m), m, std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(")");
            },
            .textarea => {
                e.print("{s}.ct.textarea(theme, .{f}, .{f}, {d}, ", .{ e.use("textarea"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind), n.level });
                e.caption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(")");
            },
            .each => e.print("lcgf.ct_interop.region(.{f}, {s})", .{ std.zig.fmtId(n.id), e.styleText(n.style, n.params_expr) }),
            .spinner => unreachable,
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
        all.appendSlice(e.arena, tokens_close) catch unreachable;
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
            // A run-time region's content is built at run time (`Page.frame`), not in the spec.
            if (e.eachOf(parent) != none) continue;
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
            .@"enum" => "enum {}",
        };
    }

    fn defaultOf(f: ir.Field) []const u8 {
        if (f.default.len > 0) return f.default;
        return switch (f.type) {
            .str => "\"\"",
            .bool => "false",
            .f32, .u32 => "0",
            .text, .number, .pair, .@"enum" => ".{}",
        };
    }

    /// The handler's function type, as the app writes it.
    fn signature(e: *Emit, h: ir.Handler, comptime H: []const u8) []const u8 {
        const extra = if (h.each.len > 0) ", index: u32" else if (h.payload) |p| std.fmt.allocPrint(e.arena, ", value: {s}", .{fieldType(p)}) catch unreachable else "";
        return std.fmt.allocPrint(e.arena, "pub fn {s}(h: *{s}, ui: *Ui{s}) void", .{ h.name, H, extra }) catch unreachable;
    }

    fn fnType(e: *Emit, h: ir.Handler) []const u8 {
        if (h.each.len > 0) return "fn (*H, *Ui, u32) void";
        return std.fmt.allocPrint(e.arena, "fn (*H, *Ui{s}{s}) void", .{ if (h.payload != null) ", " else "", if (h.payload) |p| fieldType(p) else "" }) catch unreachable;
    }

    pub fn file(e: *Emit, source: []const u8) []const u8 {
        const page = e.page;
        var body: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        e.spec();
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        var rt: std.ArrayList(u8) = .empty;
        // Generated before the imports, which list the widget modules these use.
        std.mem.swap(std.ArrayList(u8), &rt, &e.out);
        if (e.runtime) e.runtimeUi() else e.page_fn();
        std.mem.swap(std.ArrayList(u8), &rt, &e.out);
        e.print("//! Generated from {s} by lcgf-gen ({s} frontend); do not edit.\n\n", .{ std.fs.path.basename(source), if (e.runtime) "runtime" else "spec" });
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
            for (page.fields.items) |f| {
                if (f.type == .@"enum") {
                    e.print("    {f}: enum {{", .{std.zig.fmtId(f.name)});
                    for (f.cases, 0..) |c, k| e.print("{s} {f}", .{ if (k == 0) "" else ",", std.zig.fmtId(c) });
                    e.print(" }} = .{f}, // {s}\n", .{ std.zig.fmtId(f.cases[0]), e.where(f.loc) });
                } else e.print("    {f}: {s} = {s}, // {s}\n", .{ std.zig.fmtId(f.name), fieldType(f.type), defaultOf(f), e.where(f.loc) });
            }
            e.write("};\n\n");
        }
        e.write("pub const theme: w.Theme = ");
        e.structure(page.theme, ir.Theme{});
        e.write(";\n\n");
        e.tokensDecl();
        e.write(body.items);
        if (e.runtime) {
            e.write(rt.items);
            e.runtimePage();
        } else {
            if (page.tokens.items.len > 0)
                e.write("\npub const Ui = w.ComptimeUiTokens(State, spec, theme, Tokens);\npub const Widget = Ui.Events.Widget;\n\n")
            else
                e.write("\npub const Ui = w.ComptimeUi(State, spec, theme);\npub const Widget = Ui.Events.Widget;\n\n");
            e.write(rt.items);
        }
        e.checkBlock();
        return e.out.items;
    }

    // ---- runtime frontend -----------------------------------------------------------------

    /// `ui.signals.state.<name>`.
    /// The `each` region node `i` is in (itself included), or none.
    fn eachOf(e: *Emit, i: u32) u32 {
        var k = i;
        const nodes = e.page.nodes.slice();
        while (k != none) : (k = nodes.items(.parent)[k]) if (nodes.items(.kind)[k] == .each) return k;
        return none;
    }

    /// A style literal as text.
    fn styleText(e: *Emit, st: types.Style, params: []const u8) []const u8 {
        var buf: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &buf, &e.out);
        e.fields(st, types.Style{}, &.{}, params);
        std.mem.swap(std.ArrayList(u8), &buf, &e.out);
        return buf.items;
    }

    fn stateRef(e: *Emit, name: []const u8) []const u8 {
        // `item.field` of an lcgf-each item: the loop's capture, not the view state.
        if (std.mem.indexOfScalar(u8, name, '.') != null) return name;
        return std.fmt.allocPrint(e.arena, "ui.signals.state.{f}", .{std.zig.fmtId(name)}) catch unreachable;
    }

    /// A runtime caption: the string literal or the bound field.
    fn rtCaption(e: *Emit, kind: ir.TextKind, text: []const u8) void {
        switch (kind) {
            .none => e.write("\"\""),
            .literal, .format => e.string(text),
            .field => e.write(e.stateRef(text)),
        }
    }

    /// The widget id of node `n` in the runtime frontend: hashed while compiling, and inside a
    /// repeated template made unique by the copy's index.
    fn rtId(e: *Emit, id: []const u8, list_depth: u32) []const u8 {
        if (list_depth == 0) return std.fmt.allocPrint(e.arena, ".from(\"{s}\")", .{id}) catch unreachable;
        return std.fmt.allocPrint(e.arena, "lcgf.types.Id.from(\"{s}\").with(@intCast(copy{d}))", .{ id, list_depth - 1 }) catch unreachable;
    }

    /// lcgf's format language (`{}`, `{.N}`) as std.fmt's, which `Frame.textfStyled` takes.
    fn stdFormat(e: *Emit, f: []const u8, args: []const []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        var i: usize = 0;
        while (i < f.len) : (i += 1) {
            if (f[i] == '{' and i + 1 < f.len and f[i + 1] == '{') {
                out.appendSlice(e.arena, "{{") catch unreachable;
                i += 1;
            } else if (f[i] == '{') {
                const close = std.mem.indexOfScalarPos(u8, f, i, '}').?;
                const spec_ = f[i + 1 .. close];
                const ty = for (e.page.fields.items) |fd| {
                    if (std.mem.eql(u8, fd.name, args[k])) break fd.type;
                } else .str;
                if (spec_.len > 0) out.print(e.arena, "{{d:{s}}}", .{spec_}) catch unreachable else out.appendSlice(e.arena, if (ty == .str) "{s}" else "{any}") catch unreachable;
                k += 1;
                i = close;
            } else out.append(e.arena, f[i]) catch unreachable;
        }
        return out.items;
    }

    /// Statements that build node `i` up to its children, and what closes it.
    fn rtOpen(e: *Emit, i: u32, list_depth: u32) []const u8 {
        const n = e.page.nodes.get(i);
        e.uses = n.uses;
        e.text_uses = n.text_uses;
        switch (n.kind) {
            .container, .landmark => {
                var st = n.style;
                if (n.kind == .landmark) st.role = std.meta.stringToEnum(types.Role, n.landmark).?;
                e.write("_ = f.open(.none, ");
                e.fields(st, types.Style{}, &.{}, n.params_expr);
                e.write(");");
                return "f.close();";
            },
            .label, .heading, .text => {
                const plain = n.kind == .label and std.meta.eql(n.style, n.base_style) and std.meta.eql(n.text_style, n.base_text) and n.params_expr.len == 0 and n.uses.len == 0 and n.text_uses.color == none and n.text_uses.px == none;
                if (plain) {
                    e.print("_ = {s}.label(f, &theme, ", .{e.use("label")});
                    e.rtCaption(n.text_kind, n.text);
                    e.write(");");
                    return "";
                }
                if (n.text_kind == .format) {
                    e.write("_ = f.textfStyled(");
                    e.string(e.stdFormat(n.text, n.args));
                    e.write(", .{");
                    for (n.args, 0..) |a, k| e.print("{s}{s}", .{ if (k == 0) " " else ", ", e.stateRef(a) });
                    e.write(if (n.args.len > 0) " }, " else "}, ");
                } else {
                    e.write("_ = f.textStyled(");
                    e.rtCaption(n.text_kind, n.text);
                    e.write(", ");
                }
                e.structure(n.text_style, types.TextStyle{});
                e.write(", ");
                e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                e.write(");");
                return "";
            },
            .button => {
                const h = e.clickHandler(n.id);
                e.print("{s}{s}.button(f, &theme, {s}, ", .{ if (h != null) "if (" else "_ = ", e.use("button"), e.rtId(n.id, list_depth) });
                e.rtCaption(n.text_kind, n.text);
                if (h == null) e.write(");") else if (e.eachOf(i) != none)
                    e.print(").clicked) events.{f} = @intCast(copy0);", .{std.zig.fmtId(n.id)})
                else
                    e.print(").clicked) ui.events.{f} = true;", .{std.zig.fmtId(n.id)});
                return "";
            },
            .checkbox, .@"switch", .toggle => {
                const m = switch (n.kind) {
                    .checkbox => "checkbox",
                    .@"switch" => "switch_",
                    else => "toggle",
                };
                const fn_name = if (n.kind == .@"switch") "@\"switch\"" else m;
                e.print("_ = {s}.{s}(f, &theme, {s}, &{s}, ", .{ e.use(m), fn_name, e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                e.rtCaption(n.text_kind, n.text);
                e.write(");");
                return "";
            },
            .slider => {
                e.print("_ = {s}.slider(f, &theme, {s}, &{s}, {d}, {d});", .{ e.use("slider"), e.rtId(n.id, list_depth), e.stateRef(n.bind), n.range[0], n.range[1] });
                return "";
            },
            .progress => {
                e.print("_ = {s}.progress(f, &theme, {s});", .{ e.use("progress"), e.stateRef(n.bind) });
                return "";
            },
            .separator => {
                e.print("_ = {s}.separator(f, &theme, .{s});", .{ e.use("separator"), if (n.level == 1) "vertical" else "horizontal" });
                return "";
            },
            .number => {
                e.print("_ = {s}.number(f, &theme, {s}, &{s}, ", .{ e.use("number"), e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                e.structure(lcgf.widgets_number.Range{ .lo = n.range[0], .hi = n.range[1], .step = n.range[2] }, .{});
                e.write(");");
                return "";
            },
            .radio => {
                e.print("_ = {s}.radio(f, &theme, {s}, &{s}, &.{{", .{ e.use("radio"), e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                for (n.captions, 0..) |c, k| {
                    e.write(if (k == 0) " " else ", ");
                    e.string(c);
                }
                e.write(" });");
                return "";
            },
            .textfield, .search => {
                const m = if (n.kind == .search) "search" else "textfield";
                e.print("_ = {s}.{s}(f, &theme, {s}, &{s}, ", .{ e.use(m), m, e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                e.rtCaption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(");");
                return "";
            },
            .textarea => {
                e.print("_ = {s}.textarea(f, &theme, {s}, &{s}, {d}, ", .{ e.use("textarea"), e.rtId(n.id, list_depth), e.stateRef(n.bind), n.level });
                e.rtCaption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(");");
                return "";
            },
            .when => {
                e.print("if ({s}) {{", .{e.stateRef(n.bind)});
                return "}";
            },
            .list => {
                e.write("_ = f.open(.none, ");
                e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                e.print("); for (0..@min({s}, {d})) |copy{d}| {{", .{ e.stateRef(n.bind), n.max, list_depth });
                if (!e.usesCopy(i)) e.print(" _ = copy{d};", .{list_depth});
                return "} f.close();";
            },
            .choice => {
                e.print("_ = f.open(.none, .{{}}); switch ({s}) {{", .{e.stateRef(n.bind)});
                return "} f.close();";
            },
            .spacer, .spinner, .each => unreachable,
        }
    }

    /// Whether a list's template holds a widget, whose id needs the copy index.
    fn usesCopy(e: *Emit, list: u32) bool {
        const parents = e.page.nodes.items(.parent);
        for (e.page.nodes.items(.id), 0..) |id, k| if (id.len > 0) {
            var p = parents[k];
            while (p != none) : (p = parents[p]) if (p == list) return true;
        };
        return false;
    }

    fn clickHandler(e: *Emit, widget: []const u8) ?ir.Handler {
        for (e.page.handlers.items) |h| if (h.event == .click and std.mem.eql(u8, h.widget, widget)) return h;
        return null;
    }

    /// `Tokens`, `ThemeTable` and `default_tokens` of a page with run-time theme tokens.
    fn tokensDecl(e: *Emit) void {
        const tokens = e.page.tokens.items;
        if (tokens.len == 0) return;
        e.write("/// The page's run-time theme tokens (its `--t-*` custom properties), with the defaults its\n/// CSS gives. The page reads them from the caller's table (`ui.tokens`) as it builds.\npub const Tokens = struct {\n");
        for (tokens) |t| switch (t.kind) {
            .length => e.print("    {f}: f32 = {d}, // {s}\n", .{ std.zig.fmtId(t.field), t.default_px, e.where(t.loc) }),
            .color => {
                e.print("    {f}: lcgf.types.Color = ", .{std.zig.fmtId(t.field)});
                e.color(t.default_color);
                e.print(", // {s}\n", .{e.where(t.loc)});
            },
        };
        e.write("};\npub const ThemeTable = lcgf.theme_table.ThemeTable(Tokens);\npub const default_tokens: ThemeTable = .{};\n\n");
    }

    /// `Ui` of the runtime frontend: the state store the comptime page has (`signals`), and
    /// `build(ui, f)`, which builds the page into a runtime `Frame` and records its events.
    fn runtimeUi(e: *Emit) void {
        const tokens = e.page.tokens.items;
        e.write(
            \\
            \\/// The page in the runtime front end: the same state store as the comptime page's
            \\/// (`ui.signals`), so handlers are the same code in both front ends.
            \\pub const Ui = struct {
            \\    signals: lcgf.signals.Signals(State, spec).Runtime = .{},
            \\    /// This frame's clicks, dispatched by `Page.frame` after the draw list is final.
            \\    events: struct {
        );
        var any = false;
        for (e.page.handlers.items) |h| if (h.event == .click) {
            e.print(" {f}: bool = false,", .{std.zig.fmtId(h.widget)});
            any = true;
        };
        e.write(if (any) " } = .{},\n" else "} = .{},\n");
        e.write(
            \\    /// The state as the frame began, for on:change.
            \\    before: State = .{},
            \\
        );
        const flex = e.hasFlex();
        if (flex) e.write(
            \\    /// Flex rules (layout/flex.zig) of the nodes with margins, written while the page
            \\    /// builds and used by `end`. They point into `flex_buf`: a Ui does not move once built.
            \\    flex_buf: [flex_bytes]u8 align(lcgf.mem.column_align) = undefined,
            \\    flex: ?lcgf.flex.Flex = null,
            \\
            \\    /// Ends the frame with this page's flex rules (`Frame.endFlex`).
            \\    pub fn end(ui: *Ui, f: *lcgf.frame.Frame, font: lcgf.protocol.Mono) lcgf.context.Output {
            \\        return f.endFlex(font, &ui.flex.?);
            \\    }
            \\
            \\
        );
        if (tokens.len > 0) e.write(
            \\    /// The caller's theme tokens; point it at your table.
            \\    tokens: *const ThemeTable = &default_tokens,
            \\    /// The table's generation the last build read.
            \\    seen: u32 = 0,
            \\
            \\    /// Whether the tokens changed since the last build, which then lays the page out again.
            \\    pub fn themeChanged(ui: *const Ui) bool {
            \\        return ui.tokens.changedSince(ui.seen);
            \\    }
            \\
            \\
        );
        e.write(
            \\    pub fn build(ui: *Ui, f: *lcgf.frame.Frame) void {
            \\        ui.events = .{};
            \\        ui.before = ui.signals.state;
            \\
        );
        if (tokens.len > 0) e.write("        ui.seen = ui.tokens.generation;\n");
        if (flex) e.write(
            \\        if (ui.flex == null) {
            \\            var carver: lcgf.mem.Carver = .{ .buf = &ui.flex_buf };
            \\            ui.flex = lcgf.flex.Flex.init(&carver, limits.nodes);
            \\        }
            \\        const fx = &ui.flex.?;
            \\
        );
        e.rtWalk(none, 0);
        e.write("    }\n\n");
        e.rtDispatch();
    }

    /// The runtime statements of every node (`within` none), or of the descendants of
    /// `within`, nested `depth` levels below the function body, inside `lists` repeats.
    fn rtWalk(e: *Emit, within: u32, lists_: u32) void {
        const nodes = e.page.nodes.slice();
        const base: usize = if (within == none) 2 else 4;
        var stack: std.ArrayList(struct { node: u32, close: []const u8 }) = .empty;
        var lists: u32 = lists_;
        const first: u32 = if (within == none) 0 else within + 1;
        for (first..nodes.len) |i_| {
            const i: u32 = @intCast(i_);
            const parent = nodes.items(.parent)[i];
            if (within != none) {
                var k = parent;
                while (k != none and k != within) k = nodes.items(.parent)[k];
                if (k == none) break;
            }
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].node != parent) {
                const top = stack.pop().?;
                if (nodes.items(.kind)[top.node] == .list) lists -= 1;
                e.indent(stack.items.len + base);
                e.print("{s}\n", .{top.close});
            }
            // An alternative of a choice is one prong of its switch.
            const in_choice = parent != none and nodes.items(.kind)[parent] == .choice;
            e.indent(stack.items.len + base);
            if (in_choice) {
                var k: usize = 0;
                for (nodes.items(.parent)[0..i]) |p| k += @intFromBool(p == parent);
                const field = for (e.page.fields.items) |fd| {
                    if (std.mem.eql(u8, fd.name, nodes.items(.bind)[parent])) break fd;
                } else unreachable;
                e.print(".{f} => {{ ", .{std.zig.fmtId(field.cases[k])});
            }
            var close = e.rtOpenFlex(i, lists);
            if (in_choice) close = std.fmt.allocPrint(e.arena, "{s}{s}}},", .{ close, if (close.len > 0) " " else "" }) catch unreachable;
            if (nodes.items(.kind)[i] == .list) lists += 1;
            e.print(" // {s}\n", .{e.where(nodes.items(.loc)[i])});
            // A leaf inside a choice closes its prong at once.
            const leaf = switch (nodes.items(.kind)[i]) {
                .container, .landmark, .when, .list, .choice => false,
                else => true,
            };
            if (leaf and in_choice) {
                e.indent(stack.items.len + base);
                e.write("},\n");
            } else if (!leaf) stack.append(e.arena, .{ .node = i, .close = close }) catch unreachable;
        }
        while (stack.pop()) |top| {
            e.indent(stack.items.len + base);
            e.print("{s}\n", .{top.close});
        }
    }

    fn rtDispatch(e: *Emit) void {
        // Dispatch: clicks, then value changes, in tree order.
        e.write("    /// Calls the handlers of the frame `build` made.\n    pub fn dispatch(ui: *Ui, h: anytype) void {\n");
        if (e.page.handlers.items.len == 0) e.write("        _ = ui;\n        _ = h;\n");
        for (e.page.handlers.items) |h| switch (h.event) {
            .click => e.print("        if (ui.events.{f}) h.{f}(ui); // {s}\n", .{ std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) }),
            .change => e.print("        if ({s} != ui.before.{f}) h.{f}(ui, {s}); // {s}\n", .{ e.stateRef(h.field), std.zig.fmtId(h.field), std.zig.fmtId(h.name), e.stateRef(h.field), e.where(h.loc) }),
        };
        e.write("    }\n};\n\n");
    }

    /// Whether a node has flex rules (CSS margins, engine spec F2).
    fn hasFlex(e: *Emit) bool {
        for (e.page.nodes.items(.margin)) |m| if (m != null) return true;
        return false;
    }

    /// `rtOpen`, with the node's flex rules written for the node its statement makes.
    fn rtOpenFlex(e: *Emit, i: u32, list_depth: u32) []const u8 {
        const m = e.page.nodes.items(.margin)[i] orelse return e.rtOpen(i, list_depth);
        var statement: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &statement, &e.out);
        const close = e.rtOpen(i, list_depth);
        std.mem.swap(std.ArrayList(u8), &statement, &e.out);
        // lower.checkRuntime admits margins only on nodes whose statement is `_ = call;`.
        const call = statement.items[4 .. statement.items.len - 1];
        e.print("fx.set(@backingInt({s}), &.{{ .margin = ", .{call});
        e.value(m);
        e.write(" });");
        return close;
    }

    fn runtimePage(e: *Emit) void {
        const n: u32 = @intCast(e.page.nodes.len);
        // Rows: widgets push up to a few rows each; texts and bytes as the literals need.
        e.print(
            \\/// A runtime `Context` large enough for this page.
            \\pub const limits: lcgf.context.Limits = .{{ .nodes = {d}, .texts = {d}, .customs = 4, .strings = 8192, .depth = 64 }};
            \\
            \\/// The page driven by the app's handler type `H`, in a caller's runtime `Context`:
            \\/// `frame` builds and draws, then calls the handlers after the draw list is final.
            \\pub fn Page(comptime H: type) type {{
            \\    comptime check(H);
            \\    return struct {{
            \\        ui: Ui = .{{}},
            \\
            \\        pub fn frame(p: *@This(), ctx: *lcgf.context.Context, h: *H, in: *const lcgf.input.Input) lcgf.context.Output {{
            \\            var f = ctx.begin(in);
            \\            p.ui.build(&f);
            \\            const out = {s};
            \\            p.ui.dispatch(h);
            \\            return out;
            \\        }}
            \\    }};
            \\}}
            \\
            \\
        , .{ 8 * n + 16, 2 * n + 8, if (e.hasFlex()) "p.ui.end(&f, .{})" else "f.end(.{})" });
        if (e.hasFlex()) e.write(
            \\/// The bytes of the runtime page's flex columns.
            \\const flex_bytes = blk: {
            \\    var carver: lcgf.mem.Carver = .{ .buf = null };
            \\    _ = carver.columns(lcgf.flex.Flex.Columns, lcgf.simd.rows(limits.nodes));
            \\    break :blk carver.off;
            \\};
            \\
            \\
        );
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
        );
        const each = for (e.page.nodes.items(.kind), 0..) |k, i| {
            if (k == .each) break @as(u32, @intCast(i));
        } else none;
        if (each != none) e.eachFields(each);
        e.write(if (each != none) "        pub fn frame(p: *@This(), h: *H, in: *const lcgf.input.Input, data: anytype) Ui.Output {\n" else "        pub fn frame(p: *@This(), h: *H, in: *const lcgf.input.Input) Ui.Output {\n");
        var changes = false;
        var clicks: u32 = 0;
        for (hs) |h| {
            changes = changes or h.event == .change;
            clicks += @intFromBool(h.event == .click);
        }
        var item_clicks: u32 = 0;
        for (hs) |h| item_clicks += @intFromBool(h.each.len > 0);
        clicks -= item_clicks;
        if (hs.len == 0) e.write("            _ = h;\n");
        if (changes) e.write("            const before = p.ui.signals.state;\n");
        e.write(if (each != none) "            var out = p.ui.frame(in);\n" else "            const out = p.ui.frame(in);\n");
        if (each != none) e.eachFrame(each);
        // Clicks: one prong per widget with a click handler.
        if (clicks > 0) {
            e.write("            if (out.event) |event| switch (event) {\n");
            for (hs) |h| if (h.event == .click and h.each.len == 0) e.print("                .{f} => h.{f}(&p.ui), // {s}\n", .{ std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
            var widgets: u32 = 0;
            for (e.page.nodes.items(.id), 0..) |id, k| widgets += @intFromBool(id.len > 0 and (e.eachOf(@intCast(k)) == none or e.page.nodes.items(.kind)[k] == .each));
            if (widgets > clicks) e.write("                else => {},\n");
            e.write("            };\n");
        }
        for (hs) |h| if (h.event == .click and h.each.len > 0)
            e.print("            if (events.{f}) |index| h.{f}(&p.ui, index); // {s}\n", .{ std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
        for (hs) |h| if (h.event == .change)
            e.print("            if (p.ui.signals.state.{f} != before.{f}) h.{f}(&p.ui, p.ui.signals.state.{f}); // {s}\n", .{ std.zig.fmtId(h.field), std.zig.fmtId(h.field), std.zig.fmtId(h.name), std.zig.fmtId(h.field), e.where(h.loc) });
        e.write("            return out;\n        }\n    };\n}\n\n");
    }

    /// The Page fields of its run-time region: the region's runtime Context, and the draw list
    /// the page's and the region's draw lists are composed into.
    fn eachFields(e: *Emit, each: u32) void {
        const n = e.page.nodes.get(each);
        e.print(
            \\        /// The run-time region `{s}` (lcgf-each="{s} in {s}"): its own runtime Context, and the
            \\        /// draw list the page and the region are composed into. A Page does not move once used.
            \\        region_buf: [lcgf.context.Context.requiredBytes(region_limits)]u8 align(lcgf.mem.column_align) = undefined,
            \\        region: ?lcgf.context.Context = null,
            \\        draw_buf: [draw_bytes]u8 align(lcgf.mem.column_align) = undefined,
            \\        draw: lcgf.draw_list.DrawList = undefined,
            \\        draw_carved: bool = false,
            \\        strings: [region_limits.strings + 8192]u8 = undefined,
            \\
            \\        const region_limits: lcgf.context.Limits = .{{ .nodes = {d}, .texts = {d}, .customs = 4, .strings = 16384, .depth = 64 }};
            \\        const draw_rows = {d} + region_limits.nodes;
            \\        const draw_bytes = blk: {{
            \\            var carver: lcgf.mem.Carver = .{{ .buf = null }};
            \\            _ = lcgf.draw_list.DrawList.init(&carver, draw_rows, draw_rows, 8);
            \\            break :blk carver.off;
            \\        }};
            \\
            \\
        , .{ n.id, n.text, n.bind, n.max, @as(u32, @intFromFloat(n.range[0])), 8 * e.page.nodes.len + 16 });
    }

    /// `Page.frame`'s run-time region: built after the page, in the region's rect, from the app's
    /// `data.<list>`, and composed into the page's draw list.
    fn eachFrame(e: *Emit, each: u32) void {
        const n = e.page.nodes.get(each);
        // The item fields the page reads, checked with the HTML location.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        e.print("            comptime {{\n                const Item = @import(\"std\").meta.Elem(@TypeOf(data.{f}));\n", .{std.zig.fmtId(n.bind)});
        for (e.page.item_fields.items) |f| {
            if (seen.contains(f.field)) continue;
            seen.put(e.arena, f.field, {}) catch unreachable;
            e.print("                if (!@hasField(Item, \"{s}\")) @compileError(\"{s}: the items of '{s}' have no field '{s}'\");\n", .{ f.field, e.whereFull(f.loc), n.bind, f.field });
        }
        e.write("            }\n");
        var events: std.ArrayList(u8) = .empty;
        for (e.page.handlers.items) |h| if (h.each.len > 0) events.print(e.arena, " {f}: ?u32 = null,", .{std.zig.fmtId(h.widget)}) catch unreachable;
        e.print("            var events: struct {{{s} }} = .{{}};\n", .{events.items});
        // The copies' statements first: they name `ui` only when they read the view state.
        var body: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        e.rtWalk(each, 1);
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        if (std.mem.indexOf(u8, body.items, "ui.") != null) e.write("            const ui = &p.ui;\n");
        e.print(
            \\            if (p.region == null) p.region = lcgf.context.Context.init(&p.region_buf, region_limits) catch unreachable;
            \\            if (!p.draw_carved) {{
            \\                var carver: lcgf.mem.Carver = .{{ .buf = &p.draw_buf }};
            \\                p.draw = lcgf.draw_list.DrawList.init(&carver, draw_rows, draw_rows, 8);
            \\                p.draw_carved = true;
            \\            }}
            \\            const rect = out.tree.rect(out.tree.find(.from("{s}")));
            \\            const region_in = lcgf.ct_interop.regionInput(in, .{{ rect.x0, rect.y0, rect.x1, rect.y1 }});
            \\            var region_frame = p.region.?.begin(&region_in);
            \\            const f = &region_frame;
            \\            // The copies are laid out in the region as its CSS says.
            \\            _ = f.open(.none, {s});
            \\            for (data.{f}, 0..) |{f}, copy0| {{ // {s}
            \\
        , .{ n.id, e.styleText(.{ .size = .{ .fill, .fill }, .dir = n.style.dir, .gap = n.style.gap, .pad = n.style.pad, .main = n.style.main, .cross = n.style.cross }, ""), std.zig.fmtId(n.bind), std.zig.fmtId(n.text), e.where(n.loc) });
        e.write(body.items);
        e.print(
            \\            }}
            \\            f.close();
            \\            const region_out = f.end(.{{}});
            \\            if (lcgf.ct_interop.compose(&p.draw, out.draw, region_out.draw, @backingInt(lcgf.types.Id.from("{s}")), &p.strings)) out.draw = &p.draw else |_| {{}}
            \\
        , .{n.id});
    }

    /// The check block: each handler the markup names, with the signature it must have.
    fn checkBlock(e: *Emit) void {
        const hs = e.page.handlers.items;
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
