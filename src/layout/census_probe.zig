//! Branch-census probe for the ported layout and hit passes: one exported function per pass, so
//! tools/census/census.py can count the conditional jumps each one compiles to (docs/CHECKS.md
//! section 2). Built as an object by `zig build census-src-obj`; not exported from src/lcgr.zig,
//! because the library itself must not export symbols. Same arguments as prototype/asm_probe.zig.
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const Texts = lcgr.texts.Texts;
const Customs = lcgr.customs.Customs;
const DrawList = lcgr.draw_list.DrawList;

export fn p_prepare(t: *Tree) void {
    lcgr.layout.prepare(t);
}
export fn p_apply_text(t: *Tree, tx: *const Texts) void {
    lcgr.layout.applyText(t, tx, .x);
}
export fn p_fit(t: *Tree) void {
    lcgr.layout.fit(t, .x);
}
export fn p_resolve(t: *Tree) void {
    lcgr.layout.resolve(t, .x, 800);
}
export fn p_text_avail(t: *const Tree, tx: *Texts) void {
    lcgr.layout.textAvail(t, tx);
}
export fn p_place(t: *Tree) void {
    lcgr.layout.place(t);
}
export fn p_finalize(t: *Tree) void {
    lcgr.layout.finalize(t);
}
export fn p_coefs(t: *const Tree, k: *lcgr.coefs.Coefs) void {
    lcgr.coefs.coefs(t, k, .x);
}
export fn p_resolve_k(t: *Tree, k: *const lcgr.coefs.Coefs) void {
    lcgr.coefs.resolveK(t, k, .x, 800);
}
export fn p_place_rows(t: *const Tree, k: *lcgr.coefs.Coefs) void {
    lcgr.coefs.placeRows(t, k);
}
export fn p_place_k(t: *Tree, k: *const lcgr.coefs.Coefs) void {
    lcgr.coefs.placeK(t, k);
}
export fn p_tree_push(t: *Tree, parent: u32, s: *const lcgr.types.Style) u32 {
    return t.push(parent, .none, s);
}
export fn p_paint(t: *const Tree, tx: *const Texts, cu: *const Customs, d: *DrawList) void {
    lcgr.paint.emit(t, tx, cu, "", d);
}
export fn p_hit(t: *const Tree, x: f32, y: f32) u32 {
    return lcgr.hit.at(t, x, y, .any);
}
export fn p_hit_near(t: *const Tree, x: f32, y: f32) u32 {
    return lcgr.hit.near(t, x, y, .any, 8);
}
export fn p_anchor(t: *Tree, an: *const lcgr.overlay.Anchors) void {
    lcgr.overlay.anchor(t, an, .{ .x1 = 800, .y1 = 600 });
}
export fn p_order(t: *const Tree, ly: *lcgr.overlay.Layers) void {
    lcgr.overlay.order(t, ly);
}
export fn p_fit_flex(t: *Tree, fx: *const lcgr.flex.Flex) void {
    lcgr.layout.fitFlex(t, fx, .y);
}
export fn p_resolve_flex(t: *Tree, fx: *const lcgr.flex.Flex) void {
    lcgr.layout.resolveFlex(t, fx, .y, 800);
}
export fn p_place_flex(t: *Tree, fx: *const lcgr.flex.Flex) void {
    lcgr.layout.placeFlex(t, fx);
}
export fn p_wrap(t: *const Tree, fx: *const lcgr.flex.Flex) void {
    lcgr.wrap.wrap(t, fx);
}
export fn p_baseline_apply(t: *const Tree, fx: *const lcgr.flex.Flex, tx: *const Texts, ascent: [*]const f32) void {
    lcgr.baseline.apply(t, fx, tx, ascent[0..tx.len]);
}
export fn p_cluster_hit(c: *const lcgr.shape_cluster.Carets, x: i32) u32 {
    return lcgr.shape_cluster.hit(c, x);
}
export fn p_cluster_caret_x(c: *const lcgr.shape_cluster.Carets, offset: u32) i32 {
    return lcgr.shape_cluster.caretX(c, offset);
}
export fn p_levels_build(t: *const Tree, lv: *lcgr.levels.Levels) void {
    lcgr.levels.build(t, lv);
}
export fn p_levels_resolve(t: *Tree, lv: *const lcgr.levels.Levels) void {
    lcgr.levels.resolve(t, lv, .x, 800);
}
