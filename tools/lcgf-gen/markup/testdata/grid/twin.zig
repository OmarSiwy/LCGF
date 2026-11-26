//! grid, written by hand: display: grid with tracks (px, fr, auto, minmax, repeat), named
//! areas, gaps, placed and spanning cells, implicit rows, column dense flow and alignment
//! (`spec.grid`, `spec.cell`).

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

const card: lcgf.grid.Track = .minmaxFr(40, 1, lcgf.types.inf);

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.grid(.{ .pad = @splat(4) }, .{ .columns = &.{ .px(120), .fr(1) }, .rows = &.{ .px(40), .fit, .px(30) }, .gap = .{ 8, 6 } }, .{
        // grid-template-areas: "head head" "side main" "foot foot".
        s.cell(s.styled(label.ct.label(theme, "Head"), .{ .fill = .rgb(0x20, 0x30, 0x40), .role = .label }), .{ .cell = .{ 0, 0 }, .span = .{ 2, 1 } }),
        s.cell(label.ct.label(theme, "Side"), .{ .cell = .{ 0, 1 }, .justify = .{ .stretch, .start } }),
        s.cell(s.col(.{}, .{
            s.grid(.{}, .{ .columns = &.{ card, card, card }, .auto = .{ .fit, .px(24) }, .gap = .{ 4, 2 }, .justify = .{ .center, .stretch } }, .{
                label.ct.label(theme, "A"),
                s.cell(label.ct.label(theme, "B"), .{ .span = .{ 2, 1 } }),
                label.ct.label(theme, "C"),
                // grid-column: 3; grid-row: 2 / 4.
                s.cell(label.ct.label(theme, "D"), .{ .cell = .{ 2, 1 }, .span = .{ 1, 2 } }),
                label.ct.label(theme, "E"),
            }),
        }), .{ .cell = .{ 1, 1 } }),
        s.cell(label.ct.label(theme, "Foot"), .{ .cell = .{ 0, 2 }, .span = .{ 2, 1 }, .justify = .{ .end, .stretch } }),
    }),
    s.grid(.{}, .{ .rows = &.{ .fit, .fit }, .flow = .column_dense, .distribution = .{ .space_between, .start } }, .{
        label.ct.label(theme, "1"),
        label.ct.label(theme, "2"),
        label.ct.label(theme, "3"),
    }),
});
