//! Line break opportunities (UAX #14, Unicode 16.0.0, default rules without tailoring). Tier 0.
//!
//! `State.boundary` decides one position from the text before it, the code point after it and
//! the two code points after that which rule LB9 keeps (LB15b, LB15c, LB19a, LB25 and LB28a look
//! ahead). `LineBreaks` walks UTF-8 bytes with it. Neither allocates.

const std = @import("std");
const property = @import("property.zig");
const utf8 = @import("utf8.zig");

const Lb = property.Lb;

/// One code point as the rules see it: its Line row with the class resolved by LB1.
pub const Item = struct {
    p: property.Line,
    cp: u21,

    pub fn of(cp: u21) Item {
        var p = property.line(cp);
        p.lb = switch (p.lb) {
            .AI, .SG, .XX => .AL,
            .SA => if (p.mark) .CM else .AL,
            .CJ => .NS,
            else => p.lb,
        };
        return .{ .p = p, .cp = cp };
    }

    fn combining(it: Item) bool {
        return it.p.lb == .CM or it.p.lb == .ZWJ;
    }
    /// AK, AS or U+25CC DOTTED CIRCLE (LB28a).
    fn aksara(it: Item) bool {
        return it.p.lb == .AK or it.p.lb == .AS or it.cp == 0x25CC;
    }
};

pub const Break = enum { none, allowed, mandatory };

fn in(c: Lb, comptime set: []const Lb) bool {
    inline for (set) |s| if (c == s) return true;
    return false;
}

