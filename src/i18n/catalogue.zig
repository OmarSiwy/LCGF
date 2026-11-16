//! Message catalogues: one table of translated strings per locale, indexed by an application enum
//! of message keys. The checks run at comptime: a missing key, an unknown key or a malformed
//! placeholder is a compile error, so a catalogue that builds has every message. The strings are
//! the application's rodata; `fill` writes into a buffer the caller owns. No allocator.
//!
//! A message is one template, or a plural message: a struct with one template per CLDR category
//! the locale selects (`.{ .one = "{0} file", .other = "{0} files" }`); a missing or unused
//! category is a compile error too.
//!
//! Template syntax: `{0}` to `{9}` are positional arguments (translators may reorder them),
//! `{{` and `}}` are literal braces. Anything else after a brace is malformed.

const std = @import("std");
const rules = @import("plural.zig");
const number = @import("number.zig");

const forms = @typeInfo(rules.Category).@"enum".field_names.len;

/// A catalogue of one locale for the message keys of `Key`, an enum whose values are 0 to n-1.
pub fn Catalogue(comptime Key: type) type {
    const names = @typeInfo(Key).@"enum".field_names;
    return struct {
        locale: rules.Locale,
        /// One template per key and plural category, indexed by `@intFromEnum`. A plain message
        /// repeats its template in every form, so every lookup is one load.
        texts: [count][forms][]const u8,

        pub const count = names.len;

        /// Builds a catalogue from a struct literal with one field per key:
        /// `.init(.en, .{ .greeting = "Hello, {0}", .files = .{ .one = "...", .other = "..." } })`.
        pub fn init(comptime locale: rules.Locale, comptime messages: anytype) @This() {
            if (comptime check(Key, locale, messages)) |problem| @compileError(problem);
            const c = comptime blk: {
                var c: @This() = .{ .locale = locale, .texts = undefined };
                for (names, 0..) |name, k| {
                    const m = @field(messages, name);
                    if (@typeInfo(@TypeOf(m)) == .pointer) {
                        c.texts[k] = @splat(m);
                    } else {
                        c.texts[k] = @splat(m.other);
                        for (@typeInfo(@TypeOf(m)).@"struct".field_names) |form| {
                            c.texts[k][@backingInt(@field(rules.Category, form))] = @field(m, form);
                        }
                    }
                }
                break :blk c;
            };
            return c;
        }

        /// The template of `key`; for a plural message, its "other" form.
        pub fn text(c: *const @This(), key: Key) []const u8 {
            return c.texts[@backingInt(key)][@backingInt(rules.Category.other)];
        }

        /// The form of `key` that the number `n` takes in this catalogue's locale.
        pub fn plural(c: *const @This(), key: Key, n: rules.Operands) []const u8 {
            return c.texts[@backingInt(key)][@backingInt(rules.category(c.locale, n))];
        }

        /// The one-call form for counts: formats `value / 10^frac_digits` for the locale, picks
        /// the plural form of `key` it takes and fills `{0}` with it. Other placeholders are
        /// not allowed in that message.
        pub fn formatCount(c: *const @This(), out: []u8, key: Key, value: i64, frac_digits: u8) error{NoSpaceLeft}![]u8 {
            var digits: [128]u8 = undefined; // 20 digits, 6 groups, a separator and a sign, each at most 4 bytes
            const shown = try number.format(&digits, c.locale, value, frac_digits);
            return fill(out, c.plural(key, number.operands(value, frac_digits)), &.{shown});
        }
    };
}

