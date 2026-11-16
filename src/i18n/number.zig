//! Number formatting: decimal numbers with the locale's digits, decimal separator, digit grouping
//! and minus sign. Symbols are those of CLDR's default numbering system for each locale, checked
//! against CLDR 49 by `zig build i18n-cldr` (src/i18n/cldr.zig). Numbers are fixed point, `value / 10^frac_digits`, so formatting needs no
//! float printing and the visible fraction digits are exactly what the plural rules count.

const std = @import("std");
const plural = @import("plural.zig");

pub const Symbols = struct {
    decimal: []const u8,
    group: []const u8,
    minus: []const u8,
    /// CLDR minimumGroupingDigits: 2 means 1000 stays ungrouped and 10 000 is grouped.
    min_grouping: u8 = 1,
    digits: [10][]const u8 = .{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" },
};

pub fn symbols(locale: plural.Locale) Symbols {
    return switch (locale) {
        .en, .ja, .pseudo => .{ .decimal = ".", .group = ",", .minus = "-" },
        .de => .{ .decimal = ",", .group = ".", .minus = "-" },
        .fr => .{ .decimal = ",", .group = "\u{202f}", .minus = "-" },
        .ru => .{ .decimal = ",", .group = "\u{a0}", .minus = "-" },
        .pl => .{ .decimal = ",", .group = "\u{a0}", .minus = "-", .min_grouping = 2 },
        // CLDR's default numbering system for "ar" is latn; the minus carries a left-to-right mark.
        .ar => .{ .decimal = ".", .group = ",", .minus = "\u{200e}-" },
    };
}

/// Writes `value / 10^frac_digits` into `out` with `frac_digits` digits after the separator and
/// returns the written part: `format(buf, .de, -123456, 2)` is "-1.234,56".
pub fn format(out: []u8, locale: plural.Locale, value: i64, frac_digits: u8) error{NoSpaceLeft}![]u8 {
    std.debug.assert(frac_digits < 20);
    const s = symbols(locale);
    var digits: [20]u8 = undefined; // u64 has at most 20 decimal digits
    var mag = @abs(value);
    var len: usize = 0;
    while (len == 0 or mag != 0 or len <= frac_digits) : (len += 1) {
        digits[digits.len - 1 - len] = @intCast(mag % 10);
        mag /= 10;
    }
    const ds = digits[digits.len - len ..];
    const int_digits = len - frac_digits;
    const grouped = int_digits >= 3 + @as(usize, s.min_grouping);

    var n: usize = 0;
    if (value < 0) try put(out, &n, s.minus);
    for (ds, 0..) |d, k| {
        if (k == int_digits) try put(out, &n, s.decimal);
        if (grouped and k != 0 and k < int_digits and (int_digits - k) % 3 == 0) try put(out, &n, s.group);
        try put(out, &n, s.digits[d]);
    }
    return out[0..n];
}

/// The plural operands of `value / 10^frac_digits`, for `Catalogue.plural`.
pub fn operands(value: i64, frac_digits: u8) plural.Operands {
    std.debug.assert(frac_digits < 20);
    const scale = std.math.powi(u64, 10, frac_digits) catch unreachable;
    const mag = @abs(value);
    return .{ .i = mag / scale, .v = frac_digits, .f = mag % scale };
}

fn put(out: []u8, n: *usize, bytes: []const u8) error{NoSpaceLeft}!void {
    if (out.len - n.* < bytes.len) return error.NoSpaceLeft;
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}

const testing = std.testing;

fn expectFormat(want: []const u8, locale: plural.Locale, value: i64, frac_digits: u8) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(want, try format(&buf, locale, value, frac_digits));
}

test "separators, grouping and minus per locale" {
    try expectFormat("1,234,567.89", .en, 123456789, 2);
    try expectFormat("-1.234,56", .de, -123456, 2);
    try expectFormat("1\u{202f}234,5", .fr, 12345, 1);
    try expectFormat("12\u{a0}345", .ru, 12345, 0);
    try expectFormat("1234", .pl, 1234, 0); // minimumGroupingDigits 2
    try expectFormat("12\u{a0}345", .pl, 12345, 0);
    try expectFormat("1,234", .ja, 1234, 0);
    try expectFormat("\u{200e}-1,234.5", .ar, -12345, 1);
}

test "small values, padding of the fraction and extremes" {
    try expectFormat("0", .en, 0, 0);
    try expectFormat("0.05", .en, 5, 2);
    try expectFormat("-0.5", .en, -5, 1);
    try expectFormat("999", .en, 999, 0);
    try expectFormat("-9,223,372,036,854,775,808", .en, std.math.minInt(i64), 0);
    var buf: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, format(&buf, .en, 12345, 0));
}

test "operands feed the plural rules" {
    try testing.expectEqual(plural.Operands{ .i = 1, .v = 2, .f = 50 }, operands(150, 2));
    try testing.expectEqual(plural.Operands{ .i = 3, .v = 0, .f = 0 }, operands(-3, 0));
    try testing.expectEqual(plural.Category.other, plural.category(.en, operands(10, 1)));
    try testing.expectEqual(plural.Category.one, plural.category(.en, operands(1, 0)));
}
