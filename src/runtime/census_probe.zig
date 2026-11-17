//! Branch-census probe for the runtime front end's reuse (docs/CHECKS.md section 2), imported by
//! src/census_probes.zig. Not exported from src/lcgf.zig.
const lcgf = @import("lcgf");

export fn p_reuse(f: *lcgf.frame.Frame, id: u32, deps: [*]const lcgf.runtime_signals.Signal, n: usize) bool {
    return f.reuse(@fromBackingInt(id), deps[0..n]);
}
// The kept-subtree layout passes of src/layout/incremental.zig that have loops of their own.
// fitKept, resolveKept and placeKept are only loops over the kept list around layout.zig's
// span forms; probing them here makes LLVM outline fitOf/resolveOf/placeOf from p_fit,
// p_resolve and p_place, and the census would lose sight of those per-row loops.
export fn p_prepare_kept(t: *lcgf.tree.Tree, kept: [*]const u32, n: usize) void {
    lcgf.incremental.prepareKept(t, kept[0..n]);
}
export fn p_apply_text_kept(t: *lcgf.tree.Tree, tx: *const lcgf.texts.Texts, kept: [*]const u32, n: usize) void {
    lcgf.incremental.applyTextKept(t, tx, .x, kept[0..n]);
}
