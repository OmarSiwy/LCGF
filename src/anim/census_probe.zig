//! Branch-census probe for the spring passes (docs/CHECKS.md section 2), imported by
//! src/census_probes.zig. Not exported from src/lcgr.zig.
const lcgr = @import("lcgr");

export fn p_anim(a: *lcgr.anims.Anims, dt: f32) f32 {
    return a.step(dt);
}
export fn p_sweep(a: *lcgr.anims.Anims, frame: u32) void {
    a.sweep(frame);
}
export fn p_tween(t: *lcgr.tweens.Tweens, dt: f32) f32 {
    return t.step(dt);
}
export fn p_flip(t: *lcgr.tree.Tree, prev: *const lcgr.tree.Tree, fl: *lcgr.flip.Flips, an: *lcgr.anims.Anims, frame: u32) f32 {
    return lcgr.flip.apply(t, prev, fl, an, frame);
}
