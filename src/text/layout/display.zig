//! Display-only Unicode 16 casing, width conversion and grapheme masking, with original
//! byte offsets preserved for selections and editing. The source text is never mutated.
//! Explicit caller buffers make expansion (ß -> SS) and hidden graphemes observable.

const std = @import("std");
const data = @import("../unicode/display_data.zig");
const utf8 = @import("../unicode/utf8.zig");
const Words = @import("../unicode/word.zig").Words;
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;
pub const Buffer = @import("whitespace.zig").Buffer;

pub const Casing = enum { none, lower, upper, title, capitalize };
pub const Locale = enum { root, tr, az, lt, nl };
pub const Options = struct {
    casing: Casing = .none,
    locale: Locale = .root,
    /// Unicode narrow decomposition mappings plus ASCII -> fullwidth and space -> U+3000.
    /// This pass preserves scalar order; canonical composition remains a separate choice.
    full_width: bool = false,
    /// One display scalar per extended grapheme. Newlines remain line breaks by default.
    mask: ?u21 = null,
    preserve_breaks: bool = true,
    /// Optional original byte inside one grapheme to reveal (e.g. a password's last input).
    reveal: ?u32 = null,
};

const Mapping = struct { cps: [3]u21, len: u2 = 1 };

pub fn prepare(out: *Buffer, text: []const u8, options: Options) error{ NoSpace, InvalidScalar }![]const u8 {
    out.len = 0;
    if (out.source.len == 0) return error.NoSpace;
    out.source[0] = 0;
    if (options.mask) |mask| {
        if (mask > 0x10ffff or (mask >= 0xd800 and mask <= 0xdfff)) return error.InvalidScalar;
        var clusters: Graphemes = .{ .text = text };
        var start: usize = 0;
        while (clusters.next()) |end| {
            const first = utf8.decode(text, start).cp;
            const hard = first == '\r' or first == '\n' or first == 0x2028 or first == 0x2029;
            const reveal = if (options.reveal) |at| at >= start and at < end else false;
            if (reveal or (hard and options.preserve_breaks)) {
                var i = start;
                while (i < end) {
                    const d = utf8.decode(text, i);
                    try append(out, d.cp, @intCast(i));
                    i += d.len;
                }
            } else try append(out, mask, @intCast(start));
            start = end;
        }
    } else {
        var words: Words = .{ .text = text };
        var word_end = words.next() orelse text.len;
        var initial = true;
        var dutch_j: ?usize = null;
        var i: usize = 0;
        while (i < text.len) {
            if (i >= word_end) {
                word_end = words.next() orelse text.len;
                initial = true;
            }
            const d = utf8.decode(text, i);
            const cased = flags(d.cp) & 1 != 0;
            const mode: ?u2 = switch (options.casing) {
                .none => null,
                .lower => 0,
                .upper => 2,
                .title => if (initial or dutch_j == i) 1 else 0,
                .capitalize => if (initial or dutch_j == i) 1 else null,
            };
            if (initial and cased and options.locale == .nl and (options.casing == .title or options.casing == .capitalize) and (d.cp == 'i' or d.cp == 'I')) {
                const next = i + d.len;
                if (next < word_end and (text[next] == 'j' or text[next] == 'J')) dutch_j = next;
            }
            const mapped = if (mode) |m| casing(text, i, d.cp, m, options.locale) else one(d.cp);
            for (mapped.cps[0..mapped.len]) |cp| try append(out, if (options.full_width) fullWidth(cp) else cp, @intCast(i));
            if (cased) initial = false;
            i += d.len;
        }
    }
    out.source[out.len] = @intCast(text.len);
    return out.bytes[0..out.len];
}

