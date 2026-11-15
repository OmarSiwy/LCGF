//! Branch-census probe for the ported layout: one exported function per pass, so
//! tools/census/census.py can count the conditional jumps each one compiles to (docs/CHECKS.md
//! section 2). Built as an object by `zig build census-src-obj`; not exported from src/lcgr.zig,
//! because the library itself must not export symbols. Same arguments as prototype/asm_probe.zig.
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const Texts = lcgr.texts.Texts;

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
