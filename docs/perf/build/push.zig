//! C0800: building the benchmark's tree (330 rows of 12 nodes, 3,961 rows) per frame, two ways:
//!   push     Tree.push(&style) per node: the style turned into its row every time
//!   pushRow  Template.from once per style per frame, then Tree.pushRow per node
//! The styles are runtime values (a theme read through a pointer), as widgets build them.
//! Min and median of 4,000 reps, alternated.
const std = @import("std");
const lcgf = @import("lcgf");
const linux = std.os.linux;
const Style = lcgf.types.Style;
const Template = lcgf.tree.Template;
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
var raw: [8 << 20]u8 align(64) = undefined;

/// The seven styles of the bench scene's row, read at run time.
var styles = [_]Style{
    .{ .size = .{ .px(1280), .px(8000) } },
    .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 6, .pad = @splat(2), .cross = .center },
    .{ .size = .{ .px(80), .px(16) } },
    .{ .pad = @splat(4), .fill = .rgb(40, 40, 40), .radius = 4, .border = 1 },
    .{ .size = .{ .px(40), .px(16) } },
    .{ .dir = .x, .gap = 4 },
    .{ .size = .{ .fill, .px(4) }, .fill = .rgb(90, 90, 90), .radius = 2 },
};

fn scene(t: *lcgf.tree.Tree, comptime rows: bool) void {
    var r: [styles.len]Template = undefined;
    if (rows) for (&r, &styles) |*d, *s| {
        d.* = .from(s);
    };
    const P = struct {
        fn n(tt: *lcgf.tree.Tree, p: u32, k: usize, rr: *const [styles.len]Template) u32 {
            return if (rows) tt.pushRow(p, .none, &rr[k]) else tt.push(p, .none, &styles[k]);
        }
    };
    t.reset();
    const root = P.n(t, 0, 0, &r);
    for (0..330) |_| {
        const row = P.n(t, root, 1, &r);
        _ = P.n(t, row, 2, &r);
        for (0..2) |_| {
            const b = P.n(t, row, 3, &r);
            _ = P.n(t, b, 4, &r);
            t.seal(b);
        }
        const cb = P.n(t, row, 5, &r);
        _ = P.n(t, cb, 2, &r);
        _ = P.n(t, cb, 4, &r);
        t.seal(cb);
        const sl = P.n(t, row, 3, &r);
        _ = P.n(t, sl, 6, &r);
        t.seal(sl);
        _ = P.n(t, row, 4, &r);
        t.seal(row);
    }
    t.seal(root);
}

pub fn main() !void {
    var carver: lcgf.mem.Carver = .{ .buf = &raw };
    var t = lcgf.tree.Tree.init(&carver, 4096);
    const reps = 4000;
    var s: [2][reps]u64 = undefined;
    for (0..reps) |k| {
        inline for (0..2) |v| {
            const t0 = now();
            scene(&t, v == 1);
            s[v][k] = now() - t0;
            std.mem.doNotOptimizeAway(t.c.min[0][t.len - 1]);
        }
    }
    for (&s, [_][]const u8{ "push", "pushRow" }) |*x, name| {
        std.mem.sort(u64, x, {}, std.sort.asc(u64));
        std.debug.print("{s:<8} nodes={d} min {d:.1} us  median {d:.1} us  {d:.1} ns/node\n", .{ name, t.len, @as(f64, @floatFromInt(x[0])) / 1000, @as(f64, @floatFromInt(x[reps / 2])) / 1000, @as(f64, @floatFromInt(x[reps / 2])) / @as(f64, @floatFromInt(t.len)) });
    }
}
