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
