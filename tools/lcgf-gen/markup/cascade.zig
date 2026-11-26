//! The cascade, at build time: every selector matched against the static document, and per
//! element and longhand the winning declaration (origin, `!important`, `@layer`, specificity,
//! order). Declarations under a state pseudo-class or `@media` are not in the static result;
//! they are collected as run-time rules for the recipes and variants (§2.3 of the plan).
//! Custom properties cascade the same way and inherit.

const std = @import("std");
const css = @import("css.zig");
const html = @import("html.zig");
const values = @import("values.zig");
const diag = @import("diag.zig");

const none = diag.none;
const Prop = values.Prop;

/// One cascaded value: the declaration, and the shorthand it came from (its index into
/// `values.shorthands`, or none for a longhand).
pub const Entry = struct { decl: u32 = none, shorthand: u32 = none, key: u64 = 0 };

/// A declaration that applies at run time: under a state pseudo-class, a media condition or
/// both. `states` names the pseudo-classes of the selector's last compound.
pub const Dynamic = struct { node: u32, decl: u32, sel: u32, cond: u32, element: []const u8 };

pub const Cascade = struct {
    /// `elements * prop_count` entries, row-major by element; non-elements have rows too.
    table: []Entry,
    /// Custom properties: names, and `nodes * customs.len` entries.
    customs: [][]const u8,
    custom_table: []Entry,
    dynamic: std.ArrayList(Dynamic),
    /// `::backdrop`'s longhands, as `table` holds the element's: from its static rules.
    backdrop: []Entry,
    /// Other rules matching a pseudo-element (`::before`, or `::backdrop` under a state or a
    /// condition, or setting a custom property): node, declaration, element.
    elements: std.ArrayList(Dynamic),
    /// Precomputed tree links, for the structural pseudo-classes and combinators.
    prev_el: []u32,
    next_el: []u32,
    first_el: []u32,
    /// One past the last node of each node's subtree.
    end: []u32,

    pub fn get(k: *const Cascade, node: u32, p: Prop) Entry {
        return k.table[node * values.prop_count + @backingInt(p)];
    }

    pub fn custom(k: *const Cascade, node: u32, name: []const u8) ?Entry {
        for (k.customs, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            const e = k.custom_table[node * k.customs.len + i];
            return if (e.decl == none) null else e;
        };
        return null;
    }
};

/// Cascade order of a declaration: later in this ordering wins.
fn key(c: *const css.Css, d: u32, specificity: u32, layers: u32) u64 {
    const r = c.decls.items(.rule)[d];
    const origin = c.rules.items(.origin)[r];
    const important = c.decls.items(.important)[d];
    const layer: u64 = c.rules.items(.layer)[r];
    // Unlayered declarations beat layered ones; `!important` reverses both origin and layer.
    const layer_rank: u64 = if (layer == 0) layers + 1 else layer;
    const tier: u64 = switch (origin) {
        .ua => if (important) 4 else 0,
        .author, .inline_style => if (important) 3 else 1,
    };
    const rank = if (important) layers + 1 - layer_rank + 1 else layer_rank;
    const spec: u64 = if (origin == .inline_style) 0xff_ffff else specificity;
    return (tier << 60) | (rank << 44) | (spec << 20) | @min(d, 0xf_ffff);
}

