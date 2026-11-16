//! The hand-written locale tables of src/i18n/ checked against CLDR 49 JSON (`zig build
//! i18n-cldr`; the data is a lazy build.zig.zon dependency). CLDR is only the oracle here: the
//! runtime tables stay small, hand-written and tier 0. Test-only code, so it may allocate.
//!
//! Plural rules are checked twice: every `@integer` / `@decimal` sample CLDR lists, and CLDR's
//! rule text, evaluated here, against `plural.category` over a grid of integers and decimals.
//! Every mismatch is printed (file, key, ours, CLDR) before the test fails.

const std = @import("std");
const lcgr = @import("lcgr");
const plural = lcgr.i18n_plural;
const number = lcgr.i18n_number;
const date = lcgr.i18n_date;

const Json = std.json.Value;
const testing = std.testing;

var mismatches: usize = 0;

fn mismatch(file: []const u8, key: []const u8, ours: []const u8, cldr: []const u8) void {
    mismatches += 1;
    std.debug.print("MISMATCH {s}: {s}: ours \"{s}\" ({x}), CLDR \"{s}\" ({x})\n", .{ file, key, ours, ours, cldr, cldr });
}

fn expectSame(file: []const u8, key: []const u8, ours: []const u8, cldr: []const u8) void {
    if (!std.mem.eql(u8, ours, cldr)) mismatch(file, key, ours, cldr);
}

fn get(v: Json, keys: []const []const u8) Json {
    var at = v;
    for (keys) |k| at = at.object.get(k) orelse std.debug.panic("CLDR JSON has no key '{s}'", .{k});
    return at;
}

fn parse(bytes: []const u8) !std.json.Parsed(Json) {
    return std.json.parseFromSlice(Json, testing.allocator, bytes, .{});
}

const locales = [_]plural.Locale{ .en, .de, .fr, .ru, .pl, .ja, .ar };

// --- plural rules -------------------------------------------------------------------------

/// Evaluates a CLDR plural condition ("v = 0 and i % 10 = 2..4 or ...") for operands i, v, f.
/// Exponent operands e and c are 0: nothing here formats compact numbers.
fn holds(condition: []const u8, n: plural.Operands) bool {
    var t = n.f; // f without trailing zeros, and w its digit count
    var w: u64 = n.v;
    while (t != 0 and t % 10 == 0) : (w -= 1) t /= 10;
    if (t == 0) w = 0;
    var ors = std.mem.splitSequence(u8, condition, " or ");
    while (ors.next()) |and_part| {
        var all = true;
        var ands = std.mem.splitSequence(u8, and_part, " and ");
        while (ands.next()) |relation| {
            var words = std.mem.tokenizeScalar(u8, relation, ' ');
            const operand = words.next().?;
            var word = words.next().?;
            var modulus: ?u64 = null;
            if (std.mem.eql(u8, word, "%")) {
                modulus = std.fmt.parseInt(u64, words.next().?, 10) catch unreachable;
                word = words.next().?;
            }
            const negate = std.mem.eql(u8, word, "!=");
            std.debug.assert(negate or std.mem.eql(u8, word, "="));
            const ranges = words.rest();
            // n is the whole value: with a non-zero fraction it equals no integer.
            const integral = operand[0] != 'n' or n.f == 0;
            var x: u64 = switch (operand[0]) {
                'n', 'i' => n.i,
                'v' => n.v,
                'w' => w,
                'f' => n.f,
                't' => t,
                'e', 'c' => 0,
                else => std.debug.panic("unknown plural operand {s}", .{operand}),
            };
            if (modulus) |m| x %= m;
            var in = false;
            var items = std.mem.tokenizeScalar(u8, ranges, ',');
            while (items.next()) |item| {
                var bounds = std.mem.splitSequence(u8, item, "..");
                const lo = std.fmt.parseInt(u64, bounds.next().?, 10) catch unreachable;
                const hi = if (bounds.next()) |h| std.fmt.parseInt(u64, h, 10) catch unreachable else lo;
                in = in or (integral and x >= lo and x <= hi);
            }
            all = all and (in != negate);
        }
        if (all) return true;
    }
    return false;
}

