//! Bidirectional levels (UAX #9, Unicode 16.0.0, rules P2 to I2 and L1). Tier 0.
//!
//! One paragraph at a time, over columns the caller owns: the Bidi_Class of each code point in,
//! one level per code point out, and three scratch columns of the same length. Isolating run
//! sequences are not lists: `next[i]` links each character to the next one of its sequence,
//! which is how the W, N and I rules walk them without allocating.

const std = @import("std");
const none = @import("../../core/types.zig").none;
const property = @import("property.zig");

const Class = property.BidiClass;

pub const max_depth = 125;

/// Scratch columns, each at least as long as the paragraph.
pub const Scratch = struct {
    /// The working class of each character (W1 to N2 rewrite it).
    cls: []Class,
    /// The next character of the same isolating run sequence, or `none`.
    next: []u32,
    /// An isolate initiator's matching PDI and back; an opening bracket's closing bracket.
    pair: []u32,
};

/// Bidi_Class of each code point.
pub fn classes(cps: []const u21, out: []Class) void {
    for (cps, out[0..cps.len]) |cp, *c| c.* = property.bidiClass(cp);
}

fn isolate(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}
/// Removed by X9: embeddings, overrides, PDF and BN.
fn removed(c: Class) bool {
    return switch (c) {
        .RLE, .LRE, .RLO, .LRO, .PDF, .BN => true,
        else => false,
    };
}

/// BD9: links each isolate initiator to its matching PDI and back (`none` when unmatched). The
/// open initiators form a stack threaded through `pair` itself, so nesting depth costs nothing.
fn matchIsolates(orig: []const Class, pair: []u32) void {
    var open: u32 = none;
    for (orig, 0..) |c, i| {
        pair[i] = none;
        if (isolate(c)) {
            pair[i] = open;
            open = @intCast(i);
        } else if (c == .PDI and open != none) {
            const j = open;
            open = pair[j];
            pair[j] = @intCast(i);
            pair[i] = j;
        }
    }
    while (open != none) {
        const j = open;
        open = pair[j];
        pair[j] = none;
    }
}

/// P2, P3: the direction of the first strong character in `orig[from..to]`, skipping isolates.
fn firstStrong(orig: []const Class, pair: []const u32, from: usize, to: usize) ?u8 {
    var i = from;
    while (i < to) : (i += 1) switch (orig[i]) {
        .L => return 0,
        .R, .AL => return 1,
        .LRI, .RLI, .FSI => {
            if (pair[i] == none) return null;
            i = pair[i];
        },
        else => {},
    };
    return null;
}

/// P2, P3: the paragraph level from the text (0 when it has no strong character).
pub fn paragraphLevel(orig: []const Class, scratch: Scratch) u8 {
    matchIsolates(orig, scratch.pair);
    return firstStrong(orig, scratch.pair, 0, orig.len) orelse 0;
}

/// A paragraph's base direction: given (HL1), or `auto` from its text (P2, P3). The values
/// are BidiCharacterTest's paragraph directions.
pub const Direction = enum(u8) { ltr = 0, rtl = 1, auto = 2 };

/// The paragraph level for direction `d`.
pub fn baseLevel(orig: []const Class, scratch: Scratch, d: Direction) u8 {
    return if (d == .auto) paragraphLevel(orig, scratch) else @backingInt(d);
}