/// What the rules need to know about the text before a position.
pub const State = struct {
    /// The code point before the position, as it is (LB8a).
    raw: Lb,
    /// The last two code points after LB9 and LB10; `prev2` is null at the start of text.
    prev: Item,
    prev2: ?Item = null,
    zw_sp: bool = false, // ZW SP*          (LB8)
    op_sp: bool = false, // OP SP*          (LB14)
    qu_sp: bool = false, // (sot|...) [Pi&QU] SP* (LB15a)
    cl_sp: bool = false, // (CL|CP) SP*     (LB16)
    b2_sp: bool = false, // B2 SP*          (LB17)
    hyphen: bool = false, // (sot|BK|CR|LF|NL|SP|ZW|CB|GL) (HY|U+2010) (LB20a)
    nu: bool = false, // NU (SY|IS)*        (LB25)
    nu_close: bool = false, // NU (SY|IS)* (CL|CP) (LB25)
    ri_odd: bool = false, // odd run of RI  (LB30a)

    pub fn start(first: Item) State {
        var s: State = .{ .raw = first.p.lb, .prev = undefined };
        s.keep(if (first.combining()) .of('A') else first, null);
        return s;
    }

    /// The break opportunity between the text so far and `cur`; `next` and `next2` are the
    /// following code points that are not CM or ZWJ (null past the end). Advances to `cur`.
    pub fn boundary(s: *State, cur_in: Item, next: ?Item, next2: ?Item) Break {
        const p = s.prev.p.lb;
        const raw = s.raw;
        s.raw = cur_in.p.lb;
        // LB4 to LB8a decide before combining marks are folded.
        if (p == .BK) return s.keepRet(cur_in, .mandatory);
        if (p == .CR and cur_in.p.lb == .LF) return s.keepRet(cur_in, .none);
        if (p == .CR or p == .LF or p == .NL) return s.keepRet(cur_in, .mandatory);
        if (in(cur_in.p.lb, &.{ .BK, .CR, .LF, .NL, .SP, .ZW })) return s.keepRet(cur_in, .none); // LB6, LB7
        if (s.zw_sp) return s.keepRet(cur_in, .allowed); // LB8
        // LB9: X CM* is X, unless X is SP or ZW (LB8 has taken ZW SP*); the state stays at X.
        if (cur_in.combining() and p != .SP and p != .ZW) return .none;
        if (raw == .ZWJ) return s.keepRet(cur_in, .none); // LB8a
        const cur: Item = if (cur_in.combining()) .of('A') else cur_in; // LB10
        const c = cur.p.lb;
        const prev = s.prev;
        const ea = cur.p.east_asian;
        const brk: bool = blk: {
            if (c == .WJ or p == .WJ) break :blk false; // LB11
            if (p == .GL) break :blk false; // LB12
            if (c == .GL and !in(p, &.{ .SP, .BA, .HY })) break :blk false; // LB12a
            if (in(c, &.{ .CL, .CP, .EX, .SY })) break :blk false; // LB13
            if (s.op_sp) break :blk false; // LB14
            if (s.qu_sp) break :blk false; // LB15a
            if (c == .QU and cur.p.pf and (next == null or in(next.?.p.lb, &.{ .SP, .GL, .WJ, .CL, .QU, .CP, .EX, .IS, .SY, .BK, .CR, .LF, .NL, .ZW }))) break :blk false; // LB15b
            if (p == .SP and c == .IS and next != null and next.?.p.lb == .NU) break :blk true; // LB15c
            if (c == .IS) break :blk false; // LB15d
            if (s.cl_sp and c == .NS) break :blk false; // LB16
            if (s.b2_sp and c == .B2) break :blk false; // LB17
            if (p == .SP) break :blk true; // LB18
            if (c == .QU and !cur.p.pi) break :blk false; // LB19
            if (p == .QU and !prev.p.pf) break :blk false;
            if (c == .QU and !prev.p.east_asian) break :blk false; // LB19a
            if (c == .QU and (next == null or !next.?.p.east_asian)) break :blk false;
            if (p == .QU and !ea) break :blk false;
            if (p == .QU and (s.prev2 == null or !s.prev2.?.p.east_asian)) break :blk false;
            if (c == .CB or p == .CB) break :blk true; // LB20
            if (s.hyphen and c == .AL) break :blk false; // LB20a
            if (in(c, &.{ .BA, .HY, .NS }) or p == .BB) break :blk false; // LB21
            if (s.prev2 != null and s.prev2.?.p.lb == .HL and (p == .HY or (p == .BA and !prev.p.east_asian)) and c != .HL) break :blk false; // LB21a
            if (p == .SY and c == .HL) break :blk false; // LB21b
            if (c == .IN) break :blk false; // LB22
            if ((in(p, &.{ .AL, .HL }) and c == .NU) or (p == .NU and in(c, &.{ .AL, .HL }))) break :blk false; // LB23
            if ((p == .PR and in(c, &.{ .ID, .EB, .EM })) or (in(p, &.{ .ID, .EB, .EM }) and c == .PO)) break :blk false; // LB23a
            if ((in(p, &.{ .PR, .PO }) and in(c, &.{ .AL, .HL })) or (in(p, &.{ .AL, .HL }) and in(c, &.{ .PR, .PO }))) break :blk false; // LB24
            // LB25
            if ((s.nu_close or s.nu) and in(c, &.{ .PO, .PR })) break :blk false;
            if (in(p, &.{ .PO, .PR }) and c == .OP and next != null and (next.?.p.lb == .NU or
                (next.?.p.lb == .IS and next2 != null and next2.?.p.lb == .NU))) break :blk false;
            if (in(p, &.{ .PO, .PR, .HY, .IS }) and c == .NU) break :blk false;
            if (s.nu and c == .NU) break :blk false;
            // LB26, LB27
            if (p == .JL and in(c, &.{ .JL, .JV, .H2, .H3 })) break :blk false;
            if (in(p, &.{ .JV, .H2 }) and in(c, &.{ .JV, .JT })) break :blk false;
            if (in(p, &.{ .JT, .H3 }) and c == .JT) break :blk false;
            if ((in(p, &.{ .JL, .JV, .JT, .H2, .H3 }) and c == .PO) or (p == .PR and in(c, &.{ .JL, .JV, .JT, .H2, .H3 }))) break :blk false;
            if (in(p, &.{ .AL, .HL }) and in(c, &.{ .AL, .HL })) break :blk false; // LB28
            // LB28a
            if (p == .AP and cur.aksara()) break :blk false;
            if (prev.aksara() and in(c, &.{ .VF, .VI })) break :blk false;
            if (p == .VI and s.prev2 != null and s.prev2.?.aksara() and (c == .AK or cur.cp == 0x25CC)) break :blk false;
            if (prev.aksara() and cur.aksara() and next != null and next.?.p.lb == .VF) break :blk false;
            if (p == .IS and in(c, &.{ .AL, .HL })) break :blk false; // LB29
            if (in(p, &.{ .AL, .HL, .NU }) and c == .OP and !ea) break :blk false; // LB30
            if (p == .CP and !prev.p.east_asian and in(c, &.{ .AL, .HL, .NU })) break :blk false;
            if (p == .RI and c == .RI and s.ri_odd) break :blk false; // LB30a
            if (c == .EM and (p == .EB or prev.p.pict_cn)) break :blk false; // LB30b
            break :blk true; // LB31
        };
        return s.keepRet(cur, if (brk) .allowed else .none);
    }

    fn keepRet(s: *State, cur: Item, b: Break) Break {
        // A combining mark not folded by LB9 (after BK, SP, ZW, ...) is AL by LB10.
        s.keep(if (cur.combining()) .of('A') else cur, s.prev);
        return b;
    }

    fn keep(s: *State, cur: Item, before: ?Item) void {
        const c = cur.p.lb;
        const sp = c == .SP;
        const p: ?Lb = if (before) |b| b.p.lb else null;
        s.zw_sp = c == .ZW or (sp and s.zw_sp);
        s.op_sp = c == .OP or (sp and s.op_sp);
        s.qu_sp = (c == .QU and cur.p.pi and (p == null or in(p.?, &.{ .BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW }))) or (sp and s.qu_sp);
        s.cl_sp = c == .CL or c == .CP or (sp and s.cl_sp);
        s.b2_sp = c == .B2 or (sp and s.b2_sp);
        s.hyphen = (c == .HY or cur.cp == 0x2010) and (p == null or in(p.?, &.{ .BK, .CR, .LF, .NL, .SP, .ZW, .CB, .GL }));
        s.nu_close = s.nu and (c == .CL or c == .CP);
        s.nu = c == .NU or (s.nu and (c == .SY or c == .IS));
        s.ri_odd = c == .RI and !(s.ri_odd and p == .RI);
        s.prev2 = before;
        s.prev = cur;
    }
};

