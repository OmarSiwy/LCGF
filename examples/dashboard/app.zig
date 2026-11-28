//! Dashboard with charts on a canvas: the UI lays out the cards (a title, a figure, a chart)
//! and each chart is a `Frame.canvas` node, bars and a line in LCGF's own 2D primitives
//! (src/draw/canvas.zig), which every back end draws, software included. The rows are written
//! once per day of data, not once per frame: `Next day` shifts in a new day and rewrites them.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const w = lcgf.widgets_base;
const canvas = lcgf.canvas;
const Frame = lcgf.frame.Frame;
const types = lcgf.types;
const Id = types.Id;
const Color = types.Color;
const Events = lcgf.shell_iface.Events;

pub const days = 14;
pub const Chart = enum(u8) { bars, line };
pub const id_next = Id.from("next-day");
pub const ids = [_]Id{ .from("chart-bars"), .from("chart-line") };
/// A chart's size: logical pixels, and the canvas's world units (the camera's scale is 1).
pub const chart_size = [2]i32{ 340, 200 };

pub const bg: Color = .rgb(20, 22, 28);
pub const bar_color: Color = .rgb(90, 140, 255);
pub const line_color: Color = .rgb(120, 220, 140);

/// Rows for the bars and the line's segments.
const rows = 2 * days;

pub const App = struct {
    theme: w.Theme = .default,
    /// Visits and sign-ups per day, oldest first; `Next day` shifts in a new day.
    visits: [days]f32 = .{ 120, 135, 128, 160, 172, 150, 190, 210, 205, 230, 220, 260, 250, 280 },
    signups: [days]f32 = .{ 12, 14, 11, 18, 20, 15, 22, 25, 24, 27, 26, 31, 29, 34 },
    day: u32 = days,
    /// Both charts' rows, and the range of each.
    buf: [canvas.Instances.requiredBytes(rows, 0, 1, .{})]u8 align(lcgf.mem.column_align) = undefined,
    shapes: canvas.Instances = undefined,
    ranges: [2][1]canvas.Range = undefined,
    /// The day the rows were written for; 0 before the first.
    charted: u32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        _ = f.open(.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
        if (w.button(f, th, id_next, "Next day").clicked) app.nextDay();
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Day {d}", .{app.day}) catch "?");
        f.close();

        if (app.charted != app.day) app.writeCharts();
        _ = f.open(.from("cards"), .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(8), .gap = 8 });
        app.card(f, .bars, "Visits", app.visits[days - 1]);
        app.card(f, .line, "Sign-ups", app.signups[days - 1]);
        f.close();
    }

    fn card(app: *const App, f: *Frame, chart: Chart, title: []const u8, last: f32) void {
        const th = &app.theme;
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 6, .fill = th.panel, .radius = th.radius });
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "{s}: {d:.0}", .{ title, last }) catch "?");
        const k = @backingInt(chart);
        const size: types.Style = .{ .size = .{ .px(chart_size[0]), .px(chart_size[1]) }, .fill = bg };
        _ = f.canvas(ids[k], size, &app.shapes, .{ .ranges = &app.ranges[k] });
        f.close();
    }

    /// Writes both charts' rows from the data: a bar per day, its height relative to the
    /// largest, and a 3-unit line through the sign-ups.
    fn writeCharts(app: *App) void {
        if (app.charted == 0) {
            var carver: lcgf.mem.Carver = .{ .buf = &app.buf };
            app.shapes = .init(&carver, rows, 0, 1, .{});
        }
        app.shapes.reset();
        const top = std.mem.max(f32, &app.visits);
        const slot = @divTrunc(chart_size[0], days);
        for (app.visits, 0..) |v, i| {
            const x0 = @as(i32, @intCast(i)) * slot;
            const h: i32 = @intFromFloat(v / top * @as(f32, @floatFromInt(chart_size[1])));
            _ = app.shapes.rect(.{ x0 + 2, chart_size[1] - h }, .{ x0 + slot - 2, chart_size[1] }, .{ .color = bar_color, .stroke = false });
        }
        app.ranges[0] = .{app.shapes.since(0)};
        const first = app.shapes.len;
        const high = std.mem.max(f32, &app.signups);
        var points: [days][2]i32 = undefined;
        for (&points, app.signups, 0..) |*p, v, i| p.* = .{
            @divTrunc(@as(i32, @intCast(i)) * (chart_size[0] - 1), days - 1),
            chart_size[1] - 2 - @as(i32, @intFromFloat(v / high * @as(f32, @floatFromInt(chart_size[1] - 4)))),
        };
        _ = app.shapes.polyline(&points, .{ .color = line_color, .cap = .round, .width = 3 });
        app.ranges[1] = .{app.shapes.since(first)};
        app.charted = app.day;
    }

    fn nextDay(app: *App) void {
        app.day += 1;
        const d: f32 = @floatFromInt(app.day);
        std.mem.copyForwards(f32, app.visits[0 .. days - 1], app.visits[1..]);
        std.mem.copyForwards(f32, app.signups[0 .. days - 1], app.signups[1..]);
        app.visits[days - 1] = 200 + 80 * @sin(d * 0.7);
        app.signups[days - 1] = 20 + 10 * @sin(d * 0.5);
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "Dashboard" });
}

const testing = std.testing;
const replay = @import("lcgf_replay");

test "dashboard: the charts are canvases, drawn from the data, again on Next day" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    var canvases: u32 = 0;
    const d = s.out.?.draw;
    for (d.cmd.kind[0..d.cmd_len]) |k| canvases += @intFromBool(k == @backingInt(lcgf.draw_list.DrawList.Kind.canvas));
    try testing.expectEqual(@as(u32, 2), canvases);
    // The newest (tallest) visits bar reaches the top of its chart; left of the first bar is
    // the chart's background; the line chart has the line.
    const r = s.rect(ids[0]);
    const slot: f32 = @floatFromInt(@divTrunc(chart_size[0], days));
    try testing.expectEqual(bar_color, s.at(@intFromFloat(r.x0 + slot * (days - 0.5)), @intFromFloat(r.y0 + 1)));
    try testing.expectEqual(bg, s.at(@intFromFloat(r.x0 + 1), @intFromFloat(r.y0 + 1)));
    const l = s.rect(ids[1]);
    var found = false;
    for (@intFromFloat(l.y0)..@intFromFloat(l.y1)) |y| found = found or std.meta.eql(s.at(@intFromFloat(l.x0 + 10), @intCast(y)), line_color);
    try testing.expect(found);
    const revision = app.shapes.revision;

    // Next day: new data, new rows.
    var rec: [256]u8 = undefined;
    app = .{};
    s = try replay.run(&app, try replay.clicks(&rec, &.{replay.center(s.rect(id_next))}));
    try testing.expectEqual(@as(u32, days + 1), app.day);
    try testing.expectEqual(app.day, app.charted);
    try testing.expect(app.shapes.revision > revision);
}
