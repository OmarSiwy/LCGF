//! Stylesheets as rows: tokens (Lexbor's CSS Syntax 3 tokenizer, lexbor.c), then rules,
//! declarations and selectors parsed here over token ranges, each with its source location.
//! Blocks nest (`@media`, `@layer`, `@supports`) and `@import` pulls in another file; both are
//! handled with explicit stacks, never by recursing on the input.

const std = @import("std");
const lx = @import("lexbor.zig");
const diag = @import("diag.zig");

pub const none = diag.none;
pub const T = lx.TokenType;
const Loc = diag.Loc;

pub const Tok = struct { type: T, loc: Loc, end: u32, str: []const u8, num: f64, delim: u32 };

/// Where a declaration comes from, in cascade order of normal declarations.
pub const Origin = enum(u8) { ua, author, inline_style };

pub const Rule = struct {
    origin: Origin,
    /// Selectors `sel_first..+sel_count` (a selector list); none for an inline style.
    sel_first: u32,
    sel_count: u32,
    decl_first: u32,
    decl_count: u32,
    /// Index into `conds` of the innermost `@media`/`@supports` around the rule, or none.
    cond: u32,
    /// Layer order (1 + index into `layers`); 0 for unlayered.
    layer: u16,
};

pub const Decl = struct {
    /// Lower-case property name; a custom property (`--x`) keeps its case.
    name: []const u8,
    loc: Loc,
    /// Value tokens `[first, end)`, without the leading and trailing whitespace and `!important`.
    first: u32,
    end: u32,
    important: bool,
    rule: u32,
};

pub const Combinator = enum(u8) { none, descendant, child, next, subsequent };

pub const Selector = struct {
    rule: u32,
    first: u32,
    count: u32,
    /// a << 16 | b << 8 | c.
    specificity: u32,
    loc: Loc,
    /// `::before`, `::after`, `::part(x)`, `::placeholder`: the part the rule styles, or "".
    element: []const u8,
};

pub const Compound = struct {
    /// How this compound relates to the one before it (to its left).
    combinator: Combinator,
    first: u32,
    count: u32,
};

pub const SimpleKind = enum(u8) {
    universal,
    type,
    id,
    class,
    attr,
    /// A structural pseudo-class without arguments (`:root`, `:first-child`, `:empty`).
    pseudo,
    /// `:nth-child(a n + b)` and its relatives; `name` tells which.
    nth,
    /// `:not()`, `:is()`, `:where()`, `:has()` over the selectors `arg..+arg_count`.
    logical,
    /// A state pseudo-class resolved at run time (`:hover`, `:checked`).
    state,
};

pub const AttrOp = enum(u8) { exists, eq, includes, dash, prefix, suffix, substring };

pub const Simple = struct {
    kind: SimpleKind,
    name: []const u8,
    value: []const u8 = "",
    op: AttrOp = .exists,
    insensitive: bool = false,
    a: i32 = 0,
    b: i32 = 0,
    arg: u32 = none,
    arg_count: u32 = 0,
    loc: Loc,
};

pub const Cond = struct {
    kind: enum(u8) { media, supports },
    /// Prelude tokens.
    first: u32,
    end: u32,
    parent: u32,
    loc: Loc,
};

pub const Keyframes = struct {
    name: []const u8,
    first: u32,
    end: u32,
    loc: Loc,
    stops: []const Stop = &.{},

    /// `from` (0), `to` (1) or a percentage, and its declarations `decl_first..+decl_count`.
    pub const Stop = struct { at: f32, decl_first: u32, decl_count: u32, loc: Loc };
};

pub const FontFace = struct { decl_first: u32, decl_count: u32, loc: Loc };