/// Resolves the embedding level of every character of one paragraph (X1 to I2). Characters
/// removed by X9 get the level of the character before them. `cps` gives the code points for
/// bracket pairs (N0); pass an empty slice when only classes are known. L1 is `lineLevels`.
pub fn resolve(orig: []const Class, cps: []const u21, para: u8, levels: []u8, scratch: Scratch) void {
    const n = orig.len;
    std.debug.assert(levels.len >= n and scratch.cls.len >= n and scratch.next.len >= n and scratch.pair.len >= n);
    std.debug.assert(cps.len == 0 or cps.len == n);
    const cls = scratch.cls;
    const next = scratch.next;
    const pair = scratch.pair;
    matchIsolates(orig, pair);

    // X1 to X8: the directional status stack.
    const Entry = struct { level: u8, override: ?Class, isolate: bool };
    var stack: [max_depth + 2]Entry = undefined;
    stack[0] = .{ .level = para, .override = null, .isolate = false };
    var sp: usize = 1;
    var overflow_isolate: u32 = 0;
    var overflow_embedding: u32 = 0;
    var valid_isolate: u32 = 0;
    for (orig, 0..) |c, i| {
        const top = stack[sp - 1];
        cls[i] = c;
        levels[i] = top.level;
        switch (c) {
            .RLE, .LRE, .RLO, .LRO => {
                const odd = c == .RLE or c == .RLO;
                const level = if (odd) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (level <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    stack[sp] = .{ .level = level, .override = if (c == .RLO) .R else if (c == .LRO) .L else null, .isolate = false };
                    sp += 1;
                } else if (overflow_isolate == 0) overflow_embedding += 1;
                cls[i] = .BN;
            },
            .RLI, .LRI, .FSI => {
                if (top.override) |o| cls[i] = o;
                const rtl = c == .RLI or (c == .FSI and
                    firstStrong(orig, pair, i + 1, if (pair[i] == none) n else pair[i]) == 1);
                const level = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (level <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    valid_isolate += 1;
                    stack[sp] = .{ .level = level, .override = null, .isolate = true };
                    sp += 1;
                } else overflow_isolate += 1;
            },
            .PDI => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embedding = 0;
                    while (!stack[sp - 1].isolate) sp -= 1;
                    sp -= 1;
                    valid_isolate -= 1;
                }
                levels[i] = stack[sp - 1].level;
                if (stack[sp - 1].override) |o| cls[i] = o;
            },
            .PDF => {
                if (overflow_isolate > 0) {} else if (overflow_embedding > 0) {
                    overflow_embedding -= 1;
                } else if (!top.isolate and sp >= 2) sp -= 1;
                cls[i] = .BN;
            },
            .B => levels[i] = para, // X8
            .BN => {},
            else => if (top.override) |o| {
                cls[i] = o;
            },
        }
    }

    // X10, BD13: link each character to the next of its isolating run sequence.
    var last: u32 = none;
    for (0..n) |i| {
        if (removed(orig[i])) continue;
        if (last != none) next[last] = if (levels[last] == levels[i]) @intCast(i) else if (isolate(orig[last])) pair[last] else none;
        last = @intCast(i);
    }
    if (last != none) next[last] = if (isolate(orig[last])) pair[last] else none;

    // Each sequence starts at a level run that does not begin with a matched PDI.
    var before: u8 = para; // level of the last kept character before i
    var prev_level: ?u8 = null;
    for (0..n) |i| {
        if (removed(orig[i])) continue;
        const run_start = prev_level == null or prev_level.? != levels[i];
        if (run_start and !(orig[i] == .PDI and pair[i] != none)) {
            sequence(orig, cps, para, levels, scratch, @intCast(i), before);
        }
        before = levels[i];
        prev_level = levels[i];
    }

    // I1, I2 last: until here `levels` holds embedding levels, which the sequences read.
    // Removed characters take the level before them.
    var level = para;
    for (0..n) |i| {
        const c = cls[i];
        const up: u8 = if (levels[i] & 1 == 0)
            (if (c == .R) 1 else if (c == .AN or c == .EN) 2 else 0)
        else
            (if (c == .L or c == .EN or c == .AN) 1 else 0);
        if (removed(orig[i])) levels[i] = level else {
            levels[i] += up;
            level = levels[i];
        }
    }
}

