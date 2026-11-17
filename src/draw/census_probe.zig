//! Branch-census probe for the draw passes in src/draw (docs/CHECKS.md section 2): one exported
//! function per pass, built into `zig build census-src-obj` through src/census_probes.zig. Not
//! exported from src/lcgf.zig. `p_paint` predates this file and stays in src/layout/census_probe.zig.
const lcgf = @import("lcgf");
const Tree = lcgf.tree.Tree;
const Texts = lcgf.texts.Texts;
const Customs = lcgf.customs.Customs;
const DrawList = lcgf.draw_list.DrawList;

export fn p_damage_frame(dm: *lcgf.damage.Damage, t: *const Tree, tx: *const Texts, cu: *const Customs) u32 {
    return dm.frame(t, tx, cu, "");
}
export fn p_damage_cull(d: *DrawList, g: *const lcgf.damage.Region) void {
    lcgf.damage.cull(d, g);
}
export fn p_inherit_opacity(t: *Tree) void {
    lcgf.inherit.opacity(t);
}
export fn p_inherit_transform(t: *Tree) void {
    lcgf.inherit.transform(t);
}
export fn p_inherit_clip(t: *Tree) void {
    lcgf.inherit.clip(t);
}
export fn p_paint_layered(t: *Tree, tx: *const Texts, cu: *const Customs, ly: *const lcgf.overlay.Layers, d: *DrawList) void {
    lcgf.paint.emitLayered(t, tx, cu, "", ly, d);
}
export fn p_merge_across_text(d: *DrawList) void {
    lcgf.order.mergeAcrossText(d);
}
export fn p_depth_order(d: *DrawList) void {
    lcgf.order.depthOrder(d);
}