pub const Css = struct {
    arena: std.mem.Allocator,
    ds: *diag.Diags,
    toks: std.MultiArrayList(Tok) = .empty,
    rules: std.MultiArrayList(Rule) = .empty,
    decls: std.MultiArrayList(Decl) = .empty,
    sels: std.MultiArrayList(Selector) = .empty,
    comps: std.MultiArrayList(Compound) = .empty,
    simples: std.MultiArrayList(Simple) = .empty,
    conds: std.ArrayList(Cond) = .empty,
    layers: std.ArrayList([]const u8) = .empty,
    fonts: std.ArrayList(FontFace) = .empty,
    /// `@keyframes`: each name and its stops, in source order. A stop's declarations belong
    /// to a rule without selectors, which the cascade skips.
    keyframes: std.ArrayList(Keyframes) = .empty,

    fn ok(r: anytype) @typeInfo(@TypeOf(r)).error_union.payload {
        return r catch @panic("out of memory");
    }

    /// Tokenizes `src` (bytes of file `file` starting at `base`) into the token table and
    /// returns its range. Whitespace tokens are kept: they separate selector compounds.
    pub fn tokenize(c: *Css, file: u16, base: u32, src: []const u8) [2]u32 {
        var out: lx.Css = undefined;
        defer lx.lcgf_css_free(&out);
        if (lx.lcgf_css_tokenize(src.ptr, src.len, &out) != 0) @panic("out of memory");
        const pool: []const u8 = if (out.pool) |p| ok(c.arena.dupe(u8, p[0..out.pool_len])) else "";
        const first: u32 = @intCast(c.toks.len);
        if (out.tokens) |tokens| for (tokens[0..out.n_tokens]) |t| ok(c.toks.append(c.arena, .{
            .type = t.type,
            .loc = .{ .file = file, .off = base + t.begin },
            .end = base + t.end,
            .str = pool[t.str.off..][0..t.str.len],
            .num = t.num,
            .delim = t.delim,
        }));
        if (out.diags) |diags| for (diags[0..out.n_diags]) |e|
            c.ds.err(.{ .file = file, .off = if (e.src == none) none else base + e.src }, "{s}", .{pool[e.msg.off..][0..e.msg.len]});
        return .{ first, @intCast(c.toks.len) };
    }

    pub fn tokLoc(c: *const Css, t: u32) Loc {
        return c.toks.items(.loc)[t];
    }

    /// Source bytes of tokens `[a, b)`, for messages.
    pub fn text(c: *const Css, a: u32, b: u32) []const u8 {
        if (a >= b) return "";
        const l = c.toks.items(.loc)[a];
        return c.ds.files.items[l.file].bytes[l.off..c.toks.items(.end)[b - 1]];
    }

    fn isWs(c: *const Css, t: u32) bool {
        return c.toks.items(.type)[t] == .whitespace;
    }

    /// Skips to the token after the block or function opened at `open` (its matching closer).
    fn skipBlock(c: *const Css, open: u32, end: u32) u32 {
        var depth: u32 = 0;
        var i = open;
        const ty = c.toks.items(.type);
        while (i < end) : (i += 1) switch (ty[i]) {
            .lc_bracket, .ls_bracket, .l_parenthesis, .function => depth += 1,
            .rc_bracket, .rs_bracket, .r_parenthesis => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        };
        return end;
    }

    /// Parses the declarations in `[a, b)` (a block's inside) as rule `rule`'s.
    pub fn declarations(c: *Css, a: u32, b: u32, rule: u32) [2]u32 {
        const first: u32 = @intCast(c.decls.len);
        const ty = c.toks.items(.type);
        var i = a;
        while (i < b) {
            while (i < b and (ty[i] == .whitespace or ty[i] == .semicolon)) i += 1;
            if (i >= b) break;
            const start = i;
            // The declaration runs to the next `;` outside any block.
            var end = i;
            while (end < b and ty[end] != .semicolon) end = switch (ty[end]) {
                .lc_bracket, .ls_bracket, .l_parenthesis, .function => c.skipBlock(end, b),
                else => end + 1,
            };
            i = end;
            if (ty[start] != .ident) {
                c.ds.err(c.tokLoc(start), "expected a property name, found '{s}'", .{c.text(start, start + 1)});
                continue;
            }
            var v = start + 1;
            while (v < end and ty[v] == .whitespace) v += 1;
            if (v >= end or ty[v] != .colon) {
                c.ds.err(c.tokLoc(start), "expected ':' after '{s}'", .{c.toks.items(.str)[start]});
                continue;
            }
            v += 1;
            var e = end;
            while (e > v and ty[e - 1] == .whitespace) e -= 1;
            while (v < e and ty[v] == .whitespace) v += 1;
            // `! important`, any case, whitespace allowed between.
            var important = false;
            if (e > v and ty[e - 1] == .ident and std.ascii.eqlIgnoreCase(c.toks.items(.str)[e - 1], "important")) {
                var bang = e - 1;
                while (bang > v and ty[bang - 1] == .whitespace) bang -= 1;
                if (bang > v and ty[bang - 1] == .delim and c.toks.items(.delim)[bang - 1] == '!') {
                    important = true;
                    e = bang - 1;
                    while (e > v and ty[e - 1] == .whitespace) e -= 1;
                }
            }
            const raw = c.toks.items(.str)[start];
            const name = if (std.mem.startsWith(u8, raw, "--")) raw else ok(std.ascii.allocLowerString(c.arena, raw));
            ok(c.decls.append(c.arena, .{ .name = name, .loc = c.tokLoc(start), .first = v, .end = e, .important = important, .rule = rule }));
        }
        return .{ first, @intCast(c.decls.len) };
    }

    /// A rule whose declarations are element `node`'s `style` attribute (`[a, b)`). It has no
    /// selectors; `sel_count` holds the element.
    pub fn inlineStyle(c: *Css, a: u32, b: u32, node: u32) u32 {
        const r: u32 = @intCast(c.rules.len);
        ok(c.rules.append(c.arena, .{ .origin = .inline_style, .sel_first = none, .sel_count = node, .decl_first = 0, .decl_count = 0, .cond = none, .layer = 0 }));
        const d = c.declarations(a, b, r);
        c.rules.items(.decl_first)[r] = d[0];
        c.rules.items(.decl_count)[r] = d[1] - d[0];
        return r;
    }

    fn layerIndex(c: *Css, name: []const u8) u16 {
        for (c.layers.items, 1..) |l, i| if (std.mem.eql(u8, l, name)) return @intCast(i);
        ok(c.layers.append(c.arena, name));
        return @intCast(c.layers.items.len);
    }

    /// The prelude of an at-rule or qualified rule at `i`: up to `{` or `;` outside any block.
    fn prelude(c: *const Css, i: u32, end: u32) u32 {
        const ty = c.toks.items(.type);
        var p = i;
        while (p < end and ty[p] != .lc_bracket and ty[p] != .semicolon and ty[p] != .rc_bracket) p = switch (ty[p]) {
            .ls_bracket, .l_parenthesis, .function => c.skipBlock(p, end),
            else => p + 1,
        };
        return p;
    }

    /// Parses the stylesheet in tokens `[a, b)`. `imports` loads an `@import`ed file and
    /// returns its token range, or null after reporting why it could not.
    pub fn sheet(c: *Css, a: u32, b: u32, origin: Origin, importer: anytype) void {
        const Frame = struct { i: u32, end: u32, cond: u32, layer: u16, block_end: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        ok(stack.append(c.arena, .{ .i = a, .end = b, .cond = none, .layer = 0, .block_end = b }));
        // An @import appends tokens, so the type column is fetched again for every rule.
        var rules_seen = false;
        while (stack.items.len > 0) {
            const ty = c.toks.items(.type);
            const top = &stack.items[stack.items.len - 1];
            var i = top.i;
            while (i < top.end and (ty[i] == .whitespace or ty[i] == .cdo or ty[i] == .cdc or ty[i] == .semicolon)) i += 1;
            if (i >= top.end) {
                _ = stack.pop();
                continue;
            }
            const cond = top.cond;
            const layer = top.layer;
            if (ty[i] == .rc_bracket) {
                c.ds.err(c.tokLoc(i), "unmatched '}}'", .{});
                top.i = i + 1;
                continue;
            }
            const p = c.prelude(i, top.end);
            const has_block = p < top.end and ty[p] == .lc_bracket;
            const block_end = if (has_block) c.skipBlock(p, top.end) else @min(p + 1, top.end);
            // Inside `[p + 1, inner)`: the block without its braces.
            const inner = if (has_block and block_end > p + 1 and ty[block_end - 1] == .rc_bracket) block_end - 1 else block_end;
            top.i = block_end;
            if (ty[i] == .at_keyword) {
                const name = c.toks.items(.str)[i];
                const loc = c.tokLoc(i);
                var pa = i + 1;
                while (pa < p and c.isWs(pa)) pa += 1;
                var pe = p;
                while (pe > pa and c.isWs(pe - 1)) pe -= 1;
                if (eq(name, "import")) {
                    if (rules_seen) {
                        c.ds.err(loc, "@import must come before every other rule", .{});
                        continue;
                    }
                    if (importer.load(c, pa, pe)) |range| {
                        // The imported sheet's rules come first: parse it before the rest.
                        ok(stack.append(c.arena, .{ .i = range[0], .end = range[1], .cond = cond, .layer = layer, .block_end = range[1] }));
                    }
                    continue;
                }
                rules_seen = true;
                if (eq(name, "media") or eq(name, "supports")) {
                    if (!has_block) {
                        c.ds.err(loc, "@{s} needs a block", .{name});
                        continue;
                    }
                    ok(c.conds.append(c.arena, .{ .kind = if (eq(name, "media")) .media else .supports, .first = pa, .end = pe, .parent = cond, .loc = loc }));
                    ok(stack.append(c.arena, .{ .i = p + 1, .end = inner, .cond = @intCast(c.conds.items.len - 1), .layer = layer, .block_end = inner }));
                } else if (eq(name, "layer")) {
                    // `@layer a, b;` fixes the order; `@layer a { … }` also scopes the rules.
                    var t = pa;
                    var last: u16 = 0;
                    while (t < pe) : (t += 1) if (ty[t] == .ident) {
                        last = c.layerIndex(c.text(t, t + 1));
                    };
                    if (has_block) ok(stack.append(c.arena, .{ .i = p + 1, .end = inner, .cond = cond, .layer = if (pa == pe) c.layerIndex("") else last, .block_end = inner }));
                } else if (eq(name, "font-face")) {
                    const r: u32 = @intCast(c.rules.len);
                    ok(c.rules.append(c.arena, .{ .origin = origin, .sel_first = none, .sel_count = 0, .decl_first = 0, .decl_count = 0, .cond = cond, .layer = layer }));
                    const d = c.declarations(p + 1, inner, r);
                    ok(c.fonts.append(c.arena, .{ .decl_first = d[0], .decl_count = d[1] - d[0], .loc = loc }));
                } else if (eq(name, "keyframes")) {
                    ok(c.keyframes.append(c.arena, .{ .name = c.text(pa, pe), .first = p + 1, .end = inner, .loc = loc, .stops = c.keyframeStops(p + 1, inner, origin, layer) }));
                } else if (eq(name, "page") or eq(name, "namespace") or eq(name, "property") or eq(name, "scope") or eq(name, "counter-style") or eq(name, "charset") or eq(name, "container")) {
                    c.ds.err(loc, "@{s} is not supported", .{name});
                } else c.ds.err(loc, "unknown at-rule @{s}", .{name});
                continue;
            }
            rules_seen = true;
            if (!has_block) {
                c.ds.err(c.tokLoc(i), "expected '{{' after the selector '{s}'", .{c.text(i, p)});
                continue;
            }
            const r: u32 = @intCast(c.rules.len);
            ok(c.rules.append(c.arena, .{ .origin = origin, .sel_first = 0, .sel_count = 0, .decl_first = 0, .decl_count = 0, .cond = cond, .layer = layer }));
            const s = c.selectorList(i, p, r, false) orelse [2]u32{ 0, 0 };
            c.rules.items(.sel_first)[r] = s[0];
            c.rules.items(.sel_count)[r] = s[1] - s[0];
            const d = c.declarations(p + 1, inner, r);
            c.rules.items(.decl_first)[r] = d[0];
            c.rules.items(.decl_count)[r] = d[1] - d[0];
        }
    }

    /// The stops of a `@keyframes` block `[a, b)`: `from, 50% { … }` gives one stop per
    /// selector, sharing the block's declarations.
    fn keyframeStops(c: *Css, a: u32, b: u32, origin: Origin, layer: u16) []const Keyframes.Stop {
        const ty = c.toks.items(.type);
        var out: std.ArrayList(Keyframes.Stop) = .empty;
        var i = a;
        while (i < b) {
            while (i < b and ty[i] == .whitespace) i += 1;
            if (i >= b) break;
            var open = i;
            while (open < b and ty[open] != .lc_bracket) open += 1;
            if (open >= b) {
                c.ds.err(c.tokLoc(i), "expected '{{' after a keyframe selector", .{});
                break;
            }
            const close = c.skipBlock(open, b);
            const r: u32 = @intCast(c.rules.len);
            ok(c.rules.append(c.arena, .{ .origin = origin, .sel_first = none, .sel_count = 0, .decl_first = 0, .decl_count = 0, .cond = none, .layer = layer }));
            const d = c.declarations(open + 1, close - 1, r);
            var t = i;
            while (t < open) : (t += 1) {
                const at: ?f32 = switch (ty[t]) {
                    .whitespace, .comma => continue,
                    .percentage => @as(f32, @floatCast(c.toks.items(.num)[t])) / 100,
                    .ident => if (eq(c.toks.items(.str)[t], "from")) 0 else if (eq(c.toks.items(.str)[t], "to")) 1 else null,
                    else => null,
                };
                if (at == null or at.? < 0 or at.? > 1) {
                    c.ds.err(c.tokLoc(t), "a keyframe selector is from, to or a percentage from 0% to 100%", .{});
                    continue;
                }
                ok(out.append(c.arena, .{ .at = at.?, .decl_first = d[0], .decl_count = d[1] - d[0], .loc = c.tokLoc(t) }));
            }
            i = close;
        }
        std.mem.sort(Keyframes.Stop, out.items, {}, struct {
            fn less(_: void, x: Keyframes.Stop, y: Keyframes.Stop) bool {
                return x.at < y.at;
            }
        }.less);
        return out.items;
    }

    /// Parses a selector list over tokens `[a, b)` into `sels`; null after reporting an error
    /// (the whole rule is then dropped, as CSS drops an invalid selector list).
    pub fn selectorList(c: *Css, a: u32, b: u32, rule: u32, nested: bool) ?[2]u32 {
        const ty = c.toks.items(.type);
        const str = c.toks.items(.str);
        const first: u32 = @intCast(c.sels.len);
        var pending: std.ArrayList(struct { simple: u32, sel: u32 }) = .empty;
        var i = a;
        while (i < b and c.isWs(i)) i += 1;
        var e = b;
        while (e > i and c.isWs(e - 1)) e -= 1;
        while (i < e) {
            const sel: u32 = @intCast(c.sels.len);
            ok(c.sels.append(c.arena, .{ .rule = rule, .first = @intCast(c.comps.len), .count = 0, .specificity = 0, .loc = c.tokLoc(i), .element = "" }));
            var comb: Combinator = .none;
            var spec: [3]u32 = .{ 0, 0, 0 };
            var compound: u32 = none;
            while (i < e and ty[i] != .comma) {
                // Combinators: whitespace (descendant) unless next to `>`, `+` or `~`.
                if (ty[i] == .whitespace or (ty[i] == .delim and (c.toks.items(.delim)[i] == '>' or c.toks.items(.delim)[i] == '+' or c.toks.items(.delim)[i] == '~'))) {
                    var explicit: Combinator = .descendant;
                    while (i < e and (ty[i] == .whitespace or (ty[i] == .delim and std.mem.indexOfScalar(u8, ">+~", @intCast(c.toks.items(.delim)[i])) != null))) : (i += 1) {
                        if (ty[i] == .delim) explicit = switch (c.toks.items(.delim)[i]) {
                            '>' => .child,
                            '+' => .next,
                            else => .subsequent,
                        };
                    }
                    if (compound == none) {
                        c.ds.err(c.tokLoc(i -| 1), "a selector cannot start with a combinator", .{});
                        return null;
                    }
                    comb = explicit;
                    compound = none;
                    continue;
                }
                if (compound == none) {
                    compound = @intCast(c.comps.len);
                    ok(c.comps.append(c.arena, .{ .combinator = comb, .first = @intCast(c.simples.len), .count = 0 }));
                    c.sels.items(.count)[sel] += 1;
                }
                const loc = c.tokLoc(i);
                var simple: Simple = .{ .kind = .universal, .name = "", .loc = loc };
                switch (ty[i]) {
                    .ident => {
                        simple = .{ .kind = .type, .name = ok(std.ascii.allocLowerString(c.arena, str[i])), .loc = loc };
                        spec[2] += 1;
                        i += 1;
                    },
                    .hash => {
                        simple = .{ .kind = .id, .name = str[i], .loc = loc };
                        spec[0] += 1;
                        i += 1;
                    },
                    .delim => switch (c.toks.items(.delim)[i]) {
                        '*' => i += 1,
                        '.' => {
                            if (i + 1 >= e or ty[i + 1] != .ident) {
                                c.ds.err(loc, "expected a class name after '.'", .{});
                                return null;
                            }
                            simple = .{ .kind = .class, .name = str[i + 1], .loc = loc };
                            spec[1] += 1;
                            i += 2;
                        },
                        else => {
                            c.ds.err(loc, "unexpected '{s}' in a selector", .{c.text(i, i + 1)});
                            return null;
                        },
                    },
                    .ls_bracket => {
                        const close = c.skipBlock(i, e);
                        simple = c.attrSelector(i + 1, close - 1, loc) orelse return null;
                        spec[1] += 1;
                        i = close;
                    },
                    .colon => {
                        i += 1;
                        if (i < e and ty[i] == .colon) {
                            // A pseudo-element: the part of the element the rule styles.
                            i += 1;
                            if (i >= e) {
                                c.ds.err(loc, "expected a pseudo-element name", .{});
                                return null;
                            }
                            const pe = if (ty[i] == .function) blk: {
                                const close = c.skipBlock(i, e);
                                const name = c.text(i + 1, close - 1);
                                i = close;
                                break :blk ok(std.fmt.allocPrint(c.arena, "part({s})", .{std.mem.trim(u8, name, " ")}));
                            } else blk: {
                                const n = ok(std.ascii.allocLowerString(c.arena, str[i]));
                                i += 1;
                                break :blk n;
                            };
                            c.sels.items(.element)[sel] = pe;
                            spec[2] += 1;
                            continue;
                        }
                        if (i >= e or (ty[i] != .ident and ty[i] != .function)) {
                            c.ds.err(loc, "expected a pseudo-class name after ':'", .{});
                            return null;
                        }
                        const name = ok(std.ascii.allocLowerString(c.arena, str[i]));
                        if (ty[i] == .ident) {
                            i += 1;
                            simple = .{ .kind = if (structural.has(name)) .pseudo else .state, .name = name, .loc = loc };
                            spec[1] += 1;
                        } else {
                            const close = c.skipBlock(i, e);
                            const args = [2]u32{ i + 1, close - 1 };
                            i = close;
                            if (eq(name, "not") or eq(name, "is") or eq(name, "where") or eq(name, "has")) {
                                if (nested) {
                                    c.ds.err(loc, ":{s}() inside another :not(), :is(), :where() or :has() is not supported", .{name});
                                    return null;
                                }
                                // Parsed once this list is done, so this compound's simples
                                // and this list's selectors stay contiguous.
                                simple = .{ .kind = .logical, .name = name, .arg = args[0], .arg_count = args[1], .loc = loc };
                                ok(pending.append(c.arena, .{ .simple = @intCast(c.simples.len), .sel = sel }));
                            } else if (std.mem.startsWith(u8, name, "nth-")) {
                                const ab = c.nth(args[0], args[1]) orelse {
                                    c.ds.err(loc, "expected An+B, odd or even in :{s}()", .{name});
                                    return null;
                                };
                                simple = .{ .kind = .nth, .name = name, .a = ab[0], .b = ab[1], .loc = loc };
                                spec[1] += 1;
                            } else {
                                c.ds.err(loc, "unknown pseudo-class :{s}()", .{name});
                                return null;
                            }
                        }
                    },
                    else => {
                        c.ds.err(loc, "unexpected '{s}' in a selector", .{c.text(i, i + 1)});
                        return null;
                    },
                }
                ok(c.simples.append(c.arena, simple));
                c.comps.items(.count)[compound] += 1;
            }
            if (compound == none) {
                c.ds.err(c.sels.items(.loc)[sel], "a selector cannot end with a combinator", .{});
                return null;
            }
            c.sels.items(.specificity)[sel] = (@as(u32, @min(spec[0], 255)) << 16) | (@as(u32, @min(spec[1], 255)) << 8) | @min(spec[2], 255);
            if (i < e) {
                i += 1;
                while (i < e and c.isWs(i)) i += 1;
                if (i >= e) {
                    c.ds.err(c.tokLoc(e - 1), "a selector list cannot end with ','", .{});
                    return null;
                }
            }
        }
        if (c.sels.len == first) {
            c.ds.err(c.tokLoc(a), "expected a selector", .{});
            return null;
        }
        const end: u32 = @intCast(c.sels.len);
        for (pending.items) |p| {
            const s = c.simples.slice();
            const range = c.selectorList(s.items(.arg)[p.simple], s.items(.arg_count)[p.simple], rule, true) orelse return null;
            c.simples.items(.arg)[p.simple] = range[0];
            c.simples.items(.arg_count)[p.simple] = range[1] - range[0];
            // :is/:not/:has take their most specific argument; :where adds nothing.
            if (!eq(c.simples.items(.name)[p.simple], "where")) {
                var most: u32 = 0;
                for (c.sels.items(.specificity)[range[0]..range[1]]) |sp| most = @max(most, sp);
                c.sels.items(.specificity)[p.sel] += most;
            }
        }
        return .{ first, end };
    }

    fn attrSelector(c: *Css, a: u32, b: u32, loc: Loc) ?Simple {
        const ty = c.toks.items(.type);
        var i = a;
        while (i < b and c.isWs(i)) i += 1;
        if (i >= b or ty[i] != .ident) {
            c.ds.err(loc, "expected an attribute name in '[…]'", .{});
            return null;
        }
        var s: Simple = .{ .kind = .attr, .name = ok(std.ascii.allocLowerString(c.arena, c.toks.items(.str)[i])), .loc = loc };
        i += 1;
        while (i < b and c.isWs(i)) i += 1;
        if (i >= b) return s;
        if (ty[i] != .delim) {
            c.ds.err(c.tokLoc(i), "expected an attribute operator", .{});
            return null;
        }
        const d = c.toks.items(.delim)[i];
        s.op = switch (d) {
            '=' => .eq,
            '~' => .includes,
            '|' => .dash,
            '^' => .prefix,
            '$' => .suffix,
            '*' => .substring,
            else => {
                c.ds.err(c.tokLoc(i), "expected an attribute operator", .{});
                return null;
            },
        };
        i += 1;
        if (d != '=') {
            if (i >= b or ty[i] != .delim or c.toks.items(.delim)[i] != '=') {
                c.ds.err(c.tokLoc(i - 1), "expected '=' after '{u}'", .{@as(u21, @intCast(d))});
                return null;
            }
            i += 1;
        }
        while (i < b and c.isWs(i)) i += 1;
        if (i >= b or (ty[i] != .ident and ty[i] != .string)) {
            c.ds.err(loc, "expected an attribute value", .{});
            return null;
        }
        s.value = c.toks.items(.str)[i];
        i += 1;
        while (i < b and c.isWs(i)) i += 1;
        if (i < b and ty[i] == .ident and (eq(c.toks.items(.str)[i], "i") or eq(c.toks.items(.str)[i], "s"))) {
            s.insensitive = eq(c.toks.items(.str)[i], "i");
            i += 1;
        }
        while (i < b and c.isWs(i)) i += 1;
        if (i < b) {
            c.ds.err(c.tokLoc(i), "unexpected '{s}' in an attribute selector", .{c.text(i, i + 1)});
            return null;
        }
        return s;
    }

    /// `An+B` from the source bytes of `[a, b)`; the tokenizer splits it unhelpfully
    /// (`2n+1` is a dimension then a number), so it is read from the text.
    fn nth(c: *const Css, a: u32, b: u32) ?[2]i32 {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (c.text(a, b)) |ch| if (ch != ' ' and ch != '\t' and ch != '\n') {
            if (n == buf.len) return null;
            buf[n] = std.ascii.toLower(ch);
            n += 1;
        };
        const t = buf[0..n];
        if (std.mem.eql(u8, t, "odd")) return .{ 2, 1 };
        if (std.mem.eql(u8, t, "even")) return .{ 2, 0 };
        const at = std.mem.indexOfScalar(u8, t, 'n') orelse return .{ 0, std.fmt.parseInt(i32, t, 10) catch return null };
        const coef = t[0..at];
        const av: i32 = if (coef.len == 0 or std.mem.eql(u8, coef, "+")) 1 else if (std.mem.eql(u8, coef, "-")) -1 else std.fmt.parseInt(i32, coef, 10) catch return null;
        const rest = t[at + 1 ..];
        const bv: i32 = if (rest.len == 0) 0 else std.fmt.parseInt(i32, if (rest[0] == '+') rest[1..] else rest, 10) catch return null;
        return .{ av, bv };
    }
};

/// Structural pseudo-classes matched against the static document.
pub const structural = std.StaticStringMap(void).initComptime(.{
    .{"root"},    .{"first-child"},   .{"last-child"},   .{"only-child"},
    .{"empty"},   .{"first-of-type"}, .{"last-of-type"}, .{"only-of-type"},
    .{"defined"}, .{"scope"},
});

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// An importer that refuses every `@import`; for tests and for sheets that may not import.
pub const NoImports = struct {
    pub fn load(_: NoImports, c: *Css, a: u32, _: u32) ?[2]u32 {
        c.ds.err(c.tokLoc(a), "@import is not allowed here", .{});
        return null;
    }
};

fn testCss(arena: std.mem.Allocator, ds: *diag.Diags, src: []const u8) Css {
    var c: Css = .{ .arena = arena, .ds = ds };
    const f = ds.addFile("t.css", src);
    const r = c.tokenize(f, 0, src);
    c.sheet(r[0], r[1], .author, NoImports{});
    return c;
}

test "sheet: rules, declarations with offsets, !important, @media nesting, specificity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    const src = "p, .a > #b:first-child { color: red ! IMPORTANT; Padding : 4px 2px }\n@media (min-width: 600px) { @layer x { div { gap: 1px } } }";
    const c = testCss(arena.allocator(), &ds, src);
    try std.testing.expectEqual(0, ds.errors);
    try std.testing.expectEqual(2, c.rules.len);
    try std.testing.expectEqual(3, c.decls.len);
    try std.testing.expectEqualStrings("padding", c.decls.items(.name)[1]);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "Padding").?, c.decls.items(.loc)[1].off);
    try std.testing.expect(c.decls.items(.important)[0]);
    try std.testing.expectEqualStrings("red", c.text(c.decls.items(.first)[0], c.decls.items(.end)[0]));
    try std.testing.expectEqualStrings("4px 2px", c.text(c.decls.items(.first)[1], c.decls.items(.end)[1]));
    try std.testing.expectEqual(0x000001, c.sels.items(.specificity)[0]);
    try std.testing.expectEqual(0x010200, c.sels.items(.specificity)[1]);
    try std.testing.expectEqual(2, c.sels.items(.count)[1]);
    try std.testing.expectEqual(Combinator.child, c.comps.items(.combinator)[c.sels.items(.first)[1] + 1]);
    try std.testing.expectEqual(0, c.rules.items(.cond)[1]);
    try std.testing.expectEqual(1, c.rules.items(.layer)[1]);
    try std.testing.expectEqualStrings("(min-width: 600px)", c.text(c.conds.items[0].first, c.conds.items[0].end));
}

