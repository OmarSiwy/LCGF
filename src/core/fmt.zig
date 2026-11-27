//! fmt: the format of a formatted label (`spec.text("Volume {.1} dB", .{.volume})`, a `.zon`
//! `.text`), one meaning in every front end. Tier 0: no allocator; the caller holds the
//! segments and the output.
//!
//! The language:
//! - `{}` is the next argument: a string as it is, a bool as `true` or `false`, an integer in
//!   decimal, an enum(u8) as its number.
//! - `{.N}`, N from 0 to 6, is the next argument, an f32, with N decimals: the value widened to
//!   f64, times 10^N, rounded half away from zero (every step exact or correctly rounded, so
//!   every language gets the same digits). The sign shows only when that result is not zero; a
//!   NaN is `nan`, an infinity `inf` or `-inf`, and a result of 10^18 or more is written as an
//!   infinity of its sign. An f32 needs a precision: `{}` on one is an error.
//! - `{{` and `}}` are a brace. Any other brace is an error, as is a count of `{}`s other than
//!   the argument count.

const std = @import("std");

/// What a segment writes. The values are the ABI's (the static UI words' `segs`).
pub const Kind = enum(u8) { literal = 0, str = 1, bool = 2, u32 = 3, u8 = 4, f32 = 5 };

/// A piece of the output: format text (`start`, `len` into it), or argument `arg` written as
/// `kind` (with `prec` decimals, an f32).
pub const Seg = struct { kind: Kind, prec: u8 = 0, arg: u32 = 0, start: u32 = 0, len: u32 = 0 };

pub const Error = error{
    /// A brace that is not `{}`, `{.N}`, `{{` or `}}`, or a precision past 6.
    BadFormat,
    /// More or fewer placeholders than arguments, an f32 without a precision, a precision on
    /// something else, or an argument of a type the format cannot write.
    BadArg,
};

pub const max_prec = 6;

/// An upper bound on the segments of `text`: one per placeholder or brace, one per text run.
pub fn maxSegs(text: []const u8) usize {
    var n: usize = 1;
    for (text) |c| n += 2 * @as(usize, @intFromBool(c == '{' or c == '}'));
    return n;
}

/// The segments of `text` for arguments of kinds `args`, into `out` (at least `maxSegs`
/// long); returns how many. Runs while compiling or at run time.
pub fn parse(text: []const u8, args: []const Kind, out: []Seg) Error!usize {
    var n: usize = 0;
    var next_arg: u32 = 0;
    var run: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c != '{' and c != '}') {
            i += 1;
            continue;
        }
        if (i > run) {
            out[n] = .{ .kind = .literal, .start = @intCast(run), .len = @intCast(i - run) };
            n += 1;
        }
        if (i + 1 < text.len and text[i + 1] == c) {
            // `{{` or `}}`: the first brace is the text.
            out[n] = .{ .kind = .literal, .start = @intCast(i), .len = 1 };
            n += 1;
            i += 2;
            run = i;
            continue;
        }
        if (c == '}') return error.BadFormat;
        var prec: ?u8 = null;
        var j = i + 1;
        if (j < text.len and text[j] == '.') {
            if (j + 1 >= text.len or text[j + 1] < '0' or text[j + 1] > '0' + max_prec) return error.BadFormat;
            prec = text[j + 1] - '0';
            j += 2;
        }
        if (j >= text.len or text[j] != '}') return error.BadFormat;
        if (next_arg >= args.len) return error.BadArg;
        const kind = args[next_arg];
        if (kind == .literal) return error.BadArg;
        if ((kind == .f32) != (prec != null)) return error.BadArg;
        out[n] = .{ .kind = kind, .prec = prec orelse 0, .arg = next_arg };
        n += 1;
        next_arg += 1;
        i = j + 1;
        run = i;
    }
    if (run < text.len) {
        out[n] = .{ .kind = .literal, .start = @intCast(run), .len = @intCast(text.len - run) };
        n += 1;
    }
    if (next_arg != args.len) return error.BadArg;
    return n;
}

/// The kind a field of Zig type `T` formats as, or null when it cannot be an argument.
pub fn kindOf(comptime T: type) ?Kind {
    if (T == []const u8) return .str;
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .float => if (T == f32) .f32 else null,
        .int => if (T == u32) .u32 else if (T == u8) .u8 else null,
        .@"enum" => |e| if (e.tag_type == u8) .u8 else null,
        else => null,
    };
}

