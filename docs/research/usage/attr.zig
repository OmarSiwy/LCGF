//! docs/research/usage-report.md, questions 3 to 5. Build as docs/perf/build/bytes.zig:
//!   zig build-exe -O ReleaseFast --dep lcgf -Mmain=docs/research/usage/attr.zig --dep build_options \
//!     -Mlcgf=src/lcgf.zig -Mbuild_options=docs/perf/build/opts.zig -femit-bin=attr && ./attr
const std = @import("std");
const builtin = @import("builtin");
const l = @import("lcgf");
const mem = l.mem;
const simd = l.simd;
const Limits = l.context.Limits;

fn colBytes(comptime S: type, n: usize) usize {
    var sum: usize = 0;
    inline for (@typeInfo(S).@"struct".field_types) |FT| switch (@typeInfo(FT)) {
        .pointer => |p| sum += std.mem.alignForward(usize, n * @sizeOf(p.child), 64),
        .array => |a| sum += a.len * std.mem.alignForward(usize, n * @sizeOf(@typeInfo(a.child).pointer.child), 64),
        else => unreachable,
    };
    return sum;
}

fn report(lim: Limits) void {
    var c: mem.Carver = .{ .buf = null };
    var last: usize = 0;
    const P = struct {
        fn mark(cc: *mem.Carver, lst: *usize, name: []const u8) void {
            std.debug.print("  {s:<22} {d:>10}\n", .{ name, cc.off - lst.* });
            lst.* = cc.off;
        }
    };
    const first = l.tree.Tree.init(&c, lim.nodes);
    P.mark(&c, &last, "tree gen 0");
    _ = l.tree.Tree.initSharing(&c, lim.nodes, &first);
    P.mark(&c, &last, "tree gen 1 (no scratch)");
    _ = l.texts.Texts.init(&c, lim.texts);
    _ = l.texts.Texts.init(&c, lim.texts);
    P.mark(&c, &last, "texts x2");
    _ = l.customs.Customs.init(&c, lim.customs);
    _ = l.customs.Customs.init(&c, lim.customs);
    P.mark(&c, &last, "customs x2");
    _ = c.slice(u8, lim.strings);
    _ = c.slice(u8, lim.strings);
    P.mark(&c, &last, "strings x2");
    _ = l.draw_list.DrawList.init(&c, lim.nodes, lim.texts, lim.customs);
    P.mark(&c, &last, "draw list");
    _ = l.runtime_signals.Signals.init(&c, lim.signals);
    P.mark(&c, &last, "signals");
    _ = l.anims.Anims.init(&c, lim.anims);
    P.mark(&c, &last, "anims");
    _ = l.tweens.Tweens.init(&c, lim.tweens);
    P.mark(&c, &last, "tweens");
    _ = l.flip.Flips.init(&c, lim.flips);
    P.mark(&c, &last, "flips");
    _ = c.slice(u32, lim.depth);
    P.mark(&c, &last, "stack (depth)");
    _ = l.scheduler.Timers.init(&c, lim.timers);
    P.mark(&c, &last, "timers");
    _ = l.reuse.Memos.init(&c, lim.memos);
    P.mark(&c, &last, "memos");
    _ = l.levels.Levels.init(&c, lim.nodes);
    P.mark(&c, &last, "levels");
    _ = l.focus.Scopes.init(&c, lim.nodes);
    P.mark(&c, &last, "focus scopes");
    const req = l.context.Context.requiredBytes(lim);
    std.debug.print("  sum {d} requiredBytes {d} match={}\n", .{ c.off, req, c.off == req });

    const T = l.tree.Tree;
    const rows = T.rows(lim.nodes);
    var tc: mem.Carver = .{ .buf = null };
    _ = T.init(&tc, lim.nodes);
    const cols = colBytes(T.Columns, rows);
    const xs = colBytes(T.Extras, simd.rows(lim.nodes + 1));
    std.debug.print("  tree: Columns {d} + Extras {d} = {d}, Tree.init {d} match={}\n", .{ cols, xs, cols + xs, tc.off, cols + xs == tc.off });
}

pub fn main() void {
    std.debug.print("mode={t} lanes={d} @sizeOf(Context)={d}\n", .{ builtin.mode, simd.lanes, @sizeOf(l.context.Context) });
    std.debug.print("default Limits:\n", .{});
    report(.{});
    std.debug.print("example Limits (1024 nodes, 256 texts):\n", .{});
    report(.{ .nodes = 1024, .texts = 256 });
    const a = l.context.Context.requiredBytes(.{ .nodes = 4096 });
    const b = l.context.Context.requiredBytes(.{ .nodes = 8192 });
    std.debug.print("per node {d}\n", .{(b - a) / 4096});
    // Rounding up to simd row size is free? rows(cap) = padded(cap)+lanes; check bytes at cap..cap+lanes
    var prev: usize = 0;
    for (4090..4106) |n| {
        const r = l.context.Context.requiredBytes(.{ .nodes = @intCast(n) });
        std.debug.print("nodes {d}: {d} (+{d})\n", .{ n, r, if (prev == 0) 0 else r - prev });
        prev = r;
    }
}
