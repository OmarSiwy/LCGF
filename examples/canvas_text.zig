//! A canvas label through the example host: its glyphs sample the bundled font, as text runs
//! do, so they draw as letters and not as boxes of the layer's colour.
const std = @import("std");
const lcgf = @import("lcgf");
const host = @import("host");
const canvas = lcgf.canvas;
const Frame = lcgf.frame.Frame;
const Events = host.Events;

const px = 16;
const text = "AB";
/// Where the canvas label and the same text as a text run are drawn, side by side.
const label_at = [2]f32{ 100, 100 };
const run_at = [2]f32{ 300, 100 };

const App = struct {
    rows: [2 * 64]lcgf.draw_list.CanvasDraw = undefined,
    buf: [canvas.Instances.requiredBytes(8, 0, 1, .{})]u8 align(lcgf.mem.column_align) = undefined,
    shapes: canvas.Instances = undefined,
    ready: bool = false,
    layers: [1]canvas.Layer = .{.of(.{ .stroke = .white })},
    // The canvas command reads these when the host draws, after `build`: the app's, not temporaries.
    palette: canvas.Palette = undefined,
    ranges: [1]canvas.Range = undefined,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        if (!app.ready) {
            f.ctx.enableCanvas(&app.rows);
            var carver: lcgf.mem.Carver = .{ .buf = &app.buf };
            app.shapes = .init(&carver, 8, 0, 1, .{});
            app.ranges = .{app.shapes.glyphs(text, .{ 0, 0 }, .{ .px = px, .atlas = host.font.cells })};
            app.palette = .{ .layers = &app.layers };
            app.ready = true;
        }
        _ = f.open(.none, .{ .size = .{ .fill, .fill } });
        _ = f.canvas(.from("label"), .{ .float = true, .offset = label_at, .size = .{ .px(100), .px(40) } }, &app.shapes, .{
            .palette = &app.palette,
            .ranges = &app.ranges,
        });
        _ = f.textStyled(text, .{ .px = px, .color = .white }, .{ .float = true, .offset = run_at });
        f.close();
    }
};

/// Lit pixels in the cell box of the text's `k`th glyph at `at`.
fn lit(s: *const host.Smoke, at: [2]f32, k: u32) u32 {
    const w: u32 = @intFromFloat(@round(px * 0.6));
    const h: u32 = @intFromFloat(@round(px * 1.25));
    const x0: u32 = @as(u32, @intFromFloat(at[0])) + k * w;
    const y0: u32 = @intFromFloat(at[1]);
    var n: u32 = 0;
    for (y0..y0 + h) |y| for (x0..x0 + w) |x| {
        n += @intFromBool(s.at(@intCast(x), @intCast(y)).r > 128);
    };
    return n;
}

/// Pixels of glyph `k` whose coverage differs by more than a quarter between the canvas label
/// and the text run.
fn differ(s: *const host.Smoke, k: u32) u32 {
    const w: u32 = @intFromFloat(@round(px * 0.6));
    const h: u32 = @intFromFloat(@round(px * 1.25));
    var n: u32 = 0;
    for (0..h) |y| for (0..w) |x| {
        const a = s.at(@as(u32, @intFromFloat(label_at[0])) + k * w + @as(u32, @intCast(x)), @as(u32, @intFromFloat(label_at[1])) + @as(u32, @intCast(y)));
        const b = s.at(@as(u32, @intFromFloat(run_at[0])) + k * w + @as(u32, @intCast(x)), @as(u32, @intFromFloat(run_at[1])) + @as(u32, @intCast(y)));
        n += @intFromBool(@abs(@as(i32, a.r) - @as(i32, b.r)) > 64);
    };
    return n;
}

test "canvas text: glyphs sample the font and look like the same text run" {
    var app: App = .{};
    const s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const cell: u32 = @intFromFloat(@round(px * 0.6) * @round(px * 1.25));
    for (0..text.len) |k| {
        const from_canvas = lit(&s, label_at, @intCast(k));
        const from_run = lit(&s, run_at, @intCast(k));
        // A glyph covers part of its cell; a box would cover all of it.
        try std.testing.expect(from_canvas > cell / 10 and from_canvas < cell / 2);
        // The same letter in the same font: about the same ink as the text run's.
        try std.testing.expect(@abs(@as(i32, @intCast(from_canvas)) - @as(i32, @intCast(from_run))) * 5 < from_run);
        // Pixel for pixel nearly the run's: the same cell of the same atlas. The 16 x 16 byte
        // grid on the bundled 16 x 6 font picks other cells: 60 of 200 pixels differ.
        try std.testing.expect(differ(&s, @intCast(k)) * 6 < cell);
    }
}