fn append(out: *Buffer, cp: u21, source: u32) error{NoSpace}!void {
    var bytes: [4]u8 = undefined;
    const n: usize = std.unicode.utf8Encode(cp, &bytes) catch unreachable;
    if (out.bytes.len - out.len < n or out.source.len - out.len <= n) return error.NoSpace;
    @memcpy(out.bytes[out.len..][0..n], bytes[0..n]);
    @memset(out.source[out.len..][0..n], source);
    out.len += @intCast(n);
    out.source[out.len] = source;
}

fn one(cp: u21) Mapping {
    return .{ .cps = .{ cp, 0, 0 } };
}

fn rangeValue(table: []const data.Range, cp: u21) u8 {
    var lo: usize = 0;
    var hi = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < table[mid].first) hi = mid else if (cp > table[mid].last) lo = mid + 1 else return table[mid].value;
    }
    return 0;
}
fn flags(cp: u21) u8 {
    return rangeValue(&data.flags, cp);
}
fn combining(cp: u21) u8 {
    return rangeValue(&data.combining, cp);
}

/// UAX #50 orientation: rotated, upright, upright with vertical substitution, or rotated
/// when no vertical substitution is available. Consumers decide whether shaping supplied
/// the vertical alternate; these values alone do not imply that it did.
pub const Vertical = enum(u2) { rotated, upright, transformed_upright, transformed_rotated };
pub fn vertical(cp: u21) Vertical {
    return @fromBackingInt(@intCast(@as(u2, @intCast(rangeValue(&data.vertical, cp)))));
}

fn previous(text: []const u8, at: usize) usize {
    var i = at - 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn casedBefore(text: []const u8, at: usize) bool {
    var i = at;
    while (i > 0) {
        i = previous(text, i);
        const f = flags(utf8.decode(text, i).cp);
        if (f & 2 == 0) return f & 1 != 0;
    }
    return false;
}
fn casedAfter(text: []const u8, at: usize) bool {
    var i = at;
    while (i < text.len) {
        const d = utf8.decode(text, i);
        const f = flags(d.cp);
        if (f & 2 == 0) return f & 1 != 0;
        i += d.len;
    }
    return false;
}

fn beforeDot(text: []const u8, at: usize) bool {
    var i = at;
    while (i < text.len) {
        const d = utf8.decode(text, i);
        if (d.cp == 0x307) return true;
        const c = combining(d.cp);
        if (c == 0 or c == 230) return false;
        i += d.len;
    }
    return false;
}
fn moreAbove(text: []const u8, at: usize) bool {
    var i = at;
    while (i < text.len) {
        const d = utf8.decode(text, i);
        const c = combining(d.cp);
        if (c == 230) return true;
        if (c == 0) return false;
        i += d.len;
    }
    return false;
}
fn afterBase(text: []const u8, at: usize, soft_dotted: bool) bool {
    var i = at;
    while (i > 0) {
        i = previous(text, i);
        const cp = utf8.decode(text, i).cp;
        if (if (soft_dotted) flags(cp) & 4 != 0 else cp == 'I') return true;
        const c = combining(cp);
        if (c == 0 or c == 230) return false;
    }
    return false;
}

fn casing(text: []const u8, at: usize, cp: u21, mode: u2, locale: Locale) Mapping {
    const after = at + utf8.decode(text, at).len;
    if (mode == 0 and cp == 0x3a3 and casedBefore(text, at) and !casedAfter(text, after)) return one(0x3c2);
    if (locale == .tr or locale == .az) {
        if (mode == 0) {
            if (cp == 0x130) return one('i');
            if (cp == 0x307 and afterBase(text, at, false)) return .{ .cps = @splat(0), .len = 0 };
            if (cp == 'I' and !beforeDot(text, after)) return one(0x131);
        } else if (cp == 'i') return one(0x130);
    }
    if (locale == .lt) {
        if (mode != 0 and cp == 0x307 and afterBase(text, at, true)) return .{ .cps = @splat(0), .len = 0 };
        if (mode == 0) {
            if ((cp == 'I' or cp == 'J' or cp == 0x12e) and moreAbove(text, after))
                return .{ .cps = .{ if (cp == 'I') 'i' else if (cp == 'J') 'j' else 0x12f, 0x307, 0 }, .len = 2 };
            if (cp == 0xcc or cp == 0xcd or cp == 0x128)
                return .{ .cps = .{ 'i', 0x307, if (cp == 0xcc) 0x300 else if (cp == 0xcd) 0x301 else 0x303 }, .len = 3 };
        }
    }
    var lo: usize = 0;
    var hi = data.mappings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = data.mappings[mid];
        if (cp < entry.cp) hi = mid else if (cp > entry.cp) lo = mid + 1 else {
            const code = entry.modes[mode];
            if (code == 0) return one(cp);
            const n: u2 = @truncate(code);
            var result: Mapping = .{ .cps = @splat(0), .len = n };
            @memcpy(result.cps[0..n], data.pool[code >> 2 ..][0..n]);
            return result;
        }
    }
    return one(cp);
}

