//! Script itemisation: split UTF-8 text into runs of one script, the unit a shaper takes.
//! Tier 0.
//!
//! Common and Inherited characters (spaces, digits, punctuation, combining marks) join the run
//! around them: the run before, or at the start of text the first real script after them. A
//! closing bracket takes the script of its opening bracket (UAX #24 section 5.2, as HarfBuzz and
//! ICU do it), so "abc (αβγ) def" is Latin, Greek, Latin with both brackets Latin.
//! Script_Extensions is not used: a character with several scripts counts as its Script value.

const std = @import("std");
const property = @import("property.zig");
const utf8 = @import("utf8.zig");

const Script = property.Script;

pub const Run = struct { end: usize, script: Script };

pub const Scripts = struct {
    text: []const u8,
    pos: usize = 0,
    /// Open brackets not yet closed, with the script of the run they opened in (null while
    /// that run has seen only Common characters). Deeper nesting than this is not tracked.
    open: [32]Open = undefined,
    depth: usize = 0,

    const Open = struct { want: u21, script: ?Script };

    /// The next run; it starts where the previous one ended (0 first). A text of only Common
    /// characters is one Common run.
    pub fn next(it: *Scripts) ?Run {
        const t = it.text;
        if (it.pos >= t.len) return null;
        var cur: ?Script = null;
        var i = it.pos;
        while (i < t.len) {
            const d = utf8.decode(t, i);
            const s = property.script(d.cp);
            const b = property.bracket(d.cp);
            var eff: ?Script = if (s == .Common or s == .Inherited) null else s;
            var match: ?usize = null;
            if (b.kind == .close) {
                const want = canonical(d.cp);
                var k = it.depth;
                while (k > 0) {
                    k -= 1;
                    if (it.open[k].want == want) {
                        match = k;
                        if (it.open[k].script) |os| eff = os;
                        break;
                    }
                }
            }
            if (eff != null and cur != null and eff.? != cur.?) break;
            if (cur == null and eff != null) {
                cur = eff;
                for (it.open[0..it.depth]) |*o| {
                    if (o.script == null) o.script = cur;
                }
            }
            if (match) |k| it.depth = k;
            if (b.kind == .open and it.depth < it.open.len) {
                it.open[it.depth] = .{ .want = canonical(b.pair), .script = cur };
                it.depth += 1;
            }
            i += d.len;
        }
        it.pos = i;
        return .{ .end = i, .script = cur orelse .Common };
    }
};

fn canonical(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

test Scripts {
    const text = "12 abc (αβγ) def, Привет!";
    var it = Scripts{ .text = text };
    var got: [8]Run = undefined;
    var n: usize = 0;
    while (it.next()) |r| : (n += 1) got[n] = r;
    const greek = std.mem.indexOf(u8, text, "α").?;
    const close = std.mem.indexOf(u8, text, ")").?;
    const cyr = std.mem.indexOf(u8, text, "П").?;
    try std.testing.expectEqualSlices(Run, &.{
        .{ .end = greek, .script = .Latin },
        .{ .end = close, .script = .Greek },
        .{ .end = cyr, .script = .Latin },
        .{ .end = text.len, .script = .Cyrillic },
    }, got[0..n]);
}
