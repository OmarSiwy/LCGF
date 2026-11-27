//! Branch-census probe for the ported layout and hit passes: one exported function per pass, so
//! bench/census/census.py can count the conditional jumps each one compiles to (docs/CHECKS.md
//! section 2). Built as an object by `zig build census-src-obj`; not exported from src/lcgf.zig,
//! because the library itself must not export symbols. Same arguments as prototype/asm_probe.zig.
const lcgf = @import("lcgf");
const Tree = lcgf.tree.Tree;
const Texts = lcgf.texts.Texts;
const Customs = lcgf.customs.Customs;
const DrawList = lcgf.draw_list.DrawList;

export fn p_prepare(t: *Tree) void {
    lcgf.layout.prepare(t);
}
export fn p_apply_text(t: *Tree, tx: *const Texts) void {
    lcgf.layout.applyText(t, tx, .x);
}
export fn p_fit(t: *Tree) void {
    lcgf.layout.fit(t, .x);
}
export fn p_resolve(t: *Tree) void {
    lcgf.layout.resolve(t, .x, 800);
}
export fn p_text_avail(t: *const Tree, tx: *Texts) void {
    lcgf.layout.textAvail(t, tx);
}
export fn p_place(t: *Tree) void {
    lcgf.layout.place(t);
}
export fn p_finalize(t: *Tree) void {
    lcgf.layout.finalize(t);
}
// Inlined, so the count is the run loop's and not a call's.
export fn p_runs_place(t: *Tree) void {
    @call(.always_inline, lcgf.runs.place, .{t});
}
export fn p_runs_fit(t: *Tree) void {
    @call(.always_inline, lcgf.runs.fit, .{ t, 0, 0, t.len });
}
export fn p_coefs(t: *const Tree, k: *lcgf.coefs.Coefs) void {
    lcgf.coefs.coefs(t, k, .x);
}
export fn p_resolve_k(t: *Tree, k: *const lcgf.coefs.Coefs) void {
    lcgf.coefs.resolveK(t, k, .x, 800);
}
export fn p_place_rows(t: *const Tree, k: *lcgf.coefs.Coefs) void {
    lcgf.coefs.placeRows(t, k);
}
export fn p_place_k(t: *Tree, k: *const lcgf.coefs.Coefs) void {
    lcgf.coefs.placeK(t, k);
}
export fn p_tree_push(t: *Tree, parent: u32, s: *const lcgf.types.Style) u32 {
    return t.push(parent, .none, s);
}
export fn p_paint(t: *Tree, tx: *const Texts, cu: *const Customs, d: *DrawList) void {
    lcgf.paint.emit(t, tx, cu, "", d);
}
export fn p_hit(t: *const Tree, x: f32, y: f32) u32 {
    return lcgf.hit.at(t, x, y, .any);
}
export fn p_hit_near(t: *const Tree, x: f32, y: f32) u32 {
    return lcgf.hit.near(t, x, y, .any, 8);
}
export fn p_anchor(t: *Tree, an: *const lcgf.overlay.Anchors) void {
    lcgf.overlay.anchor(t, an, .{ .x1 = 800, .y1 = 600 });
}
export fn p_order(t: *const Tree, ly: *lcgf.overlay.Layers) void {
    lcgf.overlay.order(t, ly);
}
export fn p_extent(t: *const Tree, out: *const [2][]f32) void {
    lcgf.scroll.extent(t, out.*);
}
export fn p_clamp(t: *Tree, ext: *const [2][]const f32) void {
    lcgf.scroll.clamp(t, ext.*);
}
export fn p_stick(t: *Tree, st: *const lcgf.scroll.Sticky) void {
    lcgf.scroll.stick(t, st);
}
export fn p_grid_fit(t: *Tree, gs: *lcgf.grid.Grids) void {
    lcgf.grid.fit(t, gs, .x);
}
export fn p_grid_resolve(t: *Tree, gs: *lcgf.grid.Grids) void {
    lcgf.grid.resolve(t, gs, .x, 800);
}
export fn p_direction(t: *const Tree, r: *lcgf.rtl.Rtl) void {
    lcgf.rtl.direction(t, r);
}
export fn p_start_end(t: *Tree, r: *const lcgf.rtl.Rtl) void {
    lcgf.rtl.startEnd(t, r);
}
export fn p_mirror(t: *Tree, r: *lcgf.rtl.Rtl) void {
    lcgf.rtl.mirror(t, r);
}
export fn p_fit_flex(t: *Tree, fx: *const lcgf.flex.Flex) void {
    lcgf.layout.fitFlex(t, fx, .y);
}
export fn p_resolve_flex(t: *Tree, fx: *const lcgf.flex.Flex) void {
    lcgf.layout.resolveFlex(t, fx, .y, 800);
}
export fn p_place_flex(t: *Tree, fx: *const lcgf.flex.Flex) void {
    lcgf.layout.placeFlex(t, fx);
}
export fn p_wrap(t: *const Tree, fx: *const lcgf.flex.Flex) void {
    lcgf.wrap.wrap(t, fx);
}
export fn p_baseline_apply(t: *const Tree, fx: *const lcgf.flex.Flex, tx: *const Texts, ascent: [*]const f32) void {
    lcgf.baseline.apply(t, fx, tx, ascent[0..tx.len]);
}
export fn p_levels_build(t: *const Tree, lv: *lcgf.levels.Levels) void {
    lcgf.levels.build(t, lv);
}
export fn p_levels_resolve(t: *Tree, lv: *const lcgf.levels.Levels) void {
    lcgf.levels.resolve(t, lv, .x, 800);
}
