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
    /// Where a styled label records its texts row: the page's rows, or its region's.
    para_var: []const u8 = "ui.paragraphs",
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

    /// A `grid.Track` as its constructor (`.px(80)`, `.fr(1)`, `.fit`, `.minmax(…)`).
    fn track(e: *Emit, t: lcgf.grid.Track) void {
        const T = lcgf.grid.Track;
        if (std.meta.eql(t, T.fit)) return e.write(".fit");
        if (std.meta.eql(t, T.px(t.k_px))) return e.print(".px({d})", .{t.k_px});
        if (std.meta.eql(t, T.fr(t.k_fr))) return e.print(".fr({d})", .{t.k_fr});
        if (std.meta.eql(t, T.minmaxFr(t.min, t.k_fr, t.max))) {
            e.print(".minmaxFr({d}, {d}, ", .{ t.min, t.k_fr });
            e.value(t.max);
            return e.write(")");
        }
        if (std.meta.eql(t, T.fitContent(t.max))) return e.print(".fitContent({d})", .{t.max});
        e.print(".minmax({d}, ", .{t.min});
        e.value(t.max);
        e.write(")");
    }

    fn tracks(e: *Emit, list: []const lcgf.grid.Track) void {
        e.write("&.{");
        for (list, 0..) |t, i| {
            e.write(if (i == 0) " " else ", ");
            e.track(t);
        }
        e.write(if (list.len > 0) " }" else "}");
    }

    /// A `grid.Decl` literal, with the fields that differ from the defaults.
    fn gridDecl(e: *Emit, d: lcgf.grid.Decl) void {
        const D = lcgf.grid.Decl;
        var any = false;
        e.write(".{");
        inline for (comptime @typeInfo(D).@"struct".field_names) |name| {
            const v = @field(d, name);
            const differs = if (comptime std.mem.eql(u8, name, "columns") or std.mem.eql(u8, name, "rows")) v.len > 0 else !std.meta.eql(v, @field(D{}, name));
            if (differs) {
                e.write(if (any) ", ." ++ name ++ " = " else " ." ++ name ++ " = ");
                if (comptime std.mem.eql(u8, name, "columns") or std.mem.eql(u8, name, "rows")) e.tracks(v) else if (comptime std.mem.eql(u8, name, "auto")) {
                    e.write(".{ ");
                    e.track(v[0]);
                    e.write(", ");
                    e.track(v[1]);
                    e.write(" }");
                } else if (comptime std.mem.eql(u8, name, "repeat")) {
                    e.print(".{{ .mode = .{s}, .track = ", .{@tagName(v.?.mode)});
                    e.track(v.?.track);
                    e.print(", .max = {d} }}", .{v.?.max});
                } else e.value(v);
                any = true;
            }
        }
        e.write(if (any) " }" else "}");
    }

    /// An `overlay.Place` literal; `at` and `pivot` have no default.
    fn anchorPlace(e: *Emit, p: lcgf.overlay.Place) void {
        e.print(".{{ .at = .{s}, .pivot = .{s}", .{ @tagName(p.at), @tagName(p.pivot) });
        const d: lcgf.overlay.Place = .{ .at = p.at, .pivot = p.pivot };
        inline for (.{ "offset", "viewport", "flip" }) |name| if (!std.meta.eql(@field(p, name), @field(d, name))) {
            e.write(", ." ++ name ++ " = ");
            e.value(@field(p, name));
        };
        e.write(" }");
    }

    fn gridItem(e: *Emit, it: lcgf.grid.Item) void {
        e.structure(it, .{});
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
            .counter => unreachable, // only in run-time regions
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
        // A grid child's cell: engine spec F7, `spec.cell(s, grid.Item)`.
        var cell_close: []const u8 = "";
        if (n.placed.cell) |c| {
            e.write("s.cell(");
            var buf: std.ArrayList(u8) = .empty;
            std.mem.swap(std.ArrayList(u8), &buf, &e.out);
            e.write(", ");
            e.gridItem(c);
            e.write(")");
            std.mem.swap(std.ArrayList(u8), &buf, &e.out);
            cell_close = buf.items;
        }
        // Positioning: engine spec F17, `spec.layer`, `spec.sticky`, `spec.anchored`.
        var pos_close: std.ArrayList(u8) = .empty;
        if (n.placed.layer != 0) e.write("s.layer(");
        if (n.placed.sticky != null) e.write("s.sticky(");
        if (n.placed.anchor != null) e.write("s.anchored(");
        if (n.placed.anchor) |a| {
            std.mem.swap(std.ArrayList(u8), &pos_close, &e.out);
            e.write(", ");
            e.anchorPlace(a);
            e.write(")");
            std.mem.swap(std.ArrayList(u8), &pos_close, &e.out);
        }
        if (n.placed.sticky) |top| pos_close.print(e.arena, ", {d})", .{top}) catch unreachable;
        if (n.placed.layer != 0) pos_close.print(e.arena, ", {d})", .{n.placed.layer}) catch unreachable;
        // A recipe widget's CSS is in its recipe's rules.
        const restyle = n.recipe.len == 0 and (!std.meta.eql(n.style, n.base_style) or n.params_expr.len > 0);
        const has_children = switch (n.kind) {
            .container, .landmark, .when, .choice, .list, .dialog, .section, .popover, .scroll => true,
            .component => e.hasChild(i),
            else => false,
        };
        var inner_close: std.ArrayList(u8) = .empty;
        const text_styled = switch (n.kind) {
            .label, .text, .heading => !std.meta.eql(n.text_style, n.base_text),
            else => false,
        };
        if (n.spans.len > 0) e.write("s.spans(");
        if (n.decoration != null) e.write("s.decorated(");
        if (n.paragraph != null) e.write("s.paragraph(");
        if (text_styled) e.write("s.textStyled(");
        if (restyle and !has_children) e.write("s.styled(");
        if (n.placed.grid) |d| {
            // A grid container, landmark or not: `spec.grid(style, decl, children)`.
            var st = n.style;
            if (n.kind == .landmark) st.role = std.meta.stringToEnum(types.Role, n.landmark).?;
            e.write("s.grid(");
            e.fields(st, types.Style{}, &.{"dir"}, n.params_expr);
            e.write(", ");
            e.gridDecl(d);
            e.write(", .{");
            inner_close.appendSlice(e.arena, "})") catch unreachable;
        } else switch (n.kind) {
            .container => if (n.recipe.len > 0) {
                if (boxInteractive(n)) e.print("recipes.ct.box(.{f}, ", .{std.zig.fmtId(n.id)}) else e.write("recipes.ct.box(null, ");
                e.print("{s}, .{{", .{e.config(n)});
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            } else {
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
            .button, .link => if (n.recipe.len > 0) {
                e.print("recipes.ct.button(.{f}, ", .{std.zig.fmtId(n.id)});
                e.caption(n.text_kind, n.text);
                e.print(", {s})", .{e.config(n)});
            } else {
                // Text CSS on a <button> draws its caption.
                const ts = n.kind == .button and !std.meta.eql(n.text_style, n.base_text);
                e.print("{s}.ct.{s}(theme, .{f}, ", .{ e.use(@tagName(n.kind)), if (ts) "buttonStyled" else @tagName(n.kind), std.zig.fmtId(n.id) });
                e.caption(n.text_kind, n.text);
                if (ts) {
                    e.write(", ");
                    e.structure(n.text_style, types.TextStyle{});
                }
                e.write(")");
            },
            .checkbox, .@"switch" => if (n.recipe.len > 0) {
                e.print("recipes.ct.{s}(.{f}, .{f}, ", .{ if (n.kind == .checkbox) "checkbox" else "switchControl", std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(n.text_kind, n.text);
                e.print(", {s})", .{e.config(n)});
            } else e.boolSpec(n),
            .toggle => e.boolSpec(n),
            .slider => if (n.recipe.len > 0) {
                e.print("recipes.ct.slider(.{f}, .{f}, ", .{ std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.structure(lcgf.widgets_slider.Range{ .lo = n.range[0], .hi = n.range[1] }, .{});
                e.print(", {s})", .{e.config(n)});
            } else {
                e.print("{s}.ct.slider(theme, .{f}, .{f}, ", .{ e.use("slider"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.structure(lcgf.widgets_slider.Range{ .lo = n.range[0], .hi = n.range[1] }, .{});
                e.write(")");
            },
            .progress => e.print("{s}.ct.progress(theme, .{f})", .{ e.use("progress"), std.zig.fmtId(n.bind) }),
            .separator => e.print("{s}.ct.separator(theme, .{s})", .{ e.use("separator"), if (n.level == 1) "vertical" else "horizontal" }),
            .spacer => e.print("{s}.ct.spacer(.{s})", .{ e.use("spacer"), if (n.dir == .x) "x" else "y" }),
            .section => {
                const faced_ = restyle or n.part == .header;
                e.print("{s}.ct.{s}(theme, .{f}, .{f}, ", .{ e.use("accordion"), if (faced_) "sectionFace" else "section", std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(n.text_kind, n.text);
                if (faced_) {
                    e.write(", ");
                    e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                    e.write(", ");
                    e.fields(if (n.part == .header) n.part.header else lcgf.widgets_accordion.headerStyle(&e.page.theme), types.Style{}, &.{}, "");
                }
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
            .textfield, .search => if (n.recipe.len > 0) {
                e.print("recipes.ct.textfield(.{f}, .{f}, ", .{ std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.print(", {s})", .{e.config(n)});
            } else {
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
            .menu_button, .menu_list => {
                e.print("{s}.ct.{s}(theme, .{f}, .{f}, ", .{ e.use("menu"), if (n.kind == .menu_button) "button" else "list", std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.menuDef(n.args);
                e.write(", ");
                if (n.kind == .menu_button) e.caption(n.text_kind, n.text) else e.stringList(n.captions);
                e.write(")");
            },
            .popover_button => {
                e.print("{s}.ct.button(theme, .{f}, .{f}, ", .{ e.use("popover"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.caption(n.text_kind, n.text);
                e.write(")");
            },
            .popover => {
                e.print("{s}.ct.popover(theme, .{f}, .{f}, .{{", .{ e.use("popover"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
            .tooltip => {
                e.print("{s}.ct.tooltip(theme, .{f}, .{f}, ", .{ e.use("tooltip"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                e.string(n.text);
                e.write(")");
            },
            .image => {
                e.print("{s}.ct.image(theme, assets[{d}].picture(), ", .{ e.use("image"), n.asset });
                e.structure(n.image, lcgf.widgets_image.Options{});
                e.write(")");
            },
            .dialog => {
                if (restyle or n.part == .backdrop) {
                    e.print("{s}.ct.dialogFace(theme, .{f}, .{f}, ", .{ e.use("dialog"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                    e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                    e.print(", {s}, .{{", .{e.backdrop(n)});
                } else e.print("{s}.ct.dialog(theme, .{f}, .{f}, .{{", .{ e.use("dialog"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
                inner_close.appendSlice(e.arena, "})") catch unreachable;
            },
            .scroll => {
                e.print("{s}.ct.scroll(theme, .{f}, .{f}, .{{", .{ e.use("scroll"), std.zig.fmtId(n.id), std.zig.fmtId(n.bind) });
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
        if (n.spans.len > 0) {
            e.write(", ");
            e.spanList(n.spans);
            e.write(")");
        }
        var all: std.ArrayList(u8) = .empty;
        all.appendSlice(e.arena, inner_close.items) catch unreachable;
        all.appendSlice(e.arena, pos_close.items) catch unreachable;
        all.appendSlice(e.arena, cell_close) catch unreachable;
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

    /// A menu's `widgets_menu.Def`: its item names.
    fn menuDef(e: *Emit, names: []const []const u8) void {
        e.write(".{ .items = ");
        e.stringList(names);
        e.write(" }");
    }

    /// `&.{ "a", "b" }`.
    fn stringList(e: *Emit, list: []const []const u8) void {
        e.write("&.{");
        for (list, 0..) |c, k| {
            e.write(if (k == 0) " " else ", ");
            e.string(c);
        }
        e.write(" }");
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
        if (n.part == .option) {
            const o = n.part.option;
            e.write(", .option = ");
            e.structure(o.face, types.Style{});
            e.write(", .option_text = ");
            e.structure(o.text, types.TextStyle{});
        }
        e.write(" }");
    }

    fn boolSpec(e: *Emit, n: ir.Node) void {
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
    }

    // ---- recipes --------------------------------------------------------------------------

    /// `recipe_<id>`: the id is an identifier, so this is one too.
    fn recipeName(e: *Emit, n: ir.Node) []const u8 {
        return std.fmt.allocPrint(e.arena, "recipe_{s}", .{n.id}) catch unreachable;
    }

    /// The recipe `Config` (spec) or `Options` (runtime) of recipe widget `n`: its recipe, the
    /// page's tokens on a widget, and `disabled` when HTML disables it.
    fn config(e: *Emit, n: ir.Node) []const u8 {
        var validation: std.ArrayList(u8) = .empty;
        if (!std.meta.eql(n.validation, @TypeOf(n.validation){})) {
            std.mem.swap(std.ArrayList(u8), &validation, &e.out);
            e.write(", .validation = ");
            e.structure(n.validation, .{});
            std.mem.swap(std.ArrayList(u8), &validation, &e.out);
        }
        return std.fmt.allocPrint(e.arena, ".{{ .recipe = {s}{s}{s}{s} }}", .{ e.recipeName(n), if (n.kind == .container) "" else ", .tokens = recipe_tokens", if (n.disabled) ", .states = .{ .disabled = true }" else "", validation.items }) catch unreachable;
    }

    /// A box whose rules ask for a state takes hover and press: it is a widget.
    fn boxInteractive(n: ir.Node) bool {
        for (n.recipe) |r| if (r.require.hovered or r.require.held) return true;
        return false;
    }

    /// The runtime box finds its subtree by id for `:focus-within`, so it needs one then too.
    fn boxNamed(n: ir.Node) bool {
        for (n.recipe) |r| if (r.require.hovered or r.require.held or r.require.focus_within) return true;
        return false;
    }

    fn hasRecipes(e: *const Emit) bool {
        for (e.page.nodes.items(.recipe)) |r| if (r.len > 0) return true;
        return false;
    }

    /// One `const recipe_<id>` per recipe widget, which both front ends pass as `.recipe`:
    /// the stock recipe, then a rule per rule of its CSS.
    fn recipes(e: *Emit) void {
        const nodes = e.page.nodes.slice();
        if (!e.hasRecipes()) return;
        e.write(
            \\/// The recipe widgets' tokens: the page theme's colours and sizes under the names the stock
            \\/// recipes read, so they look like the theme widgets beside them.
            \\const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
            \\    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
            \\    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
            \\    .radius = .{ 0, 2, theme.radius, 6, 8 },
            \\    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
            \\}, .{}) }} };
            \\
            \\
        );
        for (0..nodes.len) |i| {
            const n = nodes.get(i);
            if (n.recipe.len == 0) continue;
            if (n.kind == .container) {
                // A box: its static style is the base, its rules are its CSS's alone.
                e.print("/// The recipe of box `{s}` ({s}): its static style, then its CSS in cascade order.\n", .{ n.id, e.where(n.loc) });
                e.print("const {s}: recipes.Recipe = .{{ .parts = &.{{.{{ .id = style.Parts.root, .base = .{{ .box = ", .{e.recipeName(n)});
                e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                e.write(" } }}, .rules = &[_]style.Rule{\n");
                for (n.recipe) |r| e.rule(r, "root", r);
                e.write("} };\n\n");
                continue;
            }
            const stock = switch (n.kind) {
                .button => "button",
                .checkbox => "checkbox",
                .slider => "slider",
                .textfield => "input",
                else => "switch_control",
            };
            const rules = switch (n.kind) {
                .@"switch" => "switch",
                else => stock,
            };
            // A checkbox's or switch's colours and border are its box's; the others' their root's.
            const box = switch (n.kind) {
                .checkbox => "background",
                .@"switch" => "track",
                else => "root",
            };
            e.print("/// The recipe of `{s}` ({s}): the stock {s}'s, then its CSS in cascade order.\n", .{ n.id, e.where(n.loc), stock });
            e.print("const {s}: recipes.Recipe = .{{ .parts = recipes.model.{s}.parts, .rules = &(recipes.model.{s}_rules ++ [_]style.Rule{{\n", .{ e.recipeName(n), stock, rules });
            for (n.recipe) |r| {
                const own = std.mem.eql(u8, box, "root");
                e.rule(r, "root", .{ .text_color = r.text_color, .opacity = r.opacity, .fill = if (own) r.fill else null, .border_color = if (own) r.border_color else null, .border = if (own) r.border else null });
                if (!own) e.rule(r, box, .{ .fill = r.fill, .border_color = r.border_color, .border = r.border });
            }
            e.write("}) };\n\n");
        }
    }

    /// `.{ .part = …, .require = …, .declarations = … }` of what `set` sets; nothing when it
    /// sets nothing.
    fn rule(e: *Emit, r: ir.RecipeRule, part: []const u8, set: ir.RecipeRule) void {
        var decls: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        var any = false;
        inline for (.{ .{ "fill", "fill" }, .{ "text_color", "text_color" }, .{ "border_color", "border_color" }, .{ "border", "border_width" }, .{ "opacity", "opacity" } }) |f| if (@field(set, f[0])) |v| {
            e.print("{s}style.set(.{s}, ", .{ if (any) ", " else " ", f[1] });
            e.value(v);
            e.write(")");
            any = true;
        };
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        if (!any) return;
        e.print("    .{{ .part = style.Parts.{s}", .{part});
        if (r.require.bits() != 0) {
            e.write(", .require = ");
            e.structure(r.require, .{});
        }
        if (r.forbid.bits() != 0) {
            e.write(", .forbid = ");
            e.structure(r.forbid, .{});
        }
        if (!std.meta.eql(r.when, lcgf.style.environment.Conditions{})) {
            e.write(", .when = ");
            e.structure(r.when, .{});
        }
        e.print(", .declarations = &.{{{s} }} }},\n", .{decls.items});
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
            .tip => "lcgf.widgets_tooltip.Tip",
            .menu => "lcgf.widgets_menu.MenuState",
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
            .text, .number, .pair, .@"enum", .select, .tip, .menu => ".{}",
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
        if (e.hasRecipes()) e.write("const recipes = lcgf.theme_recipes;\nconst style = lcgf.style;\n");
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
        e.recipes();
        e.write(body.items);
        if (e.runtime) {
            e.write(rt.items);
            e.runtimePage();
        } else {
            if (page.tokens.items.len > 0)
                e.write("\npub const Ui = w.ComptimeUiTokens(State, spec, theme, Tokens);\npub const Widget = Ui.Events.Widget;\n\n")
            else
                e.write("\npub const Ui = w.ComptimeUi(State, spec, theme);\npub const Widget = Ui.Events.Widget;\n\n");
            if (e.anyRegionStyled()) e.styledTables();
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
            .counter => e.write(text),
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
        var n = e.page.nodes.get(i);
        // A grid's children float: the grid places them (`Grids.place`).
        if (n.parent != none and e.page.nodes.items(.placed)[n.parent].grid != null) n.style.float = true;
        e.uses = n.uses;
        e.text_uses = n.text_uses;
        switch (n.kind) {
            .container, .landmark => {
                if (n.recipe.len > 0) {
                    e.print("_ = recipes.beginBox(f, {s}, {s}, {s}) catch unreachable;", .{ if (boxNamed(n)) e.rtId(n.id, list_depth) else ".none", if (boxInteractive(n)) "true" else "false", e.config(n) });
                    return "recipes.endBox(f);";
                }
                var st = n.style;
                if (n.kind == .landmark) st.role = std.meta.stringToEnum(types.Role, n.landmark).?;
                e.write("_ = f.open(.none, ");
                e.fields(st, types.Style{}, &.{}, n.params_expr);
                e.write(");");
                return "f.close();";
            },
            .section => {
                const faced_ = e.rtFace(n).len > 0 or n.part == .header;
                e.print("_ = {s}.{s}(f, &theme, {s}, {s}, ", .{ e.use("accordion"), if (faced_) "openFace" else "open", e.rtId(n.id, list_depth), e.ref(n.bind) });
                e.rtCaption(n.text_kind, n.text);
                if (faced_) {
                    e.write(", ");
                    e.fields(n.style, types.Style{}, &.{}, n.params_expr);
                    e.write(", ");
                    e.fields(if (n.part == .header) n.part.header else lcgf.widgets_accordion.headerStyle(&e.page.theme), types.Style{}, &.{}, "");
                }
                e.write(");");
                return "accordion.close(f);";
            },
            .label, .heading, .text => {
                // A counted list marker formats into a buffer of its own statement.
                if (n.text_kind == .counter) e.write("{ var mark: [64]u8 = undefined; ");
                defer if (n.text_kind == .counter) e.write(" }");
                const plain = n.kind == .label and !styled(n) and std.meta.eql(n.style, n.base_style) and std.meta.eql(n.text_style, n.base_text) and n.params_expr.len == 0 and n.uses.len == 0 and n.text_uses.color == none and n.text_uses.px == none;
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
                if (styled(n)) e.print(" {s}.rows[{s}.len] = f.texts().len - 1; {s}.styles[{s}.len] = {d}; {s}.len += 1;", .{ e.para_var, e.para_var, e.para_var, e.para_var, e.paragraphIndex(n), e.para_var });
                return "";
            },
            .button, .link => {
                const h = e.clickHandler(n.id);
                const face = if (n.recipe.len == 0) e.rtFace(n) else "";
                const ts = n.recipe.len == 0 and n.kind == .button and !std.meta.eql(n.text_style, n.base_text);
                const name = if (face.len > 0) e.faced(@tagName(n.kind), face) else if (ts) "buttonStyled" else @tagName(n.kind);
                if (n.recipe.len > 0)
                    e.print("{s}(recipes.button(f, {s}, ", .{ if (h != null) "if (" else "_ = ", e.rtId(n.id, list_depth) })
                else
                    e.print("{s}{s}.{s}(f, &theme, {s}, ", .{ if (h != null) "if (" else "_ = ", e.use(@tagName(n.kind)), name, e.rtId(n.id, list_depth) });
                e.rtCaption(n.text_kind, n.text);
                // A button's Face and buttonStyled take its caption's text style.
                if (ts) {
                    e.write(", ");
                    e.structure(n.text_style, types.TextStyle{});
                } else if (face.len > 0 and n.kind == .button) e.print(", {s}.labelText(&theme)", .{e.use("label")});
                e.write(face);
                if (n.recipe.len > 0) e.print(", {s}) catch unreachable", .{e.config(n)});
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
                if (n.recipe.len > 0) {
                    e.print("_ = recipes.{s}(f, {s}, {s}, ", .{ if (n.kind == .checkbox) "checkbox" else "switchControl", e.rtId(n.id, list_depth), e.ref(n.bind) });
                    e.rtCaption(n.text_kind, n.text);
                    e.print(", {s}) catch unreachable;", .{e.config(n)});
                    return "";
                }
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
                if (n.recipe.len > 0) {
                    e.print("_ = recipes.slider(f, {s}, {s}, {d}, {d}, {s}) catch unreachable;", .{ e.rtId(n.id, list_depth), e.ref(n.bind), n.range[0], n.range[1], e.config(n) });
                    return "";
                }
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
            } else if (n.recipe.len > 0) {
                e.print("_ = recipes.textfield(f, {s}, &{s}, ", .{ e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                e.rtCaption(if (n.text_kind == .none) .literal else n.text_kind, n.text);
                e.print(", {s}) catch unreachable;", .{e.config(n)});
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
            .menu_button => {
                e.print("_ = {s}.trigger(f, &theme, \"{s}\", ", .{ e.use("menu"), n.id });
                e.rtCaption(n.text_kind, n.text);
                e.write(");");
                return "";
            },
            .menu_list => {
                e.print("_ = {s}.show(f, &theme, \"{s}\", ", .{ e.use("menu"), n.id });
                e.menuDef(n.args);
                e.print(", &{s}, ", .{e.stateRef(n.bind)});
                e.stringList(n.captions);
                e.write(");");
                return "";
            },
            .popover_button => {
                e.print("_ = {s}.trigger(f, &theme, \"{s}\", &{s}, ", .{ e.use("popover"), n.id, e.stateRef(n.bind) });
                e.rtCaption(n.text_kind, n.text);
                e.write(");");
                return "";
            },
            .popover => {
                e.print("if ({s}.begin(f, &theme, \"{s}\", &{s})) {{", .{ e.use("popover"), n.id, e.stateRef(n.bind) });
                return e.arena.dupe(u8, "popover.end(f); }") catch unreachable;
            },
            .tooltip => {
                e.print("{s}.update(f, &{s}, f.ctx.inter.response(.from(\"{s}\"))); {s}.show(f, &theme, \"{s}\", &{s}, ", .{ e.use("tooltip"), e.stateRef(n.bind), n.id, e.use("tooltip"), n.id, e.stateRef(n.bind) });
                e.string(n.text);
                e.write(");");
                return "";
            },
            .image => {
                e.print("_ = {s}.image(f, &theme, assets[{d}].picture(), ", .{ e.use("image"), n.asset });
                e.structure(n.image, lcgf.widgets_image.Options{});
                e.write(");");
                return "";
            },
            .select => {
                const face = e.rtFace(n);
                e.print("_ = {s}.{s}(f, &theme, \"{s}\", comptime {s}.positional({d}), &{s}, &.{{", .{ e.use("select"), e.faced("button", face), n.id, e.use("select"), n.captions.len, e.stateRef(n.bind) });
                e.rtTexts(n.captions);
                e.write(" }");
                e.write(face);
                e.write(");");
                return "";
            },
            .select_list => {
                e.print("{s}.{s}(f, &theme, \"{s}\", comptime {s}.positional({d}), &{s}, &.{{", .{ e.use("select"), if (n.part == .option) "listFace" else "listGrouped", n.id, e.use("select"), n.captions.len, e.stateRef(n.bind) });
                e.rtTexts(n.captions);
                e.write(" }, &.{");
                for (n.groups, 0..) |g, k| {
                    e.print("{s}.{{ .at = {d}, .label = ", .{ if (k == 0) " " else ", ", g.at });
                    e.string(g.label);
                    e.write(" }");
                }
                e.write(if (n.groups.len > 0) " }" else "}");
                if (n.part == .option) {
                    const o = n.part.option;
                    e.write(", ");
                    e.structure(o.face, types.Style{});
                    e.write(", ");
                    e.structure(o.text, types.TextStyle{});
                }
                e.write(");");
                return "";
            },
            .dialog => {
                const style = if (e.rtFace(n).len == 0 and n.part == .backdrop) std.fmt.allocPrint(e.arena, ", {s}", .{e.styleText(n.style, n.params_expr)}) catch unreachable else e.rtFace(n);
                const face = if (style.len > 0) std.fmt.allocPrint(e.arena, "{s}, {s}", .{ style, e.backdrop(n) }) catch unreachable else "";
                e.print("if ({s}.{s}(f, &theme, \"{s}\", &{s}{s})) {{", .{ e.use("dialog"), e.faced("begin", face), n.id, e.stateRef(n.bind), face });
                return e.arena.dupe(u8, "dialog.end(f); }") catch unreachable;
            },
            .scroll => {
                e.print("{s}.open(f, &theme, {s}, &{s});", .{ e.use("scroll"), e.rtId(n.id, list_depth), e.stateRef(n.bind) });
                return std.fmt.allocPrint(e.arena, "scroll.close(f, &theme, {s}, {s});", .{ e.rtId(n.id, list_depth), e.stateRef(n.bind) }) catch unreachable;
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

    /// A dialog's backdrop fill: its `::backdrop` colour, or `dialog.dim`.
    fn backdrop(e: *Emit, n: ir.Node) []const u8 {
        if (n.part != .backdrop) return std.fmt.allocPrint(e.arena, "{s}.dim", .{e.use("dialog")}) catch unreachable;
        return @import("lower.zig").colorExpr(e.arena, n.part.backdrop);
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
        e.styledTables();
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
        // Fields first, then the declarations: Zig allows no declaration between fields.
        var decls: std.ArrayList(u8) = .empty;
        const named = e.namedCount();
        if (named > 0) e.print(
            \\    /// Tree rows of the nodes with an accessible name, as this frame built them (none
            \\    /// for one it did not build).
            \\    named: [{d}]u32 = @splat(lcgf.types.none),
            \\
        , .{named});
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        if (named > 0) e.print(
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
        , .{e.namedList()});
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
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
        const sides = e.hasSides();
        if (regions) e.print(
            \\    /// Tree rows of the page's regions as this frame built them (none for one it did not
            \\    /// build): `end` rounds each one's content from the region's corner, as the comptime
            \\    /// page does (`layout.snapSubtree`).
            \\    regions: [{d}]u32 = @splat(lcgf.types.none),
            \\
        , .{e.regionCount()});
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        // A page with a baseline-aligned wrapping row compiles the flex passes with per-line
        // baselines (`FlexOptions.line_baseline`): the `...Opts` forms, over the paragraph
        // font when there is one.
        const opts_font = e.fontExpr(paragraphs);
        const opts_args = std.fmt.allocPrint(e.arena, "{s}, &ui.flex.?, .{{ .line_baseline = true }}", .{opts_font}) catch unreachable;
        if (!sides and flex and e.lineBaseline()) {
            if (regions) e.print(
                \\    /// Lays the frame out (with this page's flex rules, per-line baselines compiled in),
                \\    /// puts each region's content on the grid from the region's snapped corner, and paints.
                \\    pub fn end(ui: *Ui, f: *lcgf.frame.Frame, font: lcgf.protocol.Mono) lcgf.context.Output {{
                \\        f.layoutFlexOpts({s});
                \\        for (ui.regions) |row| if (row != lcgf.types.none) lcgf.layout.snapSubtree(f.tree(), row);
                \\        return f.{s};
                \\    }}
                \\
                \\
            , .{ opts_args, if (paragraphs) std.fmt.allocPrint(e.arena, "finishParagraphs({s})", .{e.fontExpr(true)}) catch unreachable else "finish()" }) else e.print(
                \\    /// Ends the frame with this page's flex rules, per-line baselines compiled in
                \\    /// (`Frame.endFlexOpts`).
                \\    pub fn end(ui: *Ui, f: *lcgf.frame.Frame, font: lcgf.protocol.Mono) lcgf.context.Output {{
                \\        return f.endFlexOpts({s});
                \\    }}
                \\
                \\
            , .{opts_args});
        } else if (!sides and regions) e.print(
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
            if (flex and paragraphs) "flex rules and paragraph styles" else if (flex) "flex rules" else if (paragraphs) "paragraph styles" else "font",
            if (flex and paragraphs) "layoutFlexParagraphs" else if (flex) "layoutFlex" else if (paragraphs) "layoutParagraphs" else "layoutWith",
            e.fontExpr(paragraphs),
            if (flex) ", &ui.flex.?" else "",
            if (paragraphs) std.fmt.allocPrint(e.arena, "finishParagraphs({s})", .{e.fontExpr(true)}) catch unreachable else "finish()",
        }) else if (!sides and (flex or paragraphs)) e.print(
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
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        if (sides) e.write(
            \\    /// The side tables (grids, anchors, sticky nodes, layers) the page writes while it
            \\    /// builds, used by `end`. They point into `side_buf`: a Ui does not move once built.
            \\    side_buf: [side_bytes]u8 align(lcgf.mem.column_align) = undefined,
            \\    sides: ?Sides = null,
            \\
        );
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        if (e.hasLayers()) e.write(
            \\    /// Starts the frame with the pointer's hit in last frame's paint order
            \\    /// (`hit.atLayered`), so a raised box takes the clicks over what it covers.
            \\    pub fn begin(ui: *Ui, ctx: *lcgf.context.Context, in: *const lcgf.input.Input) lcgf.frame.Frame {
            \\        const sd = if (ui.sides) |*sd| sd else return ctx.begin(in);
            \\        return ctx.beginWithHit(in, lcgf.hit.atLayered(&ctx.trees[ctx.cur], sd.ly.c.layer, in.pointer[0], in.pointer[1], .any));
            \\    }
            \\
            \\
        );
        if (sides) {
            // Lays out with the side tables (and flex rules), rounds each region's content from
            // its corner, and paints (in layer order, with the paragraph decorations).
            e.write(
                \\    /// Ends the frame with this page's side tables (`Frame.layoutSides`, `finishSides`).
                \\    pub fn end(ui: *Ui, f: *lcgf.frame.Frame, font: lcgf.protocol.Mono) lcgf.context.Output {
                \\        const sd = &ui.sides.?;
                \\        const sides: lcgf.frame.Frame.Sides = .{
            );
            const pos = e.positionedRows();
            if (e.hasGrid()) e.write(" .grids = &sd.gs,");
            if (pos[0] > 0) e.write(" .anchors = &sd.an,");
            if (pos[1] > 0) e.write(" .sticky = &sd.st,");
            if (e.hasLayers()) e.write(" .layers = &sd.ly,");
            if (flex) e.write(" .flex = &ui.flex.?,");
            // A baseline-aligned wrapping row compiles in the per-line baselines, as `end` does
            // without side tables (`FlexOptions.line_baseline`).
            if (flex and e.lineBaseline())
                e.print(" }};\n        f.layoutSidesOpts({s}, sides, .{{ .line_baseline = true }});\n", .{e.fontExpr(paragraphs)})
            else
                e.print(" }};\n        f.layoutSides({s}, sides);\n", .{e.fontExpr(paragraphs)});
            if (regions) e.write("        for (ui.regions) |row| if (row != lcgf.types.none) lcgf.layout.snapSubtree(f.tree(), row);\n");
            e.print("        return f.finishSides({s}, sides);\n    }}\n\n", .{e.fontExpr(paragraphs)});
        }
        std.mem.swap(std.ArrayList(u8), &decls, &e.out);
        if (tokens.len > 0) e.write(
            \\    /// The caller's theme tokens; point it at your table.
            \\    tokens: *const ThemeTable = &default_tokens,
            \\    /// The table's generation the last build read.
            \\    seen: u32 = 0,
            \\
            \\
        );
        e.write(decls.items);
        if (tokens.len > 0) e.write(
            \\    /// Whether the tokens changed since the last build, which then lays the page out again.
            \\    pub fn themeChanged(ui: *const Ui) bool {
            \\        return ui.tokens.changedSince(ui.seen);
            \\    }
            \\
            \\
        );
        if (paragraphs) e.print(
            \\    /// This frame's styled runs, for a host with a real shaper: `f.endTextStyled(stack,
            \\    /// ascent, ui.styled(), rows, rects)` in place of `end`.
            \\    pub fn styled(ui: *const Ui) lcgf.protocol.Styled {{
            \\        return {s};
            \\    }}
            \\
            \\
        , .{e.styledExpr()});
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
        if (sides) {
            e.write(
                \\        if (ui.sides == null) {
                \\            var carver: lcgf.mem.Carver = .{ .buf = &ui.side_buf };
                \\            ui.sides = carveSides(&carver);
                \\        }
                \\
            );
            const pos = e.positionedRows();
            if (e.hasGrid()) e.write("        const gs = &ui.sides.?.gs;\n");
            if (pos[0] > 0) e.write("        const an = &ui.sides.?.an;\n        const vp: lcgf.types.Rect = .{ .x1 = f.in.viewport[0], .y1 = f.in.viewport[1] };\n");
            if (pos[1] > 0) e.write("        const st = &ui.sides.?.st;\n");
            if (e.hasLayers()) e.write("        const ly = &ui.sides.?.ly;\n");
        }
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
            } else e.rtOpenGrid(i, lists);
            if (in_choice) close = std.fmt.allocPrint(e.arena, "{s}{s}}},", .{ close, if (close.len > 0) " " else "" }) catch unreachable;
            if (nodes.items(.kind)[i] == .list) lists += 1;
            e.print(" // {s}\n", .{e.where(nodes.items(.loc)[i])});
            // A leaf inside a choice closes its prong at once.
            const leaf = switch (nodes.items(.kind)[i]) {
                .container, .landmark, .when, .list, .choice, .dialog, .section, .popover, .scroll => false,
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
            .choose => e.print("        if ({s}.chosen == {d}) h.{f}(ui); // {s}\n", .{ e.stateRef(h.field), h.item + 1, std.zig.fmtId(h.name), e.where(h.loc) }),
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

    const Styled = struct { paragraph: lcgf.text_stack.Paragraph, decoration: lcgf.text_decorations.Style, spans: []const lcgf.protocol.Span };

    /// A label `MonoParagraphs` measures: a paragraph style, a decoration or inline runs.
    fn styled(n: ir.Node) bool {
        return n.paragraph != null or n.decoration != null or n.spans.len > 0;
    }

    fn styledOf(n: ir.Node) Styled {
        return .{ .paragraph = n.paragraph orelse .{}, .decoration = n.decoration orelse .{}, .spans = n.spans };
    }

    fn sameStyled(a: Styled, b: Styled) bool {
        if (!std.meta.eql(a.paragraph, b.paragraph) or !std.meta.eql(a.decoration, b.decoration) or a.spans.len != b.spans.len) return false;
        for (a.spans, b.spans) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// The distinct (paragraph, decoration, spans) of the page's styled labels, in first-use
    /// order: `ComptimeUi`'s table, so both frontends index it alike.
    fn paragraphTable(e: *Emit) []const Styled {
        var out: std.ArrayList(Styled) = .empty;
        for (0..e.page.nodes.len) |i| {
            const n = e.page.nodes.get(i);
            if (!styled(n)) continue;
            const st = styledOf(n);
            for (out.items) |q| {
                if (sameStyled(st, q)) break;
            } else out.append(e.arena, st) catch unreachable;
        }
        return out.items;
    }

    fn paragraphIndex(e: *Emit, n: ir.Node) usize {
        for (e.paragraphTable(), 0..) |q, i| if (sameStyled(styledOf(n), q)) return i;
        unreachable;
    }

    fn anySpans(e: *Emit) bool {
        for (e.page.nodes.items(.spans)) |sp| if (sp.len > 0) return true;
        return false;
    }

    /// `&.{ .{ .start = k, .style = .{…} }, … }`.
    fn spanList(e: *Emit, spans: []const lcgf.protocol.Span) void {
        e.write("&.{");
        for (spans, 0..) |sp, k| {
            e.print("{s} .{{ .start = {d}, .style = ", .{ if (k == 0) "" else ",", sp.start });
            e.structure(sp.style, types.TextStyle{});
            if (!std.meta.eql(sp.decoration, lcgf.text_decorations.Style{})) {
                e.write(", .decoration = ");
                e.decoration(sp.decoration);
            }
            e.write(" }");
        }
        e.write(if (spans.len > 0) " }" else "}");
    }

    /// The page's style table (paragraphs, and spans and decorations when any label has
    /// them), at file scope.
    fn styledTables(e: *Emit) void {
        if (e.paragraphTable().len > 0) {
            e.write("\n/// The page's paragraph styles, indexed by `Ui.paragraphs.styles`.\nconst paragraph_table = [_]lcgf.text_stack.Paragraph{");
            for (e.paragraphTable()) |pa| {
                e.write(" ");
                e.paragraph(pa.paragraph);
                e.write(",");
            }
            e.write(" };\n");
        }
        if (e.anySpans()) {
            e.write("/// Their style runs, row for row.\nconst span_table = [_][]const lcgf.protocol.Span{");
            for (e.paragraphTable()) |pa| {
                e.write(" ");
                e.spanList(pa.spans);
                e.write(",");
            }
            e.write(" };\n");
        }
        if (e.anyDecoration()) {
            e.write("/// Their decorations, row for row.\nconst decoration_table = [_]lcgf.text_decorations.Style{");
            for (e.paragraphTable()) |pa| {
                e.write(" ");
                e.decoration(pa.decoration);
                e.write(",");
            }
            e.write(" };\n");
        }
    }

    /// Whether a styled label is inside region `each`, which then keeps its own rows.
    fn regionStyled(e: *Emit, each: u32) bool {
        for (0..e.page.nodes.len) |i| if (styled(e.page.nodes.get(i)) and e.eachOf(@intCast(i)) == each) return true;
        return false;
    }

    fn anyRegionStyled(e: *Emit) bool {
        for (0..e.page.nodes.len) |i| if (e.page.nodes.items(.kind)[i] == .each and e.regionStyled(@intCast(i))) return true;
        return false;
    }

    /// The page's `protocol.Styled` over `ui.paragraphs`.
    fn styledExpr(e: *Emit) []const u8 {
        return std.fmt.allocPrint(e.arena, ".{{ .rows = ui.paragraphs.rows[0..ui.paragraphs.len], .styles = ui.paragraphs.styles[0..ui.paragraphs.len], .table = &paragraph_table{s}{s} }}", .{
            if (e.anyDecoration()) ", .decorations = &decoration_table" else "",
            if (e.anySpans()) ", .spans = &span_table" else "",
        }) catch unreachable;
    }

    /// The `MonoParagraphsOf` this page needs: span and decoration code only when it has them.
    fn fontType(e: *Emit) []const u8 {
        return std.fmt.allocPrint(e.arena, "lcgf.protocol.MonoParagraphsOf(.{{ .spans = {}, .decorations = {} }})", .{ e.anySpans(), e.decorates() }) catch unreachable;
    }

    /// The font `Ui.end` measures with: `font`, or the page's `MonoParagraphsOf` over it.
    fn fontExpr(e: *Emit, paragraphs: bool) []const u8 {
        if (!paragraphs) return "font";
        return std.fmt.allocPrint(e.arena, "{s}{{ .mono = font, .rows = ui.paragraphs.rows[0..ui.paragraphs.len], .styles = ui.paragraphs.styles[0..ui.paragraphs.len], .table = &paragraph_table{s}{s} }}", .{
            e.fontType(),
            if (e.anyDecoration()) ", .decorations = &decoration_table" else "",
            if (e.anySpans()) ", .spans = &span_table" else "",
        }) catch unreachable;
    }

    /// Whether the page draws any decoration: a label's own or a span's.
    fn decorates(e: *Emit) bool {
        if (e.anyDecoration()) return true;
        for (e.page.nodes.items(.spans)) |list| for (list) |sp| {
            if (sp.decoration.underline or sp.decoration.overline or sp.decoration.strike) return true;
        };
        return false;
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

    /// Whether a node is a baseline-aligned wrapping row (`FlexOptions.line_baseline`).
    fn lineBaseline(e: *Emit) bool {
        for (e.page.nodes.items(.flex)) |fs| if (fs.wrap and fs.baseline) return true;
        return false;
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

    /// Whether the runtime page writes side tables: grids (F7), anchors, sticky nodes or
    /// layers (F17).
    fn hasSides(e: *Emit) bool {
        const pos = e.positionedRows();
        return e.hasGrid() or pos[0] > 0 or pos[1] > 0 or e.hasLayers();
    }

    /// Whether a node is a grid container (engine spec F7).
    fn hasGrid(e: *Emit) bool {
        for (e.page.nodes.items(.placed)) |pl| if (pl.grid != null) return true;
        return false;
    }

    /// The items of grid container `i`: its children's cells.
    fn gridItemsOf(e: *Emit, i: u32) []const lcgf.grid.Item {
        var out: std.ArrayList(lcgf.grid.Item) = .empty;
        for (e.page.nodes.items(.parent), e.page.nodes.items(.placed)) |p, pl| if (p == i) out.append(e.arena, pl.cell orelse .{}) catch unreachable;
        return out.items;
    }

    /// `rtOpenFlex`, with a grid child placed before its statement (`Grids.place`), and the
    /// side-table rows of a grid container (`Grids.declare`) or a positioned node
    /// (`Anchors.place`, `Sticky.push`, `Layers.own`) written for the node its statement makes.
    fn rtOpenGrid(e: *Emit, i: u32, list_depth: u32) []const u8 {
        const nodes = e.page.nodes.slice();
        const parent = nodes.items(.parent)[i];
        if (parent != none and nodes.items(.placed)[parent].grid != null) {
            e.print("_ = gs.place(k{d}, @intCast(f.tree().len), ", .{parent});
            e.gridItem(nodes.items(.placed)[i].cell orelse .{});
            e.write("); ");
        }
        const n = nodes.get(i);
        if (n.placed.grid == null and n.placed.anchor == null and n.placed.sticky == null and n.placed.layer == 0) return e.rtOpenFlex(i, list_depth);
        var statement: std.ArrayList(u8) = .empty;
        std.mem.swap(std.ArrayList(u8), &statement, &e.out);
        const close = e.rtOpen(i, list_depth);
        std.mem.swap(std.ArrayList(u8), &statement, &e.out);
        // lower.checkRuntime admits these only on nodes whose statement is `_ = call;`.
        e.print("const n{d}: u32 = @backingInt({s});", .{ i, statement.items[4 .. statement.items.len - 1] });
        if (flexOf(n)) |fs| {
            e.print(" fx.set(n{d}, &", .{i});
            e.structure(fs, FlexStyle{});
            e.write(");");
        }
        if (n.placed.grid) |d| {
            e.print(" const k{d} = gs.declare(n{d}, ", .{ i, i });
            e.gridDecl(d);
            e.print(", {d});", .{lcgf.grid.implicitTracks(d, e.gridItemsOf(i))});
        }
        if (n.placed.anchor) |a| {
            e.print(" _ = an.place(n{d}, ", .{i});
            e.anchorPlace(a);
            e.write(", vp);");
        }
        if (n.placed.sticky) |top| e.print(" _ = st.push(n{d}, lcgf.widgets_scroll.scrollerOf(f.tree(), f.tree().c.parent[n{d}]), .{{ 0, {d} }}, .{{ false, true }});", .{ i, i, top });
        if (n.placed.layer != 0) e.print(" ly.c.own[n{d}] = {d};", .{ i, n.placed.layer });
        return close;
    }

    /// How many copies of node `i` a frame can build: the product of its lists' maxima.
    fn copies(e: *Emit, i: u32) u32 {
        var k: u32 = 1;
        var p = e.page.nodes.items(.parent)[i];
        while (p != none) : (p = e.page.nodes.items(.parent)[p]) if (e.page.nodes.items(.kind)[p] == .list) {
            k *= e.page.nodes.items(.max)[p];
        };
        return k;
    }

    /// Rows of anchors and sticky nodes the runtime page needs, counting list copies.
    fn positionedRows(e: *Emit) [2]u32 {
        var out: [2]u32 = .{ 0, 0 };
        for (e.page.nodes.items(.placed), 0..) |pl, i| {
            if (pl.anchor != null) out[0] += e.copies(@intCast(i));
            if (pl.sticky != null) out[1] += e.copies(@intCast(i));
        }
        return out;
    }

    fn hasLayers(e: *Emit) bool {
        for (e.page.nodes.items(.placed)) |pl| if (pl.layer != 0) return true;
        return false;
    }

    /// The runtime page's grid capacity: its grids at their most implicit tracks, once per
    /// copy of the list each is in.
    fn gridCapacity(e: *Emit) lcgf.grid.Grids.Capacity {
        var cap: lcgf.grid.Grids.Capacity = .{ .grids = 0, .tracks = 0, .items = 0, .cells = 1 };
        for (e.page.nodes.items(.placed), 0..) |pl, i| if (pl.grid) |d| {
            const times = e.copies(@intCast(i));
            const items = e.gridItemsOf(@intCast(i));
            const extra = lcgf.grid.implicitTracks(d, items);
            var count: [2]u32 = .{ if (d.repeat) |r| r.max else @max(@as(u32, @intCast(d.columns.len)), 1), @max(@as(u32, @intCast(d.rows.len)), 1) };
            const given: u32 = @intCast(if (d.growAxis() == 0) d.columns.len else d.rows.len);
            count[d.growAxis()] = @max(count[d.growAxis()], given + extra);
            cap.grids += times;
            cap.tracks += times * (count[0] + count[1]);
            cap.items += times * @as(u32, @intCast(items.len));
            cap.cells = @max(cap.cells, count[0] * count[1]);
        };
        return cap;
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
            \\            var f = {s};
            \\            p.ui.build(&f{s});
            \\            const out = {s};
            \\            p.ui.dispatch(h);
            \\            return out;
            \\        }}
            \\    }};
            \\}}
            \\
            \\
        , .{ nodes, texts, strings, if (regions) ", data: anytype" else "", if (e.hasLayers()) "p.ui.begin(ctx, in)" else "ctx.begin(in)", if (regions) ", data" else "", if (e.hasFlex() or regions or e.hasSides()) "p.ui.end(&f, .{})" else "f.end(.{})" });
        if (e.hasSides()) {
            const pos = e.positionedRows();
            e.write("/// The runtime page's side tables, and their bytes.\nconst Sides = struct {");
            if (e.hasGrid()) e.write(" gs: lcgf.grid.Grids,");
            if (pos[0] > 0) e.write(" an: lcgf.overlay.Anchors,");
            if (pos[1] > 0) e.write(" st: lcgf.scroll.Sticky,");
            if (e.hasLayers()) e.write(" ly: lcgf.overlay.Layers,");
            e.write(" };\n\nfn carveSides(carver: *lcgf.mem.Carver) Sides {\n    var sd: Sides = undefined;\n");
            if (e.hasGrid()) {
                const cap = e.gridCapacity();
                e.print("    sd.gs = lcgf.grid.Grids.init(carver, .{{ .grids = {d}, .tracks = {d}, .items = {d}, .cells = {d} }});\n", .{ cap.grids, cap.tracks, @max(cap.items, 1), cap.cells });
            }
            if (pos[0] > 0) e.print("    sd.an = lcgf.overlay.Anchors.init(carver, {d});\n", .{pos[0]});
            if (pos[1] > 0) e.print("    sd.st = lcgf.scroll.Sticky.init(carver, {d});\n", .{pos[1]});
            if (e.hasLayers()) e.write("    sd.ly = lcgf.overlay.Layers.init(carver, limits.nodes);\n    if (carver.buf != null) sd.ly.reset();\n");
            e.write(
                \\    return sd;
                \\}
                \\
                \\const side_bytes = blk: {
                \\    @setEvalBranchQuota(20_000);
                \\    var carver: lcgf.mem.Carver = .{ .buf = null };
                \\    _ = carveSides(&carver);
                \\    break :blk carver.off;
                \\};
                \\
                \\
            );
        }
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
            if (h.each.len == 0 and h.event != .choose and (h.event != .change or textChange(h))) prongs.put(e.arena, h.widget, {}) catch unreachable;
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
        for (hs) |h| if (h.event == .choose)
            e.print("            if (p.ui.signals.state.{f}.chosen == {d}) h.{f}(&p.ui); // {s}\n", .{ std.zig.fmtId(h.field), h.item + 1, std.zig.fmtId(h.name), e.where(h.loc) });
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
            if (n.level == 1) e.print(
                \\        /// Where region `{s}`'s content is measured, with no input, before the page's layout.
                \\        {s}_measure_buf: [lcgf.context.Context.requiredBytes({s}_limits)]u8 align(lcgf.mem.column_align) = undefined,
                \\        {s}_measure: ?lcgf.context.Context = null,
                \\
            , .{ n.id, n.id, n.id, n.id });
            if (e.regionStyled(@intCast(i))) e.print(
                \\        /// The region's labels with a paragraph style, decoration or inline runs this frame.
                \\        {s}_paragraphs: struct {{ rows: [{s}_limits.texts]u32 = undefined, styles: [{s}_limits.texts]u16 = undefined, len: u32 = 0 }} = .{{}},
                \\
            , .{ n.id, n.id, n.id });
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
        // A region sized by its content (a fit axis) is measured first, in a Context of its
        // own that takes no input, and the page is laid out again around the sizes measured
        // (`ComptimeUi.rebuild`; the frame's event stays the first layout's). Every region is
        // then built with the frame's input against its final rect.
        var fits = false;
        for (0..e.page.nodes.len) |i_| {
            const i: u32 = @intCast(i_);
            if (e.page.nodes.items(.kind)[i] != .each or e.page.nodes.items(.level)[i] != 1) continue;
            if (!fits) e.write("            var refit = false;\n");
            fits = true;
            e.eachFrame(i, 0, .measure);
        }
        if (fits) e.write(
            \\            if (refit) {
            \\                const event = out.event;
            \\                out = p.ui.rebuild(in);
            \\                out.event = event;
            \\            }
            \\
        );
        var k: u32 = 0;
        for (0..e.page.nodes.len) |i_| {
            const i: u32 = @intCast(i_);
            if (e.page.nodes.items(.kind)[i] != .each) continue;
            e.eachFrame(i, k, .whole);
            k += 1;
        }
    }

    /// Region `each`, the `slot`-th of the page: built with the frame's input and composed
    /// (`whole`), or, for a fit region, measured (`measure`): built with no input in its own
    /// Context, with throwaway events and editors, its content's size recorded for the layout.
    fn eachFrame(e: *Emit, each: u32, slot: u32, phase: enum { whole, measure }) void {
        const n = e.page.nodes.get(each);
        const fit = n.level == 1;
        const measure = phase == .measure;
        e.print("            {{ // lcgf-each=\"{s} in {s}\", {s}{s}\n", .{ n.text, n.bind, e.where(n.loc), if (measure) ", measured" else "" });
        if (!measure) e.eachChecks(each, "                ");
        // The copies' statements first: they name `ui` only when they read the view state.
        const region_styled = !e.runtime and e.regionStyled(each);
        const para_var = std.fmt.allocPrint(e.arena, "p.{s}_paragraphs", .{n.id}) catch unreachable;
        if (region_styled) e.para_var = para_var;
        const owner = e.owner;
        if (measure) e.owner = "measure";
        const body = e.eachLoop(each);
        e.owner = owner;
        e.para_var = "ui.paragraphs";
        if (measure) {
            // What the body writes, kept from the Page: the editors' state, copied. Its events
            // are the frame's, which a measure with no input never sets.
            var editors: std.ArrayList(u8) = .empty;
            for (0..e.page.nodes.len) |k| {
                const c = e.page.nodes.get(k);
                const texty = c.kind == .textfield or c.kind == .search or c.kind == .textarea;
                if (texty and e.eachOf(@intCast(k)) == each) editors.print(e.arena, " .edit_{s} = p.edit_{s}, .edit_{s}_row = p.edit_{s}_row,", .{ c.id, c.id, c.id, c.id }) catch unreachable;
            }
            if (editors.items.len > 0) e.print("                var measure = .{{{s} }};\n                _ = &measure;\n", .{editors.items});
        }
        if (std.mem.indexOf(u8, body, "ui.") != null) e.write("                const ui = &p.ui;\n");
        const ctx = if (measure) std.fmt.allocPrint(e.arena, "{s}_measure", .{n.id}) catch unreachable else n.id;
        e.print(
            \\                if (p.{s} == null) p.{s} = lcgf.context.Context.init(&p.{s}_buf, {s}_limits) catch unreachable;
            \\                const rect = out.tree.rect(out.tree.find(.from("{s}")));
            \\
        , .{ ctx, ctx, ctx, n.id, n.id });
        // The measure sees no pointer, buttons, keys or text: the content as it stands.
        if (measure) e.write("                var region_in = lcgf.ct_interop.regionInput(&.{ .viewport = in.viewport, .time = in.time, .dt = in.dt, .pointer = @splat(-lcgf.types.inf) }, .{ rect.x0, rect.y0, rect.x1, rect.y1 });\n") else e.print("                {s} region_in = lcgf.ct_interop.regionInput(in, .{{ rect.x0, rect.y0, rect.x1, rect.y1 }});\n", .{if (fit) "var" else "const"});
        e.print(
            \\{s}
            \\                var region_frame = p.{s}.?.begin(&region_in);
            \\                const f = &region_frame;
            \\
        , .{ fitViewport(e, n), ctx });
        const flex = e.regionFlex(each);
        if (flex) e.print(
            \\                if (p.{s}_flex == null) {{
            \\                    var carver: lcgf.mem.Carver = .{{ .buf = &p.{s}_flex_buf }};
            \\                    p.{s}_flex = lcgf.flex.Flex.init(&carver, {s}_limits.nodes);
            \\                }}
            \\                const fx = &p.{s}_flex.?;
            \\
        , .{ n.id, n.id, n.id, n.id, n.id });
        if (region_styled) e.print("                {s}.len = 0;\n", .{para_var});
        e.write(body);
        // Styled labels end through the paragraph forms, flex rules through the flex ones.
        const end = if (region_styled) std.fmt.allocPrint(e.arena, "f.{s}({s}{{ .rows = {s}.rows[0..{s}.len], .styles = {s}.styles[0..{s}.len], .table = &paragraph_table{s}{s} }}{s})", .{
            if (flex) "endFlexParagraphs" else "endParagraphs",
            e.fontType(),
            para_var,
            para_var,
            para_var,
            para_var,
            if (e.anyDecoration()) ", .decorations = &decoration_table" else "",
            if (e.anySpans()) ", .spans = &span_table" else "",
            if (flex) ", fx" else "",
        }) catch unreachable else if (flex) "f.endFlex(.{}, fx)" else "f.end(.{})";
        if (measure) e.print(
            \\                // The content's size before snapping, for the page's layout, so the page
            \\                // around it lays out as it would around the content itself.
            \\                const content = {s}.tree.c.size;
            \\                if (lcgf.ct_interop.setFit(&p.ui, .{f}, .{{ content[0][1], content[1][1] }})) refit = true;
            \\            }}
            \\
        , .{ end, std.zig.fmtId(n.id) }) else e.print(
            \\                const region_out = {s};{s}
            \\                if (lcgf.ct_interop.compose(&p.draws[{d}], out.draw, region_out.draw, @backingInt(lcgf.types.Id.from("{s}")), &p.strings[{d}])) out.draw = &p.draws[{d}] else |_| {{}}
            \\            }}
            \\
        , .{ end, if (fit) std.fmt.allocPrint(e.arena, "\n                // Input can change the content's size (a hover, a row's editor); the next frame\n                // lays the page out around it.\n                const content = region_out.tree.c.size;\n                if (lcgf.ct_interop.setFit(&p.ui, .{f}, .{{ content[0][1], content[1][1] }})) out.wake = 0;", .{std.zig.fmtId(n.id)}) catch unreachable else "", slot % 2, n.id, slot % 2, slot % 2 });
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
