//! Data: the shape of Schemify's UI. A 450-node editor of 25 widget kinds in a dock
//! (lcgf.widgets_records.scene) is walked from its node table every frame, each node's look taken
//! from a table of looks derived from the theme that frame, in a 1280 x 800 window with the
//! pointer moving across it. `data-idle` polls the same page with input that never changes: at
//! most the first and the settle frame are built. `mixed` builds a comptime page (a toolbar over
//! a region, `ComptimeUi`) and the same editor in its region at run time each frame, as
//! Schemify's compiled pages host their runtime parts; the comptime frame is part of `build`.
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;
const records = ui.records;
const s = ui.spec;
const w = ui.widgets;

pub const scene: Scene = .{ .name = "data", .frames = 3000, .input = input, .build = build };
pub const idle: Scene = .{ .name = "data-idle", .frames = 3000, .input = still, .build = build, .idle = true };
pub const mixed: Scene = .{ .name = "mixed", .frames = 3000, .input = input, .build = buildMixed };

var state: records.SceneState(records.scene.kind.len) = .{};

fn input(in: *ui.Input, k: u32) void {
    in.viewport = .{ 1280, 800 };
    in.pointer = .{ @floatFromInt(20 + (k * 7) % 1240), @floatFromInt(20 + (k * 13) % 760) };
}

/// The pointer rests on the status bar, over no widget: over one, the hover delay would ask for
/// one more frame (hover intent), as it should.
fn still(in: *ui.Input, k: u32) void {
    _ = k;
    in.viewport = .{ 1280, 800 };
    in.pointer = .{ 1279, 799 };
}

pub fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const looks = records.kindLooks(th);
    records.build(f, th, .from("page"), records.scene, &looks, state.state());
}

// ---- mixed: the editor in a region of a comptime page ------------------------------------------

const th_default: ui.Theme = .default;
const Host = struct {
    run_text: []const u8 = "Run",
    live: bool = false,
    live_text: []const u8 = "Live",
    level: f32 = 0.5,
};
/// The region fills the window, so its input is the window's (`regionInput` is the identity)
/// and the scene's frame is the region's; the toolbar floats over it.
const page = s.col(.{ .size = .{ .fill, .fill } }, .{
    ui.ct_interop.region(.editor, .{ .size = .{ .fill, .fill } }),
    s.row(.{ .float = true, .size = .{ .fit, .fit }, .pad = @splat(4), .gap = 6, .cross = .center, .fill = th_default.panel }, .{
        w.ct.button(th_default, .run, .run_text),
        w.ct.checkbox(th_default, .live_box, .live, .live_text),
        w.ct.slider(th_default, .level, .level),
    }),
});
var host: w.ComptimeUi(Host, page, th_default) = .{};

fn buildMixed(f: *ui.Frame, th: *const ui.Theme) void {
    _ = host.frame(f.in);
    build(f, th);
}
