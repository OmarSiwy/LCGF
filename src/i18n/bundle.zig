//! Switching language at run time: a bundle is the comptime list of an application's catalogues
//! plus one runtime index, the active one. Switching is one store; the caller asks for a new frame
//! when `select` reports a change (the runtime front end rebuilds its text every frame anyway).
//! The comptime check that makes switching safe: every catalogue uses the same placeholders for
//! each message as the first, so a `fill` call that works in one language works in all.

const std = @import("std");
const plural = @import("plural.zig");
const catalogue = @import("catalogue.zig");

pub fn Bundle(comptime Key: type, comptime catalogues: []const catalogue.Catalogue(Key)) type {
    if (comptime check(Key, catalogues)) |problem| @compileError(problem);
    return struct {
        active: u32 = 0,

        pub const all = catalogues;

        pub fn current(b: *const @This()) *const catalogue.Catalogue(Key) {
            return &all[b.active];
        }

        /// Makes `locale` the active language. Returns whether the language changed; a locale the
        /// bundle has no catalogue for leaves it as it is and returns false.
        pub fn select(b: *@This(), locale: plural.Locale) bool {
            for (all, 0..) |c, k| {
                if (c.locale != locale) continue;
                const changed = b.active != k;
                b.active = @intCast(k);
                return changed;
            }
            return false;
        }
    };
}

/// The first problem with `catalogues` as a bundle, or null.
pub fn check(comptime Key: type, comptime catalogues: []const catalogue.Catalogue(Key)) ?[]const u8 {
    comptime {
        if (catalogues.len == 0) return "a bundle needs at least one catalogue";
        const reference = catalogues[0];
        const keys = @typeInfo(Key).@"enum".field_names.len;
        @setEvalBranchQuota(1000 + 100 * catalogues.len * (catalogues.len + keys * 6));
        var bytes: usize = 0;
        for (catalogues) |c| {
            for (c.texts) |ts| for (ts) |t| {
                bytes += t.len;
            };
        }
        @setEvalBranchQuota(1000 + 100 * catalogues.len * (catalogues.len + keys * 6) + 8 * bytes);
        for (catalogues, 0..) |c, k| {
            for (catalogues[0..k]) |earlier| {
                if (earlier.locale == c.locale) return "bundle has two catalogues for locale '" ++ @tagName(c.locale) ++ "'";
            }
            for (@typeInfo(Key).@"enum".field_names, 0..) |name, m| {
                if (used(reference.texts[m]) != used(c.texts[m]))
                    return "message '" ++ name ++ "' of locale '" ++ @tagName(c.locale) ++ "' uses other placeholders than locale '" ++ @tagName(reference.locale) ++ "'";
            }
        }
        return null;
    }
}

fn used(comptime forms: anytype) u10 {
    var mask: u10 = 0;
    for (forms) |t| mask |= catalogue.placeholders(t) catch unreachable;
    return mask;
}

/// The locale for a BCP 47 language tag such as "de-AT" or "pt_BR" (its language subtag only),
/// or null when this module has no data for it. For mapping the OS or user setting.
pub fn localeFromTag(tag: []const u8) ?plural.Locale {
    const end = std.mem.indexOfAny(u8, tag, "-_") orelse tag.len;
    var lower: [8]u8 = undefined;
    if (end > lower.len) return null;
    for (tag[0..end], lower[0..end]) |c, *l| l.* = std.ascii.toLower(c);
    const locale = std.meta.stringToEnum(plural.Locale, lower[0..end]) orelse return null;
    return if (locale == .pseudo) null else locale;
}

const testing = std.testing;

const Msg = enum { greeting, files };
const Cat = catalogue.Catalogue(Msg);
const en: Cat = .init(.en, .{ .greeting = "Hello, {0}!", .files = .{ .one = "{0} file", .other = "{0} files" } });
const de: Cat = .init(.de, .{ .greeting = "Hallo, {0}!", .files = .{ .one = "{0} Datei", .other = "{0} Dateien" } });
const bad_fr: Cat = .init(.fr, .{ .greeting = "Bonjour !", .files = .{ .one = "{0} fichier", .many = "{0} de fichiers", .other = "{0} fichiers" } });
const ja: Cat = .init(.ja, .{ .greeting = "こんにちは、{0}さん", .files = "{0}個のファイル" });

test "switching the active catalogue at run time" {
    var b: Bundle(Msg, &.{ en, de, ja }) = .{};
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Hello, Ada!", try catalogue.fill(&buf, b.current().text(.greeting), &.{"Ada"}));
    try testing.expect(b.select(.de));
    try testing.expectEqualStrings("Hallo, Ada!", try catalogue.fill(&buf, b.current().text(.greeting), &.{"Ada"}));
    try testing.expectEqualStrings("12.345 Dateien", try b.current().formatCount(&buf, .files, 12345, 0));
    try testing.expect(!b.select(.de)); // already active: no new frame needed
    try testing.expect(!b.select(.fr)); // no catalogue: stays German
    try testing.expectEqual(plural.Locale.de, b.current().locale);
    try testing.expect(b.select(localeFromTag("ja-JP").?));
    try testing.expectEqualStrings("1個のファイル", try b.current().formatCount(&buf, .files, 1, 0));
}

test "catalogues that disagree on placeholders or repeat a locale are caught at comptime" {
    try testing.expectEqual(null, comptime check(Msg, &.{ en, de, ja }));
    try testing.expectEqualStrings("message 'greeting' of locale 'fr' uses other placeholders than locale 'en'", comptime check(Msg, &.{ en, bad_fr }).?);
    try testing.expectEqualStrings("bundle has two catalogues for locale 'en'", comptime check(Msg, &.{ en, de, en }).?);
    try testing.expectEqualStrings("a bundle needs at least one catalogue", comptime check(Msg, &.{}).?);
}

test "language tags map to locales" {
    try testing.expectEqual(plural.Locale.de, localeFromTag("de-AT").?);
    try testing.expectEqual(plural.Locale.pl, localeFromTag("PL").?);
    try testing.expectEqual(plural.Locale.fr, localeFromTag("fr_CA").?);
    try testing.expectEqual(null, localeFromTag("pt-BR"));
    try testing.expectEqual(null, localeFromTag("pseudo"));
    try testing.expectEqual(null, localeFromTag("verylongtag"));
}

const long: []const u8 = "{0} " ++ @as([4800]u8, @splat(0x61));
const long_en: Cat = .init(.en, .{ .greeting = long, .files = .{ .one = long, .other = long } });
const long_de: Cat = .init(.de, .{ .greeting = long, .files = long });

test "long catalogues stay within the comptime branch quota" {
    const b: Bundle(Msg, &.{ long_en, long_de }) = .{};
    try testing.expectEqual(long.len, b.current().text(.greeting).len);
}
