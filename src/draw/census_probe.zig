//! Branch-census probe for the draw passes in src/draw (docs/CHECKS.md section 2): one exported
//! function per pass, built into `zig build census-src-obj` through src/census_probes.zig. Not
//! exported from src/lcgr.zig. `p_paint` predates this file and stays in src/layout/census_probe.zig.
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const Texts = lcgr.texts.Texts;
const Customs = lcgr.customs.Customs;
const DrawList = lcgr.draw_list.DrawList;

export fn p_damage_frame(dm: *lcgr.damage.Damage, t: *const Tree, tx: *const Texts, cu: *const Customs) u32 {
    return dm.frame(t, tx, cu, "");
}
export fn p_damage_cull(d: *DrawList, g: *const lcgr.damage.Region) void {
    lcgr.damage.cull(d, g);
}
export fn p_inherit_opacity(t: *Tree) void {
    lcgr.inherit.opacity(t);
}
export fn p_inherit_transform(t: *Tree) void {
    lcgr.inherit.transform(t);
}
