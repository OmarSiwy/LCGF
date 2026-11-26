//! Lowering: the document rows and their cascaded values to the page IR. One pass over the
//! nodes in document order (parents before children), so inherited values and the IR parent
//! of each node are known when it is reached; nothing recurses on the document's depth.
//! Rejections read their messages from the manifest.

const std = @import("std");
const lcgf = @import("lcgf");
const html = @import("html.zig");
const css = @import("css.zig");
const cascade = @import("cascade.zig");
const values = @import("values.zig");
const diag = @import("diag.zig");
const ir = @import("ir.zig");
const manifest = @import("manifest.zig");

const none = diag.none;
const Prop = values.Prop;
const types = lcgf.types;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Loc = diag.Loc;

pub const Lowerer = struct {
    arena: std.mem.Allocator,
    ds: *diag.Diags,
    doc: *const html.Doc,
    c: *css.Css,
    k: *const cascade.Cascade,
    page: ir.Page,
    /// Per document node: its IR node, or none.
    ir_of: []u32,
    /// Per document node: dropped with its subtree, or consumed by its parent's label.
    skip: []bool,
    /// Per document node: its computed text style and font size.
    text: []TextStyle,
    root_px: f32 = 14,
    /// `--runtime-vars=t-`: custom properties `--t-*` are run-time theme tokens; "" for none.
    runtime_prefix: []const u8 = "",
    /// (element << 32 | declaration) pairs the lowering read (`declared`): an author
    /// declaration that wins on an element and is never read there is reported (`checkUnread`).
    reads: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Per declaration: already reported by `checkDeclarations` (unknown or refused).
    noted: []bool = &.{},
    /// Token table index of a value token that a `var(--t-*)` produced.
    origin: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The token behind the value the last `component` read, or none.
    last_token: u32 = none,
    /// Token uses of the box being lowered, attached to its IR node by `addNode`.
    uses: std.ArrayList(ir.TokenUse) = .empty,
    /// Per document node: the tokens behind its text style (inherited).
    text_tokens: []ir.TextTokens = &.{},
    /// The document node whose IR node comes next, for its text tokens.
    current: u32 = none,
    /// Flex rules of the box being lowered other than its margins, attached by `addNode`.
    flex: lcgf.flex.Flex.Style = .{},
    /// IR nodes drawn above the page (a select's list, a dialog), moved last into a root of
    /// their own by `hoistOverlays`, so they float from the viewport's origin.
    overlays: std.ArrayList(u32) = .empty,
    /// Per document node: its computed font-family list, weight and style (inherited).
    font: []FontState = &.{},
    /// Per document node: its paragraph style (line-height, letter- and word-spacing inherit;
    /// text-overflow is the node's own).
    para: []Paragraph = &.{},
    /// The box being lowered's `box-shadow`, drawn by a node `addNode` puts before it.
    shadow: ?Shadow = null,

    /// Its `outline`, drawn by a ring node beside the shadow's.
    outline: ?Outline = null,

    /// Per document node: the text decoration its text shows (its own and its ancestors').
    deco: []Decoration = &.{},
    /// Per document node inside a paragraph of inline runs (F11): that paragraph's element.
    inline_of: []u32 = &.{},
    /// The paragraphs of inline runs, as their text is gathered: bytes and each byte's style.
    inlines: std.ArrayList(Inline) = .empty,
    /// The marker text of the list item being lowered (`• `, `3. `), which `addNode` puts
    /// in a row before the item's content.
    marker: []const u8 = "",

    const Shadow = struct { x: f32, y: f32, blur: f32, spread: f32, color: types.Color };
    const Outline = struct { width: f32, offset: f32, color: types.Color };

    fn ok(r: anytype) @typeInfo(@TypeOf(r)).error_union.payload {
        return r catch @panic("out of memory");
    }

    fn tag(l: *const Lowerer, n: u32) []const u8 {
        return l.doc.nodes.items(.name)[n];
    }

    fn loc(l: *const Lowerer, n: u32) Loc {
        // An implied element (`<body>` written nowhere) reports at its first located descendant.
        var i = n;
        const src = l.doc.nodes.items(.src);
        while (i < l.doc.nodes.len and src[i] == none) i += 1;
        return .{ .file = l.doc.file, .off = if (i < l.doc.nodes.len) src[i] else none };
    }

    fn attr(l: *const Lowerer, n: u32, name: []const u8) ?[]const u8 {
        return l.doc.value(n, name);
    }

    fn attrLoc(l: *const Lowerer, n: u32, name: []const u8) Loc {
        return if (l.doc.attr(n, name)) |a| l.doc.attrLoc(a) else l.loc(n);
    }

    fn valueLoc(l: *const Lowerer, n: u32, name: []const u8) Loc {
        return if (l.doc.attr(n, name)) |a| l.doc.valueLoc(a) else l.loc(n);
    }

    // ---- values ---------------------------------------------------------------------------

    /// The custom property `name` on `n` or the nearest ancestor that sets it.
    fn customOf(l: *const Lowerer, n: u32, name: []const u8) ?cascade.Entry {
        var i = n;
        while (i != none) : (i = l.doc.nodes.items(.parent)[i]) if (l.k.custom(i, name)) |e| return e;
        return null;
    }

    /// Tokens `[a, b)` with every `var()` replaced, as a new range of the token table. Each
    /// pass replaces one level of references; more levels than custom properties is a cycle.
    pub fn substitute(l: *Lowerer, n: u32, a: u32, b: u32, at: Loc) ?[2]u32 {
        var range = [2]u32{ a, b };
        var pass: u32 = 0;
        while (pass <= l.k.customs.len + 1) : (pass += 1) {
            const ty = l.c.toks.items(.type);
            var has = false;
            for (range[0]..range[1]) |t| has = has or (ty[t] == .function and css.eq(l.c.toks.items(.str)[t], "var"));
            if (!has) return range;
            const first: u32 = @intCast(l.c.toks.len);
            var t = range[0];
            while (t < range[1]) {
                const tok = l.c.toks.get(t);
                if (tok.type != .function or !css.eq(tok.str, "var")) {
                    // A token a run-time var() produced keeps its origin through later passes.
                    if (l.origin.get(t)) |o| ok(l.origin.put(l.arena, @intCast(l.c.toks.len), o));
                    ok(l.c.toks.append(l.arena, tok));
                    t += 1;
                    continue;
                }
                const close = values.closeOf(l.c, t, range[1]);
                var r: values.Reader = .init(l.c, t + 1, close - 1);
                const name_t = r.next() orelse {
                    l.ds.err(tok.loc, "var() needs a custom property name", .{});
                    return null;
                };
                const name = l.c.toks.items(.str)[name_t];
                // The fallback: everything after the first top-level comma.
                const comma = r.untilComma();
                const replacement: ?[2]u32 = if (l.customOf(n, name)) |e|
                    .{ l.c.decls.items(.first)[e.decl], l.c.decls.items(.end)[e.decl] }
                else if (comma < close - 1)
                    .{ comma + 1, close - 1 }
                else
                    null;
                const rep = replacement orelse {
                    l.ds.err(tok.loc, "{s} is not set here and var() has no fallback", .{name});
                    return null;
                };
                const at_rep: u32 = @intCast(l.c.toks.len);
                for (rep[0]..rep[1]) |x| ok(l.c.toks.append(l.arena, l.c.toks.get(x)));
                if (l.runtime_prefix.len > 0 and std.mem.startsWith(u8, name, "--") and std.mem.startsWith(u8, name[2..], l.runtime_prefix))
                    l.runtimeToken(name[2..], at_rep, @intCast(l.c.toks.len), tok.loc);
                t = close;
            }
            range = .{ first, @intCast(l.c.toks.len) };
        }
        l.ds.err(at, "custom properties refer to each other in a cycle", .{});
        return null;
    }

    /// Registers the run-time token `css` (`t-space-m`) for the value tokens `[a, b)` its
    /// var() became, which must be one value: a length or a colour.
    fn runtimeToken(l: *Lowerer, name: []const u8, a: u32, b: u32, at: Loc) void {
        var first = a;
        var end = b;
        while (first < end and l.c.toks.items(.type)[first] == .whitespace) first += 1;
        while (end > first and l.c.toks.items(.type)[end - 1] == .whitespace) end -= 1;
        if (end - first != 1) {
            l.ds.err(at, "run-time token --{s} must be one length or one colour (hex or a name)", .{name});
            return;
        }
        const index: u32 = for (l.page.tokens.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.css, name)) break @intCast(i);
        } else blk: {
            var zig_name: std.ArrayList(u8) = .empty;
            for (name[l.runtime_prefix.len..]) |ch| ok(zig_name.append(l.arena, if (ch == '-') '_' else std.ascii.toLower(ch)));
            const kind: @FieldType(ir.Token, "kind") = if (values.len(l.c, first) != null) .length else .color;
            var tk: ir.Token = .{ .css = name, .field = zig_name.items, .kind = kind, .loc = at };
            if (kind == .length) {
                tk.default_px = values.px(values.len(l.c, first).?, l.root_px, l.root_px) orelse {
                    l.ds.err(at, "run-time token --{s}: give its default in px", .{name});
                    return;
                };
            } else tk.default_color = values.color(l.c, first, end) orelse {
                l.ds.err(at, "run-time token --{s} must be one length or one colour (hex or a name)", .{name});
                return;
            };
            if (!l.identifier(tk.field, at)) return;
            ok(l.page.tokens.append(l.arena, tk));
            break :blk @intCast(l.page.tokens.items.len - 1);
        };
        ok(l.origin.put(l.arena, first, index));
    }

    /// Records that style field `target` of the box being lowered reads the token behind the
    /// value just read, if any.
    fn use(l: *Lowerer, target: ir.Target) void {
        if (l.last_token == none) return;
        const kind = l.page.tokens.items[l.last_token].kind;
        const wants: @TypeOf(kind) = switch (target) {
            .fill, .border_color => .color,
            else => .length,
        };
        if (kind != wants) l.ds.err(l.page.tokens.items[l.last_token].loc, "run-time token --{s} is a {s} but sets a {s}", .{ l.page.tokens.items[l.last_token].css, @tagName(kind), @tagName(wants) });
        ok(l.uses.append(l.arena, .{ .target = target, .token = l.last_token }));
    }

    /// The value tokens that set longhand `p` on `n`, `var()`s substituted, or null when
    /// nothing is declared. For a shorthand, the whole shorthand value (see `component`).
    fn declared(l: *Lowerer, n: u32, p: Prop) ?Value {
        const e = l.k.get(n, p);
        if (e.decl == none) return null;
        ok(l.reads.put(l.arena, (@as(u64, n) << 32) | e.decl, {}));
        const d = l.c.decls.get(e.decl);
        const r = l.substitute(n, d.first, d.end, d.loc) orelse return null;
        const v: Value = .{ .first = r[0], .end = r[1], .loc = d.loc, .shorthand = e.shorthand, .prop = p };
        if (v.first == v.end) {
            l.ds.err(d.loc, "'{s}' has no value", .{d.name});
            return null;
        }
        return v;
    }

    const Value = struct { first: u32, end: u32, loc: Loc, shorthand: u32, prop: Prop };

    /// The tokens of `v` that apply to its longhand: all of a longhand's, or the component a
    /// shorthand gives it (CSS's 1-to-4 value rule for box sides and corners).
    fn component(l: *Lowerer, v: Value) ?[2]u32 {
        const r = l.componentOf(v) orelse {
            l.last_token = none;
            return null;
        };
        l.last_token = if (r[1] - r[0] == 1) l.origin.get(r[0]) orelse none else none;
        return r;
    }

    fn componentOf(l: *Lowerer, v: Value) ?[2]u32 {
        if (v.shorthand == none) return .{ v.first, v.end };
        const sh = values.shorthands[v.shorthand];
        var parts: [8][2]u32 = undefined;
        var count: usize = 0;
        var r: values.Reader = .init(l.c, v.first, v.end);
        while (r.next()) |t| {
            if (count == parts.len) break;
            parts[count] = .{ t, r.i };
            count += 1;
        }
        const index = std.mem.indexOfScalar(Prop, sh.longhands, v.prop).?;
        if (std.mem.eql(u8, sh.name, "flex") or std.mem.eql(u8, sh.name, "border") or std.mem.eql(u8, sh.name, "background") or std.mem.eql(u8, sh.name, "flex-flow") or std.mem.eql(u8, sh.name, "outline"))
            return l.byType(sh.name, v, parts[0..count]);
        if (sh.longhands.len == 1) return .{ v.first, v.end };
        if (count > sh.longhands.len) {
            l.ds.err(v.loc, "'{s}' takes at most {d} values", .{ sh.name, sh.longhands.len });
            return null;
        }
        // 1: all; 2: (a b a b); 3: (a b c b); 4: as written. Two longhands: (a b) or (a a).
        const pick: usize = switch (count) {
            1 => 0,
            2 => index % 2,
            3 => if (index == 3) 1 else index,
            else => index,
        };
        return parts[pick];
    }

    /// Shorthands whose components are told apart by type (`border: 1px solid red`).
    fn byType(l: *Lowerer, name: []const u8, v: Value, parts: []const [2]u32) ?[2]u32 {
        for (parts) |p| {
            const t = p[0];
            const is_len = values.len(l.c, t) != null;
            const is_color = values.color(l.c, t, p[1]) != null and l.c.toks.items(.type)[t] != .number;
            const want: bool = switch (v.prop) {
                .@"border-top-width", .@"outline-width" => is_len,
                .@"border-color", .@"background-color", .@"outline-color" => is_color,
                .@"border-style", .@"outline-style" => !is_len and !is_color,
                .@"background-image" => l.c.toks.items(.type)[t] == .url or (l.c.toks.items(.type)[t] == .function and !is_color),
                .@"flex-grow" => l.c.toks.items(.type)[t] == .number and p[0] == parts[0][0],
                .@"flex-shrink" => parts.len > 1 and l.c.toks.items(.type)[t] == .number and p[0] == parts[1][0],
                .@"flex-basis" => is_len and l.c.toks.items(.type)[t] != .number,
                .@"flex-direction" => values.isIdent(l.c, t, "row") or values.isIdent(l.c, t, "column") or values.isIdent(l.c, t, "row-reverse") or values.isIdent(l.c, t, "column-reverse"),
                .@"flex-wrap" => values.isIdent(l.c, t, "wrap") or values.isIdent(l.c, t, "nowrap") or values.isIdent(l.c, t, "wrap-reverse"),
                else => false,
            };
            if (want) return p;
        }
        // `flex: auto | none` and `flex: N` set grow; the rest of their longhands stay initial.
        if (std.mem.eql(u8, name, "flex") and parts.len == 1 and v.prop == .@"flex-grow") {
            if (values.isIdent(l.c, parts[0][0], "auto")) return null;
        }
        return null;
    }

    /// The single keyword of `p` on `n`, or null when nothing is declared.
    fn keyword(l: *Lowerer, n: u32, p: Prop) ?[]const u8 {
        const v = l.declared(n, p) orelse return null;
        const r = l.component(v) orelse return null;
        if (r[1] - r[0] != 1 or l.c.toks.items(.type)[r[0]] != .ident) {
            l.ds.err(l.c.tokLoc(r[0]), "expected a keyword for {s}, found '{s}'", .{ @tagName(p), l.c.text(r[0], r[1]) });
            return null;
        }
        return l.c.toks.items(.str)[r[0]];
    }

    fn badValue(l: *Lowerer, t: u32, p: Prop, end: u32) void {
        l.ds.err(l.c.tokLoc(t), "{s}: '{s}' is not a supported value", .{ @tagName(p), l.c.text(t, end) });
    }

    /// A length of `p` on `n` in px (`em` from the element's font size), or a percentage.
    const Length = union(enum) { px: f32, pct: f32, auto };

    fn length(l: *Lowerer, n: u32, p: Prop) ?Length {
        const v = l.declared(n, p) orelse return null;
        const r = l.component(v) orelse return null;
        return l.lengthAt(n, r[0], r[1], p);
    }

    fn lengthAt(l: *Lowerer, n: u32, t: u32, end: u32, p: Prop) ?Length {
        if (end - t != 1) {
            if (l.c.toks.items(.type)[t] == .function and css.eq(l.c.toks.items(.str)[t], "calc")) {
                l.ds.err(l.c.tokLoc(t), "calc() is not folded yet; write the length", .{});
                return null;
            }
            l.badValue(t, p, end);
            return null;
        }
        if (values.unitError(l.c, t)) |msg| {
            l.ds.err(l.c.tokLoc(t), "{s}", .{msg});
            return null;
        }
        for ([_][]const u8{ "fit-content", "max-content" }) |kw| if (values.isIdent(l.c, t, kw)) return .auto;
        if (values.isIdent(l.c, t, "min-content")) {
            l.ds.err(l.c.tokLoc(t), "min-content sizes are not supported yet; give a length", .{});
            return null;
        }
        if (values.isIdent(l.c, t, "none") and (p == .@"max-width" or p == .@"max-height")) return .{ .px = types.inf };
        const len = values.len(l.c, t) orelse {
            l.badValue(t, p, end);
            return null;
        };
        if (len.unit == .auto) return .auto;
        if (len.unit == .pct) return .{ .pct = len.v / 100 };
        return .{ .px = values.px(len, l.text[n].px, l.root_px) orelse {
            l.badValue(t, p, end);
            return null;
        } };
    }

    fn px(l: *Lowerer, n: u32, p: Prop) ?f32 {
        const len = l.length(n, p) orelse return null;
        return switch (len) {
            .px => |v| v,
            else => {
                l.ds.err(l.declared(n, p).?.loc, "{s} takes a length in px, em or rem here", .{@tagName(p)});
                return null;
            },
        };
    }

    fn colorOf(l: *Lowerer, n: u32, p: Prop) ?types.Color {
        const v = l.declared(n, p) orelse return null;
        const r = l.component(v) orelse return null;
        if (values.isIdent(l.c, r[0], "currentcolor")) return l.text[n].color;
        return values.color(l.c, r[0], r[1]) orelse {
            l.badValue(r[0], p, r[1]);
            return null;
        };
    }

    fn number(l: *Lowerer, n: u32, p: Prop) ?f32 {
        const v = l.declared(n, p) orelse return null;
        const r = l.component(v) orelse return null;
        const ty = l.c.toks.items(.type)[r[0]];
        if (r[1] - r[0] != 1 or (ty != .number and ty != .percentage)) {
            l.badValue(r[0], p, r[1]);
            return null;
        }
        const x: f32 = @floatCast(l.c.toks.items(.num)[r[0]]);
        return if (ty == .percentage) x / 100 else x;
    }

    // ---- refusals -------------------------------------------------------------------------

    /// Reports `name`'s manifest refusal at `at`; true when it was refused.
    fn refused(l: *Lowerer, kind: []const u8, name: []const u8, scope: []const u8, at: Loc) bool {
        const msg = manifest.refusal(kind, name, scope) orelse return false;
        l.ds.err(at, "{s}", .{msg});
        return true;
    }

    /// An author declaration that wins on an element the lowering never read there: CSS the
    /// page would otherwise drop without a word. Reported once per declaration, at it, naming
    /// the first such element. Run after `run`.
    pub fn checkUnread(l: *Lowerer) void {
        const reported = ok(l.arena.alloc(bool, l.c.decls.len));
        @memcpy(reported, l.noted);
        for (0..l.doc.nodes.len) |n_| {
            const n: u32 = @intCast(n_);
            if (l.doc.nodes.items(.kind)[n] != .element) continue;
            // A flex container's own properties do nothing on another box, as in CSS.
            const flex = l.display(n) == .flex;
            for (0..values.prop_count) |pi| {
                const e = l.k.table[n * values.prop_count + pi];
                if (e.decl == none or reported[e.decl]) continue;
                const p: Prop = @fromBackingInt(@as(@typeInfo(Prop).@"enum".tag_type, @intCast(pi)));
                const container_only = switch (p) {
                    .@"flex-direction", .@"flex-wrap", .@"justify-content", .@"align-items", .@"align-content" => true,
                    else => false,
                };
                if (container_only and !flex) continue;
                const origin = l.c.rules.items(.origin)[l.c.decls.items(.rule)[e.decl]];
                if (origin == .ua or l.reads.contains((@as(u64, n) << 32) | e.decl)) continue;
                reported[e.decl] = true;
                l.ds.err(l.c.decls.items(.loc)[e.decl], "'{s}' on <{s}> is not lowered: nothing on this element reads it", .{ l.c.decls.items(.name)[e.decl], l.tag(n) });
            }
        }
    }

    /// Checks every declaration once: unknown properties and refused ones are errors at the
    /// declaration, not once per element it matches.
    pub fn checkDeclarations(l: *Lowerer) void {
        const d = l.c.decls.slice();
        l.noted = ok(l.arena.alloc(bool, d.len));
        @memset(l.noted, false);
        for (0..d.len) |i| {
            const name = d.items(.name)[i];
            if (std.mem.startsWith(u8, name, "--")) continue;
            // `@font-face` descriptors are read by fontFaces.
            const descriptor = for (l.c.fonts.items) |f| {
                if (i >= f.decl_first and i < f.decl_first + f.decl_count) break true;
            } else false;
            if (descriptor) continue;
            if (l.refused("property", name, "", d.items(.loc)[i])) {
                l.noted[i] = true;
                continue;
            }
            const known = std.meta.stringToEnum(Prop, name) != null or values.shorthand(name) != null;
            if (!known) {
                l.ds.err(d.items(.loc)[i], "unknown CSS property '{s}'", .{name});
                l.noted[i] = true;
            }
        }
        for (0..l.c.simples.len) |i| {
            const s = l.c.simples.get(i);
            if (s.kind != .state) continue;
            const name = ok(std.fmt.allocPrint(l.arena, ":{s}", .{s.name}));
            if (l.refused("selector", name, "", s.loc)) continue;
            const known = for (states) |x| {
                if (std.mem.eql(u8, x, s.name)) break true;
            } else false;
            if (!known) {
                l.ds.err(s.loc, "unknown pseudo-class {s}", .{name});
                continue;
            }
            _ = l.refused("selector", ":state", "", s.loc);
        }
        for (l.c.sels.items(.element), l.c.sels.items(.loc)) |e, at| if (e.len > 0)
            l.ds.err(at, "::{s} is not lowered yet", .{e});
        for (l.c.conds.items) |cnd| _ = l.refused("at-rule", if (cnd.kind == .media) "@media" else "@supports", "", cnd.loc);
        for (l.c.keyframes.items) |kf| _ = l.refused("property", "animation", "", kf.loc);
    }

    // ---- the walk -------------------------------------------------------------------------

    pub fn run(l: *Lowerer) void {
        const doc = l.doc;
        const n_nodes: u32 = @intCast(doc.nodes.len);
        const kinds = doc.nodes.items(.kind);
        const parents = doc.nodes.items(.parent);
        if (!doc.doctype or doc.quirks) l.ds.err(.{ .file = doc.file, .off = 0 }, "{s}", .{manifest.refusal("element", "!doctype", "").?});
        l.theme();
        l.fontFaces();
        const root_text = lcgf.widgets_label.labelText(&l.page.theme);
        l.root_px = root_text.px;
        var body: u32 = none;
        for (0..n_nodes) |i_| {
            const i: u32 = @intCast(i_);
            const p = parents[i];
            // Dropped with its parent, or consumed by an earlier node (a control's caption).
            if (l.skip[i] or (p != none and l.skip[p])) {
                l.skip[i] = true;
                continue;
            }
            l.text[i] = if (p == none) root_text else l.text[p];
            l.text_tokens[i] = if (p == none) .{} else l.text_tokens[p];
            l.font[i] = if (p == none) .{} else l.font[p];
            l.para[i] = if (p == none) .{} else l.para[p];
            l.para[i].ellipsis = false;
            l.deco[i] = if (p == none) .{} else l.deco[p];
            l.current = i;
            if (kinds[i] == .text) {
                if (l.inline_of[i] != none) l.inlineText(i) else l.textNode(i);
                continue;
            }
            l.computeText(i);
            if (l.inline_of[i] != none) {
                l.inlineElement(i);
                continue;
            }
            const t = l.tag(i);
            if (std.mem.eql(u8, t, "html")) {
                if (l.attr(i, "lcgf-page")) |name| l.page.name = name;
                if (l.attr(i, "lcgf-frontend")) |fe| {
                    if (std.mem.eql(u8, fe, "runtime")) l.page.runtime = true else if (!std.mem.eql(u8, fe, "spec") and !std.mem.eql(u8, fe, "auto")) l.ds.err(l.valueLoc(i, "lcgf-frontend"), "lcgf-frontend takes spec, runtime or auto", .{});
                }
                continue;
            }
            if (std.mem.eql(u8, t, "head")) {
                l.head(i);
                l.skip[i] = true;
                continue;
            }
            if (std.mem.eql(u8, t, "body")) {
                body = i;
                l.element(i, none);
                continue;
            }
            if (body == none or !l.inside(i, body)) {
                // Content the parser put outside <body> (it moves stray text and tags in).
                l.skip[i] = true;
                continue;
            }
            l.element(i, l.irParent(i));
        }
        l.finishInlines();
        l.checkFields();
        l.checkRegions();
        l.checkProps();
        l.swapElse();
        l.hoistOverlays();
    }

    /// Moves each overlay's subtree, in order, to the end of a new root: an unpadded column
    /// over the viewport holding the old root and then the overlays. A float sits at its
    /// parent's content origin, and later rows are drawn above earlier ones.
    fn hoistOverlays(l: *Lowerer) void {
        if (l.ds.errors > 0 or l.overlays.items.len == 0) return;
        const old = l.page.nodes;
        const n: u32 = @intCast(old.len);
        // Old index -> new; the wrapper is new node 0.
        const map = ok(l.arena.alloc(u32, n));
        // The innermost overlay each node is in: overlays are listed outer first (a select
        // in a dialog comes after the dialog), so a nested one moves on its own, after.
        const owner = ok(l.arena.alloc(u32, n));
        @memset(owner, none);
        for (l.overlays.items) |o| @memset(owner[o..l.subtreeEnd(o)], o);
        var order: std.ArrayList(u32) = .empty;
        for (0..n) |i| if (owner[i] == none) ok(order.append(l.arena, @intCast(i)));
        for (l.overlays.items) |o| for (o..l.subtreeEnd(o)) |i| if (owner[i] == o) ok(order.append(l.arena, @intCast(i)));
        for (order.items, 1..) |i, k| map[i] = @intCast(k);
        var nodes: std.MultiArrayList(ir.Node) = .empty;
        ok(nodes.append(l.arena, .{ .kind = .container, .parent = none, .loc = old.items(.loc)[0], .style = .{ .size = .{ .fill, .fill } } }));
        for (order.items) |i| {
            var node = old.get(i);
            const overlay = std.mem.indexOfScalar(u32, l.overlays.items, i) != null;
            node.parent = if (overlay or node.parent == none) 0 else map[node.parent];
            ok(nodes.append(l.arena, node));
        }
        l.page.nodes = nodes;
    }

    /// Whether IR node `i` is inside a region its overlay cannot leave: a list or a run-time
    /// region repeats it.
    fn inRepeat(l: *const Lowerer, i: u32) bool {
        var k = i;
        while (k != none) : (k = l.page.nodes.items(.parent)[k]) switch (l.page.nodes.items(.kind)[k]) {
            .list, .each => return true,
            else => {},
        };
        return false;
    }

    /// The `<template lcgf-else>` that is the next element after template `n`, or none.
    fn elseOf(l: *const Lowerer, n: u32) u32 {
        const parents = l.doc.nodes.items(.parent);
        for (l.k.end[n]..l.doc.nodes.len) |i| {
            if (parents[i] != parents[n]) continue;
            if (l.doc.nodes.items(.kind)[i] == .text and isBlank(l.doc.nodes.items(.name)[i])) continue;
            const ok_ = l.doc.isElement(@intCast(i), "template") and l.attr(@intCast(i), "lcgf-else") != null;
            return if (ok_) @intCast(i) else none;
        }
        return none;
    }

    /// An lcgf-if/lcgf-else choice lists its alternatives as the markup does, then before else;
    /// `spec.choice` over a bool takes false first, so the two subtrees trade places.
    fn swapElse(l: *Lowerer) void {
        if (l.ds.errors > 0) return;
        const nodes = &l.page.nodes;
        var i: u32 = 0;
        while (i < nodes.len) : (i += 1) {
            if (nodes.items(.kind)[i] != .choice or nodes.items(.level)[i] != 1) continue;
            const a = i + 1;
            const b = l.subtreeEnd(a);
            const c = l.subtreeEnd(b);
            if (b == c or c > nodes.len) continue; // reported: an alternative is missing
            var moved: std.ArrayList(ir.Node) = .empty;
            for (b..c) |k| ok(moved.append(l.arena, nodes.get(k)));
            for (a..b) |k| ok(moved.append(l.arena, nodes.get(k)));
            for (moved.items, a..) |*m, k| {
                if (m.parent >= a and m.parent < b) m.parent += c - b else if (m.parent >= b and m.parent < c) m.parent -= b - a;
                nodes.set(k, m.*);
            }
        }
    }

    /// The first IR node after `x` that is not in `x`'s subtree.
    fn subtreeEnd(l: *const Lowerer, x: u32) u32 {
        const parents = l.page.nodes.items(.parent);
        var k = x + 1;
        while (k < parents.len) : (k += 1) {
            var p = parents[k];
            while (p != none and p != x) p = parents[p];
            if (p == none) return k;
        }
        return @intCast(parents.len);
    }

    /// `<sfy-name …>`: an app component (plan §3.4). Its attributes are props: a literal
    /// string, `{f}` (a view-state field; `{f:f32}` types one nothing else on the page binds)
    /// or, inside an lcgf-each, `{x.f}` (a field of the item). CSS cannot restyle what the app
    /// builds; margins (`spec.flexed`) and `aria-label` (`spec.named`) wrap it.
    fn appComponent(l: *Lowerer, n: u32, parent: u32) void {
        const t = l.tag(n);
        const each = l.eachOf(n);
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        const st = l.boxStyle(n, .{}, l.parentDir(parent), &params, &margin);
        if (!std.meta.eql(st, Style{}) or params.len > 0)
            l.ds.err(l.loc(n), "CSS does not restyle an app component, only its margins; style it in the app or wrap it in a <div>", .{});
        var props: std.ArrayList(ir.Prop) = .empty;
        const doc = l.doc;
        const first = doc.nodes.items(.attr_first)[n];
        for (first..first + doc.nodes.items(.attr_count)[n]) |a_| {
            const a: u32 = @intCast(a_);
            const name = doc.attrs.items(.name)[a];
            const skipped = for ([_][]const u8{ "id", "class", "style", "aria-label", "aria-labelledby", "slot" }) |x| {
                if (std.mem.eql(u8, x, name)) break true;
            } else std.mem.startsWith(u8, name, "on:");
            if (skipped) continue;
            if (std.mem.startsWith(u8, name, "bind:")) {
                l.ds.err(doc.attrLoc(a), "bind: on a component is not lowered; pass the field as a prop (level=\"{{gain}}\") and report changes with on:click", .{});
                continue;
            }
            if (!l.identifier(name, doc.attrLoc(a))) continue;
            if (std.mem.eql(u8, name, "children")) {
                l.ds.err(doc.attrLoc(a), "'children' is the component's content; write it between the tags", .{});
                continue;
            }
            const v = doc.attrs.items(.value)[a];
            const at = doc.valueLoc(a);
            var prop: ir.Prop = .{ .name = name, .kind = .literal, .value = v, .loc = at };
            const tv = std.mem.trim(u8, v, " ");
            if (std.mem.startsWith(u8, tv, "var(") and std.mem.endsWith(u8, tv, ")")) {
                // `var(--t-x)`: a run-time token, passed as its `Tokens` field's name, which
                // the component gives `spec.tokened`.
                prop.value = l.tokenProp(n, std.mem.trim(u8, tv[4 .. tv.len - 1], " "), at) orelse continue;
                prop.token = true;
            } else if (isBound(v)) {
                const inner = std.mem.trim(u8, std.mem.trim(u8, v, " ")[1 .. std.mem.trim(u8, v, " ").len - 1], " ");
                if (std.mem.indexOfScalar(u8, inner, '.')) |dot| {
                    if (each == none or !std.mem.eql(u8, inner[0..dot], l.page.nodes.items(.text)[each]) or !l.identifier(inner[dot + 1 ..], at)) {
                        l.ds.err(at, "'{s}' names no item: `{{x.field}}` reads the item of an enclosing lcgf-each=\"x in xs\"", .{inner});
                        continue;
                    }
                    ok(l.page.item_fields.append(l.arena, .{ .each = l.page.nodes.items(.id)[each], .field = inner[dot + 1 ..], .loc = at }));
                    prop.kind = .item;
                    prop.value = inner;
                } else {
                    const colon = std.mem.indexOfScalar(u8, inner, ':');
                    const f = if (colon) |k| inner[0..k] else inner;
                    if (!l.identifier(f, at)) continue;
                    if (colon) |k| {
                        const ty = std.meta.stringToEnum(ir.FieldType, inner[k + 1 ..]) orelse .text;
                        if (ty != .str and ty != .bool and ty != .f32 and ty != .u32) {
                            l.ds.err(at, "'{{{s}}}': the type after ':' is str, bool, f32 or u32", .{inner});
                            continue;
                        }
                        l.field(f, ty, at, "a component prop");
                    }
                    prop.kind = .field;
                    prop.value = f;
                }
            }
            ok(props.append(l.arena, prop));
        }
        const id: []const u8 = if (l.attr(n, "id")) |x| (if (l.identifier(x, l.valueLoc(n, "id"))) x else "") else l.attr(n, "on:click") orelse "";
        l.ir_of[n] = l.addNode(.{ .kind = .component, .parent = parent, .loc = l.loc(n), .text = t, .id = id, .props = props.items, .margin = margin, .name = l.accessibleName(n) });
        l.handlers(n, id, "", null);
    }

    /// The `Tokens` field of run-time token `name` (`--t-x`) for a component prop, registered
    /// from the custom property's value where the element is; null after an error.
    fn tokenProp(l: *Lowerer, n: u32, name: []const u8, at: Loc) ?[]const u8 {
        const runtime = l.runtime_prefix.len > 0 and std.mem.startsWith(u8, name, "--") and std.mem.startsWith(u8, name[2..], l.runtime_prefix);
        if (!runtime) {
            l.ds.err(at, "a component prop takes var() only for a run-time token: var(--{s}x) under --runtime-vars={s}", .{ if (l.runtime_prefix.len > 0) l.runtime_prefix else "t-", if (l.runtime_prefix.len > 0) l.runtime_prefix else "t-" });
            return null;
        }
        const e = l.customOf(n, name) orelse {
            l.ds.err(at, "{s} is not set here", .{name});
            return null;
        };
        const d = l.c.decls.get(e.decl);
        const r = l.substitute(n, d.first, d.end, d.loc) orelse return null;
        l.runtimeToken(name[2..], r[0], r[1], at);
        for (l.page.tokens.items) |t| if (std.mem.eql(u8, t.css, name[2..])) return t.field;
        return null;
    }

    /// The accessible name of element `n`: its `aria-label`, else the text of the elements its
    /// `aria-labelledby` names, joined by spaces, else "". The text is read at build time, so
    /// it must be literal.
    fn accessibleName(l: *Lowerer, n: u32) []const u8 {
        if (l.attr(n, "aria-label")) |v| return v;
        const ids = l.attr(n, "aria-labelledby") orelse return "";
        const at = l.valueLoc(n, "aria-labelledby");
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, ids, ' ');
        while (it.next()) |id| {
            const e: u32 = for (0..l.doc.nodes.len) |i| {
                if (l.doc.nodes.items(.kind)[i] == .element and std.mem.eql(u8, l.attr(@intCast(i), "id") orelse "", id)) break @intCast(i);
            } else {
                l.ds.err(at, "aria-labelledby names '{s}', which is no element's id", .{id});
                return "";
            };
            const text = collapse(l.arena, l.allText(e));
            if (std.mem.indexOfAny(u8, text, "{}") != null) {
                l.ds.err(at, "aria-labelledby reads the text of '{s}' at build time; it cannot show a field", .{id});
                return "";
            }
            if (out.items.len > 0) ok(out.append(l.arena, ' '));
            ok(out.appendSlice(l.arena, text));
        }
        return out.items;
    }

    /// A `{f}` prop names a view-state field; something on the page must type it.
    fn checkProps(l: *Lowerer) void {
        for (l.page.nodes.items(.props)) |props| for (props) |p| if (p.kind == .field) {
            for (l.page.fields.items) |f| {
                if (std.mem.eql(u8, f.name, p.value)) break;
            } else l.ds.err(p.loc, "nothing on the page types '{s}': bind it to a control or give its type, {{{s}:f32}} (str, bool, f32 or u32)", .{ p.value, p.value });
        };
    }

    fn inside(l: *const Lowerer, n: u32, ancestor: u32) bool {
        var i = n;
        while (i != none) : (i = l.doc.nodes.items(.parent)[i]) if (i == ancestor) return true;
        return false;
    }

    fn irParent(l: *const Lowerer, n: u32) u32 {
        var i = l.doc.nodes.items(.parent)[n];
        while (i != none) : (i = l.doc.nodes.items(.parent)[i]) if (l.ir_of[i] != none) return l.ir_of[i];
        return none;
    }

    fn head(l: *Lowerer, h: u32) void {
        const doc = l.doc;
        for (h + 1..l.k.end[h]) |i_| {
            const i: u32 = @intCast(i_);
            if (doc.nodes.items(.kind)[i] != .element) continue;
            const t = l.tag(i);
            if (std.mem.eql(u8, t, "title")) {
                l.page.title = collapse(l.arena, l.ownText(i));
            } else if (std.mem.eql(u8, t, "meta")) {
                if (l.attr(i, "charset")) |cs| if (!std.ascii.eqlIgnoreCase(cs, "utf-8")) l.ds.err(l.valueLoc(i, "charset"), "only UTF-8 sources are read", .{});
            } else if (std.mem.eql(u8, t, "script")) {
                const ty = l.attr(i, "type") orelse "";
                if (!std.mem.eql(u8, ty, "application/json")) _ = l.refused("element", "script", "", l.loc(i));
            } else if (std.mem.eql(u8, t, "base")) {
                _ = l.refused("element", "base", "", l.loc(i));
            }
        }
    }

    /// The text of `n`'s text children, in order.
    fn ownText(l: *const Lowerer, n: u32) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.parent)[i] == n and l.doc.nodes.items(.kind)[i] == .text)
            ok(out.appendSlice(l.arena, l.doc.nodes.items(.name)[i]));
        return out.items;
    }

    /// The theme: `base.Theme` with the `--lcgf-*` tokens set on `:root`.
    fn theme(l: *Lowerer) void {
        var th: ir.Theme = .{};
        if (l.doc.nodes.len == 0) return;
        const fields = .{ "text", "text_px", "panel", "control", "control_hot", "control_held", "accent", "radius", "pad", "gap" };
        inline for (fields) |f| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "--lcgf-{s}", .{f}) catch unreachable;
            std.mem.replaceScalar(u8, name, '_', '-');
            if (l.k.custom(0, name)) |e| {
                const d = l.c.decls.get(e.decl);
                const origin = l.c.rules.items(.origin)[d.rule];
                if (origin != .ua) if (l.substitute(0, d.first, d.end, d.loc)) |r| {
                    const T = @TypeOf(@field(th, f));
                    if (T == types.Color) {
                        if (values.color(l.c, r[0], r[1])) |col| @field(th, f) = col else l.ds.err(d.loc, "{s} takes a colour", .{name});
                    } else {
                        const len = if (r[1] - r[0] == 1) values.len(l.c, r[0]) else null;
                        if (len != null and values.px(len.?, 16, 16) != null) @field(th, f) = values.px(len.?, 16, 16).? else l.ds.err(d.loc, "{s} takes a length in px", .{name});
                    }
                };
            }
        }
        // accent-color on :root is the theme's accent, after --lcgf-accent.
        const ac = l.k.get(0, .@"accent-color");
        if (ac.decl != none) {
            ok(l.reads.put(l.arena, ac.decl, {})); // node 0's
            const d = l.c.decls.get(ac.decl);
            if (l.substitute(0, d.first, d.end, d.loc)) |r| {
                if (values.isIdent(l.c, r[0], "auto")) {} else if (values.isIdent(l.c, r[0], "currentcolor")) th.accent = th.text else if (values.color(l.c, r[0], r[1])) |col| th.accent = col else l.badValue(r[0], .@"accent-color", r[1]);
            }
        }
        l.page.theme = th;
    }

    /// Inherited text properties of element `n`, over its parent's (already in `text[n]`).
    fn computeText(l: *Lowerer, n: u32) void {
        var ts = l.text[n];
        // font-size first: em in the other properties is relative to it.
        if (l.declared(n, .@"font-size")) |v| if (l.component(v)) |r| {
            const t = r[0];
            const parent_px = ts.px;
            const len = values.len(l.c, t);
            if (len != null and len.?.unit == .pct) ts.px = parent_px * len.?.v / 100 else if (len) |x| {
                if (values.px(x, parent_px, l.root_px)) |p| ts.px = p else l.badValue(t, .@"font-size", r[1]);
            } else l.badValue(t, .@"font-size", r[1]);
            // A token sets the size as written: no em or % over it.
            if (l.last_token != none) l.text_tokens[n].px = l.tokenOf(l.last_token, .length);
        };
        l.text[n] = ts;
        if (l.colorOf(n, .color)) |col| {
            ts.color = col;
            l.text_tokens[n].color = if (l.last_token != none) l.tokenOf(l.last_token, .color) else none;
        }
        l.computeFont(n, &ts);
        l.computeParagraph(n, ts.px);
        if (l.keyword(n, .@"white-space")) |ws| {
            if (css.eq(ws, "normal") or css.eq(ws, "pre-wrap") or css.eq(ws, "pre-line")) ts.wrap = true else if (css.eq(ws, "nowrap") or css.eq(ws, "pre")) ts.wrap = false else l.badValue(l.declared(n, .@"white-space").?.first, .@"white-space", l.declared(n, .@"white-space").?.end);
        }
        l.text[n] = ts;
    }

    /// line-height, letter-spacing, word-spacing and text-overflow of `n` to `para[n]`
    /// (`MonoParagraphs` honours them; engine spec F12b).
    fn computeParagraph(l: *Lowerer, n: u32, font_px: f32) void {
        const pa = &l.para[n];
        if (l.declared(n, .@"line-height")) |v| if (l.component(v)) |r| {
            const t = r[0];
            const len = values.len(l.c, t);
            if (r[1] - r[0] == 1 and values.isIdent(l.c, t, "normal")) pa.line_height = .font else if (len) |x| switch (x.unit) {
                // A number inherits as a number: a multiple of each descendant's own size.
                .number => pa.line_height = .{ .multiple = x.v },
                .pct => pa.line_height = .{ .px = x.v / 100 * font_px },
                else => if (values.px(x, font_px, l.root_px)) |p| {
                    pa.line_height = .{ .px = p };
                } else l.badValue(t, .@"line-height", r[1]),
            } else l.badValue(t, .@"line-height", r[1]);
        };
        inline for (.{ .{ Prop.@"letter-spacing", "letter_spacing" }, .{ Prop.@"word-spacing", "word_spacing" } }) |sp| {
            if (l.declared(n, sp[0])) |v| if (l.component(v)) |r| {
                if (r[1] - r[0] == 1 and values.isIdent(l.c, r[0], "normal")) @field(pa, sp[1]) = 0 else if (l.lengthAt(n, r[0], r[1], sp[0])) |x| switch (x) {
                    .px => |p| @field(pa, sp[1]) = p,
                    else => l.badValue(r[0], sp[0], r[1]),
                };
            };
        }
        // text-decoration propagates to the text inside: lines add up, `none` removes none.
        if (l.declared(n, .@"text-decoration")) |v| {
            const d = &l.deco[n];
            var r: values.Reader = .init(l.c, v.first, v.end);
            while (r.next()) |t| {
                const ty = l.c.toks.items(.type)[t];
                if (ty == .ident and css.eq(l.c.toks.items(.str)[t], "underline")) d.underline = true else if (ty == .ident and css.eq(l.c.toks.items(.str)[t], "overline")) d.overline = true else if (ty == .ident and css.eq(l.c.toks.items(.str)[t], "line-through")) d.strike = true else if (ty == .ident and (css.eq(l.c.toks.items(.str)[t], "none") or css.eq(l.c.toks.items(.str)[t], "solid"))) {} else if (values.color(l.c, t, r.i)) |col| d.color = col.bitsOf() else {
                    l.badValue(t, .@"text-decoration", v.end);
                    break;
                }
            }
        }
        if (l.keyword(n, .@"text-overflow")) |kw| {
            if (css.eq(kw, "ellipsis")) pa.ellipsis = true else if (!css.eq(kw, "clip")) l.badValue(l.declared(n, .@"text-overflow").?.first, .@"text-overflow", l.declared(n, .@"text-overflow").?.end);
        }
    }

    /// The text decoration a label of `n` shows, or null for none.
    fn decorationOf(l: *const Lowerer, n: u32) ?Decoration {
        return if (std.meta.eql(l.deco[n], Decoration{})) null else l.deco[n];
    }

    /// The paragraph style a label of `n` carries, or null for the default.
    fn paragraphOf(l: *const Lowerer, n: u32) ?Paragraph {
        return if (std.meta.eql(l.para[n], Paragraph{})) null else l.para[n];
    }

    /// `@font-face` rules to the page's font table: family, weight, style and a local file.
    fn fontFaces(l: *Lowerer) void {
        const c = l.c;
        const d = c.decls.slice();
        for (c.fonts.items) |face| {
            var family: []const u8 = "";
            var path: []const u8 = "";
            var weight: f32 = 400;
            var style: lcgf.font_match.Style = .normal;
            var src_seen = false;
            for (face.decl_first..face.decl_first + face.decl_count) |i| {
                const name = d.items(.name)[i];
                const a = d.items(.first)[i];
                const b = d.items(.end)[i];
                if (css.eq(name, "font-family")) {
                    family = l.familyAt(a, b) orelse "";
                } else if (css.eq(name, "src")) {
                    path = l.fontSrc(a, b, d.items(.loc)[i]) orelse "";
                    src_seen = true;
                } else if (css.eq(name, "font-weight")) {
                    weight = weightOf(c, a, b, 400) orelse blk: {
                        l.ds.err(d.items(.loc)[i], "@font-face font-weight takes one weight: normal, bold or 1 to 1000", .{});
                        break :blk 400;
                    };
                } else if (css.eq(name, "font-style")) {
                    style = styleOf(c, a) orelse blk: {
                        l.ds.err(d.items(.loc)[i], "@font-face font-style takes normal, italic or oblique", .{});
                        break :blk .normal;
                    };
                } else if (!css.eq(name, "font-display") and !css.eq(name, "unicode-range")) {
                    l.ds.err(d.items(.loc)[i], "@font-face descriptor '{s}' is not supported", .{name});
                }
            }
            if (family.len == 0) l.ds.err(face.loc, "@font-face needs a font-family", .{});
            if (!src_seen) l.ds.err(face.loc, "@font-face needs src: url(\"file.ttf\") naming a vendored file", .{});
            if (family.len == 0 or path.len == 0) continue;
            // Relative to the sheet's directory; written relative to the page's.
            const sheet = std.fs.path.dirname(l.ds.files.items[face.loc.file].path) orelse "";
            const page = std.fs.path.dirname(l.ds.files.items[l.doc.file].path) orelse "";
            const rel = if (std.mem.startsWith(u8, sheet, page)) std.mem.trimStart(u8, sheet[page.len..], "/") else sheet;
            const font: u16 = @intCast(l.page.fonts.items.len + 1);
            ok(l.page.fonts.append(l.arena, .{ .entry = .{ .family = family, .font = font, .weight = weight, .style = style }, .path = if (rel.len == 0) path else ok(std.fs.path.join(l.arena, &.{ rel, path })) }));
            ok(l.page.font_locs.append(l.arena, face.loc));
        }
    }

    /// The one family name in tokens `[a, b)`: a string, or idents joined by single spaces.
    fn familyAt(l: *Lowerer, a: u32, b: u32) ?[]const u8 {
        const ty = l.c.toks.items(.type);
        const str = l.c.toks.items(.str);
        var out: std.ArrayList(u8) = .empty;
        for (a..b) |t| switch (ty[t]) {
            .string => return str[t],
            .ident => {
                if (out.items.len > 0) ok(out.append(l.arena, ' '));
                ok(out.appendSlice(l.arena, str[t]));
            },
            .whitespace => {},
            else => {
                l.badValue(@intCast(t), .@"font-family", b);
                return null;
            },
        };
        return if (out.items.len > 0) out.items else null;
    }

    /// The file of an `@font-face` src: its first `url()`, which must be a local path.
    fn fontSrc(l: *Lowerer, a: u32, b: u32, at: Loc) ?[]const u8 {
        const ty = l.c.toks.items(.type);
        const str = l.c.toks.items(.str);
        for (a..b) |t| {
            const url = switch (ty[t]) {
                .url => str[t],
                .function => if (css.eq(str[t], "url") and t + 1 < b and ty[t + 1] == .string) str[t + 1] else if (css.eq(str[t], "local")) {
                    l.ds.err(at, "src: local() names a system font; vendor the file and write url(\"file.ttf\")", .{});
                    return null;
                } else continue,
                else => continue,
            };
            if (std.mem.startsWith(u8, url, "http:") or std.mem.startsWith(u8, url, "https:") or std.mem.startsWith(u8, url, "//") or std.mem.startsWith(u8, url, "data:")) {
                l.ds.err(at, "{s}", .{manifest.refusal("value", "remote-url", "").?});
                return null;
            }
            return url;
        }
        return null;
    }

    /// font-family, font-weight and font-style of `n` to `ts.font`, from the font table.
    fn computeFont(l: *Lowerer, n: u32, ts: *TextStyle) void {
        var fs = l.font[n];
        var changed = false;
        if (l.declared(n, .@"font-family")) |v| {
            fs.family = .{ v.first, v.end };
            fs.loc = v.loc;
            changed = true;
        }
        if (l.declared(n, .@"font-weight")) |v| {
            if (weightOf(l.c, v.first, v.end, fs.weight)) |x| fs.weight = x else l.badValue(v.first, .@"font-weight", v.end);
            changed = true;
        }
        if (l.declared(n, .@"font-style")) |v| {
            if (styleOf(l.c, v.first)) |x| fs.style = x else l.badValue(v.first, .@"font-style", v.end);
            changed = true;
        }
        l.font[n] = fs;
        if (!changed) return;
        ts.font = .default;
        if (fs.family[0] == none) return;
        var catalog: std.ArrayList(lcgf.font_match.Entry) = .empty;
        for (l.page.fonts.items) |f| ok(catalog.append(l.arena, f.entry));
        // One family per comma-separated item; the first with a face wins, a generic one
        // (or none at all) is the theme's font.
        const ty = l.c.toks.items(.type);
        var start = fs.family[0];
        while (start < fs.family[1]) {
            var end = start;
            while (end < fs.family[1] and ty[end] != .comma) end += 1;
            const family = l.familyAt(start, end) orelse return;
            if (isGeneric(family)) return;
            if (lcgf.font_match.find(catalog.items, &.{family}, .{ .weight = fs.weight, .style = fs.style })) |k| {
                ts.font = @fromBackingInt(catalog.items[k].font);
                return;
            }
            start = end + 1;
        }
        l.ds.err(fs.loc, "no @font-face for {s} ({d} {s}); add one or end the list with a generic family", .{ l.c.text(fs.family[0], fs.family[1]), fs.weight, @tagName(fs.style) });
    }

    /// Token `t`, which must be of `kind`.
    fn tokenOf(l: *Lowerer, t: u32, kind: @FieldType(ir.Token, "kind")) u32 {
        const tk = l.page.tokens.items[t];
        if (tk.kind != kind) l.ds.err(tk.loc, "run-time token --{s} is a {s} but sets a {s}", .{ tk.css, @tagName(tk.kind), @tagName(kind) });
        return t;
    }

    fn addNode(l: *Lowerer, node_: ir.Node) u32 {
        var node = node_;
        if (l.uses.items.len > 0) {
            node.uses = ok(l.arena.dupe(ir.TokenUse, l.uses.items));
            l.uses.clearRetainingCapacity();
        }
        if (l.current != none) node.text_uses = l.text_tokens[l.current];
        node.flex = l.flex;
        l.flex = .{};
        if (l.marker.len > 0) l.markItem(&node);
        if (l.shadow != null or l.outline != null) l.decorate(&node);
        ok(l.page.nodes.append(l.arena, node));
        return @intCast(l.page.nodes.len - 1);
    }

    /// A list item with a marker: the item's box becomes a row (its style, margins, role and
    /// decorations) holding a label of the marker, in the item's text style, then the item's
    /// content, which keeps the item's own layout of its children and fills the rest of the
    /// row. `node` becomes that content node.
    fn markItem(l: *Lowerer, node: *ir.Node) void {
        const marker = l.marker;
        l.marker = "";
        var item: ir.Node = .{ .kind = .container, .parent = node.parent, .loc = node.loc, .dir = .x, .style = node.style, .params_expr = node.params_expr, .margin = node.margin, .uses = node.uses, .name = node.name };
        item.style.dir = .x;
        item.style.gap = 0;
        item.style.main = .start;
        item.style.cross = .start;
        item.style.role = .list_item;
        item.flex = .{ .cross = node.flex.cross, .aspect = node.flex.aspect };
        if (l.shadow != null or l.outline != null) l.decorate(&item);
        ok(l.page.nodes.append(l.arena, item));
        const row_: u32 = @intCast(l.page.nodes.len - 1);
        const th = &l.page.theme;
        const ls = lcgf.widgets_label.labelStyle(th);
        const counted = std.mem.startsWith(u8, marker, "lcgf.text_counters.");
        ok(l.page.nodes.append(l.arena, .{ .kind = .label, .parent = row_, .loc = node.loc, .style = ls, .base_style = ls, .text_style = l.text[l.current], .base_text = lcgf.widgets_label.labelText(th), .text_kind = if (counted) .counter else .literal, .text = marker, .text_uses = l.text_tokens[l.current] }));
        // The content: the item's flow of its children, or its text, filling the row.
        const box = node.style;
        node.parent = row_;
        node.style = if (node.kind == .container) .{ .dir = box.dir, .gap = box.gap, .main = box.main, .cross = box.cross } else node.base_style;
        node.style.size[0] = .fill;
        node.params_expr = "";
        node.margin = null;
        node.uses = &.{};
        node.name = "";
        node.flex.cross = null;
        node.flex.aspect = 0;
    }

    /// The marker of list item `n` by its inherited `list-style-type`, or "" for none: a
    /// bullet (disc, circle, square, disclosure-open, disclosure-closed), a string as written,
    /// or a counter (`counter_styles`) of the item's place among its siblings from the
    /// list's `start` (down from it under `reversed`), formatted at build time by
    /// text_counters.
    fn markerOf(l: *Lowerer, n: u32) []const u8 {
        var i = n;
        while (i != none and l.k.get(i, .@"list-style-type").decl == none) i = l.doc.nodes.items(.parent)[i];
        if (i == none) return "";
        const v = l.declared(i, .@"list-style-type") orelse return "";
        const r = l.component(v) orelse return "";
        if (r[1] - r[0] == 1 and l.c.toks.items(.type)[r[0]] == .string) return l.c.toks.items(.str)[r[0]];
        const kw = l.keyword(i, .@"list-style-type") orelse return "";
        for ([_][2][]const u8{ .{ "disc", "\u{2022} " }, .{ "circle", "\u{25E6} " }, .{ "square", "\u{25AA} " }, .{ "disclosure-open", "\u{25BE} " }, .{ "disclosure-closed", "\u{25B8} " }, .{ "none", "" } }) |m| if (css.eq(kw, m[0])) return m[1];
        const style = for (counter_styles) |cs| {
            if (css.eq(kw, cs[0])) break cs[1];
        } else {
            l.ds.err(v.loc, "list-style-type: {s} is not lowered; use a bullet, a string, none, or decimal, decimal-leading-zero, lower- or upper-alpha, -latin, -roman, or lower-greek", .{kw});
            return "";
        };
        const p = l.doc.nodes.items(.parent)[n];
        if (p != none and l.doc.isElement(p, "template")) {
            // An item of `lcgf-each="x in xs"`: counted at run time from the copy index, in
            // the list around the template.
            const each = l.eachOf(n);
            if (each == none or l.doc.nodes.items(.parent)[n] != p or l.ir_of[p] != each) {
                l.ds.err(l.loc(n), "a counter marker in a template other than lcgf-each=\"x in xs\" has no item index (lcgf-max copies share one template); use a bullet or none there", .{});
                return "";
            }
            const list = l.doc.nodes.items(.parent)[p];
            const reversed = list != none and l.attr(list, "reversed") != null;
            const start = if (list != none) l.attr(list, "start") else null;
            const from = if (start) |st| ok(std.fmt.allocPrint(l.arena, "{d}", .{std.fmt.parseInt(i64, std.mem.trim(u8, st, " "), 10) catch 1})) else if (reversed) ok(std.fmt.allocPrint(l.arena, "@as(i64, @intCast(data.{f}.len))", .{std.zig.fmtId(l.page.nodes.items(.bind)[each])})) else "1";
            const cs = for (counter_styles) |c| {
                if (std.meta.eql(c[1], style)) break c;
            } else unreachable;
            return ok(std.fmt.allocPrint(l.arena, "lcgf.text_counters.format(@as(i64, {s}) {s} @as(i64, @intCast(copy0)), {s}, &mark) catch \"\"", .{ from, if (reversed) "-" else "+", cs[2] }));
        }
        // The item's place among the list's items; a reversed list counts down, by default
        // from its item count (HTML).
        var before: i64 = 0;
        var items: i64 = 0;
        if (p != none) for (p + 1..l.k.end[p]) |k| {
            if (l.doc.nodes.items(.parent)[k] != p or !l.doc.isElement(@intCast(k), "li")) continue;
            items += 1;
            if (k < n) before += 1;
        };
        const reversed = p != none and l.attr(p, "reversed") != null;
        const start: i64 = if (p != none) (if (l.attr(p, "start")) |st| std.fmt.parseInt(i64, std.mem.trim(u8, st, " "), 10) catch 1 else if (reversed) items else 1) else 1;
        const ordinal = if (reversed) start - before else start + before;
        const counters = lcgf.text_counters;
        const out = ok(l.arena.alloc(u8, counters.required(ordinal, style) catch 64));
        return counters.format(ordinal, style, out) catch |e| {
            l.ds.err(l.loc(n), "list marker {d}: {t}", .{ ordinal, e });
            return "";
        };
    }

    /// A box with a shadow or an outline: a column in its place takes what places and sizes
    /// it among its siblings (size, min, max, margins, align-self, aspect, position,
    /// transform, opacity, visibility) and holds floating nodes of its size, the shadow and
    /// the outline ring, then the box, which fills it. They paint first, so the shadow is
    /// under the box; the ring lies outside it. Their paint outsets place them (the shadow's
    /// offset and spread; the ring's width and offset), and `features.shadow` blurs the
    /// shadow. Both frontends build the nodes as written.
    fn decorate(l: *Lowerer, node: *ir.Node) void {
        const shade = l.shadow;
        const ring = l.outline;
        l.shadow = null;
        l.outline = null;
        switch (node.kind) {
            .when, .list, .choice, .each => return l.ds.err(node.loc, "box-shadow and outline on a template are not lowered; put them on the element inside", .{}),
            else => {},
        }
        if (node.uses.len > 0) return l.ds.err(node.loc, "box-shadow and outline on a box sized or painted by run-time tokens are not lowered", .{});
        const b = node.style;
        const d: Style = .{};
        const wrap_style: Style = .{ .size = b.size, .min = b.min, .max = b.max, .shrink = b.shrink, .float = b.float, .offset = b.offset, .transform = b.transform, .transform_origin = b.transform_origin, .opacity = b.opacity, .participation = b.participation };
        var wrapper: ir.Node = .{ .kind = .container, .parent = node.parent, .loc = node.loc, .style = wrap_style, .margin = node.margin };
        wrapper.flex = .{ .cross = node.flex.cross, .aspect = node.flex.aspect };
        node.flex.cross = null;
        node.flex.aspect = 0;
        node.margin = null;
        node.style.size = .{ .fill, .fill };
        inline for (.{ "min", "max", "shrink", "float", "offset", "transform", "transform_origin", "opacity", "participation" }) |f| @field(node.style, f) = @field(d, f);
        ok(l.page.nodes.append(l.arena, wrapper));
        const w: u32 = @intCast(l.page.nodes.len - 1);
        node.parent = w;
        if (shade) |sh| {
            const s = sh.spread;
            const shadow: Style = .{ .float = true, .size = .{ .pct(1), .pct(1) }, .fill = sh.color, .radius = @max(b.radius + s, 0), .radii = grown(b.radii, s), .paint_outset = .{ s - sh.x, s - sh.y, s + sh.x, s + sh.y } };
            ok(l.page.nodes.append(l.arena, .{ .kind = .container, .parent = w, .loc = node.loc, .style = shadow, .params_expr = ok(std.fmt.allocPrint(l.arena, "lcgf.features.shadow({d})", .{sh.blur / 2})) }));
        }
        if (ring) |o| {
            const g = o.width + o.offset;
            const style: Style = .{ .float = true, .size = .{ .pct(1), .pct(1) }, .border = o.width, .border_color = o.color, .radius = b.radius + g, .radii = grown(b.radii, g), .paint_outset = @splat(g) };
            ok(l.page.nodes.append(l.arena, .{ .kind = .container, .parent = w, .loc = node.loc, .style = style }));
        }
    }

    /// Per-corner radii grown by `by`; a corner that takes `radius` (negative) still does.
    fn grown(radii: [4]f32, by: f32) [4]f32 {
        var out = radii;
        for (&out) |*r| r.* = if (r.* < 0) -1 else @max(r.* + by, 0);
        return out;
    }

    /// `outline: width style color` and `outline-offset`, into `l.outline`. CSS's initial
    /// style is none, so only a declared solid (or auto) style draws one.
    fn outlineOf(l: *Lowerer, n: u32) void {
        const kw = l.keyword(n, .@"outline-style") orelse return;
        if (css.eq(kw, "none") or css.eq(kw, "hidden")) return;
        if (!css.eq(kw, "solid") and !css.eq(kw, "auto"))
            return l.ds.err(l.declared(n, .@"outline-style").?.loc, "outline-style: {s} is not lowered; use solid", .{kw});
        const width = l.px(n, .@"outline-width") orelse 3; // medium
        const offset = l.px(n, .@"outline-offset") orelse 0;
        if (offset < 0 or width < 0) return l.ds.err(l.declared(n, .@"outline-style").?.loc, "an outline inside the box (negative width or offset) is not lowered", .{});
        l.outline = .{ .width = width, .offset = offset, .color = l.colorOf(n, .@"outline-color") orelse l.text[n].color };
    }

    /// `box-shadow: [x y [blur [spread]]] [color]`, one outer shadow, into `l.shadow`.
    fn boxShadow(l: *Lowerer, n: u32) void {
        const v = l.declared(n, .@"box-shadow") orelse return;
        if (values.isIdent(l.c, v.first, "none")) return;
        var lens: [4]f32 = @splat(0);
        var count: usize = 0;
        var color: types.Color = l.text[n].color; // currentcolor
        var rd: values.Reader = .init(l.c, v.first, v.end);
        while (rd.next()) |t| {
            const ty = l.c.toks.items(.type)[t];
            if (ty == .comma) return l.ds.err(l.c.tokLoc(t), "more than one box-shadow is not lowered; give one", .{});
            if (values.isIdent(l.c, t, "inset")) return l.ds.err(l.c.tokLoc(t), "an inset box-shadow is not lowered (P2 decoration)", .{});
            if (ty == .dimension or ty == .number) {
                if (count == lens.len) return l.badValue(t, .@"box-shadow", v.end);
                const len = l.lengthAt(n, t, t + 1, .@"box-shadow") orelse return;
                if (len != .px) return l.badValue(t, .@"box-shadow", v.end);
                lens[count] = len.px;
                count += 1;
                continue;
            }
            if (values.isIdent(l.c, t, "currentcolor")) continue;
            color = values.color(l.c, t, rd.i) orelse return l.badValue(t, .@"box-shadow", v.end);
        }
        if (count < 2) return l.ds.err(v.loc, "box-shadow takes an x and a y offset", .{});
        if (lens[2] < 0) return l.ds.err(v.loc, "a box-shadow's blur cannot be negative", .{});
        l.shadow = .{ .x = lens[0], .y = lens[1], .blur = lens[2], .spread = lens[3], .color = color };
    }

    /// The display of `n`: what box, if any, it makes.
    const Display = enum { none, contents, block, flex };

    fn display(l: *Lowerer, n: u32) Display {
        const kw = l.keyword(n, .display) orelse return .block;
        if (css.eq(kw, "none")) return .none;
        if (css.eq(kw, "contents")) return .contents;
        if (css.eq(kw, "flex") or css.eq(kw, "inline-flex")) return .flex;
        if (css.eq(kw, "block") or css.eq(kw, "inline") or css.eq(kw, "inline-block") or css.eq(kw, "flow-root") or css.eq(kw, "list-item")) return .block;
        if (!l.refused("value", kw, "display", l.declared(n, .display).?.loc)) l.badValue(l.declared(n, .display).?.first, .display, l.declared(n, .display).?.end);
        return .block;
    }

    /// Element children of `n` and whether any text child has more than whitespace.
    fn content(l: *const Lowerer, n: u32) struct { elements: u32, text: bool, br_only: bool } {
        var elements: u32 = 0;
        var text = false;
        var br_only = true;
        for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.parent)[i] == n) {
            if (l.doc.nodes.items(.kind)[i] == .text) {
                text = text or !isBlank(l.doc.nodes.items(.name)[i]);
            } else {
                elements += 1;
                if (!std.mem.eql(u8, l.tag(@intCast(i)), "br")) br_only = false;
            }
        };
        return .{ .elements = elements, .text = text, .br_only = br_only };
    }

    fn element(l: *Lowerer, n: u32, parent: u32) void {
        const t = l.tag(n);
        if (l.doc.nodes.items(.in_template)[n] and !std.mem.eql(u8, t, "template")) {
            // Template content is lowered by its directive (§3.5); plain templates are inert.
        }
        if (l.refused("element", t, "", l.loc(n))) {
            l.skip[n] = true;
            return;
        }
        l.attributes(n);
        if (l.k.get(n, .@"accent-color").decl != none)
            l.ds.err(l.declared(n, .@"accent-color").?.loc, "accent-color is lowered on :root only, as the theme's accent", .{});
        if (std.mem.eql(u8, t, "template")) {
            l.template(n, parent);
            return;
        }
        if (std.mem.eql(u8, t, "noscript") or std.mem.eql(u8, t, "style") or std.mem.eql(u8, t, "link") or std.mem.eql(u8, t, "meta") or std.mem.eql(u8, t, "title")) {
            l.skip[n] = true;
            return;
        }
        if (l.attr(n, "hidden") != null and !isBound(l.attr(n, "hidden").?)) {
            l.skip[n] = true;
            return;
        }
        const disp = l.display(n);
        if (disp == .none) {
            l.skip[n] = true;
            return;
        }
        if (disp == .contents) return; // children go to the nearest box
        if (isComponent(t)) return l.appComponent(n, parent);
        if (l.widget(n, t, parent)) return l.tooltip(n);
        if (l.attr(n, "title") != null) l.ds.err(l.attrLoc(n, "title"), "title= is a tooltip, which only a widget shows (a button or a control)", .{});
        const content_ = l.content(n);
        const heading = headingLevel(t);
        const text_like = (content_.elements == 0 or content_.br_only) and (content_.text or heading != 0 or std.mem.eql(u8, t, "p"));
        if (text_like and !isLandmark(t)) {
            l.label(n, parent, heading);
            return;
        }
        if (std.mem.eql(u8, t, "p") and content_.text and content_.elements > 0) return l.inlineRuns(n, parent);
        if (std.mem.eql(u8, t, "hr")) {
            l.separator(n, parent);
            return;
        }
        if (std.mem.eql(u8, t, "br") or std.mem.eql(u8, t, "wbr")) return;
        l.container(n, parent, disp);
    }

    /// Attributes every element may carry: refused ones, script handlers, ids.
    fn attributes(l: *Lowerer, n: u32) void {
        const doc = l.doc;
        const first = doc.nodes.items(.attr_first)[n];
        for (first..first + doc.nodes.items(.attr_count)[n]) |a_| {
            const a: u32 = @intCast(a_);
            const name = doc.attrs.items(.name)[a];
            if (std.mem.startsWith(u8, name, "on") and !std.mem.startsWith(u8, name, "on:")) {
                l.ds.err(doc.attrLoc(a), "{s}", .{manifest.refusal("attribute", "on*", "").?});
                continue;
            }
            if (std.mem.eql(u8, name, "tabindex")) {
                const v = std.fmt.parseInt(i32, doc.attrs.items(.value)[a], 10) catch 0;
                if (v > 0) l.ds.err(doc.attrLoc(a), "{s}", .{manifest.refusal("attribute", "tabindex", "positive").?});
                continue;
            }
            _ = l.refused("attribute", name, "", doc.attrLoc(a));
        }
        if (l.attr(n, "style")) |s| {
            _ = s;
            // Parsed before the cascade (`inlineStyles`); nothing to do here.
        }
    }

    /// The style a CSS box gives node `n`, over `base` (the builder's own look). `axis` is
    /// the parent's direction: flex-grow and flex-basis act along it.
    fn boxStyle(l: *Lowerer, n: u32, base: Style, axis: types.Axis, params: *[]const u8, margin: *?[4]f32) Style {
        var s = base;
        l.uses.clearRetainingCapacity();
        l.flex = .{};
        l.shadow = null;
        l.outline = null;
        l.marker = "";
        l.boxShadow(n);
        l.outlineOf(n);
        const main: u1 = @backingInt(axis);
        const cross: u1 = 1 - main;
        inline for (.{ .{ Prop.width, 0, ir.Target.width }, .{ Prop.height, 1, ir.Target.height } }) |pa| if (l.length(n, pa[0])) |len| {
            if (len == .px) l.use(pa[2]);
            s.size[pa[1]] = switch (len) {
                .px => |v| .px(v),
                .pct => |v| .pct(v),
                .auto => .fit,
            };
        };
        inline for (.{ .{ Prop.@"min-width", 0, ir.Target.min_width }, .{ Prop.@"min-height", 1, ir.Target.min_height } }) |pa| if (l.px(n, pa[0])) |v| {
            s.min[pa[1]] = v;
            l.use(pa[2]);
        };
        inline for (.{ .{ Prop.@"max-width", 0, ir.Target.max_width }, .{ Prop.@"max-height", 1, ir.Target.max_height } }) |pa| if (l.px(n, pa[0])) |v| {
            s.max[pa[1]] = v;
            l.use(pa[2]);
        };
        // CSS top, right, bottom, left; LCGF left, top, right, bottom.
        inline for (.{ .{ Prop.@"padding-left", 0, ir.Target.pad_left }, .{ Prop.@"padding-top", 1, ir.Target.pad_top }, .{ Prop.@"padding-right", 2, ir.Target.pad_right }, .{ Prop.@"padding-bottom", 3, ir.Target.pad_bottom } }) |pa| if (l.px(n, pa[0])) |v| {
            s.pad[pa[1]] = v;
            l.use(pa[2]);
        };
        if (l.number(n, .@"flex-grow")) |g| s.size[main] = if (g == 0) s.size[main] else .grow(g);
        if (l.number(n, .@"flex-shrink")) |g| s.shrink = g > 0;
        if (l.length(n, .@"flex-basis")) |len| switch (len) {
            .px => |v| s.size[main] = if (s.size[main].kind == .grow) s.size[main] else .px(v),
            .pct => |v| s.size[main] = .pct(v),
            .auto => {},
        };
        if (l.keyword(n, .@"align-self")) |kw| {
            if (css.eq(kw, "stretch")) s.size[cross] = .fill else if (alignOf(kw)) |a| {
                l.flex.cross = a;
            } else if (!css.eq(kw, "auto")) l.badValue(l.declared(n, .@"align-self").?.first, .@"align-self", l.declared(n, .@"align-self").?.end);
        }
        // Margins are flex item margins (engine spec F2).
        var m: [4]f32 = .{ 0, 0, 0, 0 };
        var has_margin = false;
        inline for (.{ .{ Prop.@"margin-left", 0 }, .{ Prop.@"margin-top", 1 }, .{ Prop.@"margin-right", 2 }, .{ Prop.@"margin-bottom", 3 } }) |pa| if (l.length(n, pa[0])) |len| switch (len) {
            .px => |v| if (v != 0) {
                m[pa[1]] = v;
                has_margin = true;
            },
            .auto => l.ds.err(l.declared(n, pa[0]).?.loc, "margin: auto is not supported yet; use justify-content or a spacer", .{}),
            .pct => l.ds.err(l.declared(n, pa[0]).?.loc, "a margin in % is not supported; give px", .{}),
        };
        if (has_margin) margin.* = m;
        if (l.declared(n, .@"aspect-ratio")) |v| l.aspectRatio(v);
        // overflow
        inline for (.{ Prop.@"overflow-x", Prop.@"overflow-y" }) |p| if (l.keyword(n, p)) |kw| {
            if (css.eq(kw, "hidden") or css.eq(kw, "clip")) s.clip = true else if (!css.eq(kw, "visible")) l.ds.err(l.declared(n, p).?.loc, "overflow: {s} needs a scroll container, which the compiler does not lower yet", .{kw});
        };
        if (l.colorOf(n, .@"background-color")) |col| {
            s.fill = col;
            l.use(.fill);
        }
        if (l.declared(n, .@"background-image")) |v| if (l.component(v)) |r| {
            if (!values.isIdent(l.c, r[0], "none")) l.gradient(n, r, &s, params);
        };
        if (l.px(n, .@"border-top-width")) |w| {
            s.border = w;
            l.use(.border);
        }
        if (l.colorOf(n, .@"border-color")) |col| {
            s.border_color = col;
            l.use(.border_color);
        }
        if (l.keyword(n, .@"border-style")) |kw| {
            if (params.len > 0 and (css.eq(kw, "dashed") or css.eq(kw, "dotted")))
                l.ds.err(l.declared(n, .@"border-style").?.loc, "one quad feature per box: a {s} border and a gradient cannot share a box", .{kw});
            if (css.eq(kw, "none") or css.eq(kw, "hidden")) s.border = 0 else if (css.eq(kw, "dashed")) {
                params.* = ok(std.fmt.allocPrint(l.arena, "lcgf.features.dashed({d}, {d})", .{ 3 * @max(s.border, 1), 3 * @max(s.border, 1) }));
            } else if (css.eq(kw, "dotted")) {
                params.* = ok(std.fmt.allocPrint(l.arena, "lcgf.features.dotted({d})", .{@max(s.border, 1)}));
            } else if (!css.eq(kw, "solid")) l.ds.err(l.declared(n, .@"border-style").?.loc, "border-style: {s} is not supported; use solid, dashed or dotted", .{kw});
        }
        // CSS's border colour defaults to currentcolor; a widget's own border keeps its colour.
        if (l.k.get(n, .@"border-top-width").decl != none and l.k.get(n, .@"border-color").decl == none) s.border_color = l.text[n].color;
        var radii: [4]f32 = .{ -1, -1, -1, -1 };
        var any_radius = false;
        inline for (.{ Prop.@"border-top-left-radius", Prop.@"border-top-right-radius", Prop.@"border-bottom-right-radius", Prop.@"border-bottom-left-radius" }, 0..) |p, i| if (l.px(n, p)) |v| {
            radii[i] = v;
            any_radius = true;
            if (i == 0) l.use(.radius);
        };
        if (any_radius) {
            if (radii[0] == radii[1] and radii[1] == radii[2] and radii[2] == radii[3]) s.radius = radii[0] else {
                for (&radii) |*r| r.* = @max(r.*, 0);
                s.radii = radii;
            }
        }
        if (l.number(n, .opacity)) |o| s.opacity = std.math.clamp(o, 0, 1);
        if (l.keyword(n, .visibility)) |kw| {
            if (css.eq(kw, "hidden") or css.eq(kw, "collapse")) s.participation = .hidden;
        }
        if (l.keyword(n, .@"pointer-events")) |kw| {
            if (css.eq(kw, "none")) s.participation.hit = false;
        }
        if (l.keyword(n, .cursor)) |kw| s.cursor = cursorOf(kw) orelse blk: {
            l.ds.err(l.declared(n, .cursor).?.loc, "cursor: '{s}' has no LCGF cursor", .{kw});
            break :blk null;
        };
        l.position(n, &s);
        l.transform(n, &s);
        return s;
    }

    /// `aspect-ratio: W / H`, `W`, `auto` or `auto W / H` as Flex.Style.aspect (W over H). An
    /// LCGF box is never a replaced element, so `auto` with a ratio is the ratio.
    fn aspectRatio(l: *Lowerer, v: Value) void {
        var rd: values.Reader = .init(l.c, v.first, v.end);
        var ratio: [2]f32 = .{ 0, 1 };
        var count: usize = 0;
        var slash = false;
        const ty = l.c.toks.items(.type);
        while (rd.next()) |t| {
            if (count == 0 and values.isIdent(l.c, t, "auto")) continue;
            if (ty[t] == .delim and l.c.toks.items(.delim)[t] == '/' and count == 1 and !slash) {
                slash = true;
                continue;
            }
            if (ty[t] == .number and (count == 0 or (count == 1 and slash))) {
                ratio[count] = @floatCast(l.c.toks.items(.num)[t]);
                count += 1;
                continue;
            }
            return l.badValue(t, .@"aspect-ratio", v.end);
        }
        if (count == 0) return; // auto
        if (slash and count != 2) return l.badValue(v.first, .@"aspect-ratio", v.end);
        if (!(ratio[0] > 0 and ratio[1] > 0)) return l.ds.err(v.loc, "aspect-ratio takes a positive ratio", .{});
        l.flex.aspect = ratio[0] / ratio[1];
    }

    fn gradient(l: *Lowerer, n: u32, r: [2]u32, s: *Style, params: *[]const u8) void {
        const t = r[0];
        const ty = l.c.toks.items(.type)[t];
        // `url(x.png)` or `url("x.png")`: the asset's texture over the box, stretched to it.
        const url: ?[]const u8 = if (ty == .url) l.c.toks.items(.str)[t] else if (ty == .function and css.eq(l.c.toks.items(.str)[t], "url") and t + 1 < r[1] and l.c.toks.items(.type)[t + 1] == .string) l.c.toks.items(.str)[t + 1] else null;
        if (url) |src| {
            const box: [2]f32 = .{ if (s.size[0].kind == .px) s.size[0].v else 0, if (s.size[1].kind == .px) s.size[1].v else 0 };
            const k = l.asset(src, l.c.tokLoc(t), box) orelse return;
            if (l.k.get(n, .@"background-color").decl != none and !std.meta.eql(s.fill, types.Color.transparent))
                l.ds.err(l.c.tokLoc(t), "a background-color under a background-image is not drawn: one quad per box; set one of them", .{});
            s.texture = @fromBackingInt(@as(u16, @intCast(k + 1)));
            s.fill = .white;
            return;
        }
        const name = if (ty == .function) l.c.toks.items(.str)[t] else "";
        const radial = css.eq(name, "radial-gradient");
        if (!radial and !css.eq(name, "linear-gradient")) {
            l.ds.err(l.c.tokLoc(t), "background-image: only url(), linear-gradient() and radial-gradient() are lowered", .{});
            return;
        }
        const close = values.closeOf(l.c, t, r[1]);
        var rd: values.Reader = .init(l.c, t + 1, close - 1);
        var item: [65][2]u32 = undefined;
        var count: usize = 0;
        while (!rd.done()) {
            const s0 = rd.i;
            const e = rd.untilComma();
            if (count == item.len) {
                l.ds.err(l.c.tokLoc(t), "a gradient takes at most 64 colours", .{});
                return;
            }
            item[count] = .{ s0, e };
            count += 1;
            rd.i = @min(e + 1, rd.end);
        }
        // The first item is the gradient's shape unless it is a colour stop.
        const shaped = count > 0 and values.color(l.c, item[0][0], item[0][1]) == null;
        var angle: f32 = std.math.pi; // `to bottom`, CSS's default
        var centre: [2]f32 = .{ 0.5, 0.5 };
        var radius: ?f32 = null;
        if (shaped and !radial) {
            var a: values.Reader = .init(l.c, item[0][0], item[0][1]);
            const at = a.next().?;
            if (values.angle(l.c, at)) |x| angle = x else if (values.isIdent(l.c, at, "to")) {
                const dir = a.next() orelse at;
                const d = l.c.toks.items(.str)[dir];
                angle = if (css.eq(d, "right")) std.math.pi / 2.0 else if (css.eq(d, "left")) 3 * std.math.pi / 2.0 else if (css.eq(d, "top")) 0 else std.math.pi;
            } else {
                l.ds.err(l.c.tokLoc(at), "expected an angle or 'to <side>' in linear-gradient()", .{});
                return;
            }
        } else if (shaped) {
            // `circle`, a radius in px, `at X Y` (percentages or keywords); in any order CSS allows.
            var a: values.Reader = .init(l.c, item[0][0], item[0][1]);
            var after_at: u2 = 0;
            while (a.next()) |x| {
                if (values.isIdent(l.c, x, "at")) {
                    after_at = 1;
                    continue;
                }
                if (after_at > 0 and after_at < 3) {
                    const axis = after_at - 1;
                    const kw = values.ident(l.c, x);
                    const v: ?f32 = if (kw) |k| (if (css.eq(k, "center")) 0.5 else if (css.eq(k, "left") or css.eq(k, "top")) 0 else if (css.eq(k, "right") or css.eq(k, "bottom")) 1 else null) else if (values.len(l.c, x)) |len| (if (len.unit == .pct) len.v / 100 else null) else null;
                    centre[axis] = v orelse {
                        l.ds.err(l.c.tokLoc(x), "radial-gradient(): the centre is given in % or by keywords", .{});
                        return;
                    };
                    after_at += 1;
                    continue;
                }
                if (values.isIdent(l.c, x, "circle")) continue;
                if (values.len(l.c, x)) |len| if (values.px(len, l.text[n].px, l.root_px)) |v| {
                    radius = v;
                    continue;
                };
                l.ds.err(l.c.tokLoc(x), "radial-gradient(): only a circle, its radius in px and 'at X Y' are lowered", .{});
                return;
            }
        }
        if (radial and radius == null) {
            // CSS's farthest-corner, from a box whose size is known while building.
            if (s.size[0].kind != .px or s.size[1].kind != .px) {
                l.ds.err(l.c.tokLoc(t), "radial-gradient(): give its radius in px, or the box a px width and height", .{});
                return;
            }
            const w = s.size[0].v;
            const h = s.size[1].v;
            const dx = @max(centre[0], 1 - centre[0]) * w;
            const dy = @max(centre[1], 1 - centre[1]) * h;
            radius = @sqrt(dx * dx + dy * dy);
        }
        // Colour stops: a colour and an optional percentage.
        var stops: [64]lcgf.features.Stop = undefined;
        var given: [64]bool = undefined;
        const n_stops = count - @intFromBool(shaped);
        if (n_stops < 2) {
            l.ds.err(l.c.tokLoc(t), "a gradient needs at least two colours", .{});
            return;
        }
        for (item[@intFromBool(shaped)..count], 0..) |it, k| {
            var a: values.Reader = .init(l.c, it[0], it[1]);
            const c0 = a.next().?;
            stops[k] = .{ .color = values.color(l.c, c0, it[1]) orelse {
                l.ds.err(l.c.tokLoc(c0), "expected a colour stop", .{});
                return;
            }, .at = 0 };
            given[k] = false;
            if (a.next()) |p| {
                const len = values.len(l.c, p);
                if (len == null or len.?.unit != .pct or a.next() != null) {
                    l.ds.err(l.c.tokLoc(p), "a colour stop's position is one percentage", .{});
                    return;
                }
                stops[k].at = len.?.v / 100;
                given[k] = true;
            }
        }
        fixStops(stops[0..n_stops], given[0..n_stops]);
        const plain = n_stops == 2 and stops[0].at == 0 and stops[1].at == 1;
        // CSS angles start at the top, clockwise; features.linear's 0 runs left to right.
        const rad = angle - std.math.pi / 2.0;
        if (plain) {
            s.fill = stops[0].color;
            params.* = if (radial)
                ok(std.fmt.allocPrint(l.arena, "lcgf.features.radial({s}, .{{ {d}, {d} }}, {d})", .{ colorExpr(l.arena, stops[1].color), centre[0], centre[1], radius.? }))
            else
                ok(std.fmt.allocPrint(l.arena, "lcgf.features.linear({s}, {d})", .{ colorExpr(l.arena, stops[1].color), rad }));
            return;
        }
        // More colours, or stops not at the ends: a ramp row in the asset table (features.ramp).
        if (l.k.get(n, .@"background-color").decl != none and !std.meta.eql(s.fill, types.Color.transparent))
            l.ds.err(l.c.tokLoc(t), "a background-color under a gradient of more than two colours is not drawn: one quad per box; set one of them", .{});
        const k = l.ramp(stops[0..n_stops], l.c.text(t, close), l.c.tokLoc(t)) orelse return;
        s.texture = @fromBackingInt(@as(u16, @intCast(k + 1)));
        s.fill = .white;
        params.* = if (radial)
            ok(std.fmt.allocPrint(l.arena, "lcgf.features.radialRamp(.{{ {d}, {d} }}, {d})", .{ centre[0], centre[1], radius.? }))
        else
            ok(std.fmt.allocPrint(l.arena, "lcgf.features.linearRamp({d})", .{rad}));
    }

    /// The asset of a gradient's ramp row (`ramp_texels` wide), made here; one per distinct row.
    fn ramp(l: *Lowerer, stops: []const lcgf.features.Stop, text: []const u8, at: Loc) ?u32 {
        const texels = ok(l.arena.alloc(u32, ramp_texels));
        lcgf.features.rampPixels(stops, texels);
        const bytes = std.mem.sliceAsBytes(texels);
        for (l.page.assets.items, 0..) |a, k| if (a.path.len == 0 and std.mem.eql(u8, a.pixels, bytes)) return @intCast(k);
        if (l.page.assets.items.len + 1 >= std.math.maxInt(u16)) {
            l.ds.err(at, "too many images on one page", .{});
            return null;
        }
        const src = ok(l.arena.dupe(u8, text));
        for (src) |*c| if (c.* == '\n' or c.* == '\r') {
            c.* = ' ';
        };
        ok(l.page.assets.append(l.arena, .{ .src = src, .path = "", .loc = at, .w = ramp_texels, .h = 1, .pixels = bytes }));
        return @intCast(l.page.assets.items.len - 1);
    }

    fn position(l: *Lowerer, n: u32, s: *Style) void {
        const kw = l.keyword(n, .position) orelse return;
        if (css.eq(kw, "static")) return;
        const left = l.px(n, .left) orelse 0;
        const top = l.px(n, .top) orelse 0;
        if (css.eq(kw, "relative")) {
            s.transform[4] += left;
            s.transform[5] += top;
        } else if (css.eq(kw, "absolute")) {
            s.float = true;
            s.offset = .{ left, top };
        } else l.ds.err(l.declared(n, .position).?.loc, "position: {s} needs anchors (engine spec F17), not lowered yet", .{kw});
        for ([_]Prop{ .right, .bottom }) |p| if (l.k.get(n, p).decl != none)
            l.ds.err(l.declared(n, p).?.loc, "{s} needs anchors (engine spec F17), not lowered yet; position with top and left", .{@tagName(p)});
    }

    fn transform(l: *Lowerer, n: u32, s: *Style) void {
        if (l.declared(n, .@"transform-origin")) |v| {
            var rd: values.Reader = .init(l.c, v.first, v.end);
            var i: usize = 0;
            while (rd.next()) |t| : (i += 1) {
                if (i == 2) break;
                const kw = values.ident(l.c, t);
                const len = values.len(l.c, t);
                const axis: usize = if (kw != null and (css.eq(kw.?, "top") or css.eq(kw.?, "bottom"))) 1 else i;
                s.transform_origin[axis] = if (kw) |k| (if (css.eq(k, "left") or css.eq(k, "top")) 0 else if (css.eq(k, "center")) 0.5 else 1) else if (len != null and len.?.unit == .pct) len.?.v / 100 else blk: {
                    l.ds.err(l.c.tokLoc(t), "transform-origin: give % or keywords", .{});
                    break :blk 0.5;
                };
            }
        }
        const v = l.declared(n, .transform) orelse return;
        if (values.isIdent(l.c, v.first, "none")) return;
        var m = s.transform;
        var rd: values.Reader = .init(l.c, v.first, v.end);
        while (rd.next()) |t| {
            if (l.c.toks.items(.type)[t] != .function) {
                l.badValue(t, .transform, v.end);
                return;
            }
            const name = l.c.toks.items(.str)[t];
            const close = values.closeOf(l.c, t, v.end);
            var args: [6]f32 = @splat(0);
            var count: usize = 0;
            var ar: values.Reader = .init(l.c, t + 1, close - 1);
            while (ar.next()) |a| {
                if (l.c.toks.items(.type)[a] == .comma) continue;
                if (count == args.len) break;
                args[count] = if (values.angle(l.c, a)) |x| (if (l.c.toks.items(.type)[a] == .dimension) x else @floatCast(l.c.toks.items(.num)[a])) else if (values.len(l.c, a)) |len| (values.px(len, l.text[n].px, l.root_px) orelse len.v) else 0;
                count += 1;
            }
            var f: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
            if (css.eq(name, "translate")) {
                f[4] = args[0];
                f[5] = if (count > 1) args[1] else 0;
            } else if (css.eq(name, "translatex")) {
                f[4] = args[0];
            } else if (css.eq(name, "translatey")) {
                f[5] = args[0];
            } else if (css.eq(name, "scale")) {
                f[0] = args[0];
                f[3] = if (count > 1) args[1] else args[0];
            } else if (css.eq(name, "scalex")) {
                f[0] = args[0];
            } else if (css.eq(name, "scaley")) {
                f[3] = args[0];
            } else if (css.eq(name, "rotate")) {
                f = .{ @cos(args[0]), @sin(args[0]), -@sin(args[0]), @cos(args[0]), 0, 0 };
            } else if (css.eq(name, "skewx")) {
                f[2] = @tan(args[0]);
            } else if (css.eq(name, "skewy")) {
                f[1] = @tan(args[0]);
            } else if (css.eq(name, "matrix") and count == 6) {
                f = args;
            } else {
                l.ds.err(l.c.tokLoc(t), "{s}() is not a 2D transform function LCGF folds", .{name});
                return;
            }
            m = mul(m, f);
        }
        s.transform = m;
    }

    fn container(l: *Lowerer, n: u32, parent: u32, disp: Display) void {
        const t = l.tag(n);
        var dir: types.Axis = .y;
        if (disp == .flex) {
            if (l.keyword(n, .@"flex-direction")) |kw| {
                if (css.eq(kw, "row")) dir = .x else if (css.eq(kw, "column")) dir = .y else if (!l.refused("value", kw, "flex-direction", l.declared(n, .@"flex-direction").?.loc)) l.badValue(l.declared(n, .@"flex-direction").?.first, .@"flex-direction", l.declared(n, .@"flex-direction").?.end);
            } else dir = .x;
        }
        const pdir = l.parentDir(parent);
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        var s = l.boxStyle(n, .{}, pdir, &params, &margin);
        s.dir = dir;
        if (disp == .flex) if (l.keyword(n, .@"flex-wrap")) |kw| {
            const at = l.declared(n, .@"flex-wrap").?.loc;
            // Flex.Style.wrap: a row's lines stack down it, one gap apart both ways.
            if (css.eq(kw, "wrap")) {
                if (dir != .x) l.ds.err(at, "flex-wrap: wrap is lowered on rows only (flex-direction: row)", .{}) else l.flex.wrap = true;
                const rg = l.px(n, .@"row-gap");
                if (rg != null and rg.? != (l.px(n, .@"column-gap") orelse 0)) l.ds.err(l.declared(n, .@"row-gap").?.loc, "a wrapping row has one gap: give row-gap and column-gap the same length", .{});
            } else if (css.eq(kw, "wrap-reverse")) {
                l.ds.err(at, "flex-wrap: wrap-reverse changes visual but not focus order; not supported", .{});
            } else if (!css.eq(kw, "nowrap")) l.badValue(l.declared(n, .@"flex-wrap").?.first, .@"flex-wrap", l.declared(n, .@"flex-wrap").?.end);
        };
        // CSS's initial align-content, normal, stretches a wrapping row's lines.
        if (l.flex.wrap) l.flex.line_space = .stretch;
        if (disp == .flex) if (l.keyword(n, .@"align-content")) |kw| {
            // Flex.Style.lines and line_space: where a wrapping row's spare height goes.
            const space = std.meta.stringToEnum(lcgf.flex.Flex.LineSpace, if (std.mem.startsWith(u8, kw, "space-")) kw[6..] else kw);
            if (alignOf(kw)) |a| {
                l.flex.lines = a;
                l.flex.line_space = .none;
            } else if (css.eq(kw, "normal")) {} else if (space != null and space.? != .none) l.flex.line_space = space.? else l.badValue(l.declared(n, .@"align-content").?.first, .@"align-content", l.declared(n, .@"align-content").?.end);
        };
        // gap along the main axis; CSS's column-gap is the gap between items of a row.
        const gp: Prop = if (dir == .x) .@"column-gap" else .@"row-gap";
        if (l.px(n, gp)) |g| {
            s.gap = g;
            l.use(.gap);
        }
        if (l.keyword(n, .@"justify-content")) |kw| {
            const space = std.meta.stringToEnum(lcgf.flex.Flex.Space, if (std.mem.startsWith(u8, kw, "space-")) kw[6..] else "");
            if (space) |sp| {
                // Flex.Style.space; a wrapping row's lines keep Style.main.
                if (l.flex.wrap) l.ds.err(l.declared(n, .@"justify-content").?.loc, "justify-content: {s} is not lowered on a wrapping row", .{kw}) else l.flex.space = sp;
            } else if (alignOf(kw)) |a| s.main = a else if (!l.refused("value", kw, "justify-content", l.declared(n, .@"justify-content").?.loc)) l.badValue(l.declared(n, .@"justify-content").?.first, .@"justify-content", l.declared(n, .@"justify-content").?.end);
        }
        if (l.keyword(n, .@"align-items")) |kw| {
            if (alignOf(kw)) |a| s.cross = a else if (css.eq(kw, "baseline")) {
                // Flex.Style.baseline lines up a row's children, per line when it wraps. A column's cross axis is
                // horizontal, where no baseline runs: CSS falls back to start there.
                if (dir == .x) l.flex.baseline = true else s.cross = .start;
            } else if (!css.eq(kw, "stretch") and !css.eq(kw, "normal")) {
                if (!l.refused("value", kw, "align-items", l.declared(n, .@"align-items").?.loc)) l.badValue(l.declared(n, .@"align-items").?.first, .@"align-items", l.declared(n, .@"align-items").?.end);
            }
        }
        if (disp == .block) if (l.keyword(n, .@"text-align")) |kw| {
            // A column's children are its lines: text-align places them across it.
            if (alignOf(kw)) |a| s.cross = a;
        };
        var node: ir.Node = .{ .kind = .container, .parent = parent, .loc = l.loc(n), .dir = dir, .style = s, .params_expr = params, .margin = margin };
        if (parent == none) {
            // The root box (<body>): the whole viewport.
            node.style.size = .{ .fill, .fill };
            if (l.k.get(n, .width).decl != none) node.style.size[0] = s.size[0];
            if (l.k.get(n, .height).decl != none) node.style.size[1] = s.size[1];
        }
        if (landmarkOf(l, n, t)) |lm| {
            node.kind = .landmark;
            node.landmark = lm;
        }
        if (listRole(t)) |r| node.style.role = r;
        if (std.mem.eql(u8, t, "li")) l.marker = l.markerOf(n);
        node.name = l.accessibleName(n);
        l.ir_of[n] = l.addNode(node);
    }

    fn parentDir(l: *const Lowerer, parent: u32) types.Axis {
        return if (parent == none) .y else l.page.nodes.items(.dir)[parent];
    }

    fn textNode(l: *Lowerer, n: u32) void {
        const p = l.doc.nodes.items(.parent)[n];
        if (p == none or l.ir_of[p] == none) {
            // Text in a hoisted (display: contents) element or between widgets.
            if (p == none or l.skip[p]) return;
        }
        const bytes = l.doc.nodes.items(.name)[n];
        if (isBlank(bytes)) return;
        const parent = if (l.ir_of[p] != none) l.ir_of[p] else l.irParent(p);
        if (parent == none) return;
        const kind = l.page.nodes.items(.kind)[parent];
        if (kind != .container and kind != .landmark and kind != .component and kind != .dialog and kind != .section and kind != .popover) return;
        const style = lcgf.widgets_label.labelStyle(&l.page.theme);
        var node: ir.Node = .{ .kind = .label, .parent = parent, .loc = .{ .file = l.doc.file, .off = l.doc.nodes.items(.src)[n] }, .style = style, .base_style = style, .text_style = l.text[p], .base_text = lcgf.widgets_label.labelText(&l.page.theme), .paragraph = l.paragraphOf(p), .decoration = l.decorationOf(p) };
        l.caption(&node, collapse(l.arena, bytes), node.loc);
        _ = l.addNode(node);
    }

    /// An element whose content is only text: one label (or heading) carrying its box.
    fn label(l: *Lowerer, n: u32, parent: u32, heading: u8) void {
        const th = &l.page.theme;
        const pre = std.mem.eql(u8, l.tag(n), "pre");
        var raw: std.ArrayList(u8) = .empty;
        for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.parent)[i] == n) {
            // A <br> is a 0 byte until white space has collapsed, then a newline.
            if (l.doc.nodes.items(.kind)[i] == .text) ok(raw.appendSlice(l.arena, l.doc.nodes.items(.name)[i])) else ok(raw.append(l.arena, if (pre) '\n' else 0));
            l.skip[i] = true;
        };
        const base_style: Style = if (heading != 0) .{ .role = .heading, .value = @floatFromInt(heading) } else lcgf.widgets_label.labelStyle(th);
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        var s = l.boxStyle(n, base_style, l.parentDir(parent), &params, &margin);
        if (listRole(l.tag(n))) |r| s.role = r;
        if (std.mem.eql(u8, l.tag(n), "li")) l.marker = l.markerOf(n);
        var node: ir.Node = .{
            .kind = if (heading != 0) .heading else .label,
            .parent = parent,
            .loc = l.loc(n),
            .style = s,
            .base_style = base_style,
            .params_expr = params,
            .text_style = l.text[n],
            .base_text = lcgf.widgets_label.labelText(th),
            .paragraph = l.paragraphOf(n),
            .decoration = l.decorationOf(n),
            .level = heading,
            .name = l.accessibleName(n),
            .margin = margin,
        };
        l.caption(&node, if (pre) raw.items else breaks(l.arena, collapse(l.arena, raw.items)), l.loc(n));
        if (heading != 0 and node.text_kind == .format) l.ds.err(node.loc, "a heading shows one literal or one field; put the formatted text in a <span>", .{});
        l.ir_of[n] = l.addNode(node);
    }

    /// `<p>` with text and phrasing elements (F11): one label whose text is all of it, in
    /// style runs (`spec.spans`). Its descendants add their text as the walk reaches them
    /// (`inlineText`, `inlineElement`), with their computed styles; `finishInlines` collapses
    /// the white space and cuts the runs.
    fn inlineRuns(l: *Lowerer, n: u32, parent: u32) void {
        const th = &l.page.theme;
        const base_style = lcgf.widgets_label.labelStyle(th);
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        const s = l.boxStyle(n, base_style, l.parentDir(parent), &params, &margin);
        const node: ir.Node = .{
            .kind = .label,
            .parent = parent,
            .loc = l.loc(n),
            .style = s,
            .base_style = base_style,
            .params_expr = params,
            .text_style = l.text[n],
            .base_text = lcgf.widgets_label.labelText(th),
            .paragraph = l.paragraphOf(n),
            .decoration = l.decorationOf(n),
            .text_kind = .literal,
            .name = l.accessibleName(n),
            .margin = margin,
        };
        l.ir_of[n] = l.addNode(node);
        const owner: u32 = @intCast(l.inlines.items.len);
        ok(l.inlines.append(l.arena, .{ .element = n, .ir = l.ir_of[n] }));
        for (n + 1..l.k.end[n]) |i| l.inline_of[i] = owner;
    }

    fn inlineText(l: *Lowerer, i: u32) void {
        const p = l.doc.nodes.items(.parent)[i];
        const bytes = l.doc.nodes.items(.name)[i];
        const in = &l.inlines.items[l.inline_of[i]];
        if (std.mem.indexOfScalar(u8, bytes, '{') != null) {
            l.ds.err(.{ .file = l.doc.file, .off = l.doc.nodes.items(.src)[i] }, "bound text inside a paragraph of inline runs is not lowered yet; put it in its own element", .{});
            return;
        }
        ok(in.bytes.appendSlice(l.arena, bytes));
        for (bytes) |_| ok(in.styles.append(l.arena, l.text[p]));
    }

    fn inlineElement(l: *Lowerer, i: u32) void {
        const in = &l.inlines.items[l.inline_of[i]];
        const t = l.tag(i);
        const phrasing = [_][]const u8{ "span", "strong", "b", "em", "i", "code", "small", "mark", "kbd", "samp", "var", "abbr", "cite", "q", "time", "data", "bdi", "bdo", "dfn", "u", "s", "ins", "del", "sub", "sup", "br", "wbr" };
        const known = for (phrasing) |x| {
            if (std.mem.eql(u8, t, x)) break true;
        } else false;
        if (!known) {
            l.ds.err(l.loc(i), "<{s}> inside a paragraph of inline runs is not lowered; inline runs take text and phrasing elements (span, strong, em, b, i, code, …)", .{t});
            l.skip[i] = true;
            return;
        }
        if (std.mem.eql(u8, t, "br")) {
            ok(in.bytes.append(l.arena, 0));
            ok(in.styles.append(l.arena, l.text[i]));
            return;
        }
        // One paragraph style and one decoration for the whole paragraph, for now.
        const e = in.element;
        if (!std.meta.eql(l.deco[i], l.deco[e])) l.ds.err(l.loc(i), "text-decoration on part of a paragraph is not lowered yet; decorate the whole <p>", .{});
        var a = l.para[i];
        var b = l.para[e];
        a.ellipsis = false;
        b.ellipsis = false;
        if (!std.meta.eql(a, b)) l.ds.err(l.loc(i), "line-height, letter-spacing and word-spacing apply to the whole paragraph of inline runs; set them on the <p>", .{});
    }

    /// Each paragraph of inline runs: white space collapsed as `label` does, then one span at
    /// every change of style (a span back to the paragraph's own style included).
    fn finishInlines(l: *Lowerer) void {
        for (l.inlines.items) |in| {
            var text: std.ArrayList(u8) = .empty;
            var styles: std.ArrayList(TextStyle) = .empty;
            var space = false;
            var space_style: TextStyle = .{};
            for (in.bytes.items, in.styles.items) |ch, st| {
                if (std.ascii.isWhitespace(ch)) {
                    if (!space) space_style = st;
                    space = text.items.len > 0;
                    continue;
                }
                // No space next to a line break, as `breaks` drops it.
                if (space and ch != 0 and (text.items.len == 0 or text.items[text.items.len - 1] != '\n')) {
                    ok(text.append(l.arena, ' '));
                    ok(styles.append(l.arena, space_style));
                }
                space = false;
                ok(text.append(l.arena, if (ch == 0) '\n' else ch));
                ok(styles.append(l.arena, st));
            }
            const base = l.text[in.element];
            var spans: std.ArrayList(lcgf.protocol.Span) = .empty;
            var prev = base;
            for (styles.items, 0..) |st, k| {
                if (!std.meta.eql(st, prev)) ok(spans.append(l.arena, .{ .start = @intCast(k), .style = st }));
                prev = st;
            }
            const nodes = l.page.nodes.slice();
            nodes.items(.text)[in.ir] = text.items;
            nodes.items(.spans)[in.ir] = spans.items;
        }
    }

    /// `<template lcgf-if|lcgf-each|lcgf-switch|lcgf-case>`: a region over its content. A
    /// template without lcgf-* is inert, as in a browser.
    fn template(l: *Lowerer, n: u32, parent: u32) void {
        const at = l.loc(n);
        if (l.attr(n, "lcgf-else") != null) {
            // Its lcgf-if made the choice and gave this template its node, the content's parent.
            if (l.ir_of[n] == none) {
                l.ds.err(at, "<template lcgf-else> belongs right after a <template lcgf-if>", .{});
                l.skip[n] = true;
            }
            return;
        }
        if (l.attr(n, "lcgf-case")) |case| {
            // An alternative of the enclosing lcgf-switch: its content is the alternative.
            const p = l.doc.nodes.items(.parent)[n];
            if (p == none or !l.doc.isElement(p, "template") or l.attr(p, "lcgf-switch") == null) {
                l.ds.err(at, "lcgf-case belongs directly inside <template lcgf-switch>", .{});
                l.skip[n] = true;
            }
            _ = case;
            return;
        }
        var node: ir.Node = .{ .kind = .when, .parent = parent, .loc = at };
        if (l.attr(n, "lcgf-if")) |f| {
            // With an lcgf-else after it: `spec.choice` over the bool (engine spec T4), whose
            // false alternative comes first (`level` 1; `swapElse` reorders the nodes).
            const other = l.elseOf(n);
            if (other != none) {
                node.kind = .choice;
                node.level = 1;
                if (l.content(n).elements != 1 or l.content(other).elements != 1)
                    l.ds.err(at, "<template lcgf-if> and its lcgf-else each hold exactly one element (wrap them in a <div>)", .{});
            }
            if (l.eachOf(n) != none) {
                // Per item: a bool field of the item (`row.expanded`).
                node.bind = l.itemBinding(n, f, l.valueLoc(n, "lcgf-if"), .bool, false);
                if (node.bind.len == 0) return;
            } else {
                if (!l.identifier(f, l.valueLoc(n, "lcgf-if"))) return;
                l.field(f, .bool, l.valueLoc(n, "lcgf-if"), "lcgf-if");
                node.bind = f;
            }
            l.ir_of[n] = l.addNode(node);
            if (other != none) l.ir_of[other] = l.ir_of[n];
            return;
        } else if (l.attr(n, "lcgf-each")) |f| {
            if (std.mem.indexOf(u8, f, " in ")) |at_in| {
                l.eachRegion(n, parent, std.mem.trim(u8, f[0..at_in], " "), std.mem.trim(u8, f[at_in + 4 ..], " "));
                return;
            }
            if (!l.identifier(f, l.valueLoc(n, "lcgf-each"))) return;
            const max = l.attr(n, "lcgf-max") orelse {
                l.ds.err(at, "lcgf-each=\"{s}\" needs lcgf-max=\"N\", the most copies it shows", .{f});
                l.skip[n] = true;
                return;
            };
            node.max = std.fmt.parseInt(u32, max, 10) catch 0;
            if (node.max == 0 or node.max > 4096) {
                l.ds.err(l.valueLoc(n, "lcgf-max"), "lcgf-max takes a count from 1 to 4096", .{});
                return;
            }
            l.field(f, .u32, l.valueLoc(n, "lcgf-each"), "lcgf-each");
            node.kind = .list;
            node.bind = f;
            var params: []const u8 = "";
            var margin: ?[4]f32 = null;
            node.style = l.boxStyle(n, .{}, l.parentDir(parent), &params, &margin);
            // The copies stack in a column.
            if (l.px(n, .@"row-gap")) |g| node.style.gap = g;
        } else if (l.attr(n, "lcgf-switch")) |f| {
            if (!l.identifier(f, l.valueLoc(n, "lcgf-switch"))) return;
            var cases: std.ArrayList([]const u8) = .empty;
            for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.parent)[i] == n and l.doc.isElement(@intCast(i), "template")) {
                const c = l.attr(@intCast(i), "lcgf-case") orelse continue;
                if (l.identifier(c, l.valueLoc(@intCast(i), "lcgf-case"))) ok(cases.append(l.arena, c));
            };
            if (cases.items.len == 0) {
                l.ds.err(at, "lcgf-switch needs <template lcgf-case=\"name\"> alternatives", .{});
                return;
            }
            l.field(f, .@"enum", l.valueLoc(n, "lcgf-switch"), "lcgf-switch");
            for (l.page.fields.items) |*fd| if (std.mem.eql(u8, fd.name, f)) {
                fd.cases = cases.items;
            };
            node.kind = .choice;
            node.bind = f;
        } else {
            l.skip[n] = true;
            return;
        }
        l.ir_of[n] = l.addNode(node);
    }

    /// What the runtime frontend cannot say yet: CSS that restyles a widget without a runtime
    /// function that takes its style (`<widget>Face`; engine spec R1).
    pub fn checkRuntime(l: *Lowerer) void {
        const nodes = l.page.nodes.slice();
        for (0..nodes.len) |i| {
            const kind = nodes.items(.kind)[i];
            switch (kind) {
                .container, .landmark, .label, .text, .heading => continue,
                .when, .list, .choice, .each => continue,
                .component => continue,
                else => {},
            }
            // These restyle their root through `<widget>Face`, as `spec.styled` does. Flex
            // rules (margins) go on the row a widget pushes first, its root.
            const faced = switch (kind) {
                .button, .link, .toggle, .checkbox, .@"switch", .slider, .textfield, .search, .textarea, .number, .progress, .separator, .radio, .select => true,
                else => false,
            };
            const restyled = !std.meta.eql(nodes.items(.style)[i], nodes.items(.base_style)[i]) or nodes.items(.params_expr)[i].len > 0;
            if (restyled and !faced)
                l.ds.err(nodes.items(.loc)[i], "{s}", .{manifest.refusal("feature", "runtime-widget-style", "").?});
        }
    }

    /// Run-time tokens on a widget: its builder makes its own rows, so neither frontend can
    /// write a token into them (engine spec R1 for runtime, `spec.tokened` for comptime).
    pub fn checkTokens(l: *Lowerer) void {
        const nodes = l.page.nodes.slice();
        for (0..nodes.len) |i| switch (nodes.items(.kind)[i]) {
            .container, .landmark, .label, .text, .heading, .when, .list, .choice => {},
            else => if (nodes.items(.uses)[i].len > 0)
                l.ds.err(nodes.items(.loc)[i], "run-time theme tokens set only containers and text; this widget's builder makes its own rows", .{}),
        };
    }

    /// `<template lcgf-each="item in items">`: a run-time region in the comptime page, sized by
    /// its CSS (it is laid out before its content exists), built each frame from the app's
    /// `items` (plan §3.5, M8.2).
    fn eachRegion(l: *Lowerer, n: u32, parent: u32, item: []const u8, list: []const u8) void {
        const at = l.valueLoc(n, "lcgf-each");
        if (!l.identifier(item, at) or !l.identifier(list, at)) return;
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        var style = l.boxStyle(n, .{}, l.parentDir(parent), &params, &margin);
        l.uses.clearRetainingCapacity();
        // The copies stack in a column, or a row under display: flex.
        if (l.display(n) == .flex) style.dir = if (l.keyword(n, .@"flex-direction")) |kw| (if (css.eq(kw, "column")) .y else .x) else .x;
        if (l.px(n, if (style.dir == .x) .@"column-gap" else .@"row-gap")) |g| style.gap = g;
        // A fit axis takes the size the content measured last frame (ct_interop.fitRegion).
        const fit: u8 = @intFromBool(style.size[0].kind == .fit or style.size[1].kind == .fit);
        const nodes = if (l.attr(n, "lcgf-nodes")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 256;
        const texts = if (l.attr(n, "lcgf-texts")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 64;
        if (nodes == 0 or texts == 0 or texts > 255 * 64) l.ds.err(at, "lcgf-nodes and lcgf-texts take positive counts", .{});
        const id = ok(std.fmt.allocPrint(l.arena, "each_{s}", .{list}));
        l.ir_of[n] = l.addNode(.{ .kind = .each, .parent = parent, .loc = l.loc(n), .style = style, .base_style = style, .params_expr = params, .bind = list, .text = item, .id = id, .max = nodes, .range = .{ @floatFromInt(texts), 0, 0 }, .level = fit });
    }

    /// A binding inside an lcgf-each region: per-item state lives in the app's item, so it names
    /// a field of the item (`bind:checked="row.selected"`), typed by the control.
    fn itemBinding(l: *Lowerer, n: u32, f: []const u8, at: Loc, ty: ir.FieldType, writes: bool) []const u8 {
        const each = l.eachOf(n);
        const item = l.page.nodes.items(.text)[each];
        const dot = std.mem.indexOfScalar(u8, f, '.');
        if (dot == null or !std.mem.eql(u8, f[0..dot.?], item) or !l.identifier(f[dot.? + 1 ..], at)) {
            l.ds.err(at, "inside lcgf-each, bind a field of the item: \"{s}.field\" (per-item state is the app's)", .{item});
            return "";
        }
        if (ty == .text) {
            l.ds.err(at, "inside lcgf-each a text control shows an item field one way: value=\"{{{s}.field}}\" with on:change and on:submit", .{item});
            return "";
        }
        if (ty != .bool and ty != .f32 and ty != .u32 and ty != .str) {
            l.ds.err(at, "inside lcgf-each, only checkboxes, switches, toggles, sliders, radio groups and lcgf-if bind an item field so far", .{});
            return "";
        }
        ok(l.page.item_fields.append(l.arena, .{ .each = l.page.nodes.items(.id)[each], .field = f[dot.? + 1 ..], .loc = at, .bound = ty, .writes = writes }));
        return f;
    }

    /// A one-way control inside an lcgf-each: `attr="{row.field}"` shows the item's field and
    /// its on:change reports the new value; the app writes it, if it wants (a one-way view).
    fn oneWay(l: *Lowerer, n: u32, attr_name: []const u8, ty: ir.FieldType) []const u8 {
        if (l.eachOf(n) == none) return "";
        const v = l.attr(n, attr_name) orelse return "";
        if (!isBound(v)) return "";
        const f = std.mem.trim(u8, std.mem.trim(u8, v, " ")[1 .. std.mem.trim(u8, v, " ").len - 1], " ");
        return l.itemBinding(n, f, l.valueLoc(n, attr_name), ty, false);
    }

    /// The `each` region around document node `n`, as its IR node, or none.
    fn eachOf(l: *const Lowerer, n: u32) u32 {
        var i = n;
        while (i != none) : (i = l.doc.nodes.items(.parent)[i]) {
            const r = l.ir_of[i];
            if (r != none and l.page.nodes.items(.kind)[r] == .each) return r;
        }
        return none;
    }

    /// Regions whose content is not exactly one element; checked after the walk.
    fn checkRegions(l: *Lowerer) void {
        const kinds = l.page.nodes.items(.kind);
        const parents = l.page.nodes.items(.parent);
        // A run-time region builds in a Context of its own, without the page's paragraph rows.
        for (l.page.nodes.items(.paragraph), l.page.nodes.items(.decoration), l.page.nodes.items(.spans), 0..) |pa, de, sp, i| if (pa != null or de != null or sp.len > 0) {
            var p = parents[i];
            while (p != none) : (p = parents[p]) if (kinds[p] == .each) {
                l.ds.err(l.page.nodes.items(.loc)[i], "paragraph styles, text decorations and inline runs inside lcgf-each are not supported yet", .{});
                break;
            };
        };
        for (kinds, 0..) |k, i| {
            if (k != .when and k != .list) continue;
            var children: u32 = 0;
            for (parents) |p| children += @intFromBool(p == i);
            if (children != 1) l.ds.err(l.page.nodes.items(.loc)[i], "<template {s}> holds {d} elements; it takes exactly one (wrap them in a <div>)", .{ if (k == .when) "lcgf-if" else "lcgf-each", children });
        }
    }

    fn separator(l: *Lowerer, n: u32, parent: u32) void {
        const vertical = l.parentDir(parent) == .x;
        const base_style = lcgf.widgets_separator.style(&l.page.theme, if (vertical) .vertical else .horizontal);
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        const s = l.boxStyle(n, base_style, l.parentDir(parent), &params, &margin);
        l.ir_of[n] = l.addNode(.{ .kind = .separator, .parent = parent, .loc = l.loc(n), .style = s, .base_style = base_style, .params_expr = params, .level = @intFromBool(vertical), .margin = margin });
    }

    // ---- text and fields ------------------------------------------------------------------

    /// Sets `node`'s caption from text with `{field}` and `{field:.N}` holes.
    fn caption(l: *Lowerer, node: *ir.Node, bytes: []const u8, at: Loc) void {
        var fmt_: std.ArrayList(u8) = .empty;
        var args: std.ArrayList([]const u8) = .empty;
        var literal: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < bytes.len) {
            const ch = bytes[i];
            if (ch == '{' and i + 1 < bytes.len and bytes[i + 1] == '{') {
                ok(fmt_.appendSlice(l.arena, "{{"));
                ok(literal.append(l.arena, '{'));
                i += 2;
                continue;
            }
            if (ch == '}' and i + 1 < bytes.len and bytes[i + 1] == '}') {
                ok(fmt_.appendSlice(l.arena, "}}"));
                ok(literal.append(l.arena, '}'));
                i += 2;
                continue;
            }
            if (ch == '}') {
                l.ds.err(at, "a lone '}}' in text; write '}}}}' for a brace", .{});
                return;
            }
            if (ch != '{') {
                ok(fmt_.append(l.arena, ch));
                ok(literal.append(l.arena, ch));
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, bytes, i, '}') orelse {
                l.ds.err(at, "'{{' without '}}' in text; write '{{{{' for a brace", .{});
                return;
            };
            const hole = std.mem.trim(u8, bytes[i + 1 .. close], " ");
            const colon = std.mem.indexOfScalar(u8, hole, ':');
            const name = if (colon) |c_| hole[0..c_] else hole;
            // `{item.field}` inside an lcgf-each reads the app's item, not the view state.
            if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
                const each = l.eachOf(l.current);
                if (each == none or !std.mem.eql(u8, name[0..dot], l.page.nodes.items(.text)[each]) or !l.identifier(name[dot + 1 ..], at)) {
                    l.ds.err(at, "'{s}' names no item: `{{x.field}}` reads the item of an enclosing lcgf-each=\"x in xs\"", .{name});
                    return;
                }
                ok(l.page.item_fields.append(l.arena, .{ .each = l.page.nodes.items(.id)[each], .field = name[dot + 1 ..], .loc = at }));
                if (colon) |c_| ok(fmt_.print(l.arena, "{{{s}}}", .{hole[c_ + 1 ..]})) else ok(fmt_.appendSlice(l.arena, "{}"));
                ok(args.append(l.arena, name));
                i = close + 1;
                continue;
            }
            if (!l.identifier(name, at)) return;
            if (colon) |c_| {
                const spec = hole[c_ + 1 ..];
                if (spec.len != 2 or spec[0] != '.' or spec[1] < '0' or spec[1] > '6') {
                    l.ds.err(at, "'{{{s}}}': write {{{s}:.N}} with N from 0 to 6 for a number", .{ hole, name });
                    return;
                }
                l.field(name, .f32, at, "{x:.N} in text");
                ok(fmt_.print(l.arena, "{{{s}}}", .{spec}));
            } else {
                l.field(name, .str, at, "{x} in text");
                ok(fmt_.appendSlice(l.arena, "{}"));
            }
            ok(args.append(l.arena, name));
            i = close + 1;
        }
        const tt = l.textTransform(l.current);
        if (tt != .none and args.items.len > 0) {
            l.ds.err(at, "text-transform on text that shows a field is not lowered (display mapping, F13); transform the value in the app", .{});
        } else if (tt != .none) {
            // Unicode 16 casing (text/layout/display.zig): ß -> SS, final sigma, the lang's rules.
            const casemap = lcgf.text_display;
            const buf = ok(l.arena.alloc(u8, 3 * literal.items.len + 16));
            var out: casemap.Buffer = .{ .bytes = buf, .source = ok(l.arena.alloc(u32, buf.len + 1)) };
            const casing: casemap.Casing = switch (tt) {
                .uppercase => .upper,
                .lowercase => .lower,
                .capitalize => .capitalize,
                .none => unreachable,
            };
            if (casemap.prepare(&out, literal.items, .{ .casing = casing, .locale = l.localeOf(l.current) })) |mapped| {
                literal.clearRetainingCapacity();
                ok(literal.appendSlice(l.arena, mapped));
            } else |e| l.ds.err(at, "text-transform: the text cannot be case-mapped ({t})", .{e});
        }
        if (args.items.len == 0) {
            node.text_kind = .literal;
            node.text = literal.items;
        } else if (args.items.len == 1 and std.mem.eql(u8, fmt_.items, "{}")) {
            node.text_kind = .field;
            node.text = args.items[0];
        } else {
            node.text_kind = .format;
            node.text = fmt_.items;
            node.args = args.items;
            // A formatted label is `spec.text`, which carries only the label role.
            if (node.kind == .label) {
                node.kind = .text;
                node.base_style = .{ .role = .label };
            }
        }
    }

    const TextTransform = enum { none, uppercase, lowercase, capitalize };

    /// The casing locale of document node `n`, from the nearest `lang` (tr, az, lt and nl
    /// change case mapping; any other is the root locale).
    fn localeOf(l: *const Lowerer, n: u32) lcgf.text_display.Locale {
        var i = n;
        while (i != none) : (i = l.doc.nodes.items(.parent)[i]) if (l.doc.nodes.items(.kind)[i] == .element) if (l.attr(i, "lang")) |lang| {
            const primary = lang[0 .. std.mem.indexOfAny(u8, lang, "-_") orelse lang.len];
            inline for (.{ "tr", "az", "lt", "nl" }) |x| if (std.ascii.eqlIgnoreCase(primary, x)) return @field(lcgf.text_display.Locale, x);
            return .root;
        };
        return .root;
    }

    /// The inherited `text-transform` of document node `n`: its own or its nearest ancestor's.
    fn textTransform(l: *Lowerer, n: u32) TextTransform {
        var i = n;
        while (i != none) : (i = l.doc.nodes.items(.parent)[i]) if (l.k.get(i, .@"text-transform").decl != none) {
            const kw = l.keyword(i, .@"text-transform") orelse return .none;
            for ([_]TextTransform{ .none, .uppercase, .lowercase, .capitalize }) |x| if (css.eq(kw, @tagName(x))) return x;
            l.badValue(l.declared(i, .@"text-transform").?.first, .@"text-transform", l.declared(i, .@"text-transform").?.end);
            return .none;
        };
        return .none;
    }

    /// Checks a field or handler name: `[a-z][a-z0-9_]*` and no keyword of Zig, C++ or Rust,
    /// so one page compiles in every language.
    pub fn identifier(l: *Lowerer, name: []const u8, at: Loc) bool {
        const valid = name.len > 0 and name[0] >= 'a' and name[0] <= 'z' and for (name) |ch| {
            if (!(ch >= 'a' and ch <= 'z') and !(ch >= '0' and ch <= '9') and ch != '_') break false;
        } else true;
        if (!valid) {
            l.ds.err(at, "'{s}' is not a valid name: use lower case letters, digits and '_', starting with a letter", .{name});
            return false;
        }
        for (keywords) |kw| if (std.mem.eql(u8, kw[0], name)) {
            l.ds.err(at, "'{s}' is a keyword in {s}; name the field something else", .{ name, kw[1] });
            return false;
        };
        return true;
    }

    /// Registers state field `name` as `ty`; a second use must agree.
    fn field(l: *Lowerer, name: []const u8, ty: ir.FieldType, at: Loc, why: []const u8) void {
        for (l.page.fields.items) |f| if (std.mem.eql(u8, f.name, name)) {
            if (f.type != ty) {
                const a = l.ds.where(f.loc);
                l.ds.err(at, "'{s}' is bound as {s} by {s} here and as {s} by {s} at {d}:{d}", .{ name, @tagName(ty), why, @tagName(f.type), f.why, a.line, a.col });
            }
            return;
        };
        ok(l.page.fields.append(l.arena, .{ .name = name, .type = ty, .loc = at, .why = why }));
    }

    fn setDefault(l: *Lowerer, name: []const u8, default: []const u8) void {
        for (l.page.fields.items) |*f| if (std.mem.eql(u8, f.name, name)) {
            f.default = default;
        };
    }

    fn checkFields(l: *Lowerer) void {
        // Widget ids: unique, and not also a field of another type's meaning.
        const ids = l.page.nodes.items(.id);
        const kinds = l.page.nodes.items(.kind);
        // A select's list and a tooltip name the widget they belong to.
        const owned = struct {
            fn is(k: ir.Kind) bool {
                return k == .select_list or k == .tooltip or k == .popover or k == .menu_list;
            }
        }.is;
        for (ids, 0..) |id, i| if (id.len > 0 and !owned(kinds[i])) for (ids[0..i], 0..) |o, j| if (!owned(kinds[j]) and std.mem.eql(u8, o, id)) {
            const a = l.ds.where(l.page.nodes.items(.loc)[j]);
            l.ds.err(l.page.nodes.items(.loc)[i], "id '{s}' is used twice; the first is at {d}:{d}", .{ id, a.line, a.col });
        };
    }

    // ---- widgets --------------------------------------------------------------------------

    /// `on:<event>` handlers of element `n` on widget `id`.
    fn handlers(l: *Lowerer, n: u32, id: []const u8, bind: []const u8, payload: ?ir.FieldType) void {
        const doc = l.doc;
        const first = doc.nodes.items(.attr_first)[n];
        for (first..first + doc.nodes.items(.attr_count)[n]) |a_| {
            const a: u32 = @intCast(a_);
            const name = doc.attrs.items(.name)[a];
            if (!std.mem.startsWith(u8, name, "on:")) continue;
            const event = name[3..];
            const handler = doc.attrs.items(.value)[a];
            const at = doc.valueLoc(a);
            if (!l.identifier(handler, at)) continue;
            if (std.mem.eql(u8, event, "click")) {
                if (bind.len != 0 and payload != null) {
                    l.ds.err(doc.attrLoc(a), "on:click is for buttons; use on:change for a control's value", .{});
                    continue;
                }
                const each = l.eachOf(n);
                ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .click, .widget = id, .loc = at, .each = if (each == none) "" else l.page.nodes.items(.id)[each] }));
            } else if (std.mem.eql(u8, event, "submit")) {
                if (payload != .text) {
                    l.ds.err(doc.attrLoc(a), "on:submit is for text fields, search fields and text areas (Enter; Ctrl+Enter in a text area)", .{});
                    continue;
                }
                const each = l.eachOf(n);
                ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .submit, .widget = id, .field = bind, .loc = at, .each = if (each == none) "" else l.page.nodes.items(.id)[each] }));
            } else if (std.mem.eql(u8, event, "change")) {
                if (payload == .text and std.mem.indexOfScalar(u8, bind, '.') != null) {
                    // A per-item text control reports its text as it is edited.
                    const each = l.eachOf(n);
                    ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .change, .widget = id, .field = bind, .payload = .str, .loc = at, .each = l.page.nodes.items(.id)[each] }));
                    continue;
                }
                if (payload == .text) {
                    // A text control reports its text as it is edited.
                    ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .change, .widget = id, .field = bind, .payload = .str, .loc = at }));
                    continue;
                }
                if (std.mem.indexOfScalar(u8, bind, '.') != null) {
                    // Per item: the handler gets the item's index and the new value.
                    const each = l.eachOf(n);
                    ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .change, .widget = id, .field = bind, .payload = payload, .loc = at, .each = l.page.nodes.items(.id)[each] }));
                    continue;
                }
                if (bind.len == 0) {
                    l.ds.err(doc.attrLoc(a), "on:change needs a bound value (bind:value or bind:checked)", .{});
                    continue;
                }
                ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .change, .widget = id, .field = bind, .payload = payload, .loc = at }));
            } else if (!l.refused("event", event, "", doc.attrLoc(a))) l.ds.err(doc.attrLoc(a), "unknown event 'on:{s}'", .{event});
        }
    }

    /// The widget an element is, if any; true when `n` was lowered as one.
    fn widget(l: *Lowerer, n: u32, t: []const u8, parent: u32) bool {
        if (l.attr(n, "popover") != null) return if (std.mem.eql(u8, t, "menu")) l.menuList(n, parent) else l.popover(n, parent);
        if (std.mem.eql(u8, t, "button")) {
            if (l.attr(n, "popovertarget") != null) return l.popoverButton(n, parent);
            if (l.attr(n, "aria-pressed") != null) return l.boolWidget(n, parent, .toggle, "pressed");
            l.button(n, parent);
            return true;
        }
        if (std.mem.eql(u8, t, "input")) {
            const ty = l.attr(n, "type") orelse "text";
            if (css.eq(ty, "checkbox")) return l.boolWidget(n, parent, if (l.attr(n, "switch") != null or std.mem.eql(u8, l.attr(n, "role") orelse "", "switch")) .@"switch" else .checkbox, "checked");
            if (css.eq(ty, "range")) return l.slider(n, parent);
            if (css.eq(ty, "button") or css.eq(ty, "submit") or css.eq(ty, "reset")) {
                l.button(n, parent);
                return true;
            }
            if (css.eq(ty, "hidden")) {
                l.skip[n] = true;
                return true;
            }
            if (css.eq(ty, "number")) return l.numberField(n, parent);
            if (css.eq(ty, "radio")) return l.radio(n, parent);
            for ([_][]const u8{ "text", "email", "url", "tel", "search", "password" }) |x| if (css.eq(ty, x)) return l.textInput(n, parent, if (css.eq(ty, "search")) .search else .textfield);
            if (l.refused("attribute", "type", ty, l.valueLoc(n, "type"))) {
                l.skip[n] = true;
                return true;
            }
            l.ds.err(l.valueLoc(n, "type"), "<input type={s}> is not lowered yet", .{ty});
            l.skip[n] = true;
            return true;
        }
        if (std.mem.eql(u8, t, "details")) {
            l.details(n, parent);
            return true;
        }
        if (std.mem.eql(u8, t, "a") and l.attr(n, "href") != null) {
            l.link(n, parent);
            return true;
        }
        if (std.mem.eql(u8, t, "textarea")) return l.textInput(n, parent, .textarea);
        if (std.mem.eql(u8, t, "select")) return l.selectWidget(n, parent);
        if (std.mem.eql(u8, t, "dialog")) return l.dialog(n, parent);
        if (std.mem.eql(u8, t, "img")) return l.img(n, parent);
        if (std.mem.eql(u8, t, "progress")) {
            l.progress(n, parent);
            return true;
        }
        if (std.mem.eql(u8, t, "label") and l.attr(n, "for") != null) {
            // `<label for=id>` captions its control wherever it is (controlCaption).
            l.skip[n] = true;
            return true;
        }
        if (std.mem.eql(u8, t, "label") and l.wrapsControl(n)) {
            // The label is its control's caption: no box, its text goes to the control.
            for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.kind)[i] == .text) {
                l.skip[i] = true;
            };
            return true;
        }
        return false;
    }

    fn wrapsControl(l: *const Lowerer, n: u32) bool {
        for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.kind)[i] == .element and std.mem.eql(u8, l.tag(@intCast(i)), "input")) return true;
        return false;
    }

    /// A widget's id: its `id`, else its bound field, else its click handler's name.
    fn widgetId(l: *Lowerer, n: u32, bind: []const u8, what: []const u8) ?[]const u8 {
        if (l.attr(n, "id")) |id| return if (l.identifier(id, l.valueLoc(n, "id"))) id else null;
        // A per-item field (`row.selected`) names the widget by the field; the copy index makes it unique.
        if (bind.len > 0) return if (std.mem.indexOfScalar(u8, bind, '.')) |dot| bind[dot + 1 ..] else bind;
        if (l.attr(n, "on:click")) |h| return h;
        l.ds.err(l.loc(n), "{s} needs an id, a binding or an on:click handler to name it", .{what});
        return null;
    }

    /// `bind:<what>="field"`, checked, or "".
    fn binding(l: *Lowerer, n: u32, what: []const u8, ty: ir.FieldType, why: []const u8) []const u8 {
        var buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "bind:{s}", .{what}) catch unreachable;
        const f = l.attr(n, name) orelse return "";
        const at = l.valueLoc(n, name);
        if (l.eachOf(n) != none) return l.itemBinding(n, f, at, ty, true);
        if (!l.identifier(f, at)) return "";
        l.field(f, ty, at, why);
        return f;
    }

    fn widgetStyle(l: *Lowerer, n: u32, parent: u32, base_style: Style, node: *ir.Node) void {
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        node.base_style = base_style;
        node.style = l.boxStyle(n, base_style, l.parentDir(parent), &params, &margin);
        node.params_expr = params;
        node.margin = margin;
        node.name = l.accessibleName(n);
        // A control that shows no caption of its own is named by its <label>'s text.
        const captionless = switch (node.kind) {
            .textfield, .search, .textarea, .number, .slider, .progress => true,
            else => false,
        };
        if (node.name.len == 0 and captionless) node.name = l.controlCaption(n);
    }

    fn button(l: *Lowerer, n: u32, parent: u32) void {
        const th = l.page.theme;
        var node: ir.Node = .{ .kind = .button, .parent = parent, .loc = l.loc(n) };
        const value = l.attr(n, "value");
        const is_input = std.mem.eql(u8, l.tag(n), "input");
        const content_ = l.content(n);
        if (!is_input and content_.elements > 0) {
            l.ds.err(l.loc(n), "a button shows one literal or one field; its content cannot hold elements", .{});
            l.skip[n] = true;
            return;
        }
        l.caption(&node, collapse(l.arena, if (is_input) value orelse "" else l.ownText(n)), l.loc(n));
        if (node.text_kind == .format) {
            l.ds.err(l.loc(n), "a button shows one literal or one field; give the formatted caption its own field", .{});
            return;
        }
        if (node.kind == .text) node.kind = .button;
        node.id = l.widgetId(n, "", "<button>") orelse {
            l.skip[n] = true;
            return;
        };
        const base_style = lcgf.widgets_button.buttonStyle(&th);
        l.widgetStyle(n, parent, base_style, &node);
        node.text_style = l.text[n];
        node.base_text = lcgf.widgets_label.labelText(&th);
        l.handlers(n, node.id, "", null);
        l.skip[n] = true; // its text is the caption
        l.ir_of[n] = l.addNode(node);
    }

    /// `<a href>`: a link (engine spec F4). The href is not followed; the page reports the
    /// activation to its on:click handler, which acts on it.
    fn link(l: *Lowerer, n: u32, parent: u32) void {
        const th = l.page.theme;
        var node: ir.Node = .{ .kind = .link, .parent = parent, .loc = l.loc(n) };
        if (l.content(n).elements > 0) {
            l.ds.err(l.loc(n), "a link shows one literal or one field; its content cannot hold elements", .{});
            l.skip[n] = true;
            return;
        }
        l.caption(&node, collapse(l.arena, l.ownText(n)), l.loc(n));
        if (node.text_kind == .format) {
            l.ds.err(l.loc(n), "a link shows one literal or one field; give the formatted text its own field", .{});
            return;
        }
        node.kind = .link;
        node.id = l.widgetId(n, "", "<a href>") orelse {
            l.skip[n] = true;
            return;
        };
        l.widgetStyle(n, parent, lcgf.widgets_link.linkStyle(&th), &node);
        l.handlers(n, node.id, "", null);
        l.skip[n] = true; // its text is the link's
        l.ir_of[n] = l.addNode(node);
    }

    /// `<details bind:open="f">` with a `<summary>` first: an accordion section over the bool
    /// `f` (`open` makes it start true). The summary is the header's one literal or field; the
    /// rest of the content is the panel. CSS sets only its margins.
    fn details(l: *Lowerer, n: u32, parent: u32) void {
        const th = l.page.theme;
        const bind = l.binding(n, "open", .bool, "<details>");
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "<details> needs bind:open=\"field\", the bool it shows its content by", .{});
            l.skip[n] = true;
            return;
        }
        if (l.attr(n, "open") != null) l.setDefault(bind, "true");
        var summary: u32 = none;
        var panel = false;
        for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.parent)[i] == n) {
            const k = l.doc.nodes.items(.kind)[i];
            if (k == .text and isBlank(l.doc.nodes.items(.name)[i])) continue;
            if (summary == none and !panel and k == .element and std.mem.eql(u8, l.tag(@intCast(i)), "summary")) summary = @intCast(i) else panel = true;
        };
        if (summary == none or !panel) {
            l.ds.err(l.loc(n), "<details> takes a <summary> first and then its content", .{});
            l.skip[n] = true;
            return;
        }
        var node: ir.Node = .{ .kind = .section, .parent = parent, .loc = l.loc(n), .bind = bind };
        if (l.content(summary).elements > 0) l.ds.err(l.loc(summary), "a <summary> shows one literal or one field; its content cannot hold elements", .{});
        l.caption(&node, collapse(l.arena, l.ownText(summary)), l.loc(summary));
        if (node.text_kind == .format) l.ds.err(l.loc(summary), "a <summary> shows one literal or one field; give the formatted text its own field", .{});
        node.kind = .section;
        l.skip[summary] = true;
        node.id = l.widgetId(n, bind, "<details>") orelse {
            l.skip[n] = true;
            return;
        };
        const base_style = lcgf.widgets_accordion.sectionStyle(&th);
        l.widgetStyle(n, parent, base_style, &node);
        if (!std.meta.eql(node.style, base_style) or node.params_expr.len > 0)
            l.ds.err(l.loc(n), "CSS sets only the margins of a <details>; style its content", .{});
        l.handlers(n, node.id, bind, .bool);
        l.ir_of[n] = l.addNode(node);
    }

    /// The caption of a control: the text of its wrapping `<label>`, or of `<label for=id>`.
    fn controlCaption(l: *Lowerer, n: u32) []const u8 {
        var p = l.doc.nodes.items(.parent)[n];
        while (p != none) : (p = l.doc.nodes.items(.parent)[p]) {
            if (l.doc.isElement(p, "label")) return collapse(l.arena, l.allText(p));
        }
        if (l.attr(n, "id")) |id| for (0..l.doc.nodes.len) |i| {
            if (l.doc.isElement(@intCast(i), "label")) if (l.attr(@intCast(i), "for")) |f| if (std.mem.eql(u8, f, id)) {
                l.skip[i] = true;
                return collapse(l.arena, l.allText(@intCast(i)));
            };
        };
        return "";
    }

    fn allText(l: *const Lowerer, n: u32) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (n + 1..l.k.end[n]) |i| if (l.doc.nodes.items(.kind)[i] == .text) ok(out.appendSlice(l.arena, l.doc.nodes.items(.name)[i]));
        return out.items;
    }

    fn boolWidget(l: *Lowerer, n: u32, parent: u32, kind: ir.Kind, what: []const u8) bool {
        const th = l.page.theme;
        const why = switch (kind) {
            .toggle => "<button aria-pressed>",
            .@"switch" => "<input type=checkbox switch>",
            else => "<input type=checkbox>",
        };
        var bind = l.binding(n, what, .bool, why);
        const shown = if (kind == .toggle) "aria-pressed" else "checked";
        const one_way = bind.len == 0 and l.oneWay(n, shown, .bool).len > 0;
        if (one_way) bind = l.oneWay(n, shown, .bool);
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "{s} needs bind:{s}=\"field\"", .{ why, what });
            l.skip[n] = true;
            return true;
        }
        const on = !one_way and (if (kind == .toggle) std.mem.eql(u8, l.attr(n, "aria-pressed") orelse "", "true") else l.attr(n, "checked") != null);
        if (on) l.setDefault(bind, "true");
        var node: ir.Node = .{ .kind = kind, .parent = parent, .loc = l.loc(n), .bind = bind };
        node.id = l.widgetId(n, bind, why) orelse return true;
        const cap = if (kind == .toggle) collapse(l.arena, l.ownText(n)) else l.controlCaption(n);
        l.caption(&node, cap, l.loc(n));
        node.kind = kind;
        node.one_way = one_way;
        if (node.text_kind == .format) l.ds.err(l.loc(n), "a control's caption is one literal or one field", .{});
        const base_style = switch (kind) {
            .checkbox => lcgf.widgets_checkbox.checkboxStyle(&th),
            .@"switch" => lcgf.widgets_switch.switchStyle(&th),
            else => lcgf.widgets_button.buttonStyle(&th),
        };
        l.widgetStyle(n, parent, row(base_style), &node);
        l.handlers(n, node.id, bind, .bool);
        l.skip[n] = true;
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    fn slider(l: *Lowerer, n: u32, parent: u32) bool {
        const th = l.page.theme;
        var bind = l.binding(n, "value", .f32, "<input type=range>");
        const one_way = bind.len == 0 and l.oneWay(n, "value", .f32).len > 0;
        if (one_way) bind = l.oneWay(n, "value", .f32);
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "<input type=range> needs bind:value=\"field\"", .{});
            l.skip[n] = true;
            return true;
        }
        const lo = l.numberAttr(n, "min") orelse 0;
        const hi = l.numberAttr(n, "max") orelse 1;
        if (!(lo < hi)) l.ds.err(l.valueLoc(n, "max"), "max ({d}) must be above min ({d})", .{ hi, lo });
        if (!one_way) if (l.numberAttr(n, "value")) |v| l.setDefault(bind, ok(std.fmt.allocPrint(l.arena, "{d}", .{v})));
        var node: ir.Node = .{ .kind = .slider, .parent = parent, .loc = l.loc(n), .bind = bind, .range = .{ lo, hi, 0 }, .one_way = one_way };
        node.id = l.widgetId(n, bind, "<input type=range>") orelse return true;
        l.widgetStyle(n, parent, row(lcgf.widgets_slider.sliderTrack(&th)), &node);
        l.handlers(n, node.id, bind, .f32);
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    fn progress(l: *Lowerer, n: u32, parent: u32) void {
        const th = l.page.theme;
        const value = l.attr(n, "value") orelse {
            // Indeterminate: a spinner, shown while its bool field (lcgf-busy, default true) is.
            l.ds.err(l.loc(n), "<progress> without value: give value=\"{{field}}\" (a spinner needs a busy field)", .{});
            l.skip[n] = true;
            return;
        };
        if (!isBound(value)) {
            l.ds.err(l.valueLoc(n, "value"), "<progress value> takes a field: value=\"{{done}}\" (an f32 from 0 to 1)", .{});
            return;
        }
        const f = std.mem.trim(u8, value[1 .. value.len - 1], " ");
        if (!l.identifier(f, l.valueLoc(n, "value"))) return;
        l.field(f, .f32, l.valueLoc(n, "value"), "<progress value>");
        var node: ir.Node = .{ .kind = .progress, .parent = parent, .loc = l.loc(n), .bind = f };
        l.widgetStyle(n, parent, lcgf.widgets_progress.trackStyle(&th), &node);
        l.skip[n] = true;
        l.ir_of[n] = l.addNode(node);
    }

    fn numberField(l: *Lowerer, n: u32, parent: u32) bool {
        const th = l.page.theme;
        const bind = l.binding(n, "value", .number, "<input type=number>");
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "<input type=number> needs bind:value=\"field\"", .{});
            l.skip[n] = true;
            return true;
        }
        const def: lcgf.widgets_number.Range = .{};
        var node: ir.Node = .{ .kind = .number, .parent = parent, .loc = l.loc(n), .bind = bind, .range = .{ l.numberAttr(n, "min") orelse def.lo, l.numberAttr(n, "max") orelse def.hi, l.numberAttr(n, "step") orelse def.step } };
        if (!(node.range[0] < node.range[1]) or !(node.range[2] > 0)) l.ds.err(l.loc(n), "<input type=number>: min must be below max and step above 0", .{});
        node.id = l.widgetId(n, bind, "<input type=number>") orelse return true;
        l.widgetStyle(n, parent, row(lcgf.widgets_number.numberStyle(&th, false, 0)), &node);
        l.handlers(n, node.id, "", null);
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    /// A text control over a `Text(256)` field; `placeholder` is its hint (engine spec T1: the
    /// builders take a literal hint).
    fn textInput(l: *Lowerer, n: u32, parent: u32, kind: ir.Kind) bool {
        const th = l.page.theme;
        const what = switch (kind) {
            .search => "<input type=search>",
            .textarea => "<textarea>",
            else => "<input type=text>",
        };
        var bind = l.binding(n, "value", .text, what);
        // Inside an lcgf-each: one way, `value="{row.name}"` over a string field of the item.
        const one_way = bind.len == 0 and l.oneWay(n, "value", .str).len > 0;
        if (one_way) bind = l.oneWay(n, "value", .str);
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "{s} needs bind:value=\"field\"", .{what});
            l.skip[n] = true;
            return true;
        }
        var node: ir.Node = .{ .kind = kind, .parent = parent, .loc = l.loc(n), .bind = bind, .one_way = one_way };
        node.secure = kind == .textfield and css.eq(l.attr(n, "type") orelse "", "password");
        node.id = l.widgetId(n, bind, what) orelse return true;
        const hint = l.attr(n, "placeholder") orelse "";
        l.caption(&node, hint, l.valueLoc(n, "placeholder"));
        node.kind = kind;
        const rows: u32 = if (l.numberAttr(n, "rows")) |r| @intFromFloat(@max(1, r)) else 2;
        node.level = @intCast(@min(rows, 255));
        const base_style = switch (kind) {
            .search => row(lcgf.widgets_search.boxStyle(&th, false)),
            .textarea => lcgf.widgets_textarea.areaStyle(&th, rows, false),
            else => row(lcgf.widgets_textfield.fieldStyle(&th, false, 0)),
        };
        l.widgetStyle(n, parent, base_style, &node);
        l.handlers(n, node.id, bind, .text);
        l.skip[n] = true;
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    /// The first `<input type=radio>` of a `name` group makes the group: one `radio` whose
    /// options are every radio of that name, captioned by their labels; the rest are its.
    fn radio(l: *Lowerer, n: u32, parent: u32) bool {
        const th = l.page.theme;
        const group = l.attr(n, "name") orelse {
            l.ds.err(l.loc(n), "<input type=radio> needs name=\"group\"", .{});
            l.skip[n] = true;
            return true;
        };
        var captions: std.ArrayList([]const u8) = .empty;
        var bind: []const u8 = "";
        var first = true;
        var selected: ?usize = null;
        for (0..l.doc.nodes.len) |i_| {
            const i: u32 = @intCast(i_);
            if (!l.doc.isElement(i, "input") or !css.eq(l.attr(i, "type") orelse "", "radio")) continue;
            if (!std.mem.eql(u8, l.attr(i, "name") orelse "", group)) continue;
            if (i < n) {
                first = false;
                break;
            }
            if (bind.len == 0) bind = l.binding(i, "selected", .u32, "<input type=radio>");
            if (l.attr(i, "checked") != null) selected = captions.items.len;
            ok(captions.append(l.arena, l.controlCaption(i)));
            l.skip[i] = true;
        }
        if (!first) return true; // an option of an earlier radio's group
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "the radio group '{s}' needs bind:selected=\"field\" on one of its radios", .{group});
            return true;
        }
        if (selected) |s| l.setDefault(bind, ok(std.fmt.allocPrint(l.arena, "{d}", .{s})));
        var node: ir.Node = .{ .kind = .radio, .parent = parent, .loc = l.loc(n), .bind = bind, .captions = captions.items };
        node.id = if (l.identifier(group, l.valueLoc(n, "name"))) group else return true;
        l.widgetStyle(n, parent, lcgf.widgets_radio.groupStyle(&th), &node);
        l.handlers(n, node.id, bind, .u32);
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    /// `<select bind:value>`: one option per `<option>` (its `label` or its text), an
    /// `<optgroup label>` a header before its first option, `<option selected>` the default.
    /// The value is the `SelectState` field's `selected`, which on:change reports.
    fn selectWidget(l: *Lowerer, n: u32, parent: u32) bool {
        const doc = l.doc;
        // The options are consumed here, whatever happens next.
        for (n + 1..l.k.end[n]) |i| l.skip[i] = true;
        const bind = l.binding(n, "value", .select, "<select>");
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "<select> needs bind:value=\"field\"", .{});
            return true;
        }
        if (l.attr(n, "multiple") != null or l.attr(n, "size") != null) {
            l.ds.err(l.loc(n), "<select multiple> and <select size> are list boxes, not lowered yet; use <select>", .{});
            return true;
        }
        var captions: std.ArrayList([]const u8) = .empty;
        var groups: std.ArrayList(lcgf.widgets_select.Group) = .empty;
        var selected: ?usize = null;
        for (n + 1..l.k.end[n]) |i_| {
            const i: u32 = @intCast(i_);
            if (doc.nodes.items(.kind)[i] != .element) continue;
            if (doc.isElement(i, "option")) {
                if (l.attr(i, "selected") != null) selected = captions.items.len;
                ok(captions.append(l.arena, collapse(l.arena, l.attr(i, "label") orelse l.allText(i))));
            } else if (doc.isElement(i, "optgroup")) {
                if (captions.items.len >= lcgf.widgets_menu.no_item) break;
                ok(groups.append(l.arena, .{ .at = @intCast(captions.items.len), .label = collapse(l.arena, l.attr(i, "label") orelse "") }));
            } else if (!doc.isElement(i, "hr")) l.ds.err(l.loc(i), "<select> holds <option> and <optgroup> only", .{});
        }
        if (captions.items.len == 0 or captions.items.len >= lcgf.widgets_menu.no_item) {
            l.ds.err(l.loc(n), "<select> needs 1 to {d} <option>s", .{lcgf.widgets_menu.no_item - 1});
            return true;
        }
        for (groups.items) |g| if (g.at == captions.items.len) l.ds.err(l.loc(n), "<optgroup label=\"{s}\"> holds no <option>", .{g.label});
        if (selected) |k| l.setDefault(bind, ok(std.fmt.allocPrint(l.arena, ".{{ .selected = {d} }}", .{k})));
        if (l.inRepeat(parent)) {
            l.ds.err(l.loc(n), "<select> inside lcgf-each is not lowered yet; bind one per page", .{});
            return true;
        }
        var node: ir.Node = .{ .kind = .select, .parent = parent, .loc = l.loc(n), .bind = bind, .captions = captions.items, .groups = groups.items };
        node.id = l.widgetId(n, bind, "<select>") orelse return true;
        // CSS on the <select> restyles its button; its list keeps the theme's look.
        l.widgetStyle(n, parent, lcgf.widgets_select.buttonStyle(&l.page.theme, .{}), &node);
        node.name = l.accessibleName(n);
        if (node.name.len == 0) node.name = l.controlCaption(n);
        const first = l.page.handlers.items.len;
        l.handlers(n, node.id, bind, .u32);
        for (l.page.handlers.items[first..]) |*h| h.member = "selected";
        l.ir_of[n] = l.addNode(node);
        var list = node;
        list.kind = .select_list;
        list.name = "";
        list.style = .{};
        list.base_style = .{};
        list.params_expr = "";
        list.margin = null;
        ok(l.overlays.append(l.arena, l.addNode(list)));
        return true;
    }

    /// `title="text"` on widget `n`: its tooltip, a `Tip` field `<id>_tip`, shown once the
    /// pointer rests on the widget (`widgets_tooltip.ct.tooltip`), moved last into the root.
    fn tooltip(l: *Lowerer, n: u32) void {
        const text = l.attr(n, "title") orelse return;
        const at = l.attrLoc(n, "title");
        const i = l.ir_of[n];
        const ok_target = i != none and l.page.nodes.items(.id)[i].len > 0 and !l.inRepeat(i) and switch (l.page.nodes.items(.kind)[i]) {
            .dialog, .image, .component, .popover, .menu_list => false,
            else => true,
        };
        if (!ok_target) {
            l.ds.err(at, "title= is a tooltip, which only a widget with an id outside lcgf-each shows (a button or a control)", .{});
            return;
        }
        const id = l.page.nodes.items(.id)[i];
        const field_name = ok(std.fmt.allocPrint(l.arena, "{s}_tip", .{id}));
        l.field(field_name, .tip, at, "title=");
        ok(l.overlays.append(l.arena, l.addNode(.{ .kind = .tooltip, .parent = l.page.nodes.items(.parent)[i], .loc = at, .id = id, .bind = field_name, .text = collapse(l.arena, text) })));
    }

    /// The bool field popover element `p` binds: its `bind:open`, else `<id>_open`.
    fn popoverField(l: *Lowerer, p: u32) []const u8 {
        if (l.attr(p, "bind:open")) |f| {
            if (l.identifier(f, l.valueLoc(p, "bind:open"))) l.field(f, .bool, l.valueLoc(p, "bind:open"), "popover");
            return f;
        }
        const f = ok(std.fmt.allocPrint(l.arena, "{s}_open", .{l.attr(p, "id").?}));
        l.field(f, .bool, l.attrLoc(p, "popover"), "popover");
        return f;
    }

    /// The element with id `id` and the `popover` attribute, or none.
    fn popoverOf(l: *const Lowerer, id: []const u8) u32 {
        for (0..l.doc.nodes.len) |i| {
            if (l.doc.nodes.items(.kind)[i] != .element) continue;
            if (l.attr(@intCast(i), "popover") == null) continue;
            if (std.mem.eql(u8, l.attr(@intCast(i), "id") orelse "", id)) return @intCast(i);
        }
        return none;
    }

    /// `<button popovertarget="id">`: the button that opens and closes popover `id`
    /// (`widgets_popover.ct.button`). It is named by the popover: the panel hangs below it.
    fn popoverButton(l: *Lowerer, n: u32, parent: u32) bool {
        l.skip[n] = true; // its text is the caption
        const target = l.attr(n, "popovertarget").?;
        const at = l.valueLoc(n, "popovertarget");
        const p = l.popoverOf(target);
        if (p == none or !l.identifier(target, at)) {
            if (p == none) l.ds.err(at, "popovertarget names no element with that id and the popover attribute", .{});
            return true;
        }
        if (l.attr(n, "id") != null or l.attr(n, "on:click") != null) {
            l.ds.err(l.loc(n), "a popovertarget button takes its popover's name: no id or on:click of its own", .{});
            return true;
        }
        for (l.page.nodes.items(.kind), l.page.nodes.items(.id)) |k, id| if (k == .popover_button and std.mem.eql(u8, id, target)) {
            l.ds.err(at, "popover '{s}' has a button already; one opens it", .{target});
            return true;
        };
        if (l.inRepeat(parent)) {
            l.ds.err(l.loc(n), "a popovertarget button inside lcgf-each is not lowered", .{});
            return true;
        }
        const is_menu = l.doc.isElement(p, "menu");
        var node: ir.Node = .{ .kind = .popover_button, .parent = parent, .loc = l.loc(n), .id = target, .bind = if (is_menu) l.menuField(p) else l.popoverField(p) };
        if (is_menu) node.args = l.menuItems(p, false).names;
        l.caption(&node, collapse(l.arena, l.ownText(n)), l.loc(n));
        if (node.text_kind == .format or l.content(n).elements > 0) {
            l.ds.err(l.loc(n), "a button shows one literal or one field", .{});
            return true;
        }
        node.kind = if (is_menu) .menu_button else .popover_button;
        node.name = l.accessibleName(n);
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    /// The `MenuState` field of `<menu popover>` `m`: `<id>_menu`.
    fn menuField(l: *Lowerer, m: u32) []const u8 {
        const f = ok(std.fmt.allocPrint(l.arena, "{s}_menu", .{l.attr(m, "id") orelse ""}));
        l.field(f, .menu, l.attrLoc(m, "popover"), "<menu popover>");
        return f;
    }

    const MenuItems = struct { names: []const []const u8, captions: []const []const u8, buttons: []const u32 };

    /// The items of `<menu popover>` `m`: one per `<button>`, in `<li>` or not, named by its id
    /// or its on:click handler, captioned by its text. With `report`, what else it holds is an
    /// error.
    fn menuItems(l: *Lowerer, m: u32, report: bool) MenuItems {
        var names: std.ArrayList([]const u8) = .empty;
        var captions: std.ArrayList([]const u8) = .empty;
        var buttons: std.ArrayList(u32) = .empty;
        for (m + 1..l.k.end[m]) |i_| {
            const i: u32 = @intCast(i_);
            if (l.doc.nodes.items(.kind)[i] != .element) continue;
            if (l.doc.isElement(i, "li")) continue;
            if (!l.doc.isElement(i, "button")) {
                if (report) l.ds.err(l.loc(i), "a <menu popover> holds <button>s, in <li>s or not", .{});
                continue;
            }
            const name = l.attr(i, "id") orelse l.attr(i, "on:click") orelse {
                if (report) l.ds.err(l.loc(i), "a menu item needs an id or an on:click handler to name it", .{});
                continue;
            };
            if (report and !l.identifier(name, l.loc(i))) continue;
            ok(names.append(l.arena, name));
            ok(captions.append(l.arena, collapse(l.arena, l.ownText(i))));
            ok(buttons.append(l.arena, i));
        }
        return .{ .names = names.items, .captions = captions.items, .buttons = buttons.items };
    }

    /// `<menu id popover>`: a menu (`widgets_menu.ct.list`) that its `<button popovertarget>`
    /// opens below itself, moved last into the root. Each item's on:click runs when it is
    /// chosen, by a click or by the keys.
    fn menuList(l: *Lowerer, n: u32, parent: u32) bool {
        for (n + 1..l.k.end[n]) |i| l.skip[i] = true;
        const id = l.attr(n, "id") orelse {
            l.ds.err(l.loc(n), "a <menu popover> needs an id, which its popovertarget button names", .{});
            return true;
        };
        if (!l.identifier(id, l.valueLoc(n, "id"))) return true;
        if (l.attr(n, "bind:open") != null) l.ds.err(l.attrLoc(n, "bind:open"), "a <menu popover> keeps its state in <id>_menu; bind:open is for other popovers", .{});
        if (l.inRepeat(parent)) {
            l.ds.err(l.loc(n), "a menu inside lcgf-each is not lowered; put it at the page level", .{});
            return true;
        }
        const has_button = for (0..l.doc.nodes.len) |i| {
            if (l.doc.nodes.items(.kind)[i] == .element and std.mem.eql(u8, l.attr(@intCast(i), "popovertarget") orelse "", id)) break true;
        } else false;
        if (!has_button) {
            l.ds.err(l.loc(n), "menu '{s}' needs a <button popovertarget=\"{s}\"> to open it", .{ id, id });
            return true;
        }
        const items = l.menuItems(n, true);
        if (items.names.len == 0 or items.names.len >= lcgf.widgets_menu.no_item) {
            l.ds.err(l.loc(n), "a <menu popover> needs 1 to {d} items", .{lcgf.widgets_menu.no_item - 1});
            return true;
        }
        const field_name = l.menuField(n);
        for (items.buttons, 0..) |b, k| {
            const first = l.doc.nodes.items(.attr_first)[b];
            for (first..first + l.doc.nodes.items(.attr_count)[b]) |a_| {
                const a: u32 = @intCast(a_);
                const attr_name = l.doc.attrs.items(.name)[a];
                if (!std.mem.startsWith(u8, attr_name, "on:")) continue;
                const handler = l.doc.attrs.items(.value)[a];
                if (!std.mem.eql(u8, attr_name, "on:click")) {
                    l.ds.err(l.doc.attrLoc(a), "a menu item takes on:click, which runs when it is chosen", .{});
                    continue;
                }
                if (!l.identifier(handler, l.doc.valueLoc(a))) continue;
                ok(l.page.handlers.append(l.arena, .{ .name = handler, .event = .choose, .widget = id, .field = field_name, .item = @intCast(k), .loc = l.doc.valueLoc(a) }));
            }
        }
        l.ir_of[n] = l.addNode(.{ .kind = .menu_list, .parent = parent, .loc = l.loc(n), .id = id, .bind = field_name, .args = items.names, .captions = items.captions });
        ok(l.overlays.append(l.arena, l.ir_of[n]));
        return true;
    }

    /// An element with `popover` (and an id): its content in a panel that a
    /// `popovertarget` button opens below itself (`widgets_popover.ct.popover`), moved last
    /// into the root. A press outside or Escape closes it.
    fn popover(l: *Lowerer, n: u32, parent: u32) bool {
        const id = l.attr(n, "id") orelse {
            l.ds.err(l.loc(n), "a popover needs an id, which its popovertarget button names", .{});
            l.skip[n] = true;
            return true;
        };
        if (!l.identifier(id, l.valueLoc(n, "id"))) {
            l.skip[n] = true;
            return true;
        }
        if (l.inRepeat(parent)) {
            l.ds.err(l.loc(n), "a popover inside lcgf-each is not lowered; put it at the page level", .{});
            l.skip[n] = true;
            return true;
        }
        const has_button = for (0..l.doc.nodes.len) |i| {
            if (l.doc.nodes.items(.kind)[i] == .element and std.mem.eql(u8, l.attr(@intCast(i), "popovertarget") orelse "", id)) break true;
        } else false;
        if (!has_button) {
            l.ds.err(l.loc(n), "popover '{s}' needs a <button popovertarget=\"{s}\"> to open it", .{ id, id });
            l.skip[n] = true;
            return true;
        }
        l.ir_of[n] = l.addNode(.{ .kind = .popover, .parent = parent, .loc = l.loc(n), .id = id, .bind = l.popoverField(n) });
        ok(l.overlays.append(l.arena, l.ir_of[n]));
        return true;
    }

    /// `<dialog bind:open>`: a modal dialog over the page while the bool field is true; its
    /// content is lowered as a column's. `open` makes the field start true. Escape closes it;
    /// a handler that sets the field closes it too.
    fn dialog(l: *Lowerer, n: u32, parent: u32) bool {
        const bind = l.binding(n, "open", .bool, "<dialog>");
        if (bind.len == 0) {
            l.ds.err(l.loc(n), "<dialog> needs bind:open=\"field\", a bool", .{});
            l.skip[n] = true;
            return true;
        }
        if (l.attr(n, "open") != null) l.setDefault(bind, "true");
        if (l.inRepeat(parent)) {
            l.ds.err(l.loc(n), "<dialog> inside lcgf-each is not lowered; put it at the page level", .{});
            l.skip[n] = true;
            return true;
        }
        var node: ir.Node = .{ .kind = .dialog, .parent = parent, .loc = l.loc(n), .bind = bind };
        node.id = l.widgetId(n, bind, "<dialog>") orelse {
            l.skip[n] = true;
            return true;
        };
        l.ir_of[n] = l.addNode(node);
        ok(l.overlays.append(l.arena, l.ir_of[n]));
        return true;
    }

    /// Asset `src` as named at `at` (an `<img src>`, a stylesheet's `url()`), resolved against
    /// the file that names it; one entry per file. Null after reporting a remote or non-PNG one.
    fn asset(l: *Lowerer, src: []const u8, at: Loc, raster: [2]f32) ?u32 {
        for ([_][]const u8{ "http:", "https:", "//", "data:" }) |p| if (std.mem.startsWith(u8, src, p)) {
            l.ds.err(at, "{s}", .{manifest.refusal("value", "remote-url", "").?});
            return null;
        };
        const svg = std.ascii.endsWithIgnoreCase(src, ".svg");
        if (!svg and !std.ascii.endsWithIgnoreCase(src, ".png")) {
            l.ds.err(at, "images are PNG or SVG; '{s}' is neither", .{src});
            return null;
        }
        // A PNG has its own size; an SVG is drawn at the size it is shown.
        const size: [2]f32 = if (svg) raster else .{ 0, 0 };
        const dir = std.fs.path.dirname(l.ds.files.items[at.file].path) orelse ".";
        const path = ok(std.fs.path.join(l.arena, &.{ dir, src }));
        for (l.page.assets.items, 0..) |a, k| if (std.mem.eql(u8, a.path, path) and std.meta.eql(a.raster, size)) return @intCast(k);
        if (l.page.assets.items.len + 1 >= std.math.maxInt(u16)) {
            l.ds.err(at, "too many images on one page", .{});
            return null;
        }
        ok(l.page.assets.append(l.arena, .{ .src = src, .path = path, .loc = at, .raster = size }));
        return @intCast(l.page.assets.items.len - 1);
    }

    /// `<img src alt>`: a local PNG from the asset table, at its size or in the box its CSS
    /// width and height (else its attributes) give, a side left out following the other by
    /// the picture's shape; `object-fit` fill (the default), contain or cover. CSS gives it
    /// only its size, margins and corner radius (0 unless set, as in a browser).
    fn img(l: *Lowerer, n: u32, parent: u32) bool {
        const src = l.attr(n, "src") orelse {
            l.ds.err(l.loc(n), "<img> needs src", .{});
            return true;
        };
        const alt = l.attr(n, "alt") orelse {
            l.ds.err(l.loc(n), "<img> needs alt: the picture's text, or alt=\"\" when it only decorates", .{});
            return true;
        };
        var params: []const u8 = "";
        var margin: ?[4]f32 = null;
        const st = l.boxStyle(n, .{}, l.parentDir(parent), &params, &margin);
        if (params.len > 0 or st.texture != .white) l.ds.err(l.loc(n), "<img> takes no gradient, background image or dashed border", .{});
        var box: [2]f32 = .{ 0, 0 };
        inline for (.{ "width", "height" }, 0..) |name, a| switch (st.size[a].kind) {
            .px => box[a] = st.size[a].v,
            .fit => box[a] = l.numberAttr(n, name) orelse 0,
            else => l.ds.err(l.loc(n), "<img>: give its " ++ name ++ " in px", .{}),
        };
        const k = l.asset(src, l.valueLoc(n, "src"), box) orelse return true;
        var fit: lcgf.widgets_image.Fit = .stretch;
        if (l.keyword(n, .@"object-fit")) |kw| {
            if (css.eq(kw, "contain")) fit = .contain else if (css.eq(kw, "cover")) fit = .cover else if (!css.eq(kw, "fill"))
                l.ds.err(l.declared(n, .@"object-fit").?.loc, "object-fit: {s} is not lowered; use fill, contain or cover", .{kw});
        }
        const node: ir.Node = .{
            .kind = .image,
            .parent = parent,
            .loc = l.loc(n),
            .asset = k,
            .image = .{ .box = if (box[0] + box[1] > 0) box else null, .fit = fit, .radius = st.radius },
            .name = alt,
            .margin = margin,
        };
        l.ir_of[n] = l.addNode(node);
        return true;
    }

    fn numberAttr(l: *Lowerer, n: u32, name: []const u8) ?f32 {
        const v = l.attr(n, name) orelse return null;
        return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch {
            l.ds.err(l.valueLoc(n, name), "{s}=\"{s}\" is not a number", .{ name, v });
            return null;
        };
    }
};

