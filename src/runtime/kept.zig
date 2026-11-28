//! kept: text runs laid out by a real font, kept for the widget that drew them. Tier 1.
//!
//! A run that wraps (`TextStyle.wrap`) is broken where layout's width falls, by the font that
//! measures it (the text protocol's wrap point, src/text/protocol.zig). A widget that edits
//! the text needs those lines too: its caret, clicks, selection and Up and Down follow them. With
//! `Mono` the widget breaks the bytes itself, as `Mono.wrap` does; with a shaper
//! (`text_stack.Stack`, `Frame.endText`) it asks for the run here (`Frame.keepText`), and at
//! the frame's end the stack lays the run out once more and leaves, under the widget's key, each
//! line's first byte and top and each byte's x. The next frame reads them (`Frame.keptRun`) while
//! the run's text is the same. A caret the widget asks for (`Frame.keepCaret`) is placed on the
//! run as laid out in the same frame, so it never lags a frame behind an edit.
//!
//! Caller-owned columns, carved once (`init`, sized by `requiredBytes`), handed to the context
//! (`Context.enableKept`). Runs, lines or bytes past them are not kept, and the widget falls
//! back to `Mono`'s lines for them.

const std = @import("std");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const text_stack = @import("../text/layout/stack.zig");
const query = @import("../text/layout/query.zig");

/// A frame's columns after layout, before finalizing: its runs (`tx`, their bytes in
/// `strings`), each tree row's run (`text_of`), and the tree's `pos` and `size`.
pub const Laid = struct {
    tx: *const Texts,
    strings: *const Strings,
    text_of: []const u32,
    pos: [2][]f32,
    size: [2][]f32,
};

