//! grid, written by hand: display: grid with tracks (px, fr, auto, minmax, repeat), named
//! areas, gaps, placed and spanning cells, implicit rows, column dense flow and alignment
//! (`spec.grid`, `spec.cell`), and multi-column layout (`columns: N`, `columns: W`) as a column-flow grid.

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
    // repeat(auto-fill, minmax(60px, 1fr)) in 280 px: four columns, the width laid out decides.
    s.grid(.{ .size = .{ .px(280), .fit } }, .{ .gap = .{ 4, 4 }, .repeat = .{ .mode = .auto_fill, .track = .minmaxFr(60, 1, lcgf.types.inf) } }, .{
        label.ct.label(theme, "t1"),
        label.ct.label(theme, "t2"),
        label.ct.label(theme, "t3"),
        label.ct.label(theme, "t4"),
        label.ct.label(theme, "t5"),
        label.ct.label(theme, "t6"),
    }),
    // columns: 3 over five children: two rows, filled down each column in turn.
    s.grid(.{ .size = .{ .px(240), .fit } }, .{ .columns = &.{ .fr(1), .fr(1), .fr(1) }, .rows = &.{ .fit, .fit }, .flow = .column, .gap = .{ 6, 0 } }, .{
        label.ct.label(theme, "n1"),
        label.ct.label(theme, "n2"),
        label.ct.label(theme, "n3"),
        label.ct.label(theme, "n4"),
        label.ct.label(theme, "n5"),
    }),
    // columns: 50px 8 in 230 px: four columns over seven children, two rows, each column in turn.
    s.grid(.{ .size = .{ .px(230), .fit } }, .{ .gap = .{ 10, 0 }, .flow = .column, .repeat = .{ .mode = .auto_fill, .track = .minmaxFr(50, 1, lcgf.types.inf), .max = 8 } }, .{
        label.ct.label(theme, "c1"),
        label.ct.label(theme, "c2"),
        label.ct.label(theme, "c3"),
        label.ct.label(theme, "c4"),
        label.ct.label(theme, "c5"),
        label.ct.label(theme, "c6"),
        label.ct.label(theme, "c7"),
    }),
    // align-items: baseline on a wrapping row in a grid cell: a baseline per line.
    s.grid(.{}, .{ .columns = &.{ .px(90), .fr(1) } }, .{
        s.flexed(s.row(.{}, .{
            s.textStyled(label.ct.label(theme, "Big"), .{ .px = 24, .color = .rgb(230, 230, 235) }),
            label.ct.label(theme, "small"),
            label.ct.label(theme, "next"),
        }), .{ .wrap = true, .baseline = true }),
        label.ct.label(theme, "x"),
    }),
    s.grid(.{}, .{ .rows = &.{ .fit, .fit }, .flow = .column_dense, .distribution = .{ .space_between, .start } }, .{
        label.ct.label(theme, "1"),
        label.ct.label(theme, "2"),
        label.ct.label(theme, "3"),
    }),
});