pub fn run(arena: std.mem.Allocator, doc: *const html.Doc, c: *css.Css) Cascade {
    const n: u32 = @intCast(doc.nodes.len);
    const kinds = doc.nodes.items(.kind);
    const parents = doc.nodes.items(.parent);
    var k: Cascade = .{
        .table = ok(arena.alloc(Entry, n * values.prop_count)),
        .customs = &.{},
        .custom_table = &.{},
        .dynamic = .empty,
        .backdrop = ok(arena.alloc(Entry, n * values.prop_count)),
        .elements = .empty,
        .prev_el = ok(arena.alloc(u32, n)),
        .next_el = ok(arena.alloc(u32, n)),
        .first_el = ok(arena.alloc(u32, n)),
        .end = ok(arena.alloc(u32, n)),
    };
    @memset(k.table, .{});
    @memset(k.backdrop, .{});
    @memset(k.prev_el, none);
    @memset(k.next_el, none);
    @memset(k.first_el, none);
    // Links: nodes are depth-first, so a node's previous element sibling is the last element
    // seen with the same parent, and subtree ends close in reverse.
    {
        const last = ok(arena.alloc(u32, n + 1));
        @memset(last, none);
        for (0..n) |i| {
            k.end[i] = @intCast(i + 1);
            if (kinds[i] != .element) continue;
            const p = parents[i];
            const slot = if (p == none) n else p;
            if (last[slot] != none) {
                k.prev_el[i] = last[slot];
                k.next_el[last[slot]] = @intCast(i);
            } else if (p != none) k.first_el[p] = @intCast(i);
            last[slot] = @intCast(i);
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            const p = parents[i];
            if (p != none) k.end[p] = @max(k.end[p], k.end[i]);
        }
    }
    // Custom property names, in order of first declaration.
    var customs: std.ArrayList([]const u8) = .empty;
    for (c.decls.items(.name)) |name| if (std.mem.startsWith(u8, name, "--")) {
        for (customs.items) |x| {
            if (std.mem.eql(u8, x, name)) break;
        } else ok(customs.append(arena, name));
    };
    k.customs = customs.items;
    k.custom_table = ok(arena.alloc(Entry, n * customs.items.len));
    @memset(k.custom_table, .{});

    const layers: u32 = @intCast(c.layers.items.len);
    const m: Matcher = .{ .doc = doc, .c = c, .k = &k };
    const rules = c.rules.slice();
    for (0..n) |node_| {
        const node: u32 = @intCast(node_);
        if (kinds[node] != .element) continue;
        for (0..rules.len) |r| {
            if (rules.items(.origin)[r] == .inline_style) continue;
            const sf = rules.items(.sel_first)[r];
            if (sf == none) continue; // @font-face
            for (sf..sf + rules.items(.sel_count)[r]) |s_| {
                const s: u32 = @intCast(s_);
                const res = m.matches(s, node, true);
                if (!res.matched) continue;
                const element = c.sels.items(.element)[s];
                const cond = rules.items(.cond)[r];
                for (rules.items(.decl_first)[r]..rules.items(.decl_first)[r] + rules.items(.decl_count)[r]) |d| {
                    const dyn: Dynamic = .{ .node = node, .decl = @intCast(d), .sel = s, .cond = cond, .element = element };
                    const kk = key(c, @intCast(d), c.sels.items(.specificity)[s], layers);
                    const custom = std.mem.startsWith(u8, c.decls.items(.name)[d], "--");
                    if (std.mem.eql(u8, element, "backdrop") and !res.dynamic and cond == none and !custom) {
                        apply(&k, k.backdrop, c, node, @intCast(d), kk);
                    } else if (element.len > 0) {
                        ok(k.elements.append(arena, dyn));
                    } else if (res.dynamic or cond != none) {
                        ok(k.dynamic.append(arena, dyn));
                    } else apply(&k, k.table, c, node, @intCast(d), kk);
                }
            }
        }
    }
    // Inline styles: their rules were added per element (`Css.inlineStyle`), in node order,
    // and carry the element in `sel_count` (they have no selectors).
    for (0..rules.len) |r| if (rules.items(.origin)[r] == .inline_style) {
        const node = rules.items(.sel_count)[r];
        for (rules.items(.decl_first)[r]..rules.items(.decl_first)[r] + rules.items(.decl_count)[r]) |d|
            apply(&k, k.table, c, node, @intCast(d), key(c, @intCast(d), 0, layers));
    };
    return k;
}