pub const Kept = struct {
    /// Asked this frame: a key and the node of the run.
    ask_key: []u64,
    ask_node: []u32,
    ask_len: u32 = 0,
    /// A caret asked this frame: its node, on the run under `caret_key`, at byte `caret_at`.
    caret_node: u32 = types.none,
    caret_key: u64 = 0,
    caret_at: u32 = 0,
    /// Laid out at the end of the last frame: per run, its key, its text's hash, its height,
    /// and where its lines and bytes are in `starts`, `tops` and `xs`.
    key: []u64,
    hash: []u64,
    height: []f32,
    line_first: []u32,
    line_len: []u32,
    x_first: []u32,
    len: u32 = 0,
    starts: []u32,
    tops: []f32,
    /// Each line's right end, px from the run's left edge: its last stop's x.
    ends: []f32,
    lines: u32 = 0,
    /// The x of each byte offset of a run, px from its left edge, the end included: a byte
    /// inside a grapheme has the x of the grapheme's start.
    xs: []f32,
    bytes: u32 = 0,

    /// One kept run: its lines' first bytes and tops, px from the run's top, its height, and
    /// each byte offset's x (`xs.len` is its bytes plus one).
    pub const Run = struct {
        starts: []const u32,
        tops: []const f32,
        ends: []const f32,
        height: f32,
        xs: []const f32,
    };

    pub fn requiredBytes(runs: u32, lines: u32, bytes: u32) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = init(&counter, runs, lines, bytes);
        return counter.off;
    }

    pub fn init(carver: *mem.Carver, runs: u32, lines: u32, bytes: u32) Kept {
        std.debug.assert(runs > 0);
        return .{
            .ask_key = carver.slice(u64, runs),
            .ask_node = carver.slice(u32, runs),
            .key = carver.slice(u64, runs),
            .hash = carver.slice(u64, runs),
            .height = carver.slice(f32, runs),
            .line_first = carver.slice(u32, runs),
            .line_len = carver.slice(u32, runs),
            .x_first = carver.slice(u32, runs),
            .starts = carver.slice(u32, lines),
            .tops = carver.slice(f32, lines),
            .ends = carver.slice(f32, lines),
            .xs = carver.slice(f32, bytes),
        };
    }

    /// Asks for the run of `node` under `key`, laid out at this frame's end.
    pub fn ask(k: *Kept, key: u64, node: u32) void {
        if (k.ask_len == k.ask_key.len) return;
        k.ask_key[k.ask_len] = key;
        k.ask_node[k.ask_len] = node;
        k.ask_len += 1;
    }

    /// The run kept under `key` by the last frame, while its text was `text`.
    pub fn get(k: *const Kept, key: u64, text: []const u8) ?Run {
        const h = std.hash.Wyhash.hash(0, text);
        for (0..k.len) |i| {
            if (k.key[i] != key or k.hash[i] != h) continue;
            const l = k.line_first[i];
            const n = k.line_len[i];
            return .{
                .starts = k.starts[l..][0..n],
                .tops = k.tops[l..][0..n],
                .ends = k.ends[l..][0..n],
                .height = k.height[i],
                .xs = k.xs[k.x_first[i]..][0 .. text.len + 1],
            };
        }
        return null;
    }

    /// Lays out again, with `stack`, the runs asked this frame, keeps them for the next
    /// frame, and moves the caret asked for onto its run (`laid`'s columns).
    pub fn record(k: *Kept, stack: *text_stack.Stack, laid: Laid) void {
        const tx = laid.tx;
        const strings = laid.strings;
        const text_of = laid.text_of;
        const pos = laid.pos;
        const size = laid.size;
        std.debug.assert(k.ask_len <= k.ask_key.len);
        var len: u32 = 0;
        var lines: u32 = 0;
        var bytes: u32 = 0;
        defer k.ask_len = 0;
        defer k.caret_node = types.none;
        for (k.ask_key[0..k.ask_len], k.ask_node[0..k.ask_len]) |key, node| {
            const row = text_of[node];
            if (row == types.none or !stack.serves(tx, row)) continue;
            const width = text_stack.breakWidth(tx, row);
            stack.layoutAt(tx, strings, row, width) catch continue;
            if (stack.normalized) continue;
            const l = &stack.l;
            const text = stack.text;
            if (len == k.key.len or lines + l.len > k.starts.len) continue;
            if (bytes + text.len + 1 > k.xs.len) continue;
            const i = len;
            k.key[i] = key;
            k.hash[i] = std.hash.Wyhash.hash(0, text);
            k.height[i] = @import("../text/layout/lines.zig").stackHeight(l);
            k.line_first[i] = lines;
            k.line_len[i] = l.len;
            k.x_first[i] = bytes;
            const xs = k.xs[bytes..][0 .. text.len + 1];
            @memset(xs, std.math.nan(f32));
            for (0..l.len) |line| {
                k.starts[lines + line] = l.start[line];
                k.tops[lines + line] = l.top[line];
                var s: query.Stops = .init(l, &stack.g, text, @intCast(line));
                // A line's end is the next line's start: the next line, written after, wins.
                var end: f32 = 0;
                while (s.next()) |stop| {
                    xs[stop.offset] = stop.x;
                    end = stop.x;
                }
                k.ends[lines + line] = end;
            }
            // A byte inside a grapheme takes the x of the grapheme's start.
            var last: f32 = 0;
            for (xs) |*x| {
                if (std.math.isNan(x.*)) x.* = last else last = x.*;
            }
            len += 1;
            lines += l.len;
            bytes += @intCast(text.len + 1);
            if (k.caret_node != types.none and k.caret_key == key) {
                k.place(i, node, text.len, pos, size);
            }
        }
        k.len = len;
        k.lines = lines;
        k.bytes = bytes;
    }

    /// Moves the caret asked for onto kept run `i` (laid out at `node`): at its byte's x, on
    /// the line holding it, that line tall.
    fn place(k: *Kept, i: u32, node: u32, len: usize, pos: [2][]f32, size: [2][]f32) void {
        std.debug.assert(i < k.key.len);
        const r: Run = .{
            .starts = k.starts[k.line_first[i]..][0..k.line_len[i]],
            .tops = k.tops[k.line_first[i]..][0..k.line_len[i]],
            .ends = k.ends[k.line_first[i]..][0..k.line_len[i]],
            .height = k.height[i],
            .xs = k.xs[k.x_first[i]..][0 .. len + 1],
        };
        const at = @min(k.caret_at, @as(u32, @intCast(len)));
        const line = lineOf(r.starts, at);
        const c = k.caret_node;
        pos[0][c] = pos[0][node] + r.xs[at];
        pos[1][c] = pos[1][node] + r.tops[line];
        size[1][c] = lineHeight(r, line);
    }
};

/// The line of `starts` (each line's first byte, ascending) holding byte `at`: the last that
/// starts at or before it.
pub fn lineOf(starts: []const u32, at: u32) u32 {
    std.debug.assert(starts.len > 0);
    var n: u32 = 0;
    for (starts) |s| n += @intFromBool(s <= at);
    return @max(n, 1) - 1;
}

/// How tall line `line` of `r` is: to the next line's top, the last to the run's height.
pub fn lineHeight(r: Kept.Run, line: u32) f32 {
    std.debug.assert(line < r.tops.len);
    const bottom = if (line + 1 < r.tops.len) r.tops[line + 1] else r.height;
    return bottom - r.tops[line];
}

test "lineOf: the last line starting at or before a byte" {
    const starts = [_]u32{ 0, 5, 9 };
    try std.testing.expectEqual(@as(u32, 0), lineOf(&starts, 4));
    try std.testing.expectEqual(@as(u32, 1), lineOf(&starts, 5));
    try std.testing.expectEqual(@as(u32, 2), lineOf(&starts, 12));
}
