//! Branch-census probe for the interaction passes (docs/CHECKS.md section 2): one exported
//! function per pass, imported by src/census_probes.zig. Not exported from src/lcgr.zig.
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const Input = lcgr.input.Input;

export fn p_step(s: *lcgr.interaction.Interaction, prev: *const Tree, in: *const Input) void {
    s.step(prev, in);
}
export fn p_touch_step(s: *lcgr.interaction.Touches(10), prev: *const Tree, in: *const Input) void {
    s.step(prev, in);
}