/// Texels of a gradient's ramp row: a 1 KiB asset, an eighth of a texel's colour step for a
/// two-colour run across the row.
const ramp_texels = 256;

/// CSS's colour stop fix-up: a first stop without a position at 0, a last one at 1, each
/// at least the largest before it, and runs without one spread evenly between their
/// neighbours.
fn fixStops(stops: []lcgf.features.Stop, given: []const bool) void {
    const last = stops.len - 1;
    if (!given[0]) stops[0].at = 0;
    if (!given[last]) stops[last].at = 1;
    var hi: f32 = stops[0].at;
    var k: usize = 1;
    while (k < stops.len) : (k += 1) {
        if (given[k] or k == last) {
            stops[k].at = @max(stops[k].at, hi);
            hi = stops[k].at;
            continue;
        }
        // A run of stops without positions: k up to the next one with a position.
        var e = k;
        while (e < last and !given[e]) e += 1;
        const to = @max(stops[e].at, hi);
        const step = (to - hi) / @as(f32, @floatFromInt(e - k + 1));
        for (k..e) |j| stops[j].at = hi + step * @as(f32, @floatFromInt(j - k + 1));
        k = e - 1;
    }
}

pub fn init(arena: std.mem.Allocator, ds: *diag.Diags, doc: *const html.Doc, c: *css.Css, k: *const cascade.Cascade, name: []const u8, source: []const u8) Lowerer {
    const n = doc.nodes.len;
    const l: Lowerer = .{
        .arena = arena,
        .ds = ds,
        .doc = doc,
        .c = c,
        .k = k,
        .page = .{ .name = name, .source = source },
        .ir_of = Lowerer.ok(arena.alloc(u32, n)),
        .skip = Lowerer.ok(arena.alloc(bool, n)),
        .text = Lowerer.ok(arena.alloc(TextStyle, n)),
        .text_tokens = Lowerer.ok(arena.alloc(ir.TextTokens, n)),
        .font = Lowerer.ok(arena.alloc(FontState, n)),
        .para = Lowerer.ok(arena.alloc(Paragraph, n)),
        .deco = Lowerer.ok(arena.alloc(Decoration, n)),
        .inline_of = Lowerer.ok(arena.alloc(u32, n)),
    };
    @memset(l.inline_of, none);
    @memset(l.ir_of, none);
    @memset(l.skip, false);
    return l;
}

