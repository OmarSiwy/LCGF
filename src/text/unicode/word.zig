//! Word boundaries (UAX #29, section 4.1.1, Unicode 16.0.0). Tier 0.
//!
//! `State.boundary` decides one position from the text before it, the code point after it and
//! the next code point that rule WB4 does not ignore (WB6, WB7b and WB12 look one further).
//! `Words` walks UTF-8 bytes with it. Neither allocates.

const std = @import("std");
const property = @import("property.zig");
const utf8 = @import("utf8.zig");

const Wb = property.Wb;
const Word = property.Word;

fn ignored(c: Wb) bool {
    return c == .Extend or c == .Format or c == .ZWJ;
}
fn ahletter(c: Wb) bool {
    return c == .ALetter or c == .Hebrew_Letter;
}
fn midNumLetQ(c: Wb) bool {
    return c == .MidNumLet or c == .Single_Quote;
}
fn newline(c: Wb) bool {
    return c == .Newline or c == .CR or c == .LF;
}

/// What the rules need to know about the text before a position.
pub const State = struct {
    /// The code point just before the position, as it is (WB3 to WB3d).
    raw: Word,
    /// The last two code points that WB4 keeps, `e1` nearest (WB5 to WB16).
    e1: Wb,
    e2: Wb = .Other,
    /// The run of kept Regional_Indicator ending at `e1` has odd length (WB15, WB16).
    ri_odd: bool,

    pub fn start(first: Word) State {
        return .{ .raw = first, .e1 = first.wb, .ri_odd = first.wb == .Regional_Indicator };
    }

    /// Is there a boundary between the text so far and `cur`? `next` is the first code point
    /// after `cur` that is not Extend, Format or ZWJ (`.Other` at the end of text). Advances the
    /// state to `cur` either way.
    pub fn boundary(s: *State, cur: Word, next: Wb) bool {
        const r = s.raw.wb;
        const c = cur.wb;
        const e1 = s.e1;
        const e2 = s.e2;
        const brk = if (r == .CR and c == .LF)
            false // WB3
        else if (newline(r) or newline(c))
            true // WB3a, WB3b
        else if (r == .ZWJ and cur.ext_pict)
            false // WB3c
        else if (r == .WSegSpace and c == .WSegSpace)
            false // WB3d
        else if (ignored(c))
            false // WB4
        else if (ahletter(e1) and ahletter(c))
            false // WB5
        else if (ahletter(e1) and (c == .MidLetter or midNumLetQ(c)) and ahletter(next))
            false // WB6
        else if (ahletter(e2) and (e1 == .MidLetter or midNumLetQ(e1)) and ahletter(c))
            false // WB7
        else if (e1 == .Hebrew_Letter and c == .Single_Quote)
            false // WB7a
        else if (e1 == .Hebrew_Letter and c == .Double_Quote and next == .Hebrew_Letter)
            false // WB7b
        else if (e2 == .Hebrew_Letter and e1 == .Double_Quote and c == .Hebrew_Letter)
            false // WB7c
        else if ((e1 == .Numeric or ahletter(e1)) and c == .Numeric)
            false // WB8, WB9
        else if (e1 == .Numeric and ahletter(c))
            false // WB10
        else if (e2 == .Numeric and (e1 == .MidNum or midNumLetQ(e1)) and c == .Numeric)
            false // WB11
        else if (e1 == .Numeric and (c == .MidNum or midNumLetQ(c)) and next == .Numeric)
            false // WB12
        else if (e1 == .Katakana and c == .Katakana)
            false // WB13
        else if ((ahletter(e1) or e1 == .Numeric or e1 == .Katakana or e1 == .ExtendNumLet) and c == .ExtendNumLet)
            false // WB13a
        else if (e1 == .ExtendNumLet and (ahletter(c) or c == .Numeric or c == .Katakana))
            false // WB13b
        else if (e1 == .Regional_Indicator and c == .Regional_Indicator and s.ri_odd)
            false // WB15, WB16
        else
            true; // WB999
        // WB4: Extend, Format and ZWJ join the code point before them, unless that is a newline.
        if (!(ignored(c) and !newline(r) and !newline(e1))) {
            s.ri_odd = c == .Regional_Indicator and !(e1 == .Regional_Indicator and s.ri_odd);
            s.e2 = e1;
            s.e1 = c;
        }
        s.raw = cur;
        return brk;
    }
};

/// Word segments of UTF-8 text. `next` returns the end offset of the next segment; the segment
/// starts where the previous one ended (0 first).
pub const Words = struct {
    text: []const u8,
    pos: usize = 0,
    /// Offset after the last code point folded into `state`.
    scan: usize = 0,
    state: State = undefined,

    pub fn next(it: *Words) ?usize {
        const t = it.text;
        if (it.pos >= t.len) return null;
        if (it.scan == 0) {
            const first = utf8.decode(t, 0);
            it.state = .start(property.word(first.cp));
            it.scan = first.len;
        }
        while (it.scan < t.len) {
            const d = utf8.decode(t, it.scan);
            const at = it.scan;
            it.scan += d.len;
            if (it.state.boundary(property.word(d.cp), nextKept(t, it.scan))) {
                it.pos = at;
                return at;
            }
        }
        it.pos = t.len;
        return t.len;
    }

    fn nextKept(t: []const u8, from: usize) Wb {
        var i = from;
        while (i < t.len) {
            const d = utf8.decode(t, i);
            const c = property.word(d.cp).wb;
            if (!ignored(c)) return c;
            i += d.len;
        }
        return .Other;
    }
};

test Words {
    const text = "Can't stop 3.14, e.g.\u{301} 日本";
    var it = Words{ .text = text };
    var start: usize = 0;
    var words: [16][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) {
        words[n] = text[start..e];
        start = e;
    }
    const want = [_][]const u8{ "Can't", " ", "stop", " ", "3.14", ",", " ", "e.g", ".\u{301}", " ", "日", "本" };
    try std.testing.expectEqual(want.len, n);
    for (want, words[0..n]) |a, b| try std.testing.expectEqualStrings(a, b);
}
