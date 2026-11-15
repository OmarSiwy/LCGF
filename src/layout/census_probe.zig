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
export fn p_anchor(t: *Tree, an: *const lcgr.overlay.Anchors) void {
    lcgr.overlay.anchor(t, an, .{ .x1 = 800, .y1 = 600 });
}
export fn p_order(t: *const Tree, ly: *lcgr.overlay.Layers) void {
    lcgr.overlay.order(t, ly);
}
export fn p_extent(t: *const Tree, out: *const [2][]f32) void {
    lcgr.scroll.extent(t, out.*);
}
export fn p_clamp(t: *Tree, ext: *const [2][]const f32) void {
    lcgr.scroll.clamp(t, ext.*);
}
export fn p_stick(t: *Tree, st: *const lcgr.scroll.Sticky) void {
    lcgr.scroll.stick(t, st);
}
export fn p_grid_fit(t: *Tree, gs: *lcgr.grid.Grids) void {
    lcgr.grid.fit(t, gs, .x);
}
export fn p_grid_resolve(t: *Tree, gs: *lcgr.grid.Grids) void {
    lcgr.grid.resolve(t, gs, .x, 800);
}
export fn p_direction(t: *const Tree, r: *lcgr.rtl.Rtl) void {
    lcgr.rtl.direction(t, r);
}
export fn p_start_end(t: *Tree, r: *const lcgr.rtl.Rtl) void {
    lcgr.rtl.startEnd(t, r);
}
export fn p_mirror(t: *Tree, r: *lcgr.rtl.Rtl) void {
    lcgr.rtl.mirror(t, r);
}
