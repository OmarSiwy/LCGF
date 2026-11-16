//! Pseudo-localisation, a test mode for finding UI that is not ready for translation: every ASCII
//! letter gets an accent (text that bypassed the catalogue stays plain and stands out), the text
//! grows by about 40% (German and Finnish run that much longer than English, so clipping shows)
//! and is bracketed (a missing "]" means it was cut off). Placeholders and escaped braces are kept,
//! so the pseudo catalogue passes the bundle check and every `fill` call works unchanged.
//! Add `pseudo.catalogue(Key, &reference)` to a bundle and `select(.pseudo)` to turn it on.

const std = @import("std");
const plural = @import("plural.zig");
const catalogues = @import("catalogue.zig");

const accented_upper = [26][]const u8{ "Å", "Ɓ", "Ç", "Ð", "É", "Ƒ", "Ĝ", "Ĥ", "Î", "Ĵ", "Ķ", "Ļ", "Ṁ", "Ñ", "Ö", "Þ", "Ǫ", "Ŕ", "Š", "Ŧ", "Û", "Ṽ", "Ŵ", "Ẋ", "Ý", "Ž" };
const accented_lower = [26][]const u8{ "å", "ƀ", "ç", "ð", "é", "ƒ", "ĝ", "ĥ", "î", "ĵ", "ķ", "ļ", "ṁ", "ñ", "ö", "þ", "ǫ", "ŕ", "š", "ŧ", "û", "ṽ", "ŵ", "ẋ", "ý", "ž" };

/// The most bytes `transform` writes for a template of `len` bytes: three per letter, padding and
/// brackets.
pub fn maxLen(len: usize) usize {
    return 3 * len + (2 * len + 4) / 5 + 3;
}

/// Writes the pseudo-localised form of `template` into `out` and returns the written part:
/// "Hello, {0}!" becomes "[Ĥéļļö, {0}! ~~~~]".
pub fn transform(out: []u8, template: []const u8) error{NoSpaceLeft}![]u8 {
    var n: usize = 0;
    try put(out, &n, "[");
    var visible: usize = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const b = template[i];
        var piece: []const u8 = template[i..][0..1];
        if (b == '{' or b == '}') {
            // `{k}` and the escapes `{{`, `}}` are copied whole.
            const len: usize = if (template[i + 1] == b) 2 else 3;
            piece = template[i..][0..len];
            i += len - 1;
        } else if (std.ascii.isUpper(b)) {
            piece = accented_upper[b - 'A'];
        } else if (std.ascii.isLower(b)) {
            piece = accented_lower[b - 'a'];
        }
        visible += 1;
        try put(out, &n, piece);
    }
    const padding = (2 * visible + 4) / 5;
    if (padding != 0) try put(out, &n, " ");
    for (0..padding) |_| try put(out, &n, "~");
    try put(out, &n, "]");
    return out[0..n];
}

/// The pseudo-localised copy of `reference`, built at comptime, with locale `.pseudo`.
pub fn catalogue(comptime Key: type, comptime reference: *const catalogues.Catalogue(Key)) catalogues.Catalogue(Key) {
    const c = comptime blk: {
        var bytes: usize = 0;
        for (reference.texts) |ts| for (ts) |t| {
            bytes += t.len;
        };
        @setEvalBranchQuota(1000 + 100 * reference.texts.len * 6 + 16 * bytes);
        var c: catalogues.Catalogue(Key) = .{ .locale = .pseudo, .texts = undefined };
        for (reference.texts, 0..) |ts, k| for (ts, 0..) |t, f| {
            var buf: [maxLen(t.len)]u8 = undefined;
            const done = transform(&buf, t) catch unreachable;
            const frozen: [done.len]u8 = done[0..done.len].*;
            c.texts[k][f] = &frozen;
        };
        break :blk c;
    };
    return c;
}

fn put(out: []u8, n: *usize, bytes: []const u8) error{NoSpaceLeft}!void {
    if (out.len - n.* < bytes.len) return error.NoSpaceLeft;
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}

const testing = std.testing;
const bundle = @import("bundle.zig");

test "accents, growth, brackets; placeholders kept" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("[Ĥéļļö, {0}! ~~~~]", try transform(&buf, "Hello, {0}!"));
    try testing.expectEqualStrings("[]", try transform(&buf, ""));
    try testing.expectEqualStrings("[{{ŵ}} ~~]", try transform(&buf, "{{w}}"));
    try testing.expectEqualStrings("[42 ~]", try transform(&buf, "42"));
    const text = "The quick brown fox jumps over the lazy dog {1} {0}";
    const out = try transform(&buf, text);
    try testing.expect(out.len <= maxLen(text.len));
    try testing.expectEqual(try catalogues.placeholders(text), try catalogues.placeholders(out));
    try testing.expectError(error.NoSpaceLeft, transform(buf[0..4], "Hello"));
}

const Msg = enum { greeting, files };
const en: catalogues.Catalogue(Msg) = .init(.en, .{ .greeting = "Hello, {0}!", .files = .{ .one = "{0} file", .other = "{0} files" } });
const xx = catalogue(Msg, &en);

test "a pseudo catalogue joins a bundle and switches on at run time" {
    var b: bundle.Bundle(Msg, &.{ en, xx }) = .{};
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Hello, Ada!", try catalogues.fill(&buf, b.current().text(.greeting), &.{"Ada"}));
    try testing.expect(b.select(.pseudo));
    try testing.expectEqualStrings("[Ĥéļļö, Ada! ~~~~]", try catalogues.fill(&buf, b.current().text(.greeting), &.{"Ada"}));
    try testing.expectEqualStrings("[1 ƒîļé ~~~]", try b.current().formatCount(&buf, .files, 1, 0));
    try testing.expectEqualStrings("[1,234 ƒîļéš ~~~]", try b.current().formatCount(&buf, .files, 1234, 0));
}
