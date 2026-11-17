//! Branch-census probe for the core's per-node writes (lane optimise; docs/CHECKS.md section 2),
//! imported by src/census_probes.zig. Not exported from src/lcgf.zig.
const lcgf = @import("lcgf");
const Tree = lcgf.tree.Tree;

export fn p_tree_push_row(t: *Tree, parent: u32, row: *const lcgf.tree.Template) u32 {
    return @call(.always_inline, Tree.pushRow, .{ t, parent, .none, row });
}
