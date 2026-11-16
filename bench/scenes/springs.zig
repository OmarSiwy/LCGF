//! Animation: 1,000 springs (`Frame.animate`, stepped together by `Anims.step` in `begin`), one
//! per bar of a 40 x 25 grid. Every 30 frames each bar's target width flips between 4 and 40 px.
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "springs", .frames = 3000, .input = input, .build = build, .every = true };

const grid_rows = 40;
const grid_cols = 25;
/// Frame number, set by `input` for the frame `build` makes.
var tick: u32 = 0;

fn input(in: *ui.Input, k: u32) void {
    in.viewport = .{ 1280, 800 };
    in.dt = 1.0 / 60.0;
    tick = k;
}

fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const base = ui.Id.from("springs");
    const targets = [2]f32{ 4, 40 };
    _ = f.open(base, .{ .size = .{ .fill, .fill }, .gap = 2, .pad = @splat(8) });
    for (0..grid_rows) |r| {
        _ = f.open(.none, .{ .dir = .x, .gap = 2 });
        for (0..grid_cols) |c| {
            const i: u32 = @intCast(r * grid_cols + c);
            const w = f.animate(base.with(i), targets[(tick / 30 + i) % 2], .{});
            _ = f.leaf(.none, .{ .size = .{ .px(w), .px(16) }, .fill = th.accent });
        }
        f.close();
    }
    f.close();
}
