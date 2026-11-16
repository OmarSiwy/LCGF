//! Branch-census probe for the interaction passes (docs/CHECKS.md section 2): one exported
//! function per pass, imported by src/census_probes.zig. Not exported from src/lcgr.zig.
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const Input = lcgr.input.Input;

export fn p_step(s: *lcgr.interaction.Interaction, prev: *const Tree, in: *const Input) void {
    s.step(prev, in);
}
export fn p_touch_step(s: *lcgr.interaction.Touches(10), prev: *const Tree, in: *const Input) void {
    s.step(prev, in);
}
export fn p_hit_layered(t: *const Tree, ly: *const lcgr.overlay.Layers, x: f32, y: f32) u32 {
    return lcgr.hit.atLayered(t, ly.c.layer, x, y, .any);
}
export fn p_focus_seek(t: *const Tree, cur: u32, back: bool) u32 {
    return lcgr.focus.seek(t, t.c.sense, 8, 0, t.len, cur, back);
}
export fn p_focus_scan(t: *const Tree, sc: *lcgr.focus.Scopes) void {
    lcgr.focus.scan(t, sc);
}
export fn p_shortcut_fire(sh: *const lcgr.keyboard.Shortcuts, k: *lcgr.keyboard.Keyboard, out: [*]u16) u32 {
    return lcgr.keyboard.fire(sh, k, out[0..16]);
}
export fn p_wheel_route(t: *const Tree, sc: *const lcgr.gestures.Scrollables, in: *const Input, out: *lcgr.gestures.Wheel) void {
    out.* = lcgr.gestures.route(t, sc, in, 16);
}
export fn p_kinetic_step(k: *lcgr.gestures.Kinetic, dt: f32) f32 {
    return k.step(dt);
}
export fn p_drop_step(d: *lcgr.gestures.DragDrop, it: *const lcgr.interaction.Interaction, prev: *const Tree, tg: *const lcgr.gestures.Targets, in: *const Input) void {
    d.step(it, prev, tg, in);
}
