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
const FlexStyle = lcgf.flex.Flex.Style;

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
    /// The events of the run-time region being written (`events_<id>`).
    events_var: []const u8 = "events",
    /// What owns a region's text editors (`edit_<id>`): the comptime `Page` (`p`) or the
    /// runtime `Ui` (`ui`).
    owner: []const u8 = "p",
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
        if (T == types.Font) return if (v == .default) e.write(".default") else e.print("@fromBackingInt({d})", .{@backingInt(v)});
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
            // A texture or material handle past the named ones (`@fromBackingInt`).
            .@"enum" => if (std.enums.tagName(T, v)) |name| e.print(".{f}", .{std.zig.fmtId(name)}) else e.print("@fromBackingInt({d})", .{@backingInt(v)}),
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

    /// The index of the token whose `Tokens` field is `field`.
    fn tokenIndex(e: *Emit, field: []const u8) u32 {
        for (e.page.tokens.items, 0..) |t, k| if (std.mem.eql(u8, t.field, field)) return @intCast(k);
        unreachable;
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
        // Flex rules (margins, align-self, wrap, …): engine spec F2, `spec.flexed(s, Flex.Style)`.
        var margin_close: []const u8 = "";
        if (flexOf(n)) |fs| {
            e.write("s.flexed(");
            var buf: std.ArrayList(u8) = .empty;
            std.mem.swap(std.ArrayList(u8), &buf, &e.out);
            e.write(", ");
            e.structure(fs, FlexStyle{});
            e.write(")");
            std.mem.swap(std.ArrayList(u8), &buf, &e.out);
            margin_close = buf.items;
        }
        const restyle = !std.meta.eql(n.style, n.base_style) or n.params_expr.len > 0;
        const has_children = switch (n.kind) {
            .container, .landmark, .when, .choice, .list, .dialog, .section => true,
            .component => e.hasChild(i),
            else => false,
        };
        var inner_close: std.ArrayList(u8) = .empty;
        const text_styled = switch (n.kind) {
            .label, .text, .heading => !std.meta.eql(n.text_style, n.base_text),
            else => false,
        };
        if (n.decoration != null) e.write("s.decorated(");
        if (n.paragraph != null) e.write("s.paragraph(");
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
            .button, .link => {
                e.print("{s}.ct.{s}(theme, .{f}, ", .{ e.use(@tagName(n.kind)), @tagName(n.kind), std.zig.fmtId(n.id) });
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
            .section => {
                e.print("{s}.ct.section(theme, .{f}, .{f}, ", .{ e.use("accordion"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(n.text_kind, n.text);
                e.write(", .{");
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
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
                e.print("{s}.ct.{s}(theme, .{f}, .{f}, ", .{ e.use(m), if (n.secure) "password" else m, std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(")");
            },
            .textarea => {
                e.print("{s}.ct.textarea(theme, .{f}, .{f}, {d}, ", .{ e.use("textarea"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind), n.level });
                e.caption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(")");
            },
            .each => e.print("lcgf.ct_interop.{s}(.{f}, {s})", .{ if (n.level == 1) "fitRegion" else "region", std.zig.fmtId(n.id), e.styleText(n.style, n.params_expr) }),
            .component => if (e.runtime) {
                // The runtime page builds the component in `Ui.build`. Its spec, which only
                // the state store reads, keeps the content's nodes.
                e.write(if (has_children) "s.col(.{}, .{" else "s.col(.{}, .{})");
                if (has_children) inner_close.appendSlice(e.arena, "})") catch unreachable;
            } else {
                // The content is the `children` prop, a tuple of Specs.
                e.componentCall(n, false, 0, has_children);
                if (has_children) inner_close.appendSlice(e.arena, "} })") catch unreachable;
            },
            .select, .select_list => {
                e.print("{s}.ct.{s}(theme, .{f}, .{f}, ", .{ e.use("select"), if (n.kind == .select) "select" else "list", std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.selectOptions(n);
                e.write(")");
            },
            .image => {
                e.print("{s}.ct.image(theme, assets[{d}].picture(), ", .{ e.use("image"), n.asset });
                e.structure(n.image, lcgf.widgets_image.Options{});
                e.write(")");
            },
            .dialog => {
                e.print("{s}.ct.dialog(theme, .{f}, .{f}, .{{", .{ e.use("dialog"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
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
        if (n.paragraph) |pa| {
            e.write(", ");
            e.paragraph(pa);
            e.write(")");
        }
        if (n.decoration) |d| {
            e.write(", ");
            e.decoration(d);
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

    /// The asset table: each image the page draws, decoded at build time, asset k as texture
    /// k + 1.
    fn assetsDecl(e: *Emit) void {
        const assets = e.page.assets.items;
        if (assets.len == 0) return;
        e.write("/// The page's images, decoded by lcgf-gen, and its gradients' ramp rows. Before the first\n/// frame, upload each `assets[k].image.pixels` (RGBA8 rows, `w` by `h`) as texture `assets[k].texture`.\npub const assets = [_]lcgf.widgets_image.Asset{\n");
        for (assets, 1..) |a, k| {
            e.print("    .{{ .texture = @fromBackingInt({d}), .image = .{{ .w = {d}, .h = {d}, .pixels = \"", .{ k, a.w, a.h });
            for (a.pixels) |b| e.print("\\x{x:0>2}", .{b});
            e.print("\" }} }}, // {s}\n", .{a.src});
        }
        e.write("};\n\n");
    }

    /// A select's `widgets_select.Options`: its captions and group headers.
    fn selectOptions(e: *Emit, n: ir.Node) void {
        e.write(".{ .texts = &.{");
        for (n.captions, 0..) |c, k| {
            e.write(if (k == 0) " " else ", ");
            e.string(c);
        }
        e.write(" }");
        if (n.groups.len > 0) {
            e.write(", .groups = &.{");
            for (n.groups, 0..) |g, k| {
                e.print("{s}.{{ .at = {d}, .label = ", .{ if (k == 0) " " else ", ", g.at });
                e.string(g.label);
                e.write(" }");
            }
            e.write(" }");
        }
        e.write(" }");
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
        // App components are checked first, so a wrong one fails at the HTML.
        const checked = !e.runtime and e.specComponents();
        e.write(if (checked) "pub const spec = blk: {\n    checkComponents();\n    break :blk " else "pub const spec = ");
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
        e.write(if (checked) ";\n};\n" else ";\n");
        if (!checked) return;
        e.write("\n/// Checks the app's components against the markup; every message starts at the HTML.\nfn checkComponents() void {\n    comptime {\n");
        for (nodes.items(.kind), 0..) |k, i| if (k == .component and e.eachOf(@intCast(i)) == none) e.componentChecks(@intCast(i), false, "        ");
        e.write("    }\n}\n");
    }

    fn fieldType(t: ir.FieldType) []const u8 {
        return switch (t) {
            .str => "[]const u8",
            .bool => "bool",
            .f32 => "f32",
            .u32 => "u32",
            .text => "lcgf.widgets_textfield.Text(256)",
            .number => "lcgf.widgets_number.Number",
            .select => "lcgf.widgets_select.SelectState",
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
            .text, .number, .pair, .@"enum", .select => ".{}",
        };
    }

    /// The handler's function type, as the app writes it.
    fn signature(e: *Emit, h: ir.Handler, comptime H: []const u8) []const u8 {
        const value_param = if (h.payload) |p| std.fmt.allocPrint(e.arena, ", value: {s}", .{fieldType(p)}) catch unreachable else "";
        const extra = if (h.each.len > 0) std.fmt.allocPrint(e.arena, ", index: u32{s}", .{value_param}) catch unreachable else value_param;
        return std.fmt.allocPrint(e.arena, "pub fn {s}(h: *{s}, ui: *Ui{s}) void", .{ h.name, H, extra }) catch unreachable;
    }

    fn fnType(e: *Emit, h: ir.Handler) []const u8 {
        if (h.each.len > 0) return if (h.payload) |p| std.fmt.allocPrint(e.arena, "fn (*H, *Ui, u32, {s}) void", .{fieldType(p)}) catch unreachable else "fn (*H, *Ui, u32) void";
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
        if (std.mem.indexOfScalar(ir.Kind, page.nodes.items(.kind), .component) != null) e.write("const app = @import(\"app\");\n");
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
        if (page.fonts.items.len > 0) {
            e.write("/// The font table from @font-face: the host loads row k's file as font `entry.font`.\n");
            e.write("pub const fonts = [_]lcgf.font_match.Face{\n");
            for (page.fonts.items) |f| {
                e.write("    .{ .entry = .{ .family = ");
                e.string(f.entry.family);
                e.print(", .font = {d}, .weight = {d}, .style = .{s} }}, .path = ", .{ f.entry.font, f.entry.weight, @tagName(f.entry.style) });
                e.string(f.path);
                e.write(" },\n");
            }
            e.write("};\n\n");
        }
        e.assetsDecl();
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
            .section => {
                e.print("_ = {s}.open(f, &theme, {s}, {s}, ", .{ e.use("accordion"), e.rtId(n.id, list_depth), e.ref(n.bind) });
                e.rtCaption(n.text_kind, n.text);
                e.write(");");
                return "accordion.close(f);";
            },
            .label, .heading, .text => {
                const plain = n.kind == .label and n.paragraph == null and n.decoration == null and std.meta.eql(n.style, n.base_style) and std.meta.eql(n.text_style, n.base_text) and n.params_expr.len == 0 and n.uses.len == 0 and n.text_uses.color == none and n.text_uses.px == none;
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
                if (n.paragraph != null or n.decoration != null) e.print(" ui.paragraphs.rows[ui.paragraphs.len] = f.texts().len - 1; ui.paragraphs.styles[ui.paragraphs.len] = {d}; ui.paragraphs.len += 1;", .{e.paragraphIndex(n)});
                return "";
            },
            .button, .link => {
                const h = e.clickHandler(n.id);
                const face = e.rtFace(n);
                e.print("{s}{s}.{s}(f, &theme, {s}, ", .{ if (h != null) "if (" else "_ = ", e.use(@tagName(n.kind)), e.faced(@tagName(n.kind), face), e.rtId(n.id, list_depth) });
                e.rtCaption(n.text_kind, n.text);
                // A button's Face takes its caption's text style first.
                if (face.len > 0 and n.kind == .button) e.print(", {s}.labelText(&theme)", .{e.use("label")});
                e.write(face);
                if (h == null) e.write(");") else if (e.eachOf(i) != none)
                    e.print(").clicked) {s}.{f} = @intCast(copy0);", .{ e.events_var, std.zig.fmtId(n.id) })
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
                const face = e.rtFace(n);
                const fn_name = if (face.len > 0) switch (n.kind) {
                    .checkbox => "checkboxFace",
                    .@"switch" => "switchFace",
                    else => "toggleFace",
                } else if (n.kind == .@"switch") "@\"switch\"" else m;
                const item = e.eachOf(i) != none;
                if (item) e.print("{{ var value = {s}; ", .{e.stateRef(n.bind)});
                e.print("_ = {s}.{s}(f, &theme, {s}, {s}, ", .{ e.use(m), fn_name, e.rtId(n.id, list_depth), if (item) "&value" else e.ref(n.bind) });
                e.rtCaption(n.text_kind, n.text);
                e.write(face);
                e.write(");");
                if (item) e.itemChange(n);
                return "";
            },
            .slider => {
                const item = e.eachOf(i) != none;
                if (item) e.print("{{ var value = {s}; ", .{e.stateRef(n.bind)});
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, {s}, {s}, {d}, {d}{s});", .{ e.use("slider"), if (face.len > 0) "sliderFace" else "slider", e.rtId(n.id, list_depth), if (item) "&value" else e.ref(n.bind), n.range[0], n.range[1], face });
                if (item) e.itemChange(n);
                return "";
            },
            .progress => {
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, {s}{s});", .{ e.use("progress"), e.faced("progress", face), e.stateRef(n.bind), face });
                return "";
            },
            .separator => {
                const face = e.rtFace(n);
                if (face.len > 0)
                    e.print("_ = {s}.separatorFace(f{s});", .{ e.use("separator"), face })
                else
                    e.print("_ = {s}.separator(f, &theme, .{s});", .{ e.use("separator"), if (n.level == 1) "vertical" else "horizontal" });
                return "";
            },
            .number => {
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, {s}, &{s}, ", .{ e.use("number"), e.faced("number", face), e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                e.structure(lcgf.widgets_number.Range{ .lo = n.range[0], .hi = n.range[1], .step = n.range[2] }, .{});
                e.write(face);
                e.write(");");
                return "";
            },
            .radio => {
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, {s}, &{s}, &.{{", .{ e.use("radio"), e.faced("radio", face), e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                for (n.captions, 0..) |c, k| {
                    e.write(if (k == 0) " " else ", ");
                    e.string(c);
                }
                e.write(" }");
                e.write(face);
                e.write(");");
                return "";
            },
            .textfield, .search, .textarea => if (e.eachOf(i) != none) {
                e.itemText(n, list_depth);
                return "";
            } else if (n.kind == .textarea) {
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, {s}, &{s}, {d}, ", .{ e.use("textarea"), e.faced("textarea", face), e.rtId(n.id, list_depth), e.stateRef(n.bind), n.level });
                e.rtCaption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(face);
                e.write(");");
                e.submitFlag(n);
                return "";
            } else {
                const m = if (n.kind == .search) "search" else "textfield";
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, {s}, &{s}, ", .{ e.use(m), e.faced(if (n.secure) "password" else m, face), e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                e.rtCaption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.write(face);
                e.write(");");
                e.submitFlag(n);
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
            .component => {
                // With content, the namespace's `open` builds what goes before it and `close`
                // what goes after.
                const content = e.hasChild(i);
                if (e.clickHandler(n.id) != null) {
                    e.write("if (");
                    e.componentCall(n, true, list_depth, content);
                    if (e.eachOf(i) != none)
                        e.print(".clicked) {s}.{f} = @intCast(copy0);", .{ e.events_var, std.zig.fmtId(n.id) })
                    else
                        e.print(".clicked) ui.events.{f} = true;", .{std.zig.fmtId(n.id)});
                } else {
                    e.write("_ = ");
                    e.componentCall(n, true, list_depth, content);
                    e.write(";");
                }
                if (!content) return "";
                return std.fmt.allocPrint(e.arena, "app.components.{f}.close(f, &theme);", .{std.zig.fmtId(n.text)}) catch unreachable;
            },
            .image => {
                e.print("_ = {s}.image(f, &theme, assets[{d}].picture(), ", .{ e.use("image"), n.asset });
                e.structure(n.image, lcgf.widgets_image.Options{});
                e.write(");");
                return "";
            },
            .select => {
                e.print("_ = {s}.button(f, &theme, \"{s}\", comptime {s}.positional({d}), &{s}, &.{{", .{ e.use("select"), n.id, e.use("select"), n.captions.len, e.stateRef(n.bind) });
                e.rtTexts(n.captions);
                e.write(" });");
                return "";
            },
            .select_list => {
                e.print("{s}.listGrouped(f, &theme, \"{s}\", comptime {s}.positional({d}), &{s}, &.{{", .{ e.use("select"), n.id, e.use("select"), n.captions.len, e.stateRef(n.bind) });
                e.rtTexts(n.captions);
                e.write(" }, &.{");
                for (n.groups, 0..) |g, k| {
                    e.print("{s}.{{ .at = {d}, .label = ", .{ if (k == 0) " " else ", ", g.at });
                    e.string(g.label);
                    e.write(" }");
                }
                e.write(if (n.groups.len > 0) " });" else "});");
                return "";
            },
            .dialog => {
                e.print("if ({s}.begin(f, &theme, \"{s}\", &{s})) {{", .{ e.use("dialog"), n.id, e.stateRef(n.bind) });
                return e.arena.dupe(u8, "dialog.end(f); }") catch unreachable;
            },
            .spacer, .spinner, .each => unreachable,
        }
    }

    fn rtTexts(e: *Emit, texts: []const []const u8) void {
        for (texts, 0..) |c, k| {
            e.write(if (k == 0) " " else ", ");
            e.string(c);
        }
    }

    /// `, style` for a widget whose CSS restyles its root (`<widget>Face`, as `spec.styled`
    /// restyles the comptime one; engine spec R1), or "" for the widget's own look.
    fn rtFace(e: *Emit, n: ir.Node) []const u8 {
        if (std.meta.eql(n.style, n.base_style) and n.params_expr.len == 0) return "";
        return std.fmt.allocPrint(e.arena, ", {s}", .{e.styleText(n.style, n.params_expr)}) catch unreachable;
    }

    /// The runtime function `name`, or `<name>Face` when the widget is restyled (`face`).
    fn faced(e: *Emit, name: []const u8, face: []const u8) []const u8 {
        if (face.len == 0) return name;
        return std.fmt.allocPrint(e.arena, "{s}Face", .{name}) catch unreachable;
    }

    /// `app.components.@"tag"(.{ .prop = value, … })`, or in a run-time region the runtime
    /// form `(f, .{ … })`: literals as strings, `{f}` as `.f` (the spec) or its value, `{x.f}`
    /// as the item's field; `id` names the widget its on:click is on. With `children`, the
    /// spec form's `children` prop opens, and the runtime form is the namespace's `open`.
    fn componentCall(e: *Emit, n: ir.Node, region: bool, list_depth: u32, children: bool) void {
        e.print("{s}({s}.{{", .{ e.componentForm(n.text, if (!region) "spec" else if (children) "open" else "frame"), if (region) "f, &theme, " else "theme, " });
        var k: usize = 0;
        if (n.id.len > 0) {
            if (region) e.print(" .id = {s}", .{e.rtId(n.id, list_depth)}) else e.print(" .id = .{f}", .{std.zig.fmtId(n.id)});
            k += 1;
        }
        for (n.props) |p| {
            e.print("{s} .{f} = ", .{ if (k > 0) "," else "", std.zig.fmtId(p.name) });
            switch (p.kind) {
                // A token is its `Tokens` field's name for `spec.tokened`, or its value.
                .literal => if (p.token and region) e.write(e.tokenExpr(e.tokenIndex(p.value))) else e.string(p.value),
                .field => if (region) e.write(e.stateRef(p.value)) else e.print(".{f}", .{std.zig.fmtId(p.value)}),
                .item => e.write(p.value),
            }
            k += 1;
        }
        if (children and !region) e.write(if (k > 0) ", .children = &.{" else " .children = &.{") else e.write(if (k > 0) " })" else "})");
    }

    /// The form of component `tag` a context calls: the function itself, or, when the app
    /// declares both forms under one name, its namespace's `spec` (page) or `frame` (region);
    /// `open` is always the namespace's.
    fn componentForm(e: *Emit, tag: []const u8, form: []const u8) []const u8 {
        const c = std.fmt.allocPrint(e.arena, "app.components.{f}", .{std.zig.fmtId(tag)}) catch unreachable;
        if (std.mem.eql(u8, form, "open")) return std.fmt.allocPrint(e.arena, "{s}.open", .{c}) catch unreachable;
        return std.fmt.allocPrint(e.arena, "(if (@TypeOf({s}) == type) {s}.{s} else {s})", .{ c, c, form, c }) catch unreachable;
    }

    fn hasChild(e: *Emit, i: u32) bool {
        return std.mem.indexOfScalar(u32, e.page.nodes.items(.parent), i) != null;
    }

    /// Whether the page has an app component outside its run-time regions (in the spec).
    fn specComponents(e: *Emit) bool {
        for (e.page.nodes.items(.kind), 0..) |k, i| if (k == .component and e.eachOf(@intCast(i)) == none) return true;
        return false;
    }

    /// The checks of component node `i` against the app's declaration, each message at the
    /// HTML; `region` for the runtime form inside an lcgf-each, whose block has `Item`.
    fn componentChecks(e: *Emit, i: u32, region: bool, pad: []const u8) void {
        const n = e.page.nodes.get(i);
        const at = e.whereFull(n.loc);
        const tag = n.text;
        const content = e.hasChild(i);
        const c = std.fmt.allocPrint(e.arena, "app.components.{f}", .{std.zig.fmtId(tag)}) catch unreachable;
        // Where the use is, for the messages: a runtime page builds every component at run time.
        const place = if (!region) "on the page" else if (e.eachOf(i) != none) "inside lcgf-each" else "on a runtime page";
        const rt_sig = "f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme, props: anytype) …";
        const spec_sig = "comptime th: lcgf.widgets_base.Theme, comptime props: anytype) lcgf.spec.Spec";
        const close_sig = "pub fn close(f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme) void";
        // Escaped for the generated string literal.
        const want = if (region and content)
            std.fmt.allocPrint(e.arena, "pub const @\\\"{s}\\\" = struct {{ pub fn open({s}; {s} }}", .{ tag, rt_sig, close_sig }) catch unreachable
        else
            std.fmt.allocPrint(e.arena, "pub fn @\\\"{s}\\\"({s}", .{ tag, if (region) rt_sig else spec_sig }) catch unreachable;
        e.print("{s}if (!@hasDecl(app, \"components\")) @compileError(\"{s}: <{s}> is an app component: give addMarkup an .app module with `pub const components`\")\n", .{ pad, at, tag });
        e.print("{s}else if (!@hasDecl(app.components, \"{s}\")) @compileError(\"{s}: component <{s}> is missing from app.components: add `{s}`\")\n", .{ pad, tag, at, tag, want });
        const form_name = if (!region) "spec" else if (content) "open" else "frame";
        const form = e.componentForm(tag, form_name);
        if (region and content) {
            // Content goes between the two calls of a namespace.
            e.print("{s}else if (@TypeOf({s}) != type or !@hasDecl({s}, \"open\") or !@hasDecl({s}, \"close\")) @compileError(\"{s}: <{s}> has content {s}, so it is a namespace with `pub fn open({s}` and `{s}`, which build what goes before and after it\")\n", .{ pad, c, c, c, at, tag, place, rt_sig, close_sig });
            e.print("{s}else if (@typeInfo(@TypeOf({s}.close)) != .@\"fn\" or @typeInfo(@TypeOf({s}.close)).@\"fn\".param_types.len != 2) @compileError(\"{s}: <{s}> must have `{s}`\")\n", .{ pad, c, c, at, tag, close_sig });
        } else {
            // A namespace declares both forms under one name; this context needs one of them.
            const form_sig = if (region) rt_sig else spec_sig;
            e.print("{s}else if (@TypeOf({s}) == type and !@hasDecl({s}, \"{s}\")) @compileError(\"{s}: <{s}> is used {s}, so its namespace needs `pub fn {s}({s}`\")\n", .{ pad, c, c, form_name, at, tag, place, form_name, form_sig });
        }
        e.print("{s}else if (@typeInfo(@TypeOf({s})) != .@\"fn\" or @typeInfo(@TypeOf({s})).@\"fn\".param_types.len != {d}) @compileError(\"{s}: <{s}> must be `{s}`{s}{s}, or a namespace with `pub fn {s}`\")\n", .{ pad, form, form, @as(u8, if (region) 3 else 2), at, tag, want, if (region) " " else "", if (region) place else "", form_name });
        e.print("{s}else if (@typeInfo(@TypeOf({s})).@\"fn\".param_types[{d}]) |P| {{\n", .{ pad, form, @as(u8, if (region) 2 else 1) });
        // Every prop the markup passes, typed as it passes it.
        if (n.id.len > 0) e.print("{s}    if (!@hasField(P, \"id\")) @compileError(\"{s}: <{s}> has no prop 'id', so id= and on:click cannot name its widget\");\n", .{ pad, at, tag });
        const children = content and !region;
        if (children) e.print("{s}    if (!@hasField(P, \"children\")) @compileError(\"{s}: <{s}> takes no content: it has no prop 'children'\")\n{s}    else if (@FieldType(P, \"children\") != []const lcgf.spec.Spec) @compileError(\"{s}: the content of <{s}> is its prop 'children', which must be []const lcgf.spec.Spec\");\n", .{ pad, at, tag, pad, at, tag });
        for (n.props) |p| {
            const pat = e.whereFull(p.loc);
            e.print("{s}    if (!@hasField(P, \"{s}\")) @compileError(\"{s}: <{s}> has no prop '{s}'\")\n", .{ pad, p.name, pat, tag, p.name });
            const field = if (p.kind == .item) p.value[std.mem.indexOfScalar(u8, p.value, '.').? + 1 ..] else p.value;
            const want_ty, const why = switch (p.kind) {
                .literal => if (p.token and region) .{ std.fmt.allocPrint(e.arena, "@FieldType(Tokens, \"{s}\")", .{p.value}) catch unreachable, std.fmt.allocPrint(e.arena, "the token '{s}'", .{p.value}) catch unreachable } else .{ "[]const u8", "a literal" },
                .field => if (region) .{ std.fmt.allocPrint(e.arena, "@FieldType(State, \"{s}\")", .{field}) catch unreachable, std.fmt.allocPrint(e.arena, "the view state's '{s}'", .{field}) catch unreachable } else .{ "@EnumLiteral()", std.fmt.allocPrint(e.arena, "the name of the field '{s}'", .{field}) catch unreachable },
                .item => .{ std.fmt.allocPrint(e.arena, "@FieldType(Item, \"{s}\")", .{field}) catch unreachable, std.fmt.allocPrint(e.arena, "the item's '{s}'", .{field}) catch unreachable },
            };
            e.print("{s}    else if (@FieldType(P, \"{s}\") != {s}) @compileError(\"{s}: prop '{s}' of <{s}> is \" ++ @typeName(@FieldType(P, \"{s}\")) ++ \", but the markup passes {s}, \" ++ @typeName({s}));\n", .{ pad, p.name, want_ty, pat, p.name, tag, p.name, why, want_ty });
        }
        // And every prop without a default is passed.
        e.print("{s}    if (@typeInfo(P) == .@\"struct\") for (@typeInfo(P).@\"struct\".field_names, @typeInfo(P).@\"struct\".field_attrs) |name, attrs| {{\n", .{pad});
        e.print("{s}        const given = for ([_][]const u8{{", .{pad});
        var k: usize = 0;
        if (n.id.len > 0) {
            e.write(" \"id\"");
            k += 1;
        }
        if (children) {
            e.print("{s} \"children\"", .{if (k > 0) "," else ""});
            k += 1;
        }
        for (n.props) |p| {
            e.print("{s} \"{s}\"", .{ if (k > 0) "," else "", p.name });
            k += 1;
        }
        e.print(" }}) |x| {{\n{s}            if (@import(\"std\").mem.eql(u8, x, name)) break true;\n{s}        }} else false;\n", .{ pad, pad });
        e.print("{s}        if (attrs.default_value_ptr == null and !given) @compileError(\"{s}: <{s}> needs the prop '\" ++ name ++ \"'\");\n{s}    }};\n{s}}}\n", .{ pad, at, tag, pad, pad });
    }

    /// A text control inside an lcgf-each: the region keeps one editor (`edit_<id>`), for the
    /// row being edited; every other row shows its item's text through a copy made this frame.
    /// Focus on another row moves the editor there, seeded from its item. Changes and submits
    /// go to on:change (index, text) and on:submit (index); the item is never written.
    fn itemText(e: *Emit, n: ir.Node, list_depth: u32) void {
        const m = switch (n.kind) {
            .search => "search",
            .textarea => "textarea",
            else => "textfield",
        };
        const id = n.id;
        const o = e.owner;
        e.print("{{ const editing = {s}.edit_{s}_row == @as(u32, @intCast(copy0)); var scratch: lcgf.widgets_textfield.Text(256) = .{{}}; if (!editing) scratch.set({s}); const st = if (editing) &{s}.edit_{s} else &scratch; ", .{ o, id, e.stateRef(n.bind), o, id });
        const face = e.rtFace(n);
        e.print("const r = {s}.{s}(f, &theme, {s}, st, ", .{ e.use(m), e.faced(if (n.secure) "password" else m, face), e.rtId(id, list_depth) });
        if (n.kind == .textarea) e.print("{d}, ", .{n.level});
        e.rtCaption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
        e.write(face);
        e.print("); if (r.focused and !editing) {{ {s}.edit_{s} = st.*; {s}.edit_{s}_row = @intCast(copy0); }} ", .{ o, id, o, id });
        e.print("if ({s}.edit_{s}_row == @as(u32, @intCast(copy0))) {{ ", .{ o, id });
        for (e.page.handlers.items) |h| if (std.mem.eql(u8, h.widget, id) and h.each.len > 0) switch (h.event) {
            .change => e.print("if (st.result.changed) {s}.{f} = .{{ @intCast(copy0), {s}.edit_{s}.text() }}; ", .{ e.events_var, std.zig.fmtId(id), o, id }),
            .submit => e.print("if (st.result.submitted) {s}.{s}_submit = @intCast(copy0); ", .{ e.events_var, id }),
            else => {},
        };
        e.write("} }");
    }

    /// `&field`: the address a runtime control writes through.
    fn ref(e: *Emit, name: []const u8) []const u8 {
        return std.fmt.allocPrint(e.arena, "&{s}", .{e.stateRef(name)}) catch unreachable;
    }

    /// After a per-item control's call over its copy `value`: a change is recorded for its
    /// on:change handler (index, value), and written to the item only when the control binds
    /// it two-way (`bind:`); a one-way control (`checked="{row.done}"`) leaves the item as it is.
    fn itemChange(e: *Emit, n: ir.Node) void {
        const h = for (e.page.handlers.items) |h| {
            if (h.event == .change and std.mem.eql(u8, h.widget, n.id) and h.each.len > 0) break h;
        } else null;
        e.print(" if (value != {s}) {{", .{e.stateRef(n.bind)});
        if (h) |hh| e.print(" {s}.{f} = .{{ @intCast(copy0), value }};", .{ e.events_var, std.zig.fmtId(hh.widget) });
        if (!n.one_way) e.print(" {s} = value;", .{e.stateRef(n.bind)});
        if (h == null and n.one_way) e.write(" _ = &value;");
        e.write(" } }");
    }

    /// After a text control's call: its submit (`result.submitted`) recorded for dispatch.
    fn submitFlag(e: *Emit, n: ir.Node) void {
        for (e.page.handlers.items) |h| if (std.mem.eql(u8, h.widget, n.id)) {
            if (h.event == .submit) e.print(" if ({s}.result.submitted) ui.events.{f} = true;", .{ e.stateRef(n.bind), std.zig.fmtId(n.id) });
            if (textChange(h)) e.print(" if ({s}.result.changed) ui.events.{s}_change = true;", .{ e.stateRef(n.bind), n.id });
        };
    }

    /// Whether a list's template holds a widget, whose id needs the copy index, or a named node.
    fn usesCopy(e: *Emit, list: u32) bool {
        const parents = e.page.nodes.items(.parent);
        // A named node's slot reads every enclosing copy index.
        for (e.page.nodes.items(.id), e.page.nodes.items(.name), 0..) |id, name, k| if (id.len > 0 or name.len > 0) {
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
        if (e.paragraphTable().len > 0) {
            e.write("\n/// The page's paragraph styles, indexed by `Ui.paragraphs.styles`.\nconst paragraph_table = [_]lcgf.text_stack.Paragraph{");
            for (e.paragraphTable()) |pa| {
                e.write(" ");
                e.paragraph(pa.paragraph orelse .{});
                e.write(",");
            }
            e.write(" };\n");
        }
        if (e.anyDecoration()) {
            e.write("/// Their decorations, row for row.\nconst decoration_table = [_]lcgf.text_decorations.Style{");
            for (e.paragraphTable()) |pa| {
                e.write(" ");
                e.decoration(pa.decoration orelse .{});
                e.write(",");
            }
            e.write(" };\n");
        }
        e.owner = "ui";
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
        for (e.page.handlers.items) |h| if (h.each.len > 0) continue else if (h.event == .click or h.event == .submit) {
            e.print(" {f}: bool = false,", .{std.zig.fmtId(h.widget)});
            any = true;
        } else if (textChange(h)) {
            e.print(" {s}_change: bool = false,", .{h.widget});
            any = true;
        };
        e.write(if (any) " } = .{},\n" else "} = .{},\n");
        e.regionFields("    ");
        e.write(
            \\    /// The state as the frame began, for on:change.
            \\    before: State = .{},
            \\
        );
        const named = e.namedCount();
        if (named > 0) e.print(
            \\    /// Tree rows of the nodes with an accessible name, as this frame built them (none
            \\    /// for one it did not build).
            \\    named: [{d}]u32 = @splat(lcgf.types.none),
            \\
            \\    /// Names the nodes with an accessible name (`aria-label`, a `<label>`'s text) in `sem`
            \\    /// (`Semantics.label`), their bytes added to the frame's strings `str`. A host with
            \\    /// an accessibility bridge calls it after each built frame, before `a11y.names`.
            \\    pub fn semantics(ui: *const Ui, t: *const lcgf.tree.Tree, sem: *lcgf.a11y_tree.Semantics, str: *lcgf.strings.Strings) void {{
            \\        _ = t;
            \\        const names = [_][]const u8{{{s} }};
            \\        for (ui.named, names) |row, name| if (row != lcgf.types.none) {{
            \\            sem.c.label[row] = str.add(name);
            \\        }};
            \\    }}
            \\
            \\
        , .{ named, e.namedList() });
        const flex = e.hasFlex();
        const paragraphs = e.paragraphTable().len > 0;
        if (flex) e.write(
            \\    /// Flex rules (layout/flex.zig) of the nodes with margins, written while the page
            \\    /// builds and used by `end`. They point into `flex_buf`: a Ui does not move once built.
            \\    flex_buf: [flex_bytes]u8 align(lcgf.mem.column_align) = undefined,
            \\    flex: ?lcgf.flex.Flex = null,
            \\
        );
        if (paragraphs) e.write(
            \\    /// This frame's labels with a paragraph style: texts row and `paragraph_table` index.
            \\    paragraphs: struct { rows: [limits.texts]u32 = undefined, styles: [limits.texts]u16 = undefined, len: u32 = 0 } = .{},
            \\
        );
        const regions = e.hasRegions();
        if (regions) e.print(
            \\    /// Tree rows of the page's regions as this frame built them (none for one it did not
            \\    /// build): `end` rounds each one's content from the region's corner, as the comptime
            \\    /// page does (`layout.snapSubtree`).
            \\    regions: [{d}]u32 = @splat(lcgf.types.none),
            \\
            \\    /// Lays the frame out (with this page's {s}), puts each region's content on the
            \\    /// grid from the region's snapped corner, and paints.
            \\    pub fn end(ui: *Ui, f: *lcgf.frame.Frame, font: lcgf.protocol.Mono) lcgf.context.Output {{
            \\        f.{s}({s}{s});
            \\        for (ui.regions) |row| if (row != lcgf.types.none) lcgf.layout.snapSubtree(f.tree(), row);
            \\        return f.{s};
            \\    }}
            \\
            \\
        , .{
            e.regionCount(),
            if (flex and paragraphs) "flex rules and paragraph styles" else if (flex) "flex rules" else if (paragraphs) "paragraph styles" else "font",
            if (flex and paragraphs) "layoutFlexParagraphs" else if (flex) "layoutFlex" else if (paragraphs) "layoutParagraphs" else "layoutWith",
            e.fontExpr(paragraphs),
            if (flex) ", &ui.flex.?" else "",
            if (paragraphs) std.fmt.allocPrint(e.arena, "finishParagraphs({s})", .{e.fontExpr(true)}) catch unreachable else "finish()",
        }) else if (flex or paragraphs) e.print(
            \\    /// Ends the frame with this page's {s} (`Frame.{s}`).
            \\    pub fn end(ui: *Ui, f: *lcgf.frame.Frame, font: lcgf.protocol.Mono) lcgf.context.Output {{
            \\        return f.{s}({s}{s});
            \\    }}
            \\
            \\
        , .{
            if (flex and paragraphs) "flex rules and paragraph styles" else if (flex) "flex rules" else "paragraph styles",
            if (flex and paragraphs) "endFlexParagraphs" else if (flex) "endFlex" else "endParagraphs",
            if (flex and paragraphs) "endFlexParagraphs" else if (flex) "endFlex" else "endParagraphs",
            e.fontExpr(paragraphs),
            if (flex) ", &ui.flex.?" else "",
        });
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
        e.write(if (regions) "    pub fn build(ui: *Ui, f: *lcgf.frame.Frame, data: anytype) void {\n" else "    pub fn build(ui: *Ui, f: *lcgf.frame.Frame) void {\n");
        e.write("        ui.events = .{};\n");
        for (0..e.page.nodes.len) |i| if (e.page.nodes.items(.kind)[i] == .each and e.regionEvents(@intCast(i)).len > 0)
            e.print("        ui.events_{s} = .{{}};\n", .{e.page.nodes.items(.id)[i]});
        e.write("        ui.before = ui.signals.state;\n");
        if (regions) e.write("        ui.regions = @splat(lcgf.types.none);\n");
        if (paragraphs) e.write("        ui.paragraphs.len = 0;\n");
        // The app's components, checked against the markup before they are called.
        if (e.specComponents()) {
            e.write("        comptime {\n");
            for (e.page.nodes.items(.kind), 0..) |k, i| if (k == .component and e.eachOf(@intCast(i)) == none) e.componentChecks(@intCast(i), true, "            ");
            e.write("        }\n");
        }
        if (tokens.len > 0) e.write("        ui.seen = ui.tokens.generation;\n");
        if (named > 0) e.write("        ui.named = @splat(lcgf.types.none);\n");
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

    /// Whether region `each`'s content has flex rules (margins and the other flex item rules).
    fn regionFlex(e: *Emit, each: u32) bool {
        for (0..e.page.nodes.len) |k| if (k != each and e.eachOf(@intCast(k)) == each and flexOf(e.page.nodes.get(k)) != null) return true;
        return false;
    }

    fn regionCount(e: *Emit) u32 {
        return @intCast(std.mem.count(ir.Kind, e.page.nodes.items(.kind), &.{.each}));
    }

    fn hasRegions(e: *Emit) bool {
        return std.mem.indexOfScalar(ir.Kind, e.page.nodes.items(.kind), .each) != null;
    }

    /// The fields of region `each`'s events struct: an index per click and submit, an
    /// (index, value) per change.
    fn regionEvents(e: *Emit, each: u32) []const u8 {
        var events: std.ArrayList(u8) = .empty;
        const id = e.page.nodes.items(.id)[each];
        for (e.page.handlers.items) |h| if (std.mem.eql(u8, h.each, id)) switch (h.event) {
            .change => events.print(e.arena, " {f}: ?struct {{ u32, {s} }} = null,", .{ std.zig.fmtId(h.widget), fieldType(h.payload.?) }) catch unreachable,
            .submit => events.print(e.arena, " {s}_submit: ?u32 = null,", .{h.widget}) catch unreachable,
            else => events.print(e.arena, " {f}: ?u32 = null,", .{std.zig.fmtId(h.widget)}) catch unreachable,
        };
        return events.items;
    }

    /// What the runtime `Ui` keeps per region: this frame's events, and one editor per text
    /// control, for the row being edited.
    fn regionFields(e: *Emit, pad: []const u8) void {
        for (0..e.page.nodes.len) |i| {
            const n = e.page.nodes.get(i);
            if (n.kind != .each) continue;
            const events = e.regionEvents(@intCast(i));
            if (events.len > 0) e.print("{s}/// The clicks and changes of region `{s}` (lcgf-each=\"{s} in {s}\") this frame, by item index.\n{s}events_{s}: struct {{{s} }} = .{{}},\n", .{ pad, n.id, n.text, n.bind, pad, n.id, events });
            e.editorFields(@intCast(i), pad);
        }
    }

    /// One editor per text control of region `each`, for the row being edited.
    fn editorFields(e: *Emit, each: u32, pad: []const u8) void {
        for (0..e.page.nodes.len) |k| {
            const c = e.page.nodes.get(k);
            const texty = c.kind == .textfield or c.kind == .search or c.kind == .textarea;
            if (texty and e.eachOf(@intCast(k)) == each) e.print(
                \\{s}/// The editor of `{s}` for the item being edited, and that item's index.
                \\{s}edit_{s}: lcgf.widgets_textfield.Text(256) = .{{}},
                \\{s}edit_{s}_row: ?u32 = null,
                \\
            , .{ pad, c.id, pad, c.id, pad, c.id });
        }
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
            } else if (parent != none and e.eachOf(parent) != none) continue; // rtRegion writes it
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
                // lcgf-if/lcgf-else: a bool, false first.
                if (nodes.items(.level)[parent] == 1) e.print("{s} => {{ ", .{if (k == 0) "false" else "true"}) else {
                    const field = for (e.page.fields.items) |fd| {
                        if (std.mem.eql(u8, fd.name, nodes.items(.bind)[parent])) break fd;
                    } else unreachable;
                    e.print(".{f} => {{ ", .{std.zig.fmtId(field.cases[k])});
                }
            }
            // A named node: its row, which `Ui.semantics` names (engine spec R2).
            if (within == none and e.isNamed(i)) e.print("ui.named[{s}] = f.tree().len; ", .{e.namedSlot(i)});
            var close = if (nodes.items(.kind)[i] == .each) blk: {
                e.rtRegion(i);
                break :blk "";
            } else e.rtOpenFlex(i, lists);
            if (in_choice) close = std.fmt.allocPrint(e.arena, "{s}{s}}},", .{ close, if (close.len > 0) " " else "" }) catch unreachable;
            if (nodes.items(.kind)[i] == .list) lists += 1;
            e.print(" // {s}\n", .{e.where(nodes.items(.loc)[i])});
            // A leaf inside a choice closes its prong at once.
            const leaf = switch (nodes.items(.kind)[i]) {
                .container, .landmark, .when, .list, .choice, .dialog, .section => false,
                .component => !e.hasChild(i),
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
        for (e.page.handlers.items) |h| if (h.each.len > 0) continue else switch (h.event) {
            .click, .submit => e.print("        if (ui.events.{f}) h.{f}(ui); // {s}\n", .{ std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) }),
            .change => if (textChange(h))
                e.print("        if (ui.events.{s}_change) h.{f}(ui, {s}.text()); // {s}\n", .{ h.widget, std.zig.fmtId(h.name), e.stateRef(h.field), e.where(h.loc) })
            else
                e.print("        if ({s}{s} != ui.before.{f}{s}) h.{f}(ui, {s}{s}); // {s}\n", .{ e.stateRef(h.field), e.member(h), std.zig.fmtId(h.field), e.member(h), std.zig.fmtId(h.name), e.stateRef(h.field), e.member(h), e.where(h.loc) }),
        };
        // A region's handlers get the item's index, as on the comptime page.
        for (e.page.handlers.items) |h| if (h.event == .submit and h.each.len > 0)
            e.print("        if (ui.events_{s}.{s}_submit) |index| h.{f}(ui, index); // {s}\n", .{ h.each, h.widget, std.zig.fmtId(h.name), e.where(h.loc) });
        for (e.page.handlers.items) |h| if (h.event == .click and h.each.len > 0)
            e.print("        if (ui.events_{s}.{f}) |index| h.{f}(ui, index); // {s}\n", .{ h.each, std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
        for (e.page.handlers.items) |h| if (h.event == .change and h.each.len > 0)
            e.print("        if (ui.events_{s}.{f}) |change| h.{f}(ui, change[0], change[1]); // {s}\n", .{ h.each, std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
        e.write("    }\n};\n\n");
    }

    /// Whether node `i` has an accessible name the runtime page carries (outside run-time
    /// regions): the index of its first row slot. A node inside lcgf-each lcgf-max has a slot
    /// per copy (`namedSlots`).
    fn namedIndex(e: *Emit, i: u32) ?u32 {
        if (!e.isNamed(i)) return null;
        var k: u32 = 0;
        for (0..i) |j| if (e.isNamed(@intCast(j))) {
            k += e.namedSlots(@intCast(j));
        };
        return k;
    }

    fn isNamed(e: *Emit, i: u32) bool {
        return e.page.nodes.items(.name)[i].len > 0 and e.eachOf(i) == none;
    }

    /// The copies of node `i`: the product of its enclosing lists' maxima.
    fn namedSlots(e: *Emit, i: u32) u32 {
        const nodes = e.page.nodes.slice();
        var n: u32 = 1;
        var p = nodes.items(.parent)[i];
        while (p != none) : (p = nodes.items(.parent)[p]) if (nodes.items(.kind)[p] == .list) {
            n *= nodes.items(.max)[p];
        };
        return n;
    }

    /// The slot of node `i`'s copy: `copy0`, `copy1`, … of its lists, outermost first.
    fn namedSlot(e: *Emit, i: u32) []const u8 {
        const nodes = e.page.nodes.slice();
        var maxima: std.ArrayList(u32) = .empty;
        var p = nodes.items(.parent)[i];
        while (p != none) : (p = nodes.items(.parent)[p]) if (nodes.items(.kind)[p] == .list) maxima.append(e.arena, nodes.items(.max)[p]) catch unreachable;
        var out: std.ArrayList(u8) = .empty;
        out.print(e.arena, "{d}", .{e.namedIndex(i).?}) catch unreachable;
        if (maxima.items.len == 0) return out.items;
        // Outermost list first: copy0 * m1 * m2 + copy1 * m2 + copy2.
        const lists = maxima.items.len;
        for (0..lists) |d| {
            out.print(e.arena, " + copy{d}", .{d}) catch unreachable;
            for (maxima.items[0 .. lists - 1 - d]) |m| out.print(e.arena, " * {d}", .{m}) catch unreachable;
        }
        return out.items;
    }

    fn namedCount(e: *Emit) u32 {
        var k: u32 = 0;
        for (0..e.page.nodes.len) |i| if (e.isNamed(@intCast(i))) {
            k += e.namedSlots(@intCast(i));
        };
        return k;
    }

    fn namedList(e: *Emit) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (e.page.nodes.items(.name), 0..) |name, i| if (e.isNamed(@intCast(i))) for (0..e.namedSlots(@intCast(i))) |_| {
            out.print(e.arena, " \"{f}\",", .{std.zig.fmtString(name)}) catch unreachable;
        };
        if (out.items.len > 0) out.items.len -= 1;
        return out.items;
    }

    const Styled = struct { paragraph: ?lcgf.text_stack.Paragraph, decoration: ?lcgf.text_decorations.Style };

    /// The distinct (paragraph, decoration) pairs of the page's labels, in first-use order:
    /// `ComptimeUi`'s table, so both frontends index it alike.
    fn paragraphTable(e: *Emit) []const Styled {
        var out: std.ArrayList(Styled) = .empty;
        for (e.page.nodes.items(.paragraph), e.page.nodes.items(.decoration)) |p, d| if (p != null or d != null) {
            const st = norm(.{ .paragraph = p, .decoration = d });
            for (out.items) |q| {
                if (std.meta.eql(st, q)) break;
            } else out.append(e.arena, st) catch unreachable;
        };
        return out.items;
    }

    fn norm(st: Styled) Styled {
        return .{ .paragraph = st.paragraph orelse .{}, .decoration = st.decoration orelse .{} };
    }

    fn paragraphIndex(e: *Emit, n: ir.Node) usize {
        const st = norm(.{ .paragraph = n.paragraph, .decoration = n.decoration });
        for (e.paragraphTable(), 0..) |q, i| if (std.meta.eql(st, q)) return i;
        unreachable;
    }

    /// The font `Ui.end` measures with: `font`, or the page's `MonoParagraphs` over it.
    fn fontExpr(e: *Emit, paragraphs: bool) []const u8 {
        if (!paragraphs) return "font";
        return std.fmt.allocPrint(e.arena, ".{{ .mono = font, .rows = ui.paragraphs.rows[0..ui.paragraphs.len], .styles = ui.paragraphs.styles[0..ui.paragraphs.len], .table = &paragraph_table{s} }}", .{
            if (e.anyDecoration()) ", .decorations = &decoration_table" else "",
        }) catch unreachable;
    }

    fn anyDecoration(e: *Emit) bool {
        for (e.page.nodes.items(.decoration)) |d| if (d != null) return true;
        return false;
    }

    /// A decoration literal: the lines and colour the lowering sets.
    fn decoration(e: *Emit, d: lcgf.text_decorations.Style) void {
        e.write(".{");
        var any = false;
        inline for (.{ "underline", "overline", "strike" }) |f| if (@field(d, f)) {
            e.print("{s} .{s} = true", .{ if (any) "," else "", f });
            any = true;
        };
        if (d.color) |c| {
            e.print("{s} .color = 0x{x:0>8}", .{ if (any) "," else "", c });
            any = true;
        }
        e.write(if (any) " }" else "}");
    }

    /// A paragraph style literal: the fields the lowering sets.
    fn paragraph(e: *Emit, p: lcgf.text_stack.Paragraph) void {
        e.write(".{");
        var any = false;
        switch (p.line_height) {
            .font => {},
            .px => |v| {
                e.print(" .line_height = .{{ .px = {d} }}", .{v});
                any = true;
            },
            .multiple => |v| {
                e.print(" .line_height = .{{ .multiple = {d} }}", .{v});
                any = true;
            },
        }
        inline for (.{ "letter_spacing", "word_spacing" }) |f| if (@field(p, f) != 0) {
            e.print("{s} .{s} = {d}", .{ if (any) "," else "", f, @field(p, f) });
            any = true;
        };
        if (p.ellipsis) {
            e.print("{s} .ellipsis = true", .{if (any) "," else ""});
            any = true;
        }
        e.write(if (any) " }" else "}");
    }

    /// Whether a node has flex rules (CSS margins, align-self, wrap, …; engine spec F2).
    fn hasFlex(e: *Emit) bool {
        for (0..e.page.nodes.len) |i| if (flexOf(e.page.nodes.get(i)) != null) return true;
        return false;
    }

    /// `rtOpen`, with the node's flex rules written for the node its statement makes.
    fn rtOpenFlex(e: *Emit, i: u32, list_depth: u32) []const u8 {
        const fs = flexOf(e.page.nodes.get(i)) orelse return e.rtOpen(i, list_depth);
        // The rule's row is the next one pushed: the node's own, or the root a widget or a
        // component builds first, which `spec.flexed` gives the rule on a comptime page.
        e.write("fx.set(f.tree().len, &");
        e.structure(fs, FlexStyle{});
        e.write("); ");
        return e.rtOpen(i, list_depth);
    }

    fn runtimePage(e: *Emit) void {
        const n: u32 = @intCast(e.page.nodes.len);
        // Rows: widgets push up to a few rows each; texts and bytes as the literals need. A
        // region adds its lcgf-nodes and lcgf-texts, as its own Context has on a comptime page.
        var nodes: u32 = 8 * n + 16;
        var texts: u32 = 2 * n + 8;
        var strings: u32 = 8192;
        for (0..n) |i| if (e.page.nodes.items(.kind)[i] == .each) {
            nodes += e.page.nodes.items(.max)[i];
            texts += @intFromFloat(e.page.nodes.items(.range)[i][0]);
            strings += 16384;
        };
        const regions = e.hasRegions();
        e.print(
            \\/// A runtime `Context` large enough for this page.
            \\pub const limits: lcgf.context.Limits = .{{ .nodes = {d}, .texts = {d}, .customs = 4, .strings = {d}, .depth = 64 }};
            \\
            \\/// The page driven by the app's handler type `H`, in a caller's runtime `Context`:
            \\/// `frame` builds and draws, then calls the handlers after the draw list is final.
            \\pub fn Page(comptime H: type) type {{
            \\    comptime check(H);
            \\    return struct {{
            \\        ui: Ui = .{{}},
            \\
            \\        pub fn frame(p: *@This(), ctx: *lcgf.context.Context, h: *H, in: *const lcgf.input.Input{s}) lcgf.context.Output {{
            \\            var f = ctx.begin(in);
            \\            p.ui.build(&f{s});
            \\            const out = {s};
            \\            p.ui.dispatch(h);
            \\            return out;
            \\        }}
            \\    }};
            \\}}
            \\
            \\
        , .{ nodes, texts, strings, if (regions) ", data: anytype" else "", if (regions) ", data" else "", if (e.hasFlex() or regions) "p.ui.end(&f, .{})" else "f.end(.{})" });
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
        if (each != none) e.eachFields();
        e.write(if (each != none) "        pub fn frame(p: *@This(), h: *H, in: *const lcgf.input.Input, data: anytype) Ui.Output {\n" else "        pub fn frame(p: *@This(), h: *H, in: *const lcgf.input.Input) Ui.Output {\n");
        var changes = false;
        // One prong per widget: a click, or a text control's submit and change.
        var prongs: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (hs) |h| {
            changes = changes or (h.event == .change and h.each.len == 0 and !textChange(h));
            if (h.each.len == 0 and (h.event != .change or textChange(h))) prongs.put(e.arena, h.widget, {}) catch unreachable;
        }
        const clicks: u32 = @intCast(prongs.count());
        if (hs.len == 0) e.write("            _ = h;\n");
        if (changes) e.write("            const before = p.ui.signals.state;\n");
        e.write(if (each != none) "            var out = p.ui.frame(in);\n" else "            const out = p.ui.frame(in);\n");
        if (each != none) e.eachFrames();
        // Clicks: one prong per widget with a click handler.
        if (clicks > 0) {
            e.write("            if (out.event) |event| switch (event) {\n");
            for (hs) |h| if (h.event == .click and h.each.len == 0) e.print("                .{f} => h.{f}(&p.ui), // {s}\n", .{ std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
            // A text control's event is what its input did: a submit, a change of the text, or both.
            for (prongs.keys()) |widget| {
                var calls: std.ArrayList(u8) = .empty;
                var n: u32 = 0;
                for (hs) |h| if (h.each.len == 0 and std.mem.eql(u8, h.widget, widget)) {
                    if (h.event == .submit) {
                        calls.print(e.arena, "if (result.submitted) h.{f}(&p.ui); // {s}\n", .{ std.zig.fmtId(h.name), e.where(h.loc) }) catch unreachable;
                    } else if (textChange(h)) {
                        calls.print(e.arena, "if (result.changed) h.{f}(&p.ui, p.ui.signals.state.{f}.text()); // {s}\n", .{ std.zig.fmtId(h.name), std.zig.fmtId(h.field), e.where(h.loc) }) catch unreachable;
                    } else continue;
                    n += 1;
                };
                if (n == 1) {
                    const semi = std.mem.indexOf(u8, calls.items, "; //").?;
                    e.print("                .{f} => |result| {s},{s}", .{ std.zig.fmtId(widget), calls.items[0..semi], calls.items[semi + 1 ..] });
                } else if (n > 1) e.print("                .{f} => |result| {{\n{s}}},\n", .{ std.zig.fmtId(widget), calls.items });
            }
            var widgets: u32 = 0;
            for (e.page.nodes.items(.id), e.page.nodes.items(.kind), 0..) |id, kind, k| {
                // A search field is two widgets: the field and its clear button (`id.clear`).
                if (id.len > 0 and (e.eachOf(@intCast(k)) == none or kind == .each)) widgets += @as(u32, 1) + @intFromBool(kind == .search);
            }
            // An app component's widgets are tags of `Widget` the markup does not see.
            if (widgets > clicks or e.specComponents()) e.write("                else => {},\n");
            e.write("            };\n");
        }
        for (hs) |h| if (h.event == .submit and h.each.len > 0)
            e.print("            if (events_{s}.{s}_submit) |index| h.{f}(&p.ui, index); // {s}\n", .{ h.each, h.widget, std.zig.fmtId(h.name), e.where(h.loc) });
        for (hs) |h| if (h.event == .click and h.each.len > 0)
            e.print("            if (events_{s}.{f}) |index| h.{f}(&p.ui, index); // {s}\n", .{ h.each, std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
        for (hs) |h| if (h.event == .change and h.each.len > 0)
            e.print("            if (events_{s}.{f}) |change| h.{f}(&p.ui, change[0], change[1]); // {s}\n", .{ h.each, std.zig.fmtId(h.widget), std.zig.fmtId(h.name), e.where(h.loc) });
        for (hs) |h| if (h.event == .change and h.each.len == 0 and !textChange(h))
            e.print("            if (p.ui.signals.state.{f}{s} != before.{f}{s}) h.{f}(&p.ui, p.ui.signals.state.{f}{s}); // {s}\n", .{ std.zig.fmtId(h.field), e.member(h), std.zig.fmtId(h.field), e.member(h), std.zig.fmtId(h.name), std.zig.fmtId(h.field), e.member(h), e.where(h.loc) });
        e.write("            return out;\n        }\n    };\n}\n\n");
    }

    /// `.member` of a handler's field, or "": the select's value is its state's `selected`.
    fn member(e: *Emit, h: ir.Handler) []const u8 {
        if (h.member.len == 0) return "";
        return std.fmt.allocPrint(e.arena, ".{s}", .{h.member}) catch unreachable;
    }

    /// on:change on a text control outside a region: reported from its event, with its text.
    fn textChange(h: ir.Handler) bool {
        return h.event == .change and h.each.len == 0 and h.payload == .str;
    }

    /// The Page fields of its run-time regions: each region's runtime Context, and the two draw
    /// lists the page and the regions are composed into, one region after another.
    fn eachFields(e: *Emit) void {
        var rows: std.ArrayList(u8) = .empty;
        var strings: std.ArrayList(u8) = .empty;
        var decls: std.ArrayList(u8) = .empty;
        for (0..e.page.nodes.len) |i| {
            const n = e.page.nodes.get(i);
            if (n.kind != .each) continue;
            e.print(
                \\        /// The run-time region `{s}` (lcgf-each="{s} in {s}"), in its own runtime Context.
                \\        {s}_buf: [lcgf.context.Context.requiredBytes({s}_limits)]u8 align(lcgf.mem.column_align) = undefined,
                \\        {s}: ?lcgf.context.Context = null,
                \\
            , .{ n.id, n.text, n.bind, n.id, n.id, n.id });
            decls.print(e.arena, "        const {s}_limits: lcgf.context.Limits = .{{ .nodes = {d}, .texts = {d}, .customs = 4, .strings = 16384, .depth = 64 }};\n", .{ n.id, n.max, @as(u32, @intFromFloat(n.range[0])) }) catch unreachable;
            rows.print(e.arena, " + {s}_limits.nodes", .{n.id}) catch unreachable;
            e.editorFields(@intCast(i), "        ");
            // The region's flex rules (margins in its content), for its own Frame's `endFlex`.
            if (e.regionFlex(@intCast(i))) {
                e.print(
                    \\        /// The flex rules of region `{s}`'s content, written as it builds.
                    \\        {s}_flex_buf: [{s}_flex_bytes]u8 align(lcgf.mem.column_align) = undefined,
                    \\        {s}_flex: ?lcgf.flex.Flex = null,
                    \\
                , .{ n.id, n.id, n.id, n.id });
                decls.print(e.arena,
                    \\        const {s}_flex_bytes = blk: {{
                    \\            var carver: lcgf.mem.Carver = .{{ .buf = null }};
                    \\            _ = carver.columns(lcgf.flex.Flex.Columns, lcgf.simd.rows({s}_limits.nodes));
                    \\            break :blk carver.off;
                    \\        }};
                    \\
                , .{ n.id, n.id }) catch unreachable;
            }
            strings.print(e.arena, " + {s}_limits.strings", .{n.id}) catch unreachable;
        }
        e.print(
            \\        /// The draw lists the page and its regions are composed into, alternately: each region
            \\        /// composes the last one into the other. A Page does not move once used.
            \\        draws_buf: [2][draw_bytes]u8 align(lcgf.mem.column_align) = undefined,
            \\        draws: [2]lcgf.draw_list.DrawList = undefined,
            \\        draws_carved: bool = false,
            \\        strings: [2][8192{s}]u8 = undefined,
            \\
            \\{s}        const draw_rows = {d}{s};
            \\        const draw_bytes = blk: {{
            \\            var carver: lcgf.mem.Carver = .{{ .buf = null }};
            \\            _ = lcgf.draw_list.DrawList.init(&carver, draw_rows, draw_rows, 8);
            \\            break :blk carver.off;
            \\        }};
            \\
            \\
        , .{ strings.items, decls.items, 8 * e.page.nodes.len + 16, rows.items });
    }

    /// `Page.frame`'s run-time regions: each built after the page, in its rect, from the app's
    /// `data.<list>`, and composed into the page's draw list, in tree order.
    fn eachFrames(e: *Emit) void {
        e.write(
            \\            if (!p.draws_carved) {
            \\                for (&p.draws, &p.draws_buf) |*d, *b| {
            \\                    var carver: lcgf.mem.Carver = .{ .buf = b };
            \\                    d.* = lcgf.draw_list.DrawList.init(&carver, draw_rows, draw_rows, 8);
            \\                }
            \\                p.draws_carved = true;
            \\            }
            \\
        );
        // Every region's events first: handlers run after all draw lists are final.
        for (0..e.page.nodes.len) |i| {
            const n = e.page.nodes.get(i);
            if (n.kind != .each) continue;
            const events = e.regionEvents(@intCast(i));
            if (events.len > 0) e.print("            var events_{s}: struct {{{s} }} = .{{}};\n", .{ n.id, events });
        }
        var k: u32 = 0;
        for (0..e.page.nodes.len) |i_| {
            const i: u32 = @intCast(i_);
            if (e.page.nodes.items(.kind)[i] != .each) continue;
            e.eachFrame(i, k);
            k += 1;
        }
    }

    /// Region `each`, the `slot`-th of the page.
    fn eachFrame(e: *Emit, each: u32, slot: u32) void {
        const n = e.page.nodes.get(each);
        const fit = n.level == 1;
        e.print("            {{ // lcgf-each=\"{s} in {s}\", {s}\n", .{ n.text, n.bind, e.where(n.loc) });
        e.eachChecks(each, "                ");
        // The copies' statements first: they name `ui` only when they read the view state.
        const body = e.eachLoop(each);
        if (std.mem.indexOf(u8, body, "ui.") != null) e.write("                const ui = &p.ui;\n");
        e.print(
            \\                if (p.{s} == null) p.{s} = lcgf.context.Context.init(&p.{s}_buf, {s}_limits) catch unreachable;
            \\                const rect = out.tree.rect(out.tree.find(.from("{s}")));
            \\                {s} region_in = lcgf.ct_interop.regionInput(in, .{{ rect.x0, rect.y0, rect.x1, rect.y1 }});{s}
            \\                var region_frame = p.{s}.?.begin(&region_in);
            \\                const f = &region_frame;
            \\
        , .{ n.id, n.id, n.id, n.id, n.id, if (fit) "var" else "const", fitViewport(e, n), n.id });
        const flex = e.regionFlex(each);
        if (flex) e.print(
            \\                if (p.{s}_flex == null) {{
            \\                    var carver: lcgf.mem.Carver = .{{ .buf = &p.{s}_flex_buf }};
            \\                    p.{s}_flex = lcgf.flex.Flex.init(&carver, {s}_limits.nodes);
            \\                }}
            \\                const fx = &p.{s}_flex.?;
            \\
        , .{ n.id, n.id, n.id, n.id, n.id });
        e.write(body);
        e.print(
            \\                const region_out = {s};{s}
            \\                if (lcgf.ct_interop.compose(&p.draws[{d}], out.draw, region_out.draw, @backingInt(lcgf.types.Id.from("{s}")), &p.strings[{d}])) out.draw = &p.draws[{d}] else |_| {{}}
            \\            }}
            \\
        , .{ if (flex) "f.endFlex(.{}, fx)" else "f.end(.{})", if (fit) std.fmt.allocPrint(e.arena, "\n                // The content's size before snapping, for the region's next layout, so the\n                // page around it lays out as it would around the content itself.\n                const content = region_out.tree.c.size;\n                if (lcgf.ct_interop.setFit(&p.ui, .{f}, .{{ content[0][1], content[1][1] }})) out.wake = 0;", .{std.zig.fmtId(n.id)}) catch unreachable else "", slot % 2, n.id, slot % 2, slot % 2 });
    }

    /// The comptime checks of region `each`: the item fields the page reads and its
    /// components, each message at the HTML.
    fn eachChecks(e: *Emit, each: u32, pad: []const u8) void {
        const n = e.page.nodes.get(each);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        e.print("{s}comptime {{\n{s}    const Item = @import(\"std\").meta.Elem(@TypeOf(data.{f}));\n", .{ pad, pad, std.zig.fmtId(n.bind) });
        for (e.page.item_fields.items) |f| {
            if (!std.mem.eql(u8, f.each, n.id)) continue;
            if (f.bound) |ty| {
                // A bound field: the type the control writes, through a mutable item list.
                e.print("{s}    if (@hasField(Item, \"{s}\") and @FieldType(Item, \"{s}\") != {s}) @compileError(\"{s}: '{s}.{s}' is bound as {s} here; the item's field is \" ++ @typeName(@FieldType(Item, \"{s}\")));\n", .{ pad, f.field, f.field, fieldType(ty), e.whereFull(f.loc), n.text, f.field, fieldType(ty), f.field });
                if (f.writes) e.print("{s}    if (@typeInfo(@TypeOf(data.{f})) != .pointer or @typeInfo(@TypeOf(data.{f})).pointer.attrs.@\"const\") @compileError(\"{s}: '{s}.{s}' is bound here, so pass {s} as a mutable slice\");\n", .{ pad, std.zig.fmtId(n.bind), std.zig.fmtId(n.bind), e.whereFull(f.loc), n.text, f.field, n.bind });
            }
            if (seen.contains(f.field)) continue;
            seen.put(e.arena, f.field, {}) catch unreachable;
            e.print("{s}    if (!@hasField(Item, \"{s}\")) @compileError(\"{s}: the items of '{s}' have no field '{s}'\");\n", .{ pad, f.field, e.whereFull(f.loc), n.bind, f.field });
        }
        const inner = std.fmt.allocPrint(e.arena, "{s}    ", .{pad}) catch unreachable;
        for (0..e.page.nodes.len) |k| if (e.page.nodes.items(.kind)[k] == .component and e.eachOf(@intCast(k)) == each)
            e.componentChecks(@intCast(k), true, inner);
        // Item props are item fields, so `seen` holds them too.
        if (seen.count() == 0) e.print("{s}    _ = Item;\n", .{pad});
        e.print("{s}}}\n", .{pad});
    }

    /// The copies of region `each` in its Frame `f`: the wrapper its CSS lays them out in and
    /// one copy per item, as text.
    fn eachLoop(e: *Emit, each: u32) []const u8 {
        const n = e.page.nodes.get(each);
        e.events_var = if (e.runtime) std.fmt.allocPrint(e.arena, "ui.events_{s}", .{n.id}) catch unreachable else std.fmt.allocPrint(e.arena, "events_{s}", .{n.id}) catch unreachable;
        var body: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        e.rtWalk(each, 1);
        std.mem.swap(std.ArrayList(u8), &body, &e.out);
        // The copy index names widgets; a region of text alone has none.
        if (std.mem.indexOf(u8, body.items, "copy0") == null) body.insertSlice(e.arena, 0, "                    _ = copy0;\n") catch unreachable;
        var out: std.ArrayList(u8) = .empty;
        out.print(e.arena,
            \\                // The copies are laid out in the region as its CSS says.
            \\                _ = f.open(.none, {s});
            \\                for (data.{f}, 0..) |*{f}, copy0| {{
            \\{s}                }}
            \\                f.close();
            \\
        , .{ e.styleText(.{ .size = fitSize(n.style), .dir = n.style.dir, .gap = n.style.gap, .pad = n.style.pad, .main = n.style.main, .cross = n.style.cross }, ""), std.zig.fmtId(n.bind), std.zig.fmtId(n.text), body.items }) catch unreachable;
        return out.items;
    }

    /// Region `each` in the runtime frontend: a node of the page's own Frame, sized and clipped
    /// as the comptime page's region is, around the copies.
    fn rtRegion(e: *Emit, each: u32) void {
        const n = e.page.nodes.get(each);
        e.print("{{ // lcgf-each=\"{s} in {s}\"\n", .{ n.text, n.bind });
        e.eachChecks(each, "                ");
        var outer = n.style;
        outer.dir = .y;
        outer.gap = 0;
        outer.pad = @splat(0);
        outer.main = .start;
        outer.cross = .start;
        // The comptime region clips its content to its rect.
        outer.clip = true;
        var k: u32 = 0;
        for (e.page.nodes.items(.kind)[0..each]) |kind| k += @intFromBool(kind == .each);
        e.print("                ui.regions[{d}] = f.tree().len;\n", .{k});
        e.print("                _ = f.open(.from(\"{s}\"), {s});\n", .{ n.id, e.styleText(outer, n.params_expr) });
        e.write(e.eachLoop(each));
        e.write("                f.close();\n            }");
    }

    /// A fit region's content is measured in the page's viewport on its fit axes.
    fn fitViewport(e: *Emit, n: ir.Node) []const u8 {
        if (n.level != 1) return "";
        var out: std.ArrayList(u8) = .empty;
        for (0..2) |a| if (n.style.size[a].kind == .fit) out.print(e.arena, "\n                region_in.viewport[{d}] = in.viewport[{d}];", .{ a, a }) catch unreachable;
        return out.items;
    }

    /// The region content's wrapper size: the region's on a definite axis, the content's own
    /// on a fit one.
    fn fitSize(st: types.Style) [2]types.Size {
        var out: [2]types.Size = .{ .fill, .fill };
        for (0..2) |a| if (st.size[a].kind == .fit) {
            out[a] = .fit;
        };
        return out;
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
        for (e.page.nodes.items(.kind), e.page.nodes.items(.id), e.page.nodes.items(.text), 0..) |k, id, tag, i| {
            if (e.runtime or k != .component or e.eachOf(@intCast(i)) != none or e.clickHandler(id) == null) continue;
            e.print("    if (!@hasField(Widget, \"{s}\")) @compileError(\"{s}: <{s}> makes no widget '{s}': give props.id to the widget its click is on\");\n", .{ id, e.whereFull(e.page.nodes.items(.loc)[i]), tag, id });
        }
        e.write("}\n");
    }
};

/// Node `n`'s flex rules, its margins included, or null when it has none.
fn flexOf(n: ir.Node) ?FlexStyle {
    var fs = n.flex;
    if (n.margin) |m| fs.margin = m;
    return if (std.meta.eql(fs, FlexStyle{})) null else fs;
}