fn apply(k: *Cascade, table: []Entry, c: *const css.Css, node: u32, d: u32, kk: u64) void {
    const name = c.decls.items(.name)[d];
    if (std.mem.startsWith(u8, name, "--")) {
        for (k.customs, 0..) |x, i| if (std.mem.eql(u8, x, name)) {
            const e = &k.custom_table[node * k.customs.len + i];
            if (e.decl == none or kk > e.key) e.* = .{ .decl = d, .key = kk };
        };
        return;
    }
    if (std.meta.stringToEnum(Prop, name)) |p| {
        set(table, node, p, .{ .decl = d, .key = kk });
        return;
    }
    for (values.shorthands, 0..) |sh, i| if (std.mem.eql(u8, sh.name, name)) {
        for (sh.longhands) |p| set(table, node, p, .{ .decl = d, .shorthand = @intCast(i), .key = kk });
    };
}

fn set(table: []Entry, node: u32, p: Prop, e: Entry) void {
    const slot = &table[node * values.prop_count + @backingInt(p)];
    if (slot.decl == none or e.key > slot.key) slot.* = e;
}

fn ok(r: anytype) @typeInfo(@TypeOf(r)).error_union.payload {
    return r catch @panic("out of memory");
}

pub const Match = struct { matched: bool, dynamic: bool };