fn strongOf(c: Class) ?Class {
    return switch (c) {
        .L => .L,
        .R, .EN, .AN => .R,
        else => null,
    };
}
fn neutral(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

/// W1 to N2 on the isolating run sequence that starts at `first`. `before` is the level of the
/// kept character before it in text order (the paragraph level if none).
fn sequence(orig: []const Class, cps: []const u21, para: u8, levels: []const u8, scratch: Scratch, first: u32, before: u8) void {
    const cls = scratch.cls;
    const next = scratch.next;
    const level = levels[first];
    var last = first;
    while (next[last] != none) last = next[last];
    // eos: the level after the sequence, unless it ends with an isolate initiator.
    var after = para;
    if (!isolate(orig[last])) {
        var j = last + 1;
        while (j < orig.len and removed(orig[j])) j += 1;
        if (j < orig.len) after = levels[j];
    }
    const sos: Class = if (@max(level, before) & 1 == 1) .R else .L;
    const eos: Class = if (@max(level, after) & 1 == 1) .R else .L;
    const e: Class = if (level & 1 == 1) .R else .L;

    // W1: NSM takes the class before it (ON after an isolate initiator or PDI).
    var prev = sos;
    var i = first;
    while (i != none) : (i = next[i]) {
        if (cls[i] == .NSM) cls[i] = if (isolate(prev) or prev == .PDI) .ON else prev;
        prev = cls[i];
    }
    // W2: EN after AL is AN. W3: AL is R.
    var strong = sos;
    i = first;
    while (i != none) : (i = next[i]) switch (cls[i]) {
        .L, .R => strong = cls[i],
        .AL => {
            strong = .AL;
            cls[i] = .R;
        },
        .EN => if (strong == .AL) {
            cls[i] = .AN;
        },
        else => {},
    };
    // W4: one separator between two numbers of the same kind joins them.
    prev = sos;
    i = first;
    while (i != none) : (i = next[i]) {
        const nx: Class = if (next[i] != none) cls[next[i]] else eos;
        if (cls[i] == .ES and prev == .EN and nx == .EN) cls[i] = .EN;
        if (cls[i] == .CS and (prev == .EN or prev == .AN) and nx == prev) cls[i] = prev;
        prev = cls[i];
    }
    // W5: ET next to EN is EN.
    prev = sos;
    var ets: u32 = none;
    i = first;
    while (i != none) : (i = next[i]) {
        if (cls[i] == .ET) {
            if (prev == .EN) cls[i] = .EN else if (ets == none) ets = i;
        } else {
            if (cls[i] == .EN) {
                var j = ets;
                while (j != none and j != i) : (j = next[j]) cls[j] = .EN;
            }
            ets = none;
        }
        prev = cls[i];
    }
    // W6: remaining separators and terminators are ON. W7: EN after L is L.
    strong = sos;
    i = first;
    while (i != none) : (i = next[i]) switch (cls[i]) {
        .ES, .ET, .CS => cls[i] = .ON,
        .L, .R => strong = cls[i],
        .EN => if (strong == .L) {
            cls[i] = .L;
        },
        else => {},
    };

    if (cps.len != 0) brackets(orig, cps, scratch, first, sos, e);

    // N1, N2: a run of neutrals between two strong classes of one direction takes it;
    // otherwise the embedding direction.
    var left = sos;
    var run: u32 = none;
    i = first;
    while (true) : (i = next[i]) {
        const c: ?Class = if (i == none) eos else cls[i];
        if (i != none and neutral(c.?)) {
            if (run == none) run = i;
            continue;
        }
        const right = strongOf(c.?) orelse c.?;
        if (run != none) {
            const to: Class = if (left == right) left else e;
            var j = run;
            while (j != i) : (j = next[j]) cls[j] = to;
            run = none;
        }
        left = right;
        if (i == none) break;
    }
}

/// The two code points U+2329, U+232A are canonically equivalent to U+3008, U+3009 (BD16).
fn canonicalBracket(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

/// BD16 and N0 on one isolating run sequence.
fn brackets(orig: []const Class, cps: []const u21, scratch: Scratch, first: u32, sos: Class, e: Class) void {
    const cls = scratch.cls;
    const next = scratch.next;
    const pair = scratch.pair;
    // BD16: pair[opener] = closer, with a stack of 63 as the algorithm specifies.
    const Open = struct { at: u32, want: u21 };
    var stack: [63]Open = undefined;
    var sp: usize = 0;
    var i = first;
    find: while (i != none) : (i = next[i]) {
        if (orig[i] == .ON) pair[i] = none;
        if (cls[i] != .ON) continue;
        const b = property.bracket(cps[i]);
        switch (b.kind) {
            .none => {},
            .open => {
                if (sp == stack.len) break :find;
                stack[sp] = .{ .at = i, .want = canonicalBracket(b.pair) };
                sp += 1;
            },
            .close => {
                const cp = canonicalBracket(cps[i]);
                var k = sp;
                while (k > 0) {
                    k -= 1;
                    if (stack[k].want == cp) {
                        pair[stack[k].at] = i;
                        sp = k;
                        break;
                    }
                }
            },
        }
    }
    while (i != none) : (i = next[i]) {
        if (orig[i] == .ON) pair[i] = none;
    }

    // N0: pairs in order of their opening bracket. `strong` is the last strong class before `i`
    // (EN and AN count as R), including brackets already resolved.
    var strong = sos;
    i = first;
    while (i != none) : (i = next[i]) {
        if (orig[i] == .ON and pair[i] != none and cls[i] == .ON) {
            const close = pair[i];
            var inside_e = false;
            var inside_o = false;
            var j = next[i];
            while (j != close) : (j = next[j]) {
                if (strongOf(cls[j])) |s| {
                    if (s == e) inside_e = true else inside_o = true;
                }
            }
            const to: ?Class = if (inside_e) e else if (inside_o) (if (strong != e) strong else e) else null;
            if (to) |d| {
                cls[i] = d;
                cls[close] = d;
                // NSMs after each bracket follow it (W1 had made them ON).
                inline for (.{ i, close }) |br| {
                    var k = next[br];
                    while (k != none and orig[k] == .NSM) : (k = next[k]) cls[k] = d;
                }
            }
        }
        if (strongOf(cls[i])) |s| strong = s;
    }
}

/// L1 on one line of a resolved paragraph: segment and paragraph separators, and whitespace
/// (with isolate controls and characters removed by X9) before them or at the end of the line,
/// go back to the paragraph level.
pub fn lineLevels(orig: []const Class, levels: []u8, para: u8) void {
    var trailing = true;
    var i = orig.len;
    while (i > 0) {
        i -= 1;
        const c = orig[i];
        if (c == .S or c == .B) {
            levels[i] = para;
            trailing = true;
        } else if (c == .WS or isolate(c) or c == .PDI or removed(c)) {
            if (trailing) levels[i] = para;
        } else trailing = false;
    }
}

fn testResolve(text: []const u21, para: ?u8, want: []const u8) !void {
    var orig: [16]Class = undefined;
    var levels: [16]u8 = undefined;
    var cls: [16]Class = undefined;
    var nx: [16]u32 = undefined;
    var pr: [16]u32 = undefined;
    const s: Scratch = .{ .cls = &cls, .next = &nx, .pair = &pr };
    classes(text, &orig);
    const o = orig[0..text.len];
    const p = para orelse paragraphLevel(o, s);
    resolve(o, text, p, &levels, s);
    lineLevels(o, levels[0..text.len], p);
    try std.testing.expectEqualSlices(u8, want, levels[0..text.len]);
}

test resolve {
    // "ab אב 12": Hebrew letters are 1, the number after them stays with them at 2.
    try testResolve(&.{ 'a', 'b', ' ', 0x5D0, 0x5D1, ' ', '1', '2' }, null, &.{ 0, 0, 0, 1, 1, 1, 2, 2 });
    // An RTL paragraph: the Latin word goes up to 2, the brackets around it follow it (N0).
    try testResolve(&.{ 0x5D0, ' ', '(', 'a', ')' }, 1, &.{ 1, 1, 1, 2, 1 });
}

/// L2: the visual order of a line. `levels` holds one level per row (a character, or a run of
/// characters at one level, such as a shaped run); `order[v]` receives the row shown at visual
/// position `v`, left to right. Rows removed by X9 are the caller's to leave out first.
pub fn reorder(levels: []const u8, order: []u32) void {
    const n = levels.len;
    var high: u8 = 0;
    var low: u8 = 0xff;
    for (levels, order[0..n], 0..) |l, *o, i| {
        o.* = @intCast(i);
        high = @max(high, l);
        low = @min(low, l);
    }
    // The lowest odd level at or above the lowest level: runs below it never reverse.
    const low_odd = low | 1;
    // From the highest level down to the lowest odd one, reverse every run at or above it.
    var level = high;
    while (level >= low_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < n) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < n and levels[order[j]] >= level) j += 1;
            std.mem.reverse(u32, order[i..j]);
            i = j;
        }
    }
}

test reorder {
    var order: [6]u32 = undefined;
    // Two Latin rows, two Hebrew rows, two digits after them: the Hebrew reads right to left
    // and the number inside it left to right.
    reorder(&.{ 0, 0, 1, 1, 2, 2 }, &order);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 3, 2 }, &order);
}
