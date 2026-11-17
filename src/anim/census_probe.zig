//! Branch-census probe for the spring passes (docs/CHECKS.md section 2), imported by
//! src/census_probes.zig. Not exported from src/lcgf.zig.
const lcgf = @import("lcgf");

export fn p_anim(a: *lcgf.anims.Anims, dt: f32) f32 {
    return a.step(dt);
}
export fn p_sweep(a: *lcgf.anims.Anims, frame: u32) void {
    a.sweep(frame);
}
export fn p_tween(t: *lcgf.tweens.Tweens, dt: f32) f32 {
    return t.step(dt);
}
export fn p_flip(t: *lcgf.tree.Tree, prev: *const lcgf.tree.Tree, fl: *lcgf.flip.Flips, an: *lcgf.anims.Anims, frame: u32) f32 {
    return lcgf.flip.apply(t, prev, fl, an, frame);
}