fn cldrCategory(rules: Json, n: plural.Operands) plural.Category {
    for (rule_keys[0..5], 0..) |key, c| {
        const rule = rules.object.get(key) orelse continue;
        const condition = std.mem.trim(u8, rule.string[0 .. std.mem.indexOfScalar(u8, rule.string, '@') orelse rule.string.len], " ");
        if (holds(condition, n)) return @fromBackingInt(@intCast(c));
    }
    return .other;
}

const rule_keys = [_][]const u8{ "pluralRule-count-zero", "pluralRule-count-one", "pluralRule-count-two", "pluralRule-count-few", "pluralRule-count-many", "pluralRule-count-other" };

fn decimal(text: []const u8) plural.Operands {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return .int(std.fmt.parseInt(u64, text, 10) catch unreachable);
    const frac = text[dot + 1 ..];
    return .{
        .i = std.fmt.parseInt(u64, text[0..dot], 10) catch unreachable,
        .v = @intCast(frac.len),
        .f = std.fmt.parseInt(u64, frac, 10) catch unreachable,
    };
}

fn operandsText(buf: []u8, n: plural.Operands) []const u8 {
    if (n.v == 0) return std.fmt.bufPrint(buf, "{d}", .{n.i}) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}.{d:0>[2]}", .{ n.i, n.f, n.v }) catch unreachable;
}

fn checkSample(tag: []const u8, locale: plural.Locale, want: plural.Category, n: plural.Operands) void {
    const got = plural.category(locale, n);
    if (got == want) return;
    var key: [64]u8 = undefined;
    var shown: [32]u8 = undefined;
    mismatch("plural.zig", std.fmt.bufPrint(&key, "{s} sample {s}", .{ tag, operandsText(&shown, n) }) catch unreachable, @tagName(got), @tagName(want));
}

test "plural rules: every CLDR sample, and the rule text over a grid" {
    mismatches = 0;
    const doc = try parse(@embedFile("plurals.json"));
    defer doc.deinit();
    var samples: usize = 0;
    for (locales) |locale| {
        const tag = @tagName(locale);
        const rules = get(doc.value, &.{ "supplemental", "plurals-type-cardinal", tag });

        var declared: u6 = 0;
        for (rule_keys, 0..) |key, c| {
            const rule = rules.object.get(key) orelse continue;
            declared |= @as(u6, 1) << @intCast(c);
            // Samples: "@integer 0, 2~16, 100, … @decimal 0.0~1.5, 1.0000001c6, …".
            var lists = std.mem.splitScalar(u8, rule.string, '@');
            _ = lists.next();
            while (lists.next()) |list| {
                var items = std.mem.tokenizeAny(u8, list, ", ");
                _ = items.next(); // "integer" or "decimal"
                while (items.next()) |item| {
                    if (std.mem.indexOfScalar(u8, item, 'c') != null or std.mem.startsWith(u8, item, "…")) continue;
                    var ends = std.mem.splitScalar(u8, item, '~');
                    const lo = decimal(ends.next().?);
                    const hi = if (ends.next()) |h| decimal(h) else lo;
                    std.debug.assert(lo.v == hi.v);
                    const scale = std.math.powi(u64, 10, lo.v) catch unreachable;
                    var x = lo.i * scale + lo.f;
                    while (x <= hi.i * scale + hi.f) : (x += 1) {
                        const n: plural.Operands = .{ .i = x / scale, .v = lo.v, .f = x % scale };
                        checkSample(tag, locale, @fromBackingInt(@intCast(c)), n);
                        if (cldrCategory(rules, n) != @as(plural.Category, @fromBackingInt(@intCast(c))))
                            std.debug.panic("the rule evaluator disagrees with CLDR sample {s} {s}", .{ tag, item });
                        samples += 1;
                    }
                }
            }
        }
        var ours_buf: [64]u8 = undefined;
        var cldr_buf: [64]u8 = undefined;
        if (declared != plural.categories(locale)) mismatch("plural.zig", tag, std.fmt.bufPrint(&ours_buf, "categories {b:0>6}", .{plural.categories(locale)}) catch unreachable, std.fmt.bufPrint(&cldr_buf, "categories {b:0>6}", .{declared}) catch unreachable);

        // The grid: integers 0..20000, and decimals with 1 to 3 fraction digits.
        for (0..20_001) |i| {
            const n: plural.Operands = .int(i);
            checkSample(tag, locale, cldrCategory(rules, n), n);
        }
        for (0..1101) |i| for (1..4) |v| for ([_]u64{ 0, 1, 5, 10, 99, 100, 999 }) |f| {
            if (f >= (std.math.powi(u64, 10, v) catch unreachable)) continue;
            const n: plural.Operands = .{ .i = i, .v = @intCast(v), .f = f };
            checkSample(tag, locale, cldrCategory(rules, n), n);
        };
    }
    std.debug.print("plural: {d} CLDR samples checked\n", .{samples});
    try testing.expectEqual(0, mismatches);
}

