//! Branch-census probe for the semantic-tree passes (docs/CHECKS.md section 2): one exported
//! function per pass, imported by src/census_probes.zig. Not exported from src/lcgr.zig.
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const a11y = lcgr.a11y_tree;

export fn p_a11y_names(t: *const Tree, s: *a11y.Semantics) void {
    a11y.names(t, s);
}
export fn p_a11y_states(t: *const Tree, s: *a11y.Semantics) void {
    a11y.states(t, s);
}
export fn p_a11y_flatten(t: *const Tree, tx: *const lcgr.texts.Texts, bytes: [*]const u8, n: usize, s: *a11y.Semantics, out: *a11y.Export) void {
    a11y.flatten(t, tx, bytes[0..n], s, out);
}
export fn p_a11y_diff(cur: *const a11y.Export, prev: *const a11y.Export, ch: *a11y.Changes) void {
    a11y.diff(cur, prev, ch);
}
