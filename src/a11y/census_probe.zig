//! Branch-census probe for the semantic-tree passes (docs/CHECKS.md section 2): one exported
//! function per pass, imported by src/census_probes.zig. Not exported from src/lcgf.zig.
const lcgf = @import("lcgf");
const Tree = lcgf.tree.Tree;
const a11y = lcgf.a11y_tree;

export fn p_a11y_names(t: *const Tree, s: *a11y.Semantics) void {
    a11y.names(t, s);
}
export fn p_a11y_states(t: *const Tree, s: *a11y.Semantics) void {
    a11y.states(t, s);
}
export fn p_a11y_flatten(t: *const Tree, tx: *const lcgf.texts.Texts, bytes: [*]const u8, n: usize, s: *a11y.Semantics, out: *a11y.Export) void {
    a11y.flatten(t, tx, bytes[0..n], s, out);
}
export fn p_a11y_diff(cur: *const a11y.Export, prev: *const a11y.Export, ch: *a11y.Changes) void {
    a11y.diff(cur, prev, ch);
}
export fn p_a11y_apply(it: *lcgf.interaction.Interaction, acts: [*]const a11y.Action, n: usize) void {
    a11y.apply(it, acts[0..n]);
}
export fn p_a11y_set_value(acts: [*]const a11y.Action, n: usize, id: u32, v: f32) f32 {
    return a11y.setValue(acts[0..n], @fromBackingInt(@intCast(id)), v);
}
