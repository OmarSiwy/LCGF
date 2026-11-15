const std = @import("std");
const ui = @import("ui.zig");
const linux = std.os.linux;

const limits: ui.Limits = .{ .nodes = 4096, .texts = 2048, .strings = 128 * 1024 };
var buffer: [ui.Context.requiredBytes(limits)]u8 align(ui.mem.column_align) = undefined;

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var values: [400]f32 = @splat(0.5);
var pass_sum: [9]u64 = @splat(0);
var checks: [400]bool = @splat(false);

fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const base = ui.Id.from("row");
    for (0..330) |r| {
        const id = base.with(@intCast(r));
        _ = f.open(id, .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 6, .pad = @splat(2), .cross = .center });
        _ = ui.widgets.label(f, th, "Row label");
        _ = ui.widgets.button(f, th, id.with(1), "Apply");
        _ = ui.widgets.button(f, th, id.with(2), "Revert");
        _ = ui.widgets.checkbox(f, th, id.with(3), &checks[r], "Enabled");
        _ = ui.widgets.slider(f, th, id.with(4), &values[r], 0, 1);
        _ = f.leaf(.none, .{ .size = .{ .px(12), .px(12) }, .fill = th.accent });
        f.close();
    }
}

pub fn main() void {
    var ctx = ui.Context.init(&buffer, limits) catch unreachable;
    const th: ui.Theme = .{};
    var in: ui.Input = .{ .viewport = .{ 1280, 8000 } };
    const font: ui.fonts.Mono = .{};
    const N = 3000;
    var t_build: [N]u64 = undefined;
    var t_layout: [N]u64 = undefined;
    var t_paint: [N]u64 = undefined;
    var t_begin: [N]u64 = undefined;
    var sink: u64 = 0;
    for (0..N) |k| {
        in.pointer = .{ @floatFromInt(100 + (k * 7) % 900), @floatFromInt(50 + (k * 13) % 7000) };
        const a = now();
        var f = ctx.begin(&in); // includes the SIMD hit test and spring step
        const b = now();
        build(&f, &th);
        const c = now();
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        var m: [12]u64 = undefined;
        m[0] = now();
        font.measure(tx);
        m[1] = now();
        ui.layout.prepare(t);
        m[2] = now();
        ui.layout.applyText(t, tx, .x);
        ui.layout.fit(t, .x);
        m[3] = now();
        ui.layout.resolve(t, .x, in.viewport[0]);
        m[4] = now();
        ui.layout.textAvail(t, tx);
        font.wrap(tx);
        m[5] = now();
        ui.layout.applyText(t, tx, .y);
        ui.layout.fit(t, .y);
        m[6] = now();
        ui.layout.resolve(t, .y, in.viewport[1]);
        m[7] = now();
        ui.layout.place(t);
        m[8] = now();
        ui.layout.finalize(t);
        m[9] = now();
        for (0..9) |j| pass_sum[j] += m[j + 1] - m[j];
        const d = now();
        const out = f.finish();
        const e = now();
        sink +%= out.draw.cmd_len + out.draw.quad_len;
        t_begin[k] = b - a;
        t_build[k] = c - b;
        t_layout[k] = d - c;
        t_paint[k] = e - d;
        if (k == N - 1) std.debug.print("nodes={d} texts={d} quads={d} cmds={d} lanes={d} bytes={d}\n", .{ t.len, tx.len, out.draw.quad_len, out.draw.cmd_len, ui.simd.lanes, buffer.len });
    }
    inline for (.{ "begin+hit", "build", "layout", "paint" }, .{ &t_begin, &t_build, &t_layout, &t_paint }) |name, arr| {
        std.mem.sort(u64, arr, {}, std.sort.asc(u64));
        std.debug.print("{s:10} median {d:6.1} us   p99 {d:6.1} us\n", .{ name, @as(f64, @floatFromInt(arr[N / 2])) / 1000.0, @as(f64, @floatFromInt(arr[N * 99 / 100])) / 1000.0 });
    }
    std.debug.print("sink={d}\n", .{sink});
    inline for (.{ "measure", "prepare", "fit.x", "resolve.x", "wrap", "fit.y", "resolve.y", "place", "finalize" }, 0..) |name, j| {
        std.debug.print("  {s:10} mean {d:6.1} us\n", .{ name, @as(f64, @floatFromInt(pass_sum[j])) / 1000.0 / N });
    }
}
