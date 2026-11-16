//! docs/research/usage-report.md, question 2: docs/perf/build/push.zig's pushRow scene built
//! by two copies of lcgr in one process, interleaved rep by rep: "a" is the tree, "b" the tree
//! with prototype.diff applied. Build (B = a copy of src/ with the diff applied):
//!   zig build-exe -O ReleaseFast -mcpu native --dep a --dep b -Mmain=docs/research/usage/pushab.zig \
//!     --dep build_options -Ma=src/lcgr.zig --dep build_options -Mb=B/src/lcgr.zig \
//!     -Mbuild_options=docs/perf/build/opts.zig -femit-bin=pushab && taskset -c 8 ./pushab
const std = @import("std");
const A = @import("a");
const B = @import("b");
const linux = std.os.linux;
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
fn Bench(comptime lcgr: type) type {
    return struct {
        const Style = lcgr.types.Style;
        const Template = lcgr.tree.Template;
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

        pub fn scene(t: *lcgr.tree.Tree, comptime rows: bool) void {
            var r: [styles.len]Template = undefined;
            if (rows) for (&r, &styles) |*d, *s| {
                d.* = .from(s);
            };
            const P = struct {
                fn n(tt: *lcgr.tree.Tree, p: u32, k: usize, rr: *const [styles.len]Template) u32 {
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
    };
}
var raw: [8 << 20]u8 align(64) = undefined;
var raw2: [8 << 20]u8 align(64) = undefined;
pub fn main() !void {
    var ca: A.mem.Carver = .{ .buf = &raw };
    var ta = A.tree.Tree.init(&ca, 4096);
    var cb: B.mem.Carver = .{ .buf = &raw2 };
    var tb = B.tree.Tree.init(&cb, 4096);
    const reps = 20000;
    var s: [2][reps]u64 = undefined;
    for (0..reps) |k| {
        const t0 = now();
        Bench(A).scene(&ta, true);
        s[0][k] = now() - t0;
        std.mem.doNotOptimizeAway(ta.c.min[0][ta.len - 1]);
        const t1 = now();
        Bench(B).scene(&tb, true);
        s[1][k] = now() - t1;
        std.mem.doNotOptimizeAway(tb.c.min[0][tb.len - 1]);
    }
    for (&s, [_][]const u8{ "A", "B" }) |*x, name| {
        std.mem.sort(u64, x, {}, std.sort.asc(u64));
        std.debug.print("{s} min {d:.1} p10 {d:.1} median {d:.1} us\n", .{ name, @as(f64, @floatFromInt(x[0])) / 1000, @as(f64, @floatFromInt(x[reps / 10])) / 1000, @as(f64, @floatFromInt(x[reps / 2])) / 1000 });
    }
}
