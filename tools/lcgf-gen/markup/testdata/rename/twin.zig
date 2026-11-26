//! rename, written by hand: a one-way text field per item. The region keeps one editor, for the
//! row being edited; typing reports on:change (index, text), Enter on:submit (index), and the
//! const items are never written.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    lcgf.ct_interop.region(.each_rows, .{ .size = .{ .px(400), .px(200) }, .gap = 4 }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        text: [32]u8 = undefined,
        len: usize = 0,
        changed_at: ?u32 = null,
        submitted: ?u32 = null,

        pub fn renamed(h: *@This(), _: *Ui, index: u32, text: []const u8) void {
            h.changed_at = index;
            @memcpy(h.text[0..text.len], text);
            h.len = text.len;
        }
        pub fn done(h: *@This(), _: *Ui, index: u32) void {
            h.submitted = index;
        }
    };
}

const Row = struct { name: []const u8 };
const Event = lcgf.input.Input.Event;

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

/// Focus row 2's field, type "x": on:change (1, "twox"); Enter: on:submit (1); data unchanged.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const rows: []const Row = &.{ .{ .name = "one" }, .{ .name = "two" } };
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, .{ .rows = rows });
    const two = runOf(out.draw, "two").?;
    in.pointer = .{ (two[0] + two[2]) / 2, (two[1] + two[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in, .{ .rows = rows });
    in.buttons.left = false;
    _ = p.frame(h, &in, .{ .rows = rows });
    try std.testing.expectEqual(@as(?u32, null), h.changed_at);
    // Typing goes to the end of the text (the editor was seeded from the item).
    const end_key = [_]Event{.{ .kind = .press, .code = 0x4d }};
    in.events = &end_key;
    _ = p.frame(h, &in, .{ .rows = rows });
    const typed = [_]Event{.{ .kind = .text, .at = 0, .len = 1 }};
    in.events = &typed;
    in.text = "x";
    _ = p.frame(h, &in, .{ .rows = rows });
    in.text = "";
    in.events = &.{};
    try std.testing.expectEqual(@as(?u32, 1), h.changed_at);
    try std.testing.expectEqualStrings("twox", h.text[0..h.len]);
    try std.testing.expectEqualStrings("two", rows[1].name);
    const enter = [_]Event{.{ .kind = .press, .code = 0x28 }};
    in.events = &enter;
    _ = p.frame(h, &in, .{ .rows = rows });
    try std.testing.expectEqual(@as(?u32, 1), h.submitted);
}
