//! The scenes of bench/scenes/ on LCGF, for the comparison of docs/perf/vs.md. The driver is
//! bench/vs/harness.h's, line for line (arguments, 3,000 polls on the monotonic clock, median
//! and p99, `--idle` and its "ready" line), so every row runs the same loop; only the frame is
//! LCGF's. A frame asks `Context.needsFrame` first, as an LCGF host does, and builds only when it
//! says yes (list and springs always build: their state changes outside `Input`). It does what
//! the Clay harness does and nothing else; the per-pass benchmark and its checks are bench/micro.
//!
//! No libc: a Zig program needs none, so start-up, output and the clock are system calls. The
//! context's buffer is mapped on first use, as Clay mallocs its arena: memory the scenes never
//! touch never becomes resident.
const std = @import("std");
const lcgf = @import("lcgf");
const scenes = @import("scenes");
const linux = std.os.linux;

/// No panic handler in the measured builds (it would be most of the binary). The safe build is
/// the checked twin of ci/jobs/vs-lcgf-check.sh and says what failed.
const checked = @import("builtin").mode == .safe;
pub const panic = if (checked) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.no_panic;
/// No thread-local signal stack (std's default is 256 KB, cleared at start-up).
pub const std_options: std.Options = .{ .signal_stack_size = null };

const Context = lcgf.context.Context;
/// Nodes per scene in harness.h's order: its `vs_capacity`, which every harness sizes for.
const capacity = [_]u32{ 256, 256, 256, 2048, 256, 256 };
const polls = 3000;

var ctx: Context = undefined;
/// Static, as harness.h's: a frame of 24 KB would be probed page by page even under `--idle`.
var samples: [polls]u64 = undefined;
var in: lcgf.input.Input = .{};
/// `--digest`: a hash of every frame's draw list, printed in place of the timings, so two
/// builds of this driver can be told to draw the same bytes (ci/jobs/vs-lcgf-check.sh).
var digesting = false;
var digest: u64 = 0;
/// Not in the size build, whose bytes are published as the row's executable size.
const digests = @import("builtin").mode != .small;

/// Folds the bytes of `rows`' fields into the digest, field by field (no padding bytes).
fn fold(comptime T: type, rows: []const T) void {
    if (@typeInfo(T) != .@"struct") {
        digest = std.hash.Wyhash.hash(digest, std.mem.sliceAsBytes(rows));
        return;
    }
    for (rows) |*row| inline for (@typeInfo(T).@"struct".field_names) |name| {
        digest = std.hash.Wyhash.hash(digest, std.mem.asBytes(&@field(row, name)));
    };
}

fn foldDraw(d: *const lcgf.draw_list.DrawList) void {
    fold(lcgf.draw_list.Quad, d.quads[0..d.quad_len]);
    fold(u8, d.cmd.kind[0..d.cmd_len]);
    fold(u32, d.cmd.key[0..d.cmd_len]);
    fold(u32, d.cmd.first[0..d.cmd_len]);
    fold(u32, d.cmd.count[0..d.cmd_len]);
    fold(@TypeOf(d.runs[0]), d.runs[0..d.run_len]);
    fold(@TypeOf(d.customs[0]), d.customs[0..d.custom_len]);
}
const th: lcgf.widgets_base.Theme = .{};

/// Builds poll `k` of `s`: the commands and quads drawn, or 0 when no frame was needed.
fn frame(scene: usize, k: u32) u64 {
    const s = &scenes.vs[scene];
    if (k == 0) {
        const n = capacity[scene];
        const limits: lcgf.context.Limits = .{ .nodes = n, .texts = n, .strings = 32 * 1024, .anims = n };
        const bytes = Context.requiredBytes(limits);
        const p = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        const buf: [*]align(lcgf.mem.column_align) u8 = @ptrFromInt(p);
        ctx = Context.initZeroed(buf[0..bytes], limits) catch unreachable;
    }
    s.input(&in, k);
    if (!s.every and !ctx.needsFrame(&in)) return 0;
    var f = ctx.begin(&in);
    s.build(&f, &th);
    const out = f.end(.{});
    if (digests and digesting) foldDraw(out.draw);
    return out.draw.cmd_len + out.draw.quad_len;
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Output without std.fmt: strings, integers and microseconds to one decimal.
const Out = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn str(o: *Out, s: []const u8) void {
        @memcpy(o.buf[o.len..][0..s.len], s);
        o.len += s.len;
    }
    fn int(o: *Out, v: u64) void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var x = v;
        while (true) {
            i -= 1;
            tmp[i] = @intCast('0' + x % 10);
            x /= 10;
            if (x == 0) break;
        }
        o.str(tmp[i..]);
    }
    fn us(o: *Out, ns: u64) void {
        const tenths = (ns + 50) / 100;
        o.str(" ");
        o.int(tenths / 10);
        o.str(".");
        o.int(tenths % 10);
    }
    fn flush(o: *Out) void {
        _ = linux.write(1, &o.buf, o.len);
        o.len = 0;
    }
};

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

fn blockOnStdin() void {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = linux.read(0, &byte, 1);
        switch (linux.errno(n)) {
            .SUCCESS => if (n == 0) return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    var scene: usize = 0;
    var idle = false;
    var hold = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (eql(argv[i], "--idle")) {
            idle = true;
            scene = scenes.vs.len - 1;
        } else if (eql(argv[i], "--hold-after-scene")) {
            hold = true;
        } else if (digests and eql(argv[i], "--digest")) {
            digesting = true;
        } else if (eql(argv[i], "--scene") and i + 1 < argv.len) {
            i += 1;
            scene = for (scenes.vs, 0..) |s, n| {
                if (eql(argv[i], s.name)) break n;
            } else return 2;
        } else return 2;
    }
    if (hold and idle) return 2;
    const s = &scenes.vs[scene];
    var o: Out = .{};
    if (idle) {
        const out = frame(scene, 0);
        o.str("ready framework=lcgf out=");
        o.int(out);
        o.str("\n");
        o.flush();
        blockOnStdin();
        return 0;
    }
    var sink: u64 = 0;
    var out: u64 = 0;
    var built: u64 = 0;
    for (&samples, 0..) |*t, k| {
        const t0 = now();
        out = frame(scene, @intCast(k));
        t.* = now() - t0;
        sink +%= out;
        built += @intFromBool(out != 0);
    }
    // Heap sort: in place and about 5 KB smaller than std.mem.sort's block sort, which was a
    // fifteenth of this row's executable bytes. The other harnesses call libc's qsort.
    std.sort.heap(u64, &samples, {}, std.sort.asc(u64));
    o.str("framework=lcgf scene=");
    o.str(s.name);
    o.str(" frames=");
    o.int(built);
    o.str(" polls=3000 out=");
    o.int(out);
    o.str(" sink=");
    o.int(sink);
    if (digests and digesting) {
        o.str(" digest=");
        o.int(digest);
        o.str("\n");
        o.flush();
        return 0;
    }
    o.str("\npass       median us    p99 us\nframe     ");
    o.us(samples[polls / 2]);
    o.us(samples[polls * 99 / 100]);
    o.str("\n");
    if (hold) o.str("scene complete\n");
    o.flush();
    if (hold) blockOnStdin();
    return 0;
}
