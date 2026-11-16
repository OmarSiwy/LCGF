//! Object for C0165's measurement (`zig build ct-layout-size`): one exported layout run per
//! example and form, table-driven (the row count a run-time value) or unrolled (a compile-time
//! constant), and `place` alone, rolled (the tier-0 pass) against fully unrolled (`inline for`
//! over the rows; a copy of the pass body made for this measurement only). `nm --size-sort` gives
//! each function's code size; `main` times the place pair. Its own module root.

const lcgr = @import("lcgr");
const ex = lcgr.ct_examples;
const PlainOf = lcgr.ct_layout.PlainOf;

fn Probe(comptime e: ex.Example, comptime unroll: bool) type {
    return struct {
        const P = PlainOf(e.spec, e.options, unroll);
        var scratch: P.Scratch = undefined;
        var ram: P.Cols.Dynamic = undefined;
        fn run(w: f32, h: f32) callconv(.c) void {
            P.run(&scratch, &ram, .{ w, h });
        }
    };
}

fn PlaceProbe(comptime e: ex.Example) type {
    return struct {
        const P = PlainOf(e.spec, e.options, false);
        const n = P.Cols.node_count;
        var scratch: P.Scratch = undefined;
        fn rolled() callconv(.c) void {
            var v = P.view(&scratch);
            lcgr.layout.place(&v);
        }
        /// layout.placeOf's body for a non-flex tree, one copy per row.
        fn unrolled() callconv(.c) void {
            const t = P.view(&scratch);
            const c = t.c;
            inline for (1..n) |i| {
                const p = comptime P.Cols.pushed.c.parent[i];
                const fl = c.flow[i];
                inline for (0..2) |a| {
                    const inner = c.size[a][p] - c.pad_lo[a][p] - c.pad_hi[a][p];
                    const lead = @max(inner - c.used[a][p] - c.gap_total[p], 0) * c.align_main[p];
                    const across = @max(inner - c.size[a][i], 0) * c.align_cross[p];
                    const along = lead + c.cursor[p];
                    const in_flow = across + c.main[a][p] * (along - across);
                    c.pos[a][i] = c.pos[a][p] + c.pad_lo[a][p] - c.scroll[a][p] + fl * in_flow + c.offset[a][i];
                }
                const step = c.size[0][i] * c.main[0][p] + c.size[1][i] * c.main[1][p];
                c.cursor[p] += (step + c.gap[p]) * fl;
            }
        }
    };
}

/// A column of `k` rows, each a label and a slider: 2k + 1 nodes.
fn rows(comptime k: usize) lcgr.spec.Spec {
    @setEvalBranchQuota(1000 + 200 * k);
    const s = lcgr.spec;
    var kids: [k]s.Spec = undefined;
    for (&kids) |*r| r.* = s.row(.{ .gap = 4, .size = .{ .fill, .px(20) } }, .{ s.label(.x), s.col(.{ .size = .{ .fill, .px(8) } }, .{}) });
    return s.col(.{ .pad = @splat(4), .gap = 2 }, kids);
}

const State = struct { x: f32 = 0 };
const sizes = [_]usize{ 1, 2, 4, 8, 16, 32, 64 };

comptime {
    @setEvalBranchQuota(100_000);
    for (ex.all) |e| if (!std.mem.eql(u8, e.name, "custom")) {
        @export(&Probe(e, false).run, .{ .name = "table_" ++ e.name });
        @export(&Probe(e, true).run, .{ .name = "unrolled_" ++ e.name });
    };
    for (sizes) |k| {
        const e: ex.Example = .{ .name = "", .State = State, .spec = rows(k) };
        const n = std.fmt.comptimePrint("{d}", .{2 * k + 1});
        @export(&Probe(e, false).run, .{ .name = "table_rows" ++ n });
        @export(&Probe(e, true).run, .{ .name = "unrolled_rows" ++ n });
        @export(&PlaceProbe(e).rolled, .{ .name = "place_rolled_rows" ++ n });
        @export(&PlaceProbe(e).unrolled, .{ .name = "place_unrolled_rows" ++ n });
    }
}

const std = @import("std");

/// Median ns per call of `f` over 15 batches of 20,000 calls.
fn time(io: std.Io, f: *const fn () callconv(.c) void) u64 {
    var xs: [15]u64 = undefined;
    for (&xs) |*x| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        for (0..20_000) |_| f();
        x.* = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds(), 20_000));
    }
    std.mem.sort(u64, &xs, {}, std.sort.asc(u64));
    return xs[7];
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    try w.print("{s:>6} {s:>12} {s:>14}\n", .{ "nodes", "place ns", "unrolled ns" });
    inline for (sizes) |k| {
        const Pp = PlaceProbe(.{ .name = "", .State = State, .spec = rows(k) });
        try w.print("{d:>6} {d:>12} {d:>14}\n", .{ 2 * k + 1, time(init.io, &Pp.rolled), time(init.io, &Pp.unrolled) });
    }
    try w.flush();
}
