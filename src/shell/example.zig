//! The prototype's example UI (prototype/example.zig `buildUi`, `frame`) as an application the
//! shells run: toolbar on top, sidebar left, a custom viewport filling the rest. Built only from
//! the public widgets (src/widgets/base.zig), without the prototype's spring (`animate`, anim
//! lane) and sidebar reuse (`reuse`, reuse lane), as the runtime's host-loop test does; neither
//! changes the frames the shell tests check.

const std = @import("std");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const w = @import("../widgets/base.zig");
const Events = @import("iface.zig").Events;
const Tree = @import("../core/tree.zig").Tree;
const a11y = @import("../a11y/tree.zig");
const slider = @import("../widgets/slider.zig");

pub const id_reset = types.Id.from("reset");
pub const id_wire = types.Id.from("wireframe");
pub const id_exposure = types.Id.from("exposure");
pub const id_sidebar = types.Id.from("sidebar");
pub const id_add = types.Id.from("add-layer");
pub const id_viewport = types.Id.from("viewport");

const exposure_lo = 0;
const exposure_hi = 4;

pub const App = struct {
    theme: w.Theme = .default,
    resets: u32 = 0,
    exposure: f32 = 1,
    wireframe: bool = false,
    layers: u32 = 3,
    /// Frames built, so a test can tell an idle frame (not built) from a built one.
    builds: u32 = 0,

    /// The whole UI. Runs top to bottom every frame; nothing calls back into it.
    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        app.builds += 1;
        const th = &app.theme;
        _ = f.open(.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
        if (w.button(f, th, id_reset, "Reset").clicked) {
            app.resets += 1;
            app.exposure = 1;
        }
        _ = w.checkbox(f, th, id_wire, &app.wireframe, "Wireframe");
        _ = w.slider(f, th, id_exposure, &app.exposure, exposure_lo, exposure_hi);
        f.close();

        _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        _ = f.open(id_sidebar, .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4, .fill = th.panel });
        if (w.button(f, th, id_add, "Add layer").clicked) app.layers += 1;
        var name: [24]u8 = undefined;
        for (0..app.layers) |i| _ = w.label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
        f.close();
        // The 3D view. The UI only reserves the rect; the host draws into it.
        _ = f.custom(id_viewport, .{ .size = .{ .fill, .fill } }, 0);
        f.close();
    }

    /// What the tree `build` made does not say to assistive technology: the exposure slider's
    /// range. A host with an accessibility bridge calls it after each built frame.
    pub fn semantics(_: *const App, t: *const Tree, s: *a11y.Semantics) void {
        slider.semantics(t, s, id_exposure, exposure_lo, exposure_hi);
    }
};

pub fn center(r: types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}
