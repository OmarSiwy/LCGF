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