const Paragraph = lcgf.text_stack.Paragraph;
const Decoration = lcgf.text_decorations.Style;

/// A paragraph of inline runs while its text is gathered.
const Inline = struct {
    element: u32,
    ir: u32,
    bytes: std.ArrayList(u8) = .empty,
    styles: std.ArrayList(TextStyle) = .empty,
};

/// The inherited font properties of an element.
const FontState = struct {
    /// font-family value tokens, or none when no ancestor declares one.
    family: [2]u32 = .{ none, none },
    loc: Loc = .{},
    weight: f32 = 400,
    style: lcgf.font_match.Style = .normal,
};

/// A font-weight value over the inherited weight `parent`; null when it is not one.
fn weightOf(c: *const css.Css, a: u32, b: u32, parent: f32) ?f32 {
    if (b - a != 1) return null;
    const t = c.toks.get(a);
    if (t.type == .number) return if (t.num >= 1 and t.num <= 1000) @floatCast(t.num) else null;
    if (t.type != .ident) return null;
    if (css.eq(t.str, "normal")) return 400;
    if (css.eq(t.str, "bold")) return 700;
    // CSS Fonts 4, the relative weights table.
    if (css.eq(t.str, "bolder")) return if (parent < 350) 400 else if (parent < 550) 700 else @max(parent, 900);
    if (css.eq(t.str, "lighter")) return if (parent < 100) parent else if (parent < 550) 100 else if (parent < 750) 400 else 700;
    return null;
}

