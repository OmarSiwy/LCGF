//! List with 100,000 rows: the virtual list (src/widgets/vlist.zig) over 100,000 options, of
//! which only the rows on screen are built each frame, so the frame costs the same as a list of
//! twenty. The options are the application's: one slice per row into one block of bytes,
//! filled once on the first frame.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const w = lcgf.widgets_base;
const vlist = lcgf.widgets_vlist;
const Frame = lcgf.frame.Frame;
const types = lcgf.types;
const Id = types.Id;
const Events = lcgf.shell_iface.Events;

pub const rows = 100_000;
pub const visible = 20;
pub const id_list = Id.from("rows");

/// "Row 0" to "Row 99999", back to back, and a slice per row.
var name_bytes: [rows * "Row 99999".len]u8 = undefined;
var names: [rows][]const u8 = undefined;

pub const App = struct {
    theme: w.Theme = .default,
    ready: bool = false,
    selected: u32 = types.none,
    scroll: f32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        if (!app.ready) {
            var at: usize = 0;
            for (&names, 0..) |*n, i| {
                n.* = std.fmt.bufPrint(name_bytes[at..], "Row {d}", .{i}) catch unreachable;
                at += n.len;
            }
            app.ready = true;
        }
        _ = f.open(.from("page"), .{ .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel });
        var buf: [48]u8 = undefined;
        const sel = if (app.selected == types.none) "Nothing selected" else std.fmt.bufPrint(&buf, "Selected: {s}", .{names[app.selected]}) catch "?";
        _ = w.label(f, th, sel);
        _ = vlist.vlist(f, th, id_list, &names, visible, &app.selected, &app.scroll);
        f.close();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "List" });
}

const testing = std.testing;
const replay = lcgf_app.replay;

test "list: 100,000 rows build only the rows on screen; scroll and select far down" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const r = s.rect(id_list);
    // A frame of the whole page: the list's 21 rows (two nodes each), not 100,000.
    try testing.expect(s.out.?.tree.len < 3 * vlist.capacity(visible) + 8);

    // Over the list, scroll 50,000 rows down with the wheel, then click its first row.
    var rec: [256]u8 = undefined;
    const p = replay.center(r);
    const top = r.y0 + 10;
    const recording = try std.fmt.bufPrint(&rec, "frame\nviewport 800 600\nframe\npointer {d} {d}\nframe\nwheel 0 50000\nframe\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\nframe\n", .{ p[0], p[1], p[0], top });
    app = .{};
    s = try replay.run(&app, recording);
    try testing.expectEqual(@as(u32, 50_000), app.selected);
    try testing.expect(s.out.?.tree.len < 3 * vlist.capacity(visible) + 8);
    try testing.expectEqualStrings("Row 50000", names[app.selected]);
}