/// Selector matching against the document rows. Right to left, with an explicit stack of
/// backtrack points for descendant and subsequent-sibling combinators.
pub const Matcher = struct {
    doc: *const html.Doc,
    c: *const css.Css,
    k: *const Cascade,

    /// Whether selector `s` matches `node`; `dynamic` when it holds only while a state
    /// pseudo-class does (`:hover`), which then matches statically here.
    pub fn matches(m: Matcher, s: u32, node: u32, allow_logical: bool) Match {
        const first = m.c.sels.items(.first)[s];
        const count = m.c.sels.items(.count)[s];
        var dynamic = false;
        // Backtrack points: (compound index, node) to retry with the next candidate.
        var stack: [64]struct { comp: u32, node: u32 } = undefined;
        var depth: u32 = 0;
        var comp = first + count - 1;
        var at = node;
        while (true) {
            const r = m.compound(comp, at, allow_logical);
            dynamic = dynamic or r.dynamic;
            if (r.matched) {
                if (comp == first) return .{ .matched = true, .dynamic = dynamic };
                const comb = m.c.comps.items(.combinator)[comp];
                const nxt = m.step(comb, at) orelse return .{ .matched = false, .dynamic = false };
                if ((comb == .descendant or comb == .subsequent) and depth < stack.len) {
                    stack[depth] = .{ .comp = comp, .node = nxt };
                    depth += 1;
                }
                comp -= 1;
                at = nxt;
                continue;
            }
            // Retry the innermost backtrack point with the next ancestor or sibling.
            while (depth > 0) {
                const b = &stack[depth - 1];
                const comb = m.c.comps.items(.combinator)[b.comp];
                if (m.step(comb, b.node)) |again| {
                    b.node = again;
                    comp = b.comp - 1;
                    at = again;
                    break;
                }
                depth -= 1;
            } else return .{ .matched = false, .dynamic = false };
        }
    }

    /// The node a combinator moves to from `n`: parent or previous element sibling.
    fn step(m: Matcher, comb: css.Combinator, n: u32) ?u32 {
        const r = switch (comb) {
            .descendant, .child => m.doc.nodes.items(.parent)[n],
            .next, .subsequent => m.k.prev_el[n],
            .none => none,
        };
        return if (r == none) null else r;
    }

    fn compound(m: Matcher, comp: u32, n: u32, allow_logical: bool) Match {
        const doc = m.doc;
        const s = m.c.simples.slice();
        const f = m.c.comps.items(.first)[comp];
        var dynamic = false;
        for (f..f + m.c.comps.items(.count)[comp]) |i| {
            const name = s.items(.name)[i];
            const ok_ = switch (s.items(.kind)[i]) {
                .universal => true,
                .type => std.mem.eql(u8, doc.nodes.items(.name)[n], name),
                .id => if (doc.value(n, "id")) |v| std.mem.eql(u8, v, name) else false,
                .class => if (doc.value(n, "class")) |v| hasWord(v, name) else false,
                .attr => attrMatch(doc, n, s.get(i)),
                .pseudo => m.structural(n, name),
                .nth => m.nth(n, name, s.items(.a)[i], s.items(.b)[i]),
                .state => blk: {
                    dynamic = true;
                    break :blk true;
                },
                .logical => blk: {
                    if (!allow_logical) break :blk false;
                    const a = s.items(.arg)[i];
                    var any = false;
                    for (a..a + s.items(.arg_count)[i]) |sel| {
                        if (std.mem.eql(u8, name, "has")) {
                            for (n + 1..m.k.end[n]) |d| if (doc.nodes.items(.kind)[d] == .element and m.matches(@intCast(sel), @intCast(d), false).matched) {
                                any = true;
                            };
                        } else {
                            const r = m.matches(@intCast(sel), n, false);
                            any = any or r.matched;
                            dynamic = dynamic or r.dynamic;
                        }
                    }
                    break :blk if (std.mem.eql(u8, name, "not")) !any else any;
                },
            };
            if (!ok_) return .{ .matched = false, .dynamic = false };
        }
        return .{ .matched = true, .dynamic = dynamic };
    }

    fn structural(m: Matcher, n: u32, name: []const u8) bool {
        const k = m.k;
        if (std.mem.eql(u8, name, "root")) return m.doc.nodes.items(.parent)[n] == none;
        if (std.mem.eql(u8, name, "first-child")) return k.prev_el[n] == none;
        if (std.mem.eql(u8, name, "last-child")) return k.next_el[n] == none;
        if (std.mem.eql(u8, name, "only-child")) return k.prev_el[n] == none and k.next_el[n] == none;
        if (std.mem.eql(u8, name, "empty")) return k.end[n] == n + 1;
        if (std.mem.eql(u8, name, "first-of-type")) return m.ofType(n, true) == 0;
        if (std.mem.eql(u8, name, "last-of-type")) return m.ofType(n, false) == 0;
        if (std.mem.eql(u8, name, "only-of-type")) return m.ofType(n, true) == 0 and m.ofType(n, false) == 0;
        return true; // :defined, :scope
    }

    /// Element siblings before (or after) `n` with its tag.
    fn ofType(m: Matcher, n: u32, before: bool) u32 {
        var count: u32 = 0;
        var s = if (before) m.k.prev_el[n] else m.k.next_el[n];
        const names = m.doc.nodes.items(.name);
        while (s != none) : (s = if (before) m.k.prev_el[s] else m.k.next_el[s]) {
            if (std.mem.eql(u8, names[s], names[n])) count += 1;
        }
        return count;
    }

    fn nth(m: Matcher, n: u32, name: []const u8, a: i32, b: i32) bool {
        const of_type = std.mem.endsWith(u8, name, "of-type");
        const last = std.mem.startsWith(u8, name, "nth-last");
        var index: i32 = 1;
        const names = m.doc.nodes.items(.name);
        var s = if (last) m.k.next_el[n] else m.k.prev_el[n];
        while (s != none) : (s = if (last) m.k.next_el[s] else m.k.prev_el[s]) {
            if (!of_type or std.mem.eql(u8, names[s], names[n])) index += 1;
        }
        if (a == 0) return index == b;
        const diff = index - b;
        return @rem(diff, a) == 0 and @divTrunc(diff, a) >= 0;
    }
};