/// A font-style value (`oblique` may carry an angle, which selection ignores).
fn styleOf(c: *const css.Css, a: u32) ?lcgf.font_match.Style {
    const t = c.toks.get(a);
    if (t.type != .ident) return null;
    return std.meta.stringToEnum(lcgf.font_match.Style, t.str);
}

fn isGeneric(family: []const u8) bool {
    for ([_][]const u8{ "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded", "math", "emoji", "fangsong" }) |g| if (std.ascii.eqlIgnoreCase(family, g)) return true;
    return false;
}

/// `style` as `spec.row` stores it: along x.
fn row(style: Style) Style {
    var s = style;
    s.dir = .x;
    return s;
}

fn isBlank(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isWhitespace(ch)) return false;
    return true;
}

fn isBound(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " ");
    return t.len >= 2 and t[0] == '{' and t[t.len - 1] == '}';
}

/// HTML whitespace collapsing for one run of text: spaces, tabs and newlines become one
/// space; leading and trailing white space goes.
pub fn collapse(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (s) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            space = out.items.len > 0;
            continue;
        }
        if (space) out.append(arena, ' ') catch @panic("out of memory");
        space = false;
        out.append(arena, ch) catch @panic("out of memory");
    }
    return out.items;
}

/// Collapsed text with its `<br>` markers (0 bytes) as newlines, without spaces beside them.
fn breaks(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |ch, i| {
        if (ch == ' ' and ((i + 1 < s.len and s[i + 1] == 0) or (i > 0 and s[i - 1] == 0))) continue;
        out.append(arena, if (ch == 0) '\n' else ch) catch @panic("out of memory");
    }
    return out.items;
}