// --- numbers ------------------------------------------------------------------------------

const numbers_files = .{ "numbers-en.json", "numbers-de.json", "numbers-fr.json", "numbers-ru.json", "numbers-pl.json", "numbers-ja.json", "numbers-ar.json" };
const gregorian_files = .{ "gregorian-en.json", "gregorian-de.json", "gregorian-fr.json", "gregorian-ru.json", "gregorian-pl.json", "gregorian-ja.json", "gregorian-ar.json" };

test "number symbols, grouping and digits" {
    mismatches = 0;
    const systems = try parse(@embedFile("numberingSystems.json"));
    defer systems.deinit();
    inline for (locales, numbers_files) |locale, file| {
        const tag = @tagName(locale);
        const doc = try parse(@embedFile(file));
        defer doc.deinit();
        const numbers = get(doc.value, &.{ "main", tag, "numbers" });
        const system = get(numbers, &.{"defaultNumberingSystem"}).string;
        var key_buf: [64]u8 = undefined;
        const sym = get(numbers, &.{try std.fmt.bufPrint(&key_buf, "symbols-numberSystem-{s}", .{system})});
        const ours = number.symbols(locale);
        expectSame(file, "decimal", ours.decimal, get(sym, &.{"decimal"}).string);
        expectSame(file, "group", ours.group, get(sym, &.{"group"}).string);
        expectSame(file, "minusSign", ours.minus, get(sym, &.{"minusSign"}).string);
        var mg: [4]u8 = undefined;
        expectSame(file, "minimumGroupingDigits", try std.fmt.bufPrint(&mg, "{d}", .{ours.min_grouping}), get(numbers, &.{"minimumGroupingDigits"}).string);
        // format() groups by three only: the standard pattern must be "#,##0.###".
        var fmt_buf: [64]u8 = undefined;
        const pattern = get(numbers, &.{ try std.fmt.bufPrint(&fmt_buf, "decimalFormats-numberSystem-{s}", .{system}), "standard" }).string;
        expectSame(file, "decimalFormats standard (grouping)", "#,##0.###", pattern);
        const digits = get(systems.value, &.{ "supplemental", "numberingSystems", system, "_digits" }).string;
        var view = std.unicode.Utf8View.initUnchecked(digits).iterator();
        for (ours.digits, 0..) |d, k| {
            const want = view.nextCodepointSlice().?;
            var dk: [32]u8 = undefined;
            expectSame(file, try std.fmt.bufPrint(&dk, "digit {d} ({s})", .{ k, system }), d, want);
        }
    }
    try testing.expectEqual(0, mismatches);
}

// --- dates --------------------------------------------------------------------------------

test "date patterns and month names" {
    mismatches = 0;
    inline for (locales, gregorian_files) |locale, file| {
        const tag = @tagName(locale);
        const doc = try parse(@embedFile(file));
        defer doc.deinit();
        const greg = get(doc.value, &.{ "main", tag, "dates", "calendars", "gregorian" });
        expectSame(file, "dateFormats short", date.pattern(locale, .short), get(greg, &.{ "dateFormats", "short" }).string);
        expectSame(file, "dateFormats long", date.pattern(locale, .long), get(greg, &.{ "dateFormats", "long" }).string);
        const wide = get(greg, &.{ "months", "format", "wide" });
        for (date.months(locale), 1..) |name, m| {
            var mk: [8]u8 = undefined;
            const k = try std.fmt.bufPrint(&mk, "{d}", .{m});
            var key: [32]u8 = undefined;
            expectSame(file, try std.fmt.bufPrint(&key, "months format wide {s}", .{k}), name, get(wide, &.{k}).string);
        }
    }
    try testing.expectEqual(0, mismatches);
}