/// The first problem with `messages` as a catalogue for `Key`, or null. `Catalogue.init` turns it
/// into a compile error; it is public so the checks themselves can be tested.
pub fn check(comptime Key: type, comptime locale: rules.Locale, comptime messages: anytype) ?[]const u8 {
    comptime {
        const info = @typeInfo(Key).@"enum";
        @setEvalBranchQuota(1000 + 100 * forms * info.field_names.len);
        @setEvalBranchQuota(1000 + 100 * forms * info.field_names.len + 4 * templateBytes(messages));
        for (info.field_values, 0..) |v, k| {
            if (v != k) return "message key enum must number its keys 0 to n-1";
        }
        const M = @TypeOf(messages);
        for (info.field_names) |name| {
            if (!@hasField(M, name)) return "catalogue misses message '" ++ name ++ "'";
        }
        for (@typeInfo(M).@"struct".field_names) |name| {
            if (!@hasField(Key, name)) return "catalogue has unknown message '" ++ name ++ "'";
            const m = @field(messages, name);
            if (@typeInfo(@TypeOf(m)) == .pointer) {
                _ = placeholders(m) catch return "message '" ++ name ++ "' has a malformed placeholder";
                continue;
            }
            const F = @TypeOf(m);
            var have: u6 = 0;
            for (@typeInfo(F).@"struct".field_names) |form| {
                if (!@hasField(rules.Category, form)) return "message '" ++ name ++ "' has unknown plural form '" ++ form ++ "'";
                have |= @as(u6, 1) << @backingInt(@field(rules.Category, form));
                _ = placeholders(@field(m, form)) catch
                    return "message '" ++ name ++ "." ++ form ++ "' has a malformed placeholder";
            }
            const want = rules.categories(locale);
            if (want & ~have != 0) return "message '" ++ name ++ "' misses a plural form of locale '" ++ @tagName(locale) ++ "'";
            if (have & ~want != 0) return "message '" ++ name ++ "' has a plural form locale '" ++ @tagName(locale) ++ "' never selects";
        }
        return null;
    }
}

fn templateBytes(comptime messages: anytype) usize {
    var bytes: usize = 0;
    for (@typeInfo(@TypeOf(messages)).@"struct".field_names) |name| {
        const m = @field(messages, name);
        if (@typeInfo(@TypeOf(m)) == .pointer) {
            bytes += m.len;
        } else {
            for (@typeInfo(@TypeOf(m)).@"struct".field_names) |form| bytes += @field(m, form).len;
        }
    }
    return bytes;
}

/// A bit per placeholder `{0}` to `{9}` that `template` uses.
pub fn placeholders(template: []const u8) error{Malformed}!u10 {
    var used: u10 = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const b = template[i];
        if (b != '{' and b != '}') continue;
        if (i + 1 < template.len and template[i + 1] == b) {
            i += 1;
            continue;
        }
        if (b == '}') return error.Malformed;
        if (i + 2 >= template.len or template[i + 2] != '}') return error.Malformed;
        const d = template[i + 1];
        if (d < '0' or d > '9') return error.Malformed;
        used |= @as(u10, 1) << @intCast(d - '0');
        i += 2;
    }
    return used;
}

/// Writes `template` into `out` with `{k}` replaced by `args[k]` and returns the written part.
/// `template` must be well formed (a catalogue's templates are) and use only `k < args.len`.
pub fn fill(out: []u8, template: []const u8, args: []const []const u8) error{NoSpaceLeft}![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const b = template[i];
        var piece: []const u8 = template[i..][0..1];
        if (b == '{' and template[i + 1] != '{') {
            const k = template[i + 1] - '0';
            std.debug.assert(k < args.len);
            piece = args[k];
            i += 2;
        } else if (b == '{' or b == '}') {
            i += 1;
        }
        if (out.len - n < piece.len) return error.NoSpaceLeft;
        @memcpy(out[n..][0..piece.len], piece);
        n += piece.len;
    }
    return out[0..n];
}

const testing = std.testing;

const Msg = enum { greeting, files, quit };

test "a catalogue maps every key to its template" {
    const en: Catalogue(Msg) = .init(.en, .{ .greeting = "Hello, {0}!", .files = "{1} of {0}", .quit = "Quit" });
    try testing.expectEqual(3, Catalogue(Msg).count);
    try testing.expectEqualStrings("Hello, {0}!", en.text(.greeting));
    try testing.expectEqualStrings("Quit", en.text(.quit));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Hello, Ada!", try fill(&buf, en.text(.greeting), &.{"Ada"}));
    // Translators may reorder arguments.
    try testing.expectEqualStrings("3 of 7", try fill(&buf, en.text(.files), &.{ "7", "3" }));
    try testing.expectError(error.NoSpaceLeft, fill(buf[0..5], en.text(.greeting), &.{"Ada"}));
}