fn headingLevel(t: []const u8) u8 {
    if (t.len == 2 and t[0] == 'h' and t[1] >= '1' and t[1] <= '6') return t[1] - '0';
    return 0;
}

/// A custom element (a name with a hyphen, not lcgf-*): an app component.
fn isComponent(t: []const u8) bool {
    return std.mem.indexOfScalar(u8, t, '-') != null and !std.mem.startsWith(u8, t, "lcgf-");
}

/// The list role of element `t` (engine spec F1): `<ul>`, `<ol>` and `<menu>` are lists, `<li>`
/// their items.
fn listRole(t: []const u8) ?types.Role {
    if (std.mem.eql(u8, t, "ul") or std.mem.eql(u8, t, "ol") or std.mem.eql(u8, t, "menu")) return .list;
    if (std.mem.eql(u8, t, "li")) return .list_item;
    return null;
}

fn isLandmark(t: []const u8) bool {
    for ([_][]const u8{ "main", "nav", "aside", "article", "form", "search", "header", "footer", "section" }) |x| if (std.mem.eql(u8, t, x)) return true;
    return false;
}

/// The landmark role of element `n`, by the HTML-AAM rules, or null.
fn landmarkOf(l: *const Lowerer, n: u32, t: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, t, "main")) return "main";
    if (std.mem.eql(u8, t, "nav")) return "navigation";
    if (std.mem.eql(u8, t, "aside")) return "complementary";
    if (std.mem.eql(u8, t, "article")) return "article";
    if (std.mem.eql(u8, t, "form")) return "form";
    if (std.mem.eql(u8, t, "search")) return "search";
    if (std.mem.eql(u8, t, "section")) return if (l.attr(n, "aria-label") != null or l.attr(n, "aria-labelledby") != null) "region" else null;
    if (std.mem.eql(u8, t, "header") or std.mem.eql(u8, t, "footer")) {
        var p = l.doc.nodes.items(.parent)[n];
        while (p != none) : (p = l.doc.nodes.items(.parent)[p]) {
            for ([_][]const u8{ "article", "aside", "main", "nav", "section" }) |x| if (l.doc.isElement(p, x)) return null;
        }
        return if (t[0] == 'h') "banner" else "content_info";
    }
    return null;
}

