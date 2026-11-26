//! The zero-cost probe (plan M10.1): one frame of a page's ComptimeUi as an exported function.
//! Built twice per fixture, over the generated module and over the hand-written twin
//! (cost_twin.zig); ci/jobs/markup-zero-cost.sh compares the two objects' code.

const lcgf = @import("lcgf");
const Ui = @import("ui").Ui;

var ui: Ui = .{};

export fn markup_probe_frame(in: *const lcgf.input.Input) u32 {
    return ui.frame(in).tree.len;
}