fn fullWidth(cp: u21) u21 {
    if (cp == ' ') return 0x3000;
    if (cp >= '!' and cp <= '~') return cp + 0xfee0;
    var lo: usize = 0;
    var hi = data.wide.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < data.wide[mid].from) hi = mid else if (cp > data.wide[mid].from) lo = mid + 1 else return data.wide[mid].to;
    }
    return cp;
}

test "display casing expands Unicode and preserves original editing offsets" {
    var bytes: [128]u8 = undefined;
    var source: [129]u32 = undefined;
    var out: Buffer = .{ .bytes = &bytes, .source = &source };
    try std.testing.expectEqualStrings("STRASSE ΣΊΣΥΦΟΣ", try prepare(&out, "Straße Σίσυφος", .{ .casing = .upper }));
    try std.testing.expectEqual(4, out.sourceOffset(4));
    try std.testing.expectEqual(4, out.sourceOffset(5));
    try std.testing.expectEqual(6, out.displayOffset(6));
    try std.testing.expectEqualStrings("ος οσα", try prepare(&out, "ΟΣ ΟΣΑ", .{ .casing = .lower }));
    try std.testing.expectEqualStrings("ı i i", try prepare(&out, "I İ I\u{307}", .{ .casing = .lower, .locale = .tr }));
    try std.testing.expectEqualStrings("i\u{307}\u{301}", try prepare(&out, "I\u{301}", .{ .casing = .lower, .locale = .lt }));
    try std.testing.expectEqualStrings("I\u{301}", try prepare(&out, "i\u{307}\u{301}", .{ .casing = .upper, .locale = .lt }));
    try std.testing.expectEqualStrings("IJssel Straße", try prepare(&out, "ijssel STRAßE", .{ .casing = .title, .locale = .nl }));
    try std.testing.expectEqualStrings("Ａ　カ", try prepare(&out, "A ｶ", .{ .full_width = true }));
}

test "display masks whole graphemes and orientation distinguishes vertical alternates" {
    var bytes: [64]u8 = undefined;
    var source: [65]u32 = undefined;
    var out: Buffer = .{ .bytes = &bytes, .source = &source };
    const text = "a\u{301}👨‍👩‍👧\nb";
    try std.testing.expectEqualStrings("••\nb", try prepare(&out, text, .{ .mask = '•', .reveal = text.len - 1 }));
    try std.testing.expectEqual(3, out.sourceOffset(3));
    try std.testing.expectEqual(text.len, out.sourceOffset(out.len));
    try std.testing.expectEqual(Vertical.rotated, vertical('A'));
    try std.testing.expectEqual(Vertical.upright, vertical('漢'));
    try std.testing.expectEqual(Vertical.transformed_rotated, vertical('（'));
    out.bytes = bytes[0..1];
    try std.testing.expectError(error.NoSpace, prepare(&out, "ß", .{ .casing = .upper }));
    try std.testing.expectEqualStrings("S", out.bytes[0..out.len]);
}