fn alignOf(kw: []const u8) ?types.Align {
    if (css.eq(kw, "start") or css.eq(kw, "flex-start") or css.eq(kw, "left") or css.eq(kw, "self-start")) return .start;
    if (css.eq(kw, "center")) return .center;
    if (css.eq(kw, "end") or css.eq(kw, "flex-end") or css.eq(kw, "right") or css.eq(kw, "self-end")) return .end;
    return null;
}

fn cursorOf(kw: []const u8) ?types.Cursor {
    const map = [_]struct { []const u8, types.Cursor }{
        .{ "default", .arrow },           .{ "auto", .arrow },         .{ "none", .hidden },
        .{ "ns-resize", .resize_v },      .{ "ew-resize", .resize_h }, .{ "nwse-resize", .resize_nwse },
        .{ "nesw-resize", .resize_nesw },
    };
    for (map) |m| if (css.eq(kw, m[0])) return m[1];
    var buf: [32]u8 = undefined;
    if (kw.len > buf.len) return null;
    const name = buf[0..kw.len];
    for (kw, name) |ch, *o| o.* = if (ch == '-') '_' else std.ascii.toLower(ch);
    return std.meta.stringToEnum(types.Cursor, name);
}

/// The affine `a · b` (apply `b` first), as CSS composes `transform` functions left to right.
fn mul(a: [6]f32, b: [6]f32) [6]f32 {
    return .{
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    };
}

