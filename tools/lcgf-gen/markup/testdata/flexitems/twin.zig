//! flexitems, written by hand: CSS margins as flex item margins. Waits for engine spec F2
//! (`spec.flexed`, docs/plans/markup-engine-api.md); in the `markup-pending` step until then.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .gap = 4 }, .{
        // CSS top-right-bottom-left; Flex.Style.margin is left, top, right, bottom.
        s.flexed(label.ct.label(theme, "A"), .{ .margin = .{ 6, 2, 6, 2 } }),
        s.flexed(label.ct.label(theme, "B"), .{ .margin = .{ 0, 2, 6, 2 } }),
    }),
});
