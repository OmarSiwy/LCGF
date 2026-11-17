//! Dashboard with charts as custom draws: the UI lays out the cards (a title, a figure, a
//! chart area) and reserves each chart's rect with `Frame.custom` (prototype/ui.zig
//! `Frame.custom`), passing the chart's index as `data`. The host gets the rects back in paint
//! order in the draw list and draws the charts itself (host.zig `draw` calls `drawCustom`), here
//! with plain fills into the software framebuffer; a GPU host would issue its own draws there.

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const sw = lcgf.render_sw;
const Frame = lcgf.frame.Frame;
const types = lcgf.types;
const Id = types.Id;
const Color = types.Color;
const Events = lcgf.shell_iface.Events;
const host = @import("host");

pub const days = 14;
pub const Chart = enum(u64) { bars, line };
pub const id_next = Id.from("next-day");
pub const ids = [_]Id{ .from("chart-bars"), .from("chart-line") };

pub const App = struct {
    theme: w.Theme = .default,
    /// Visits and sign-ups per day, oldest first; `Next day` shifts in a new day.
    visits: [days]f32 = .{ 120, 135, 128, 160, 172, 150, 190, 210, 205, 230, 220, 260, 250, 280 },
    signups: [days]f32 = .{ 12, 14, 11, 18, 20, 15, 22, 25, 24, 27, 26, 31, 29, 34 },
    day: u32 = days,
    /// Charts drawn by the host, over every frame.
    drawn: u32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        _ = f.open(.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
        if (w.button(f, th, id_next, "Next day").clicked) app.nextDay();
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Day {d}", .{app.day}) catch "?");
        f.close();

        _ = f.open(.from("cards"), .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(8), .gap = 8 });
        card(f, th, .bars, "Visits", app.visits[days - 1]);
        card(f, th, .line, "Sign-ups", app.signups[days - 1]);
        f.close();
    }

    fn card(f: *Frame, th: *const w.Theme, chart: Chart, title: []const u8, last: f32) void {
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 6, .fill = th.panel, .radius = th.radius });
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "{s}: {d:.0}", .{ title, last }) catch "?");
        _ = f.custom(ids[@backingInt(chart)], .{ .size = .{ .fill, .fill } }, @backingInt(chart));
        f.close();
    }

    fn nextDay(app: *App) void {
        app.day += 1;
        const d: f32 = @floatFromInt(app.day);
        std.mem.copyForwards(f32, app.visits[0 .. days - 1], app.visits[1..]);
        std.mem.copyForwards(f32, app.signups[0 .. days - 1], app.signups[1..]);
        app.visits[days - 1] = 200 + 80 * @sin(d * 0.7);
        app.signups[days - 1] = 20 + 10 * @sin(d * 0.5);
    }

    /// The host's side: draws chart `c.data` into `c.rect`.
    pub fn drawCustom(app: *App, fb: *sw.Framebuffer, c: *const host.CustomDraw) void {
        app.drawn += 1;
        // ponytail: scale 1; a HiDPI host passes its scale here.
        const b = host.box(c.rect, 1);
        fb.fill(b, bg);
        switch (@as(Chart, @fromBackingInt(@intCast(c.data)))) {
            .bars => bars(fb, b, &app.visits),
            .line => line(fb, b, &app.signups),
        }
    }
};

pub const bg: Color = .rgb(20, 22, 28);
pub const bar_color: Color = .rgb(90, 140, 255);
pub const line_color: Color = .rgb(120, 220, 140);

/// Bar heights relative to the largest value.
fn bars(fb: *sw.Framebuffer, b: [4]u32, v: *const [days]f32) void {
    const top = std.mem.max(f32, v);
    const slot = (b[2] - b[0]) / days;
    for (v, 0..) |x, i| {
        const h: u32 = @intFromFloat(x / top * @as(f32, @floatFromInt(b[3] - b[1])));
        const x0 = b[0] + @as(u32, @intCast(i)) * slot;
        fb.fill(.{ x0 + 2, b[3] - h, x0 + slot - 2, b[3] }, bar_color);
    }
}

/// A 3-pixel line through the points, one column of pixels at a time.
fn line(fb: *sw.Framebuffer, b: [4]u32, v: *const [days]f32) void {
    const top = std.mem.max(f32, v);
    const width = b[2] - b[0];
    const height: f32 = @floatFromInt(b[3] - b[1] - 4);
    for (0..width) |x| {
        const t = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width)) * (days - 1);
        const i: usize = @intFromFloat(@floor(t));
        const k = @min(i + 1, days - 1);
        const y = std.math.lerp(v[i], v[k], t - @floor(t)) / top * height;
        const py = b[3] - 2 - @as(u32, @intFromFloat(y));
        const px = b[0] + @as(u32, @intCast(x));
        fb.fill(.{ px, py - 1, px + 1, py + 2 }, line_color);
    }
}

const testing = std.testing;

test "dashboard: the charts come back as custom rects and the host draws them" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    try testing.expectEqual(@as(u32, 2), s.out.?.draw.custom_len);
    try testing.expectEqual(@as(u32, 2), app.drawn);
    // The newest (tallest) visits bar reaches the top of its chart; the line chart has the line.
    const r = s.rect(ids[0]);
    const last_bar_x: u32 = @intFromFloat(r.x1 - (r.x1 - r.x0) / days / 2);
    try testing.expectEqual(bar_color, s.at(last_bar_x, @intFromFloat(r.y0 + 1)));
    try testing.expectEqual(bg, s.at(@intFromFloat(r.x0 + 4), @intFromFloat(r.y0 + 1)));
    const l = s.rect(ids[1]);
    var found = false;
    for (@intFromFloat(l.y0)..@intFromFloat(l.y1)) |y| found = found or std.meta.eql(s.at(@intFromFloat(l.x0 + 10), @intCast(y)), line_color);
    try testing.expect(found);

    // Next day: new data, the charts are drawn again.
    var rec: [256]u8 = undefined;
    app = .{};
    s = try host.Smoke.run(&app, try host.clicks(&rec, &.{host.center(s.rect(id_next))}));
    try testing.expectEqual(@as(u32, days + 1), app.day);
    try testing.expectEqual(2 * s.builds, app.drawn);
}
