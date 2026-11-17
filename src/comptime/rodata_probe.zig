//! Object file for the read-only-data check (`zig build ct-rodata`, ci/jobs/ct-rodata.sh).
//! Not exported from src/lcgr.zig: it is its own module root and imports the package as `lcgr`.
//!
//! Each `ro_*` function reads one flatten table at a run-time row, so the table must exist in
//! the object; the check reads the relocation each one makes and requires a read-only section.
//! `rw_control` reads a mutable copy of a table: it must land in writable data, which shows the
//! check can tell the two apart.

const lcgr = @import("lcgr");
const s = lcgr.spec;

const F = lcgr.flatten.Flat(s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
}));

export fn ro_parent(i: u32) u8 {
    return F.parent[i % F.node_count];
}
export fn ro_end(i: u32) u8 {
    return F.end[i % F.node_count];
}
export fn ro_depth(i: u32) u8 {
    return F.depth[i % F.node_count];
}
export fn ro_level_order(i: u32) u8 {
    return F.level_order[i % F.node_count];
}
export fn ro_level_start(i: u32) u8 {
    return F.level_start[i % F.level_start.len];
}

// Constant style columns (lcgr.columns): the same check for tables built from Tree.push rows.
const C = lcgr.columns.Columns(lcgr.ct_examples.mixer, .{});
export fn ro_col_pad(i: u32) f32 {
    return C.table("pad_lo")[i % 2][i % C.node_count];
}
export fn ro_col_gap(i: u32) f32 {
    return C.table("gap")[i % C.node_count];
}
// A column whose rows are all equal folds to a constant, so each table read here varies.
const Card = lcgr.columns.Columns(lcgr.ct_examples.static_card, .{});
export fn ro_col_look(i: u32) u32 {
    return Card.table("look")[i % Card.node_count].fill;
}

// Quad templates (lcgr.ct_paint): the rows paint copies each frame.
const P = lcgr.ct_paint.Paint(lcgr.ct_paint.tiles, .{});
export fn ro_quad_template(i: u32) u32 {
    return P.templates[i % P.quad_count].fill;
}

var ram_copy: [F.node_count]F.Index = F.end;
export fn rw_control(i: u32) u8 {
    ram_copy[i % F.node_count] +%= 1;
    return ram_copy[(i + 1) % F.node_count];
}