test "sheet: escaped identifiers, recovery from a bad declaration and EOF inside a block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    const c = testCss(arena.allocator(), &ds, ".a\\:b { 12: x; color: blue; gap: 2px");
    try std.testing.expectEqualStrings("a:b", c.simples.items(.name)[0]);
    try std.testing.expectEqual(1, ds.errors);
    try std.testing.expectEqual(2, c.decls.len);
    try std.testing.expectEqualStrings("gap", c.decls.items(.name)[1]);
}

test "selectorList: attributes, :not(), :nth-child(), pseudo-elements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    const c = testCss(arena.allocator(), &ds, "a[href^='http' i]:not(.x, #y) li:nth-child(2n+1)::before {}");
    try std.testing.expectEqual(0, ds.errors);
    const s = c.simples.slice();
    try std.testing.expectEqual(AttrOp.prefix, s.items(.op)[1]);
    try std.testing.expect(s.items(.insensitive)[1]);
    try std.testing.expectEqual(SimpleKind.logical, s.items(.kind)[2]);
    try std.testing.expectEqual(2, s.items(.arg_count)[2]);
    // a, [href], :not, li, :nth-child; then :not's arguments.
    const last = 4;
    try std.testing.expectEqual(SimpleKind.nth, s.items(.kind)[last]);
    try std.testing.expectEqual([2]i32{ 2, 1 }, [2]i32{ s.items(.a)[last], s.items(.b)[last] });
    try std.testing.expectEqualStrings("before", c.sels.items(.element)[0]);
    // a, [href], :not's most specific (#y), li, :nth-child, ::before
    try std.testing.expectEqual(0x010203, c.sels.items(.specificity)[0]);
}
