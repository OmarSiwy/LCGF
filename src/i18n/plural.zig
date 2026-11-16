//! Plural selection: which CLDR cardinal category ("one", "few", ...) a number takes in a locale.
//! The rules are CLDR `plurals.xml` (cardinal), transcribed for the locales in `Locale`; the test vectors
//! are CLDR's own `@integer` / `@decimal` samples for those rules.
// ponytail: rules written out per locale; generate from CLDR data (a pinned build.zig.zon
// dependency, once docs/DEPENDENCIES.md lists it) when the locale set grows past a handful.

const std = @import("std");

/// The locales this module has data for. `pseudo` is the pseudo-localisation test locale; it
/// follows English rules.
pub const Locale = enum(u8) { en, de, fr, ru, pl, ja, ar, pseudo };

pub const Category = enum(u3) { zero, one, two, few, many, other };

/// CLDR plural operands of an absolute value: `i` the integer digits, `v` the number of visible
/// fraction digits, `f` those digits as an integer (1.50 is i=1, v=2, f=50).
pub const Operands = struct {
    i: u64,
    v: u8 = 0,
    f: u64 = 0,

    pub fn int(n: u64) Operands {
        return .{ .i = n };
    }
};

pub fn category(locale: Locale, n: Operands) Category {
    const i = n.i;
    const int = n.v == 0;
    const m10 = i % 10;
    const m100 = i % 100;
    const teen = m100 >= 12 and m100 <= 14;
    return switch (locale) {
        .en, .de, .pseudo => if (i == 1 and int) .one else .other,
        .fr => if (i <= 1) .one else if (int and i % 1_000_000 == 0) .many else .other,
        .ru => if (!int) .other else if (m10 == 1 and m100 != 11) .one else if (m10 >= 2 and m10 <= 4 and !teen) .few else .many,
        .pl => if (!int) .other else if (i == 1) .one else if (m10 >= 2 and m10 <= 4 and !teen) .few else .many,
        .ja => .other,
        // Arabic rules test the whole value n, so a decimal with a non-zero fraction is "other".
        .ar => if (n.f != 0) .other else if (i <= 2) @fromBackingInt(@intCast(i)) else if (m100 >= 3 and m100 <= 10) .few else if (m100 >= 11) .many else .other,
    };
}

/// A bit per category (`@intFromEnum`) that `locale` can select.
pub fn categories(locale: Locale) u6 {
    const b = struct {
        fn of(cs: []const Category) u6 {
            var m: u6 = 0;
            for (cs) |c| m |= @as(u6, 1) << @backingInt(c);
            return m;
        }
    }.of;
    return switch (locale) {
        .en, .de, .pseudo => b(&.{ .one, .other }),
        .fr => b(&.{ .one, .many, .other }),
        .ru, .pl => b(&.{ .one, .few, .many, .other }),
        .ja => b(&.{.other}),
        .ar => b(&.{ .zero, .one, .two, .few, .many, .other }),
    };
}

const testing = std.testing;

fn expectInts(locale: Locale, c: Category, ns: []const u64) !void {
    for (ns) |n| try testing.expectEqual(c, category(locale, .int(n)));
}

test "CLDR integer samples" {
    try expectInts(.en, .one, &.{1});
    try expectInts(.en, .other, &.{ 0, 2, 16, 100, 1000 });
    try expectInts(.fr, .one, &.{ 0, 1 });
    try expectInts(.fr, .many, &.{ 1_000_000, 2_000_000 });
    try expectInts(.fr, .other, &.{ 2, 17, 100, 1000, 10_000 });
    try expectInts(.ru, .one, &.{ 1, 21, 31, 101, 1001 });
    try expectInts(.ru, .few, &.{ 2, 3, 4, 22, 24, 102 });
    try expectInts(.ru, .many, &.{ 0, 5, 11, 12, 14, 19, 100, 111 });
    try expectInts(.pl, .one, &.{1});
    try expectInts(.pl, .few, &.{ 2, 4, 22, 24, 32 });
    try expectInts(.pl, .many, &.{ 0, 5, 12, 14, 21, 100 });
    try expectInts(.ja, .other, &.{ 0, 1, 2, 100 });
    try expectInts(.ar, .zero, &.{0});
    try expectInts(.ar, .one, &.{1});
    try expectInts(.ar, .two, &.{2});
    try expectInts(.ar, .few, &.{ 3, 10, 103, 110, 1003 });
    try expectInts(.ar, .many, &.{ 11, 26, 99, 111, 1011 });
    try expectInts(.ar, .other, &.{ 100, 102, 200, 1000 });
}

test "CLDR decimal samples" {
    // 1.0 shows a fraction digit, so English says "1.0 files"; French "1,5 fichier".
    try testing.expectEqual(Category.other, category(.en, .{ .i = 1, .v = 1, .f = 0 }));
    try testing.expectEqual(Category.one, category(.fr, .{ .i = 1, .v = 1, .f = 5 }));
    try testing.expectEqual(Category.other, category(.ru, .{ .i = 1, .v = 1, .f = 5 }));
    try testing.expectEqual(Category.other, category(.pl, .{ .i = 2, .v = 1, .f = 5 }));
    try testing.expectEqual(Category.one, category(.ar, .{ .i = 1, .v = 1, .f = 0 }));
    try testing.expectEqual(Category.other, category(.ar, .{ .i = 1, .v = 1, .f = 5 }));
}

test "every selected category is declared" {
    for (std.enums.values(Locale)) |l| {
        for (0..2000) |n| {
            const c = category(l, .int(n));
            try testing.expect(categories(l) & (@as(u6, 1) << @backingInt(c)) != 0);
        }
    }
}
