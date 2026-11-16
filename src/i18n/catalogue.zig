//! Message catalogues: one table of translated strings per locale, indexed by an application enum
//! of message keys. The checks run at comptime: a missing key, an unknown key or a malformed
//! placeholder is a compile error, so a catalogue that builds has every message. The strings are
//! the application's rodata; `fill` writes into a buffer the caller owns. No allocator.
//!
//! Template syntax: `{0}` to `{9}` are positional arguments (translators may reorder them),
//! `{{` and `}}` are literal braces. Anything else after a brace is malformed.

const std = @import("std");

/// A catalogue for the message keys of `Key`, an enum whose values are 0 to n-1.
pub fn Catalogue(comptime Key: type) type {
    const names = @typeInfo(Key).@"enum".field_names;
    return struct {
        /// One template per key, indexed by `@intFromEnum(key)`.
        texts: [count][]const u8,

        pub const count = names.len;

        /// Builds a catalogue from a struct literal with one field per key:
        /// `.init(.{ .greeting = "Hello, {0}", .quit = "Quit" })`.
        pub fn init(comptime messages: anytype) @This() {
            if (comptime check(Key, messages)) |problem| @compileError(problem);
            const c = comptime blk: {
                var c: @This() = undefined;
                for (names, 0..) |name, k| c.texts[k] = @field(messages, name);
                break :blk c;
            };
            return c;
        }

        pub fn text(c: *const @This(), key: Key) []const u8 {
            return c.texts[@backingInt(key)];
        }
    };
}

/// The first problem with `messages` as a catalogue for `Key`, or null. `Catalogue.init` turns it
/// into a compile error; it is public so the checks themselves can be tested.
pub fn check(comptime Key: type, comptime messages: anytype) ?[]const u8 {
    comptime {
        const info = @typeInfo(Key).@"enum";
        for (info.field_values, 0..) |v, k| {
            if (v != k) return "message key enum must number its keys 0 to n-1";
        }
        const M = @TypeOf(messages);
        for (info.field_names) |name| {
            if (!@hasField(M, name)) return "catalogue misses message '" ++ name ++ "'";
        }
        for (@typeInfo(M).@"struct".field_names) |name| {
            if (!@hasField(Key, name)) return "catalogue has unknown message '" ++ name ++ "'";
            _ = placeholders(@field(messages, name)) catch
                return "message '" ++ name ++ "' has a malformed placeholder";
        }
        return null;
    }
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
    const en: Catalogue(Msg) = .init(.{ .greeting = "Hello, {0}!", .files = "{1} of {0}", .quit = "Quit" });
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
    try testing.expectEqual(null, comptime check(Msg, .{ .greeting = "", .files = "", .quit = "" }));
    try testing.expectEqualStrings("catalogue misses message 'files'", comptime check(Msg, .{ .greeting = "", .quit = "" }).?);
    try testing.expectEqualStrings("catalogue has unknown message 'help'", comptime check(Msg, .{ .greeting = "", .files = "", .quit = "", .help = "" }).?);
    try testing.expectEqualStrings("message 'quit' has a malformed placeholder", comptime check(Msg, .{ .greeting = "", .files = "", .quit = "{name}" }).?);
    const Gappy = enum(u8) { a = 1, b = 2 };
    try testing.expectEqualStrings("message key enum must number its keys 0 to n-1", comptime check(Gappy, .{ .a = "", .b = "" }).?);
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