/// Where formatted bytes go: the rest of a buffer. What does not fit is dropped, byte by byte,
/// as every engine drops it.
pub const Sink = struct {
    buf: []u8,
    len: usize = 0,
    /// Something did not fit.
    cut: bool = false,

    pub fn put(s: *Sink, bytes: []const u8) void {
        const n = @min(bytes.len, s.buf.len - s.len);
        s.cut = s.cut or n < bytes.len;
        @memcpy(s.buf[s.len..][0..n], bytes[0..n]);
        s.len += n;
    }

    pub fn putBool(s: *Sink, v: bool) void {
        s.put(if (v) "true" else "false");
    }

    pub fn putUint(s: *Sink, v: u64) void {
        var digits: [20]u8 = undefined;
        s.put(decimal(&digits, v, 1));
    }

    /// `v` with `prec` decimals, as the header says.
    pub fn putF32(s: *Sink, v: f32, prec: u8) void {
        if (v != v) return s.put("nan");
        const scaled = @round(@as(f64, v) * pow10[prec]);
        if (@abs(scaled) >= 1e18) return s.put(if (v < 0) "-inf" else "inf");
        if (scaled < 0) s.put("-");
        var digits: [20]u8 = undefined;
        const d = decimal(&digits, @intFromFloat(@abs(scaled)), @as(usize, prec) + 1);
        s.put(d[0 .. d.len - prec]);
        if (prec == 0) return;
        s.put(".");
        s.put(d[d.len - prec ..]);
    }
};

const pow10 = [max_prec + 1]f64{ 1, 10, 100, 1000, 10000, 100000, 1000000 };

/// `v` in decimal, at least `min_digits` long (zeros in front), at the end of `buf`.
fn decimal(buf: *[20]u8, v: u64, min_digits: usize) []const u8 {
    var at: usize = buf.len;
    var x = v;
    while (x != 0 or buf.len - at < min_digits) {
        at -= 1;
        buf[at] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
    }
    return buf[at..];
}

/// Writes `segs` of `text` to `sink`, reading argument values from `args`, anything with
/// `str(i) []const u8`, `boolean(i) bool`, `uint(i) u64` (a u32), `byte(i) u64` (a u8) and
/// `float(i) f32` for argument i. `segs` is a slice of anything with `Seg`'s fields.
/// A pointer to an array of segments (a length known while compiling) is unrolled.
pub inline fn write(segs: anytype, text: []const u8, args: anytype, sink: *Sink) void {
    const unrolled = comptime switch (@typeInfo(@TypeOf(segs))) {
        .pointer => |p| p.size == .one and @typeInfo(p.child) == .array,
        else => false,
    };
    if (unrolled) {
        inline for (segs) |g| writeSeg(g, text, args, sink);
    } else for (segs) |g| writeSeg(g, text, args, sink);
}

inline fn writeSeg(g: anytype, text: []const u8, args: anytype, sink: *Sink) void {
    switch (g.kind) {
        .literal => sink.put(text[g.start..][0..g.len]),
        .str => sink.put(args.str(g.arg)),
        .bool => sink.putBool(args.boolean(g.arg)),
        .u32 => sink.putUint(args.uint(g.arg)),
        .u8 => sink.putUint(args.byte(g.arg)),
        .f32 => sink.putF32(args.float(g.arg), g.prec),
    }
}

/// The arguments of a format as fields of a Zig value: argument i is field `names[i]` of
/// `state`. For `write`.
pub fn Fields(comptime State: type, comptime names: []const []const u8) type {
    return struct {
        state: *const State,

        const Self = @This();

        pub fn str(a: Self, i: u32) []const u8 {
            inline for (names, 0..) |n, k| if (comptime @FieldType(State, n) == []const u8) {
                if (i == k) return @field(a.state, n);
            };
            unreachable;
        }
        pub fn boolean(a: Self, i: u32) bool {
            inline for (names, 0..) |n, k| if (comptime @FieldType(State, n) == bool) {
                if (i == k) return @field(a.state, n);
            };
            unreachable;
        }
        pub fn uint(a: Self, i: u32) u64 {
            inline for (names, 0..) |n, k| {
                const T = @FieldType(State, n);
                if (comptime T == u32 or T == u8) {
                    if (i == k) return @field(a.state, n);
                } else if (comptime @typeInfo(T) == .@"enum") {
                    if (i == k) return @backingInt(@field(a.state, n));
                }
            }
            unreachable;
        }
        pub fn byte(a: Self, i: u32) u64 {
            return a.uint(i);
        }
        pub fn float(a: Self, i: u32) f32 {
            inline for (names, 0..) |n, k| if (comptime @FieldType(State, n) == f32) {
                if (i == k) return @field(a.state, n);
            };
            unreachable;
        }
    };
}

/// The arguments' kinds for fields `names` of `State`; a compile error naming a field that is
/// missing or cannot be an argument.
pub fn kindsOf(comptime State: type, comptime names: []const []const u8) [names.len]Kind {
    var out: [names.len]Kind = undefined;
    for (names, &out) |n, *k| {
        if (!@hasField(State, n)) @compileError("text: no state field '" ++ n ++ "'");
        k.* = kindOf(@FieldType(State, n)) orelse @compileError("text: field '" ++ n ++ "' is a " ++ @typeName(@FieldType(State, n)) ++ "; a format argument is a string, a bool, a u32, a u8, an f32 or an enum(u8)");
    }
    return out;
}