fn hasWord(list: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\n\r\x0c");
    while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn attrMatch(doc: *const html.Doc, n: u32, s: css.Simple) bool {
    const v = doc.value(n, s.name) orelse return false;
    var buf_v: [256]u8 = undefined;
    var buf_s: [256]u8 = undefined;
    const have = if (s.insensitive and v.len <= buf_v.len) std.ascii.lowerString(&buf_v, v) else v;
    const want = if (s.insensitive and s.value.len <= buf_s.len) std.ascii.lowerString(&buf_s, s.value) else s.value;
    return switch (s.op) {
        .exists => true,
        .eq => std.mem.eql(u8, have, want),
        .includes => hasWord(have, want),
        .dash => std.mem.eql(u8, have, want) or (std.mem.startsWith(u8, have, want) and have.len > want.len and have[want.len] == '-'),
        .prefix => want.len > 0 and std.mem.startsWith(u8, have, want),
        .suffix => want.len > 0 and std.mem.endsWith(u8, have, want),
        .substring => want.len > 0 and std.mem.indexOf(u8, have, want) != null,
    };
}

fn testRun(arena: std.mem.Allocator, ds: *diag.Diags, page: []const u8, sheet: []const u8) struct { html.Doc, css.Css, Cascade } {
    const doc = html.parse(arena, ds, ds.addFile("t.html", page)) catch unreachable;
    var c: css.Css = .{ .arena = arena, .ds = ds };
    const r = c.tokenize(ds.addFile("t.css", sheet), 0, sheet);
    c.sheet(r[0], r[1], .author, css.NoImports{});
    const k = run(arena, &doc, &c);
    return .{ doc, c, k };
}

/// The elements (by tag and position among nodes) whose `color` the sheet sets to the text.
fn colored(doc: *const html.Doc, c: *const css.Css, k: *const Cascade, value: []const u8, out: []u32) []u32 {
    var n: usize = 0;
    for (0..doc.nodes.len) |i| {
        const e = k.get(@intCast(i), .color);
        if (e.decl == none) continue;
        if (!std.mem.eql(u8, c.text(c.decls.items(.first)[e.decl], c.decls.items(.end)[e.decl]), value)) continue;
        out[n] = @intCast(i);
        n += 1;
    }
    return out[0..n];
}

test "cascade: selector forms give the matched node sets; specificity and !important order them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    // html0 head1 body2 div3 p4 t5 p6 t7 span8 t9 ul10 li11 li12 li13
    const page = "<!doctype html><div class=\"a b\" id=main><p>x</p><p title=\"hi there\">y</p><span>z</span></div><ul><li></li><li></li><li></li></ul>";
    const sheet =
        \\div > p { color: c1 }
        \\.a p + p { color: c2 }
        \\#main span { color: c3 }
        \\li:nth-child(2n+1) { color: c4 }
        \\li:not(:first-child):last-child { color: c5 !important }
        \\li:last-child { color: c6 }
        \\[title~=there] { gap: 1px }
        \\ul:has(li) { color: c7 }
        \\p:hover { color: c8 }
    ;
    const doc, const c, const k = testRun(arena.allocator(), &ds, page, sheet);
    try std.testing.expectEqual(0, ds.errors);
    var buf: [16]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{4}, colored(&doc, &c, &k, "c1", &buf));
    try std.testing.expectEqualSlices(u32, &.{6}, colored(&doc, &c, &k, "c2", &buf));
    try std.testing.expectEqualSlices(u32, &.{8}, colored(&doc, &c, &k, "c3", &buf));
    try std.testing.expectEqualSlices(u32, &.{11}, colored(&doc, &c, &k, "c4", &buf));
    try std.testing.expectEqualSlices(u32, &.{13}, colored(&doc, &c, &k, "c5", &buf));
    try std.testing.expectEqualSlices(u32, &.{10}, colored(&doc, &c, &k, "c7", &buf));
    try std.testing.expect(k.get(6, .@"row-gap").decl != none);
    // `p:hover` is a run-time rule for both paragraphs, not part of the static result.
    try std.testing.expectEqual(2, k.dynamic.items.len);
}

test "cascade: shorthands and longhands in source order; custom properties" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    const doc, const c, const k = testRun(arena.allocator(), &ds, "<!doctype html><p>x</p>", "p { padding-left: 1px; padding: 2px; --x: 3px } p { padding-top: 4px }");
    _ = doc;
    const left = k.get(3, .@"padding-left");
    try std.testing.expectEqualStrings("padding", c.decls.items(.name)[left.decl]);
    try std.testing.expectEqualStrings("padding-top", c.decls.items(.name)[k.get(3, .@"padding-top").decl]);
    try std.testing.expect(k.custom(3, "--x") != null);
}
