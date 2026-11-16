//! Undo and redo: a history of edits in columns and bytes the caller owns. Tier 0.
//!
//! One row per edit (an insert or a delete at a byte offset), with the bytes it inserted or
//! removed kept back to back in `bytes`. Rows with the same `group` are one step: a run of
//! typing, a run of Backspace, or a selection replaced by what was typed over it. `undo`
//! reverts the last step's rows newest first, `redo` applies them again oldest first, and a
//! new edit after an undo drops what could have been redone. When the rows or the bytes run
//! out, the oldest steps are dropped (a copy of the rest down to the front).

const std = @import("std");
const mem = @import("../../core/mem.zig");
const Buffer = @import("buffer.zig").Buffer;

pub const History = struct {
    c: Columns = .{ .kind = &.{}, .at = &.{}, .len = &.{}, .from = &.{}, .group = &.{}, .caret = &.{}, .anchor = &.{} },
    /// The text of every row: row `i`'s is `bytes[from[i]..][0..len[i]]`.
    bytes: []u8 = &.{},
    /// Rows kept.
    len: u32 = 0,
    /// Rows applied: `[top, len)` can be redone.
    top: u32 = 0,
    next_group: u32 = 0,

    pub const Kind = enum(u8) { insert, delete };

    pub const Columns = struct {
        kind: []Kind,
        /// Byte offset of the edit in the text.
        at: []u32,
        /// Bytes inserted or removed.
        len: []u32,
        /// Where they are kept in `bytes`.
        from: []u32,
        group: []u32,
        /// The caret and anchor before the edit, restored by undoing its step.
        caret: []u32,
        anchor: []u32,
    };

    /// A history of up to `rows` edits keeping up to `cap` bytes of their text. With 0 rows
    /// (the default value) nothing is recorded and nothing can be undone.
    pub fn init(carver: *mem.Carver, rows: u32, cap: u32) History {
        return .{ .c = carver.columns(Columns, rows), .bytes = carver.slice(u8, cap) };
    }

    fn used(h: *const History, n: u32) u32 {
        return if (n == 0) 0 else h.c.from[n - 1] + h.c.len[n - 1];
    }

    /// Records an edit of `n` bytes at `at`, made with the caret and anchor at `caret` and
    /// `anchor`, in the step of the previous row when `join`. Returns where the caller copies
    /// the edit's bytes (before a delete removes them), or null when the edit cannot be kept:
    /// then the history is cleared, since older steps would no longer undo correctly.
    pub fn push(h: *History, kind: Kind, at: u32, n: u32, caret: u32, anchor: u32, join: bool) ?[]u8 {
        h.len = h.top;
        if (h.c.at.len == 0 or n > h.bytes.len) {
            h.clear();
            return null;
        }
        var keep = join and h.len > 0;
        while (h.len == h.c.at.len or h.used(h.len) + n > h.bytes.len) {
            keep = keep and h.c.group[0] != h.c.group[h.len - 1];
            h.dropOldest();
        }
        const g = if (keep) h.c.group[h.len - 1] else blk: {
            h.next_group +%= 1;
            break :blk h.next_group;
        };
        const i = h.len;
        const from = h.used(i);
        h.c.kind[i] = kind;
        h.c.at[i] = at;
        h.c.len[i] = n;
        h.c.from[i] = from;
        h.c.group[i] = g;
        h.c.caret[i] = caret;
        h.c.anchor[i] = anchor;
        h.len += 1;
        h.top = h.len;
        return h.bytes[from..][0..n];
    }

    /// Drops the oldest step's rows and bytes.
    fn dropOldest(h: *History) void {
        const c = &h.c;
        var k: u32 = 0;
        while (k < h.len and c.group[k] == c.group[0]) k += 1;
        const shift = if (k < h.len) c.from[k] else h.used(h.len);
        const end = h.used(h.len);
        std.mem.copyForwards(u8, h.bytes[0 .. end - shift], h.bytes[shift..end]);
        // The ranges overlap, so not `mem.copyRows`.
        inline for (@typeInfo(Columns).@"struct".field_names) |name| {
            const col = @field(c, name);
            std.mem.copyForwards(@TypeOf(col[0]), col[0 .. h.len - k], col[k..h.len]);
        }
        for (c.from[0 .. h.len - k]) |*f| f.* -= shift;
        h.len -= k;
        h.top -|= k;
    }

    pub fn clear(h: *History) void {
        h.len = 0;
        h.top = 0;
    }

    /// The caret and anchor a step leaves.
    pub const Selection = struct { caret: u32, anchor: u32 };

    /// Reverts the last applied step in `b`. Returns the caret and anchor from before it, or
    /// null when there is nothing to undo.
    pub fn undo(h: *History, b: *Buffer) ?Selection {
        if (h.top == 0) return null;
        const c = &h.c;
        const g = c.group[h.top - 1];
        var i = h.top;
        while (i > 0 and c.group[i - 1] == g) {
            i -= 1;
            switch (c.kind[i]) {
                .insert => b.delete(c.at[i], c.at[i] + c.len[i]),
                // The text is back to how it was before row `i`, so its bytes fit again.
                .delete => b.insert(c.at[i], h.bytes[c.from[i]..][0..c.len[i]]) catch unreachable,
            }
        }
        h.top = i;
        return .{ .caret = c.caret[i], .anchor = c.anchor[i] };
    }

    /// Applies the next undone step again. Returns the caret after it (with nothing selected),
    /// or null when there is nothing to redo.
    pub fn redo(h: *History, b: *Buffer) ?Selection {
        if (h.top == h.len) return null;
        const c = &h.c;
        const g = c.group[h.top];
        var after: u32 = 0;
        while (h.top < h.len and c.group[h.top] == g) : (h.top += 1) {
            const i = h.top;
            switch (c.kind[i]) {
                .insert => {
                    b.insert(c.at[i], h.bytes[c.from[i]..][0..c.len[i]]) catch unreachable;
                    after = c.at[i] + c.len[i];
                },
                .delete => {
                    b.delete(c.at[i], c.at[i] + c.len[i]);
                    after = c.at[i];
                },
            }
        }
        return .{ .caret = after, .anchor = after };
    }
};