pub fn colorExpr(arena: std.mem.Allocator, c: types.Color) []const u8 {
    if (c.a == 255) return std.fmt.allocPrint(arena, ".rgb({d}, {d}, {d})", .{ c.r, c.g, c.b }) catch @panic("out of memory");
    return std.fmt.allocPrint(arena, ".rgba({d}, {d}, {d}, {d})", .{ c.r, c.g, c.b, c.a }) catch @panic("out of memory");
}

/// The counter styles `list-style-type` names, as text_counters formats them.
const counter_styles = blk: {
    const c = lcgf.text_counters;
    const greek = [_][]const u8{ "\u{3B1}", "\u{3B2}", "\u{3B3}", "\u{3B4}", "\u{3B5}", "\u{3B6}", "\u{3B7}", "\u{3B8}", "\u{3B9}", "\u{3BA}", "\u{3BB}", "\u{3BC}", "\u{3BD}", "\u{3BE}", "\u{3BF}", "\u{3C0}", "\u{3C1}", "\u{3C3}", "\u{3C4}", "\u{3C5}", "\u{3C6}", "\u{3C7}", "\u{3C8}", "\u{3C9}" };
    break :blk [_]struct { []const u8, c.Style, []const u8 }{
        .{ "decimal", c.decimal, "lcgf.text_counters.decimal" },
        .{ "decimal-leading-zero", c.decimal_leading_zero, "lcgf.text_counters.decimal_leading_zero" },
        .{ "lower-alpha", c.lower_alpha, "lcgf.text_counters.lower_alpha" },
        .{ "lower-latin", c.lower_alpha, "lcgf.text_counters.lower_alpha" },
        .{ "upper-alpha", c.upper_alpha, "lcgf.text_counters.upper_alpha" },
        .{ "upper-latin", c.upper_alpha, "lcgf.text_counters.upper_alpha" },
        .{ "lower-roman", c.lower_roman, "lcgf.text_counters.lower_roman" },
        .{ "upper-roman", c.upper_roman, "lcgf.text_counters.upper_roman" },
        .{ "lower-greek", .{ .system = .{ .alphabetic = &greek } }, "lcgf.text_counters.Style{ .system = .{ .alphabetic = &.{ \"\\u{3B1}\", \"\\u{3B2}\", \"\\u{3B3}\", \"\\u{3B4}\", \"\\u{3B5}\", \"\\u{3B6}\", \"\\u{3B7}\", \"\\u{3B8}\", \"\\u{3B9}\", \"\\u{3BA}\", \"\\u{3BB}\", \"\\u{3BC}\", \"\\u{3BD}\", \"\\u{3BE}\", \"\\u{3BF}\", \"\\u{3C0}\", \"\\u{3C1}\", \"\\u{3C3}\", \"\\u{3C4}\", \"\\u{3C5}\", \"\\u{3C6}\", \"\\u{3C7}\", \"\\u{3C8}\", \"\\u{3C9}\" } } }" },
    };
};

