//! Date formatting: Gregorian dates in the locale's CLDR short and long date patterns, with its
//! month names (format context, so Russian and Polish months are genitive) and digits. Patterns
//! use the CLDR letters y, yy, M, MM, MMMM, d, dd and 'quoted literals'; nothing else is needed by
//! the patterns below.

const std = @import("std");
const plural = @import("plural.zig");
const number = @import("number.zig");

pub const Date = struct {
    year: i32,
    month: u8, // 1 to 12
    day: u8, // 1 to 31

    /// The date `days` after 1970-01-01 (negative before it). Howard Hinnant's `civil_from_days`.
    pub fn fromDays(days: i64) Date {
        const z = days + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097; // [0, 146096]
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
        const mp = @divFloor(5 * doy + 2, 153); // March is 0
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m = if (mp < 10) mp + 3 else mp - 9;
        const y = yoe + era * 400 + @intFromBool(m <= 2);
        return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
    }
};

pub const Style = enum { short, long };

pub fn pattern(locale: plural.Locale, style: Style) []const u8 {
    return switch (style) {
        .short => switch (locale) {
            .en, .pseudo => "M/d/yy",
            .de => "dd.MM.yy",
            .fr => "dd/MM/y",
            .ru => "dd.MM.y",
            .pl => "d.MM.y",
            .ja => "y/MM/dd",
            .ar => "d\u{200f}/M\u{200f}/y",
        },
        .long => switch (locale) {
            .en, .pseudo => "MMMM d, y",
            .de => "d. MMMM y",
            .fr, .pl, .ar => "d MMMM y",
            .ru => "d MMMM y\u{202f}'г'.",
            .ja => "y年M月d日",
        },
    };
}

pub fn months(locale: plural.Locale) [12][]const u8 {
    return switch (locale) {
        .en, .pseudo => .{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
        .de => .{ "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" },
        .fr => .{ "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre" },
        .ru => .{ "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря" },
        .pl => .{ "stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca", "lipca", "sierpnia", "września", "października", "listopada", "grudnia" },
        .ja => .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .ar => .{ "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر" },
    };
}

/// Writes `date` in the locale's pattern for `style` and returns the written part. The year must
/// be 1 or later (CLDR writes earlier years with an era, which no pattern here has).
pub fn format(out: []u8, locale: plural.Locale, style: Style, date: Date) error{NoSpaceLeft}![]u8 {
    std.debug.assert(date.year >= 1 and date.month >= 1 and date.month <= 12 and date.day >= 1 and date.day <= 31);
    const p = pattern(locale, style);
    const digits = number.symbols(locale).digits;
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len) {
        const c = p[i];
        var run: usize = 1;
        while (i + run < p.len and p[i + run] == c) run += 1;
        switch (c) {
            'y' => try putNumber(out, &n, digits, if (run == 2) @as(u32, @intCast(date.year)) % 100 else @intCast(date.year), run),
            'M' => if (run >= 4)
                try put(out, &n, months(locale)[date.month - 1])
            else
                try putNumber(out, &n, digits, date.month, run),
            'd' => try putNumber(out, &n, digits, date.day, run),
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, p, i + 1, '\'').?;
                try put(out, &n, p[i + 1 .. end]);
                run = end + 1 - i;
            },
            else => try put(out, &n, p[i..][0..run]),
        }
        i += run;
    }
    return out[0..n];
}

/// `value` with at least `width` digits, zero padded.
fn putNumber(out: []u8, n: *usize, digits: [10][]const u8, value: u32, width: usize) error{NoSpaceLeft}!void {
    var ds: [10]u8 = undefined;
    var len: usize = 0;
    var v = value;
    while (len == 0 or v != 0 or len < width) : (len += 1) {
        ds[ds.len - 1 - len] = @intCast(v % 10);
        v /= 10;
    }
    for (ds[ds.len - len ..]) |d| try put(out, n, digits[d]);
}

fn put(out: []u8, n: *usize, bytes: []const u8) error{NoSpaceLeft}!void {
    if (out.len - n.* < bytes.len) return error.NoSpaceLeft;
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}

const testing = std.testing;

test "days since 1970 to civil dates" {
    try testing.expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, Date.fromDays(0));
    try testing.expectEqual(Date{ .year = 1969, .month = 12, .day = 31 }, Date.fromDays(-1));
    try testing.expectEqual(Date{ .year = 2000, .month = 2, .day = 29 }, Date.fromDays(11016));
    try testing.expectEqual(Date{ .year = 2026, .month = 11, .day = 15 }, Date.fromDays(20772));
    try testing.expectEqual(Date{ .year = 1, .month = 1, .day = 1 }, Date.fromDays(-719162));
}

fn expectDate(want: []const u8, locale: plural.Locale, style: Style, date: Date) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(want, try format(&buf, locale, style, date));
}

test "short and long patterns per locale" {
    const d: Date = .{ .year = 2026, .month = 3, .day = 5 };
    try expectDate("3/5/26", .en, .short, d);
    try expectDate("March 5, 2026", .en, .long, d);
    try expectDate("05.03.26", .de, .short, d);
    try expectDate("5. März 2026", .de, .long, d);
    try expectDate("05/03/2026", .fr, .short, d);
    try expectDate("5 mars 2026", .fr, .long, d);
    try expectDate("05.03.2026", .ru, .short, d);
    try expectDate("5 марта 2026\u{202f}г.", .ru, .long, d);
    try expectDate("5.03.2026", .pl, .short, d);
    try expectDate("5 marca 2026", .pl, .long, d);
    try expectDate("2026/03/05", .ja, .short, d);
    try expectDate("2026年3月5日", .ja, .long, d);
    try expectDate("5\u{200f}/3\u{200f}/2026", .ar, .short, d);
    try expectDate("5 مارس 2026", .ar, .long, d);
    try expectDate("1/1/05", .en, .short, .{ .year = 2005, .month = 1, .day = 1 });
    var buf: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, format(&buf, .en, .long, d));
}
