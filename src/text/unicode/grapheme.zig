//! Extended grapheme cluster boundaries (UAX #29, section 3.1.1, Unicode 16.0.0). Tier 0.
//!
//! Two levels, so a caller that already has code points need not have UTF-8:
//! `State.boundary` decides one position from the previous code point's state, and
//! `Graphemes` walks UTF-8 bytes with it. Neither allocates; the iterator holds two offsets.

const std = @import("std");
const property = @import("property.zig");
const utf8 = @import("utf8.zig");

const Grapheme = property.Grapheme;

/// What the rules need to know about the text before a position.
pub const State = struct {
    prev: Grapheme,
    /// The run of Regional_Indicator ending at `prev` has odd length (GB12, GB13).
    ri_odd: bool,
    /// `prev` ends `ExtPict Extend*` (GB11).
    pict: bool,
    /// `prev` is a ZWJ that follows `ExtPict Extend*` (GB11).
    pict_zwj: bool,
    /// `prev` ends `Consonant [Extend Linker]*`, and `linked` if a Linker is among them (GB9c).
    consonant: bool,
    linked: bool,

    /// The state after the first code point of a text.
    pub fn start(first: Grapheme) State {
        var s: State = undefined;
        s.pict = false;
        s.ri_odd = false;
        s.consonant = false;
        s.linked = false;
        s.advance(first);
        return s;
    }

    /// Is there a boundary between `s.prev` and `cur`? Advances the state to `cur` either way.
    pub fn boundary(s: *State, cur: Grapheme) bool {
        const p = s.prev.gcb;
        const c = cur.gcb;
        const brk = if (p == .CR and c == .LF)
            false // GB3
        else if (p == .Control or p == .CR or p == .LF or c == .Control or c == .CR or c == .LF)
            true // GB4, GB5
        else if (p == .L and (c == .L or c == .V or c == .LV or c == .LVT))
            false // GB6
        else if ((p == .LV or p == .V) and (c == .V or c == .T))
            false // GB7
        else if ((p == .LVT or p == .T) and c == .T)
            false // GB8
        else if (c == .Extend or c == .ZWJ or c == .SpacingMark or p == .Prepend)
            false // GB9, GB9a, GB9b
        else if (cur.incb == .Consonant and s.linked)
            false // GB9c
        else if (s.pict_zwj and cur.ext_pict)
            false // GB11
        else if (p == .Regional_Indicator and c == .Regional_Indicator and s.ri_odd)
            false // GB12, GB13
        else
            true; // GB999
        s.advance(cur);
        return brk;
    }

    fn advance(s: *State, cur: Grapheme) void {
        s.ri_odd = cur.gcb == .Regional_Indicator and !s.ri_odd;
        s.pict_zwj = cur.gcb == .ZWJ and s.pict;
        s.pict = cur.ext_pict or (cur.gcb == .Extend and s.pict);
        const run = s.consonant and (cur.incb == .Extend or cur.incb == .Linker);
        s.linked = run and (s.linked or cur.incb == .Linker);
        s.consonant = cur.incb == .Consonant or run;
        s.prev = cur;
    }
};

/// Grapheme clusters of UTF-8 text. `next` returns the end offset of the next cluster; the
/// cluster starts where the previous one ended (0 first).
pub const Graphemes = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *Graphemes) ?usize {
        if (it.pos >= it.text.len) return null;
        const first = utf8.decode(it.text, it.pos);
        var s = State.start(property.grapheme(first.cp));
        var i = it.pos + first.len;
        while (i < it.text.len) {
            const d = utf8.decode(it.text, i);
            if (s.boundary(property.grapheme(d.cp))) break;
            i += d.len;
        }
        it.pos = i;
        return i;
    }
};

test Graphemes {
    // e + combining acute, a flag (two regional indicators), CR LF, a family emoji (ZWJ sequence).
    const text = "e\u{301}\u{1F1E9}\u{1F1EA}\r\n\u{1F468}\u{200D}\u{1F469}x";
    var it = Graphemes{ .text = text };
    var ends: [8]usize = undefined;
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) ends[n] = e;
    try std.testing.expectEqualSlices(usize, &.{ 3, 11, 13, 24, 25 }, ends[0..n]);
}