/// The state pseudo-classes of plan §2.3, resolved at run time (style.States).
const states = [_][]const u8{ "hover", "active", "focus", "focus-visible", "focus-within", "checked", "indeterminate", "disabled", "enabled", "read-only", "read-write", "required", "optional", "invalid", "valid", "open", "placeholder-shown" };

/// Names that are keywords in one of the three target languages.
const keywords = blk: {
    const zig = [_][]const u8{ "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "var", "volatile", "while", "true", "false", "null", "undefined", "type" };
    const cpp = [_][]const u8{ "alignas", "alignof", "auto", "bool", "case", "char", "class", "concept", "consteval", "constexpr", "constinit", "decltype", "default", "delete", "do", "double", "explicit", "float", "friend", "goto", "int", "long", "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "private", "protected", "public", "register", "requires", "short", "signed", "sizeof", "static", "this", "throw", "typedef", "typeid", "typename", "unsigned", "using", "virtual", "void", "wchar_t", "not", "xor", "bitand", "bitor", "compl" };
    const rust = [_][]const u8{ "as", "crate", "dyn", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "ref", "self", "super", "trait", "unsafe", "use", "where", "async", "await", "abstract", "become", "box", "final", "macro", "override", "priv", "typeof", "unsized", "virtual", "yield", "try" };
    var out: [zig.len + cpp.len + rust.len]struct { []const u8, []const u8 } = undefined;
    for (zig, 0..) |k, i| out[i] = .{ k, "Zig" };
    for (cpp, 0..) |k, i| out[zig.len + i] = .{ k, "C++" };
    for (rust, 0..) |k, i| out[zig.len + cpp.len + i] = .{ k, "Rust" };
    break :blk out;
};

test "collapse: HTML white space" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b c", collapse(arena.allocator(), "\n  a \t b\n c  "));
}

test "mul: translate then scale composes as CSS does" {
    const t = mul(.{ 1, 0, 0, 1, 10, 0 }, .{ 2, 0, 0, 2, 0, 0 });
    try std.testing.expectEqual([6]f32{ 2, 0, 0, 2, 10, 0 }, t);
}