const testing = std.testing;

fn edit(h: *History, b: *Buffer, kind: History.Kind, at: u32, bytes: []const u8, join: bool) !void {
    const n: u32 = @intCast(bytes.len);
    const dst = h.push(kind, at, n, at, at, join);
    switch (kind) {
        .insert => {
            if (dst) |d| @memcpy(d, bytes);
            try b.insert(at, bytes);
        },
        .delete => {
            if (dst) |d| _ = b.copy(at, at + n, d);
            b.delete(at, at + n);
        },
    }
}

test "undo and redo steps, and a new edit drops the redo" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var h = History.init(&carver, 8, 64);
    var tb: [32]u8 = undefined;
    var b = try Buffer.init(&tb, "");
    try edit(&h, &b, .insert, 0, "ab", false);
    try edit(&h, &b, .insert, 2, "cd", true); // same step
    try edit(&h, &b, .delete, 1, "bc", false);
    try testing.expectEqualStrings("ad", b.text());
    try testing.expectEqual(History.Selection{ .caret = 1, .anchor = 1 }, h.undo(&b).?);
    try testing.expectEqualStrings("abcd", b.text());
    try testing.expectEqual(History.Selection{ .caret = 0, .anchor = 0 }, h.undo(&b).?);
    try testing.expectEqualStrings("", b.text());
    try testing.expectEqual(null, h.undo(&b));
    try testing.expectEqual(History.Selection{ .caret = 4, .anchor = 4 }, h.redo(&b).?);
    try testing.expectEqualStrings("abcd", b.text());
    try edit(&h, &b, .insert, 4, "!", false);
    try testing.expectEqual(null, h.redo(&b));
    _ = h.undo(&b);
    _ = h.undo(&b);
    try testing.expectEqualStrings("", b.text());
}

test "full history drops the oldest steps; an edit too long to keep clears it" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var h = History.init(&carver, 3, 4);
    var tb: [32]u8 = undefined;
    var b = try Buffer.init(&tb, "");
    try edit(&h, &b, .insert, 0, "a", false);
    try edit(&h, &b, .insert, 1, "b", false);
    try edit(&h, &b, .insert, 2, "c", false);
    try edit(&h, &b, .insert, 3, "de", false); // a fourth row: "a" goes, and 4 bytes fit
    try testing.expectEqual(3, h.len);
    try testing.expectEqualSlices(u8, "bcde", h.bytes[0..4]);
    for (0..3) |_| _ = h.undo(&b);
    try testing.expectEqual(null, h.undo(&b));
    try testing.expectEqualStrings("a", b.text());
    _ = h.redo(&b);
    try edit(&h, &b, .insert, 2, "wxyz", false); // 1 + 4 bytes: "b" goes for the bytes
    try testing.expectEqual(1, h.len);
    try testing.expectEqualStrings("abwxyz", b.text());
    _ = h.undo(&b);
    try testing.expectEqual(null, h.undo(&b));
    try testing.expectEqualStrings("ab", b.text());
    try edit(&h, &b, .insert, 2, "12345", false);
    try testing.expectEqual(0, h.len);
    try testing.expectEqual(null, h.undo(&b));
    // No rows at all: nothing is recorded.
    var none: History = .{};
    try testing.expectEqual(null, none.push(.insert, 0, 1, 0, 0, false));
}