/// Line break opportunities of UTF-8 text. `next` returns the offset of the next opportunity
/// and whether the break is mandatory; the last one is at the end of text (LB3).
pub const LineBreaks = struct {
    text: []const u8,
    /// Offset after the last code point folded into `state`.
    scan: usize = 0,
    state: State = undefined,

    pub const Opportunity = struct { pos: usize, mandatory: bool };

    pub fn next(it: *LineBreaks) ?Opportunity {
        const t = it.text;
        if (it.scan > t.len or t.len == 0) return null;
        if (it.scan == 0) {
            const first = utf8.decode(t, 0);
            it.state = .start(.of(first.cp));
            it.scan = first.len;
        }
        while (it.scan < t.len) {
            const d = utf8.decode(t, it.scan);
            const at = it.scan;
            it.scan += d.len;
            var after = it.scan;
            const n1 = kept(t, &after);
            const n2 = if (n1 != null) kept(t, &after) else null;
            const b = it.state.boundary(.of(d.cp), n1, n2);
            if (b != .none) return .{ .pos = at, .mandatory = b == .mandatory };
        }
        it.scan = t.len + 1;
        return .{ .pos = t.len, .mandatory = true };
    }

    /// The next code point at or after `i.*` that is not CM or ZWJ; `i.*` moves past it.
    fn kept(t: []const u8, i: *usize) ?Item {
        while (i.* < t.len) {
            const d = utf8.decode(t, i.*);
            i.* += d.len;
            const item: Item = .of(d.cp);
            if (!item.combining()) return item;
        }
        return null;
    }
};

test LineBreaks {
    const text = "Hello, world-wide (web).\nNext";
    var it = LineBreaks{ .text = text };
    var got: [8]LineBreaks.Opportunity = undefined;
    var n: usize = 0;
    while (it.next()) |o| : (n += 1) got[n] = o;
    const want = [_]LineBreaks.Opportunity{
        .{ .pos = 7, .mandatory = false }, // after "Hello, "
        .{ .pos = 13, .mandatory = false }, // after "world-"
        .{ .pos = 18, .mandatory = false }, // after "wide "
        .{ .pos = 25, .mandatory = true }, // after the newline
        .{ .pos = 29, .mandatory = true }, // end of text
    };
    try std.testing.expectEqualSlices(LineBreaks.Opportunity, &want, got[0..n]);
}