test "missing, unknown and malformed messages are caught at comptime" {
    try testing.expectEqual(null, comptime check(Msg, .en, .{ .greeting = "", .files = "", .quit = "" }));
    try testing.expectEqualStrings("catalogue misses message 'files'", comptime check(Msg, .en, .{ .greeting = "", .quit = "" }).?);
    try testing.expectEqualStrings("catalogue has unknown message 'help'", comptime check(Msg, .en, .{ .greeting = "", .files = "", .quit = "", .help = "" }).?);
    try testing.expectEqualStrings("message 'quit' has a malformed placeholder", comptime check(Msg, .en, .{ .greeting = "", .files = "", .quit = "{name}" }).?);
    const Gappy = enum(u8) { a = 1, b = 2 };
    try testing.expectEqualStrings("message key enum must number its keys 0 to n-1", comptime check(Gappy, .en, .{ .a = "", .b = "" }).?);
}

test "placeholders and escaped braces" {
    try testing.expectEqual(0b101, try placeholders("{0} and {2}"));
    try testing.expectEqual(0, try placeholders("{{literal}} braces"));
    for ([_][]const u8{ "{", "}", "{x}", "{0", "{10}", "a } b" }) |bad| {
        try testing.expectError(error.Malformed, placeholders(bad));
    }
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("{x} = 4", try fill(&buf, "{{x}} = {0}", &.{"4"}));
}

test "plural messages pick the form of the locale" {
    const Files = enum { files };
    const en: Catalogue(Files) = .init(.en, .{ .files = .{ .one = "{0} file", .other = "{0} files" } });
    const ru: Catalogue(Files) = .init(.ru, .{ .files = .{ .one = "{0} файл", .few = "{0} файла", .many = "{0} файлов", .other = "{0} файла" } });
    try testing.expectEqualStrings("{0} file", en.plural(.files, .int(1)));
    try testing.expectEqualStrings("{0} files", en.plural(.files, .int(5)));
    try testing.expectEqualStrings("{0} files", en.text(.files));
    try testing.expectEqualStrings("{0} файл", ru.plural(.files, .int(21)));
    try testing.expectEqualStrings("{0} файла", ru.plural(.files, .int(3)));
    try testing.expectEqualStrings("{0} файлов", ru.plural(.files, .int(11)));
    try testing.expectEqualStrings("{0} файла", ru.plural(.files, .{ .i = 1, .v = 1, .f = 5 }));
    // A plain message answers every count with its one template.
    const quit: Catalogue(enum { quit }) = .init(.ar, .{ .quit = "خروج" });
    try testing.expectEqualStrings("خروج", quit.plural(.quit, .int(3)));
}

test "missing, unknown and unused plural forms are caught at comptime" {
    const Files = enum { files };
    try testing.expectEqualStrings("message 'files' misses a plural form of locale 'ru'", comptime check(Files, .ru, .{ .files = .{ .one = "", .other = "" } }).?);
    try testing.expectEqualStrings("message 'files' has a plural form locale 'ja' never selects", comptime check(Files, .ja, .{ .files = .{ .one = "", .other = "" } }).?);
    try testing.expectEqualStrings("message 'files' has unknown plural form 'plural'", comptime check(Files, .en, .{ .files = .{ .plural = "", .other = "" } }).?);
    try testing.expectEqualStrings("message 'files.one' has a malformed placeholder", comptime check(Files, .en, .{ .files = .{ .one = "{", .other = "" } }).?);
}

test "formatCount formats the number and picks its plural form" {
    const Files = enum { files };
    const de: Catalogue(Files) = .init(.de, .{ .files = .{ .one = "{0} Datei", .other = "{0} Dateien" } });
    const ru: Catalogue(Files) = .init(.ru, .{ .files = .{ .one = "{0} файл", .few = "{0} файла", .many = "{0} файлов", .other = "{0} файла" } });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1 Datei", try de.formatCount(&buf, .files, 1, 0));
    try testing.expectEqualStrings("1,0 Dateien", try de.formatCount(&buf, .files, 10, 1));
    try testing.expectEqualStrings("12.345 Dateien", try de.formatCount(&buf, .files, 12345, 0));
    try testing.expectEqualStrings("1\u{a0}021 файл", try ru.formatCount(&buf, .files, 1021, 0));
    try testing.expectEqualStrings("2,5 файла", try ru.formatCount(&buf, .files, 25, 1));
}