/// The segments of `text` over fields `names` of `State`, checked while compiling.
pub fn compile(comptime State: type, comptime text: []const u8, comptime names: []const []const u8) []const Seg {
    return comptime blk: {
        const kinds = kindsOf(State, names);
        var buf: [maxSegs(text)]Seg = undefined;
        const n = parse(text, &kinds, &buf) catch |e| @compileError(switch (e) {
            error.BadFormat => "text: bad format \"" ++ text ++ "\": use {}, {.N} (N 0 to 6), {{ and }}",
            error.BadArg => "text: \"" ++ text ++ "\" does not fit its arguments: one {} per argument, {.N} for each f32 and only for an f32",
        });
        const final = buf[0..n].*;
        break :blk &final;
    };
}

const testing = std.testing;

fn formatted(buf: []u8, text: []const u8, kinds: []const Kind, args: anytype) ![]const u8 {
    var segs: [16]Seg = undefined;
    const n = try parse(text, kinds, &segs);
    var sink: Sink = .{ .buf = buf };
    write(segs[0..n], text, args, &sink);
    return buf[0..sink.len];
}

const Floats = struct {
    v: []const f32,
    pub fn str(_: Floats, _: u32) []const u8 {
        return "";
    }
    pub fn boolean(_: Floats, _: u32) bool {
        return false;
    }
    pub fn uint(_: Floats, _: u32) u64 {
        return 0;
    }
    pub fn byte(_: Floats, _: u32) u64 {
        return 0;
    }
    pub fn float(a: Floats, i: u32) f32 {
        return a.v[i];
    }
};

test "fmt: f32 decimals round half away from zero on the f64 product; signs, NaN and infinities" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { v: f32, prec: u8, want: []const u8 }{
        .{ .v = 0.5, .prec = 0, .want = "1" },
        .{ .v = -0.5, .prec = 0, .want = "-1" },
        .{ .v = 2.5, .prec = 0, .want = "3" },
        // 0.05 as an f32 is 0.0500000007..., so it rounds up.
        .{ .v = 0.05, .prec = 1, .want = "0.1" },
        // 0.15 as an f32 is 0.1500000059...
        .{ .v = 0.15, .prec = 1, .want = "0.2" },
        .{ .v = -0.0004, .prec = 3, .want = "0.000" },
        .{ .v = -0.0, .prec = 2, .want = "0.00" },
        .{ .v = 1.25, .prec = 1, .want = "1.3" },
        .{ .v = 3, .prec = 6, .want = "3.000000" },
        .{ .v = 123456.789, .prec = 2, .want = "123456.79" },
        .{ .v = 1e20, .prec = 0, .want = "inf" },
        .{ .v = -1e20, .prec = 0, .want = "-inf" },
        .{ .v = std.math.inf(f32), .prec = 1, .want = "inf" },
        .{ .v = std.math.nan(f32), .prec = 1, .want = "nan" },
    };
    for (cases) |c| {
        const text: []const u8 = switch (c.prec) {
            0 => "{.0}",
            1 => "{.1}",
            2 => "{.2}",
            3 => "{.3}",
            6 => "{.6}",
            else => unreachable,
        };
        const got = try formatted(&buf, text, &.{.f32}, Floats{ .v = &.{c.v} });
        try testing.expectEqualStrings(c.want, got);
    }
}

test "fmt: parse splits text, arguments and braces; refuses what it cannot write" {
    var segs: [16]Seg = undefined;
    const n = try parse("a{{b}}{}c{.2}", &.{ .str, .f32 }, &segs);
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqual(Kind.literal, segs[0].kind);
    try testing.expectEqual(@as(u32, 1), segs[1].len);
    try testing.expectEqual(Kind.str, segs[4].kind);
    try testing.expectEqual(@as(u8, 2), segs[6].prec);
    try testing.expectError(error.BadArg, parse("{}", &.{.f32}, &segs));
    try testing.expectError(error.BadArg, parse("{.1}", &.{.u32}, &segs));
    try testing.expectError(error.BadArg, parse("{}{}", &.{.u32}, &segs));
    try testing.expectError(error.BadArg, parse("x", &.{.u32}, &segs));
    try testing.expectError(error.BadFormat, parse("{x}", &.{.u32}, &segs));
    try testing.expectError(error.BadFormat, parse("{.7}", &.{.f32}, &segs));
    try testing.expectError(error.BadFormat, parse("a}b", &.{}, &segs));
    try testing.expectError(error.BadFormat, parse("{", &.{.u32}, &segs));
}

test "fmt: fields of a Zig value; what does not fit is cut" {
    const S = struct { name: []const u8 = "Ada", on: bool = true, n: u32 = 42, gain: f32 = 0.125, mode: enum(u8) { fast, slow } = .slow };
    const names = [_][]const u8{ "name", "on", "n", "gain", "mode" };
    const segs = compile(S, "{}: {} {} {.2} {}", &names);
    const s: S = .{};
    var buf: [64]u8 = undefined;
    var sink: Sink = .{ .buf = &buf };
    write(segs, "{}: {} {} {.2} {}", Fields(S, &names){ .state = &s }, &sink);
    try testing.expectEqualStrings("Ada: true 42 0.13 1", buf[0..sink.len]);
    var small: [5]u8 = undefined;
    sink = .{ .buf = &small };
    write(segs, "{}: {} {} {.2} {}", Fields(S, &names){ .state = &s }, &sink);
    try testing.expectEqualStrings("Ada: ", &small);
}
