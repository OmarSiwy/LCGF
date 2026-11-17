//! Branch-census probe for the interaction passes (docs/CHECKS.md section 2): one exported
//! function per pass, imported by src/census_probes.zig. Not exported from src/lcgf.zig.
const lcgf = @import("lcgf");
const Tree = lcgf.tree.Tree;
const Input = lcgf.input.Input;

export fn p_step(s: *lcgf.interaction.Interaction, prev: *const Tree, in: *const Input) void {
    s.step(prev, in);
}
export fn p_touch_step(s: *lcgf.interaction.Touches(10), prev: *const Tree, in: *const Input) void {
    s.step(prev, in);
}
export fn p_hit_layered(t: *const Tree, ly: *const lcgf.overlay.Layers, x: f32, y: f32) u32 {
    return lcgf.hit.atLayered(t, ly.c.layer, x, y, .any);
}
export fn p_focus_seek(t: *const Tree, cur: u32, back: bool) u32 {
    return lcgf.focus.seek(t, t.c.sense, 8, 0, t.len, cur, back);
}
export fn p_focus_scan(t: *const Tree, sc: *lcgf.focus.Scopes) void {
    lcgf.focus.scan(t, sc);
}
export fn p_shortcut_fire(sh: *const lcgf.keyboard.Shortcuts, k: *lcgf.keyboard.Keyboard, out: [*]u16) u32 {
    return lcgf.keyboard.fire(sh, k, out[0..16]);
}
export fn p_wheel_route(t: *const Tree, sc: *const lcgf.gestures.Scrollables, in: *const Input, out: *lcgf.gestures.Wheel) void {
    out.* = lcgf.gestures.route(t, sc, in, 16);
}
export fn p_kinetic_step(k: *lcgf.gestures.Kinetic, dt: f32) f32 {
    return k.step(dt);
}
export fn p_drop_step(d: *lcgf.gestures.DragDrop, it: *const lcgf.interaction.Interaction, prev: *const Tree, tg: *const lcgf.gestures.Targets, in: *const Input) void {
    d.step(it, prev, tg, in);
}
export fn p_files_route(fs: *const lcgf.gestures.Files, prev: *const Tree, tg: *const lcgf.gestures.Targets, out: *lcgf.gestures.FileDrop) void {
    out.* = fs.route(prev, tg, 4);
}
