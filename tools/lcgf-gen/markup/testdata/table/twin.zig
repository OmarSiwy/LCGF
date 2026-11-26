//! table, written by hand: a <table> as a grid of fit columns, each <tr> a row grid that
//! shares the table's columns (`Decl.subgrid`), cells with the table roles and a colspan.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const grid = lcgf.grid;

pub const theme: w.Theme = .{};

/// Accessible names the a11y export must carry (parity.zig).
pub const names = .{"Channels"};

const cols: []const grid.Track = &.{ .fit, .fit, .fit };
const row: grid.Decl = .{ .columns = cols, .rows = &.{.fit}, .subgrid = .{ true, false } };
const pad: [4]f32 = .{ 4, 2, 4, 2 };
const head: lcgf.types.TextStyle = .{ .color = .rgb(0xc0, 0xc8, 0xd0) };

fn th(comptime text: []const u8, comptime role: lcgf.types.Role) s.Spec {
    return s.textStyled(s.styled(label.ct.label(theme, text), .{ .pad = pad, .role = role }), head);
}

fn td(comptime text: []const u8) s.Spec {
    return s.styled(label.ct.label(theme, text), .{ .pad = pad, .role = .cell });
}

fn tr(comptime at: u32, comptime style: lcgf.types.Style, comptime cells: anytype) s.Spec {
    var st = style;
    st.role = .row;
    return s.cell(s.grid(st, row, cells), .{ .cell = .{ 0, at }, .span = .{ 3, 1 } });
}

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.named(s.grid(.{ .pad = @splat(4), .fill = .rgb(0x26, 0x28, 0x2e), .role = .table }, .{ .columns = cols, .rows = &.{ .fit, .fit, .fit, .fit }, .gap = .{ 12, 2 } }, .{
        tr(0, .{}, .{ th("Channel", .column_header), th("Gain", .column_header), th("Pan", .column_header) }),
        tr(1, .{}, .{ th("Kick", .row_header), td("-3 dB"), td("Centre") }),
        tr(2, .{}, .{ th("Overheads", .row_header), td("-12 dB"), td("Wide") }),
        tr(3, .{ .fill = .rgb(0x30, 0x34, 0x40) }, .{ s.cell(td("Two channels"), .{ .span = .{ 2, 1 } }), td("Stereo") }),
    }), "Channels"),
    // A rowspan: the first row covers the two rows its first cell reaches, and every cell
    // sits at its slot from the table algorithm.
    s.grid(.{ .pad = @splat(4), .fill = .rgb(0x26, 0x28, 0x2e), .role = .table }, .{ .columns = &.{ .fit, .fit }, .rows = &.{ .fit, .fit, .fit }, .gap = .{ 12, 2 } }, .{
        s.cell(s.grid(.{ .role = .row }, .{ .columns = &.{ .fit, .fit }, .rows = &.{ .fit, .fit }, .subgrid = .{ true, true } }, .{
            s.cell(td("Bus"), .{ .cell = .{ 0, 0 }, .span = .{ 1, 2 } }),
            s.cell(td("Left"), .{ .cell = .{ 1, 0 } }),
        }), .{ .cell = .{ 0, 0 }, .span = .{ 2, 2 } }),
        s.cell(s.grid(.{ .role = .row }, .{ .columns = &.{ .fit, .fit }, .rows = &.{.fit}, .subgrid = .{ true, false } }, .{
            s.cell(td("Right"), .{ .cell = .{ 1, 0 } }),
        }), .{ .cell = .{ 0, 1 }, .span = .{ 2, 1 } }),
        s.cell(s.grid(.{ .role = .row }, .{ .columns = &.{ .fit, .fit }, .rows = &.{.fit}, .subgrid = .{ true, false } }, .{
            s.cell(td("Master"), .{ .cell = .{ 0, 0 }, .span = .{ 2, 1 } }),
        }), .{ .cell = .{ 0, 2 }, .span = .{ 2, 1 } }),
    }),
});
