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
