//! Fuzz entry points: hostile input streams and style values driven through whole frames.
//!
//! Drives production runtime frames through input, layout, hit testing and paint, including
//! NaN, infinities, huge sizes, unbalanced open/close and exhausted table capacity.
//!
//! Each entry point takes a value source `s` with four methods (`value`, `valueRangeLessThan`,
//! `slice`, `eosWeightedSimple`). Two sources exist:
//!
//!   zig build fuzz                                run the std.testing.fuzz tests on their corpus
//!   zig build fuzz --fuzz=1M -Doptimize=ReleaseSafe   coverage-guided, 1M iterations (std.testing.Smith)
//!   zig build fuzz-run -Doptimize=ReleaseSafe -- [seconds] [seed] [first]
//!                                                  seeded random loop (`Rng`), bounded by time;
//!                                                  this is the CI job (ci/run.sh fuzz)
//!
//! The seeded loop runs for a set time, exits non-zero on a crash and prints the iteration
//! that reproduces it.
const std = @import("std");
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;
const Input = lcgf.input.Input;
const Id = lcgf.types.Id;
const widgets = lcgf.widgets_base;
const Smith = std.testing.Smith;

// Small limits so the overflow paths (rows, texts, strings, depth) are reached quickly.
const limits: lcgf.context.Limits = .{ .nodes = 64, .texts = 16, .customs = 4, .strings = 256, .anims = 8, .signals = 8, .memos = 4, .depth = 8 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;

/// One frame's worth of host input. `text` backs `Input.text`.
fn input(s: anytype, text: []u8) Input {
    return .{
        .time = s.value(f64),
        .dt = s.value(f32),
        .viewport = s.value([2]f32),
        .scale = s.value(f32),
        .pointer = s.value([2]f32),
        .buttons = s.value(Input.Buttons),
        .wheel = s.value([2]f32),
        .mods = s.value(Input.Mods),
        .keys = .{ .bits = s.value([4]u64) },
        .text = text[0..s.slice(text)],
    };
}

/// Check real rows only. Unbalanced opens may leave unfinished subtrees at frame end.
fn checkFrame(out: lcgf.context.Output, pointer: [2]f32) !void {
    const tree = out.tree;
    try std.testing.expect(tree.len > 0 and tree.len <= limits.nodes);
    try std.testing.expectEqual(0, tree.c.parent[0]);
    var expected_hit = lcgf.types.none;
    const sense_mask: u8 = @bitCast(lcgf.types.Sense.any);
    for (0..tree.len) |i| {
        if (i != 0) try std.testing.expect(tree.c.parent[i] < i);
        try std.testing.expect(i < tree.c.end[i] and tree.c.end[i] <= tree.len);
        const vis = tree.c.vis;
        if (tree.c.sense[i] & sense_mask != 0 and
            pointer[0] >= vis[0][i] and pointer[0] < vis[2][i] and
            pointer[1] >= vis[1][i] and pointer[1] < vis[3][i]) expected_hit = @intCast(i);
    }
    try std.testing.expectEqual(expected_hit, lcgf.hit.at(tree, pointer[0], pointer[1], .any));

    const draw = out.draw;
    for (0..draw.cmd_len) |i| switch (draw.command(@intCast(i))) {
        .quads => |batch| try std.testing.expect(batch.first + batch.count <= draw.quad_len),
        .text => |index| try std.testing.expect(index < draw.run_len),
        .custom, .canvas => |index| try std.testing.expect(index < draw.custom_len),
    };
    try std.testing.expectEqual(draw.quad_len * @sizeOf(lcgf.draw_list.Quad), draw.quadBytes().len);
}

/// Entry point: many frames of arbitrary host input over a fixed UI.
pub fn inputStream(s: anytype) !void {
    var ctx = try Context.init(&buffer, limits);
    const th: widgets.Theme = .{};
    var flag = false;
    var level: f32 = 0;
    var text: [32]u8 = undefined;
    while (!s.eosWeightedSimple(16, 1)) {
        const in = input(s, &text);
        _ = ctx.needsFrame(&in);
        var f = ctx.begin(&in);
        _ = f.open(Id.from("fuzz.row"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .clip = true });
        _ = widgets.button(&f, &th, Id.from("fuzz.button"), "button");
        _ = widgets.checkbox(&f, &th, Id.from("fuzz.check"), &flag, "check");
        _ = widgets.slider(&f, &th, Id.from("fuzz.slider"), &level, 0, 1);
        _ = f.animate(Id.from("fuzz.spring"), level, .{});
        f.close();
        try checkFrame(f.end(.{}), in.pointer);
    }
}

/// Entry point: arbitrary trees of arbitrary styles, built in any call order, under arbitrary input.
pub fn styleValues(s: anytype) !void {
    var ctx = try Context.init(&buffer, limits);
    const th: widgets.Theme = .{};
    var text: [32]u8 = undefined;
    var label: [48]u8 = undefined;
    var flag = false;
    var level: f32 = 0;
    while (!s.eosWeightedSimple(4, 1)) {
        const in = input(s, &text);
        var f = ctx.begin(&in);
        while (!s.eosWeightedSimple(32, 1)) {
            const id: Id = @fromBackingInt(s.value(u32));
            switch (s.valueRangeLessThan(u8, 0, 10)) {
                0 => _ = f.open(id, s.value(lcgf.types.Style)),
                1 => f.close(),
                2 => _ = f.leaf(id, s.value(lcgf.types.Style)),
                3 => _ = f.textStyled(label[0..s.slice(&label)], s.value(lcgf.types.TextStyle), s.value(lcgf.types.Style)),
                4 => _ = f.custom(id, s.value(lcgf.types.Style), s.value(u64)),
                5 => _ = f.interact(f.open(id, s.value(lcgf.types.Style)), s.value(lcgf.types.Sense)),
                6 => _ = f.animate(id, s.value(f32), s.value(lcgf.anims.Spring)),
                7 => _ = widgets.button(&f, &th, id, label[0..s.slice(&label)]),
                8 => _ = widgets.checkbox(&f, &th, id, &flag, label[0..s.slice(&label)]),
                9 => _ = widgets.slider(&f, &th, id, &level, s.value(f32), s.value(f32)),
                else => unreachable,
            }
        }
        try checkFrame(f.end(.{}), in.pointer);
    }
}

const entry_points = .{ inputStream, styleValues };

test "fuzz input streams" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *Smith) anyerror!void {
            return inputStream(s);
        }
    }.one, .{});
}

test "fuzz style values" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *Smith) anyerror!void {
            return styleValues(s);
        }
    }.one, .{});
}

/// The seeded source. Half of all floats are raw bit patterns (NaN, infinities, denormals,
/// huge), half are plain values a layout can actually use.
const Rng = struct {
    r: std.Random,

    pub fn value(g: Rng, comptime T: type) T {
        switch (@typeInfo(T)) {
            .bool => return g.r.boolean(),
            .int => return g.r.int(T),
            .float => return if (g.r.boolean())
                @bitCast(g.r.int(@Int(.unsigned, @bitSizeOf(T))))
            else
                (g.r.float(T) - 0.25) * 2000,
            .@"enum" => |e| return if (e.mode == .exhaustive)
                g.r.enumValueWithIndex(T, u32)
            else
                @fromBackingInt(g.r.int(e.tag_type)),
            .optional => |o| return if (g.r.boolean()) null else g.value(o.child),
            .array => |a| {
                var out: T = undefined;
                for (&out) |*x| x.* = g.value(a.child);
                return out;
            },
            .@"struct" => |st| {
                var out: T = undefined;
                inline for (st.field_names, st.field_types) |name, FT| @field(out, name) = g.value(FT);
                return out;
            },
            else => @compileError("no random " ++ @typeName(T)),
        }
    }

    pub fn valueRangeLessThan(g: Rng, comptime T: type, at_least: T, less_than: T) T {
        return g.r.intRangeLessThan(T, at_least, less_than);
    }

    pub fn slice(g: Rng, buf: []u8) u32 {
        const n = g.r.uintAtMost(usize, buf.len);
        g.r.bytes(buf[0..n]);
        return @intCast(n);
    }

    pub fn eosWeightedSimple(g: Rng, false_weight: u64, true_weight: u64) bool {
        return g.r.uintLessThan(u64, false_weight + true_weight) < true_weight;
    }
};

var current: struct { seed: u64 = 0, iteration: u64 = 0 } = .{};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("fuzz: crash at seed {d} iteration {d}; reproduce with: zig build fuzz-run -- 0 {d} {d}\n", .{
        current.seed, current.iteration, current.seed, current.iteration,
    });
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Runs every entry point on iteration `first`, `first + 1`, ... until `seconds` have passed
/// (at least one iteration). Iteration `i` draws from a PRNG seeded with `seed + i`, so one
/// iteration can be rerun alone.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const seconds = try std.fmt.parseInt(u64, args.next() orelse "60", 10);
    current.seed = try std.fmt.parseInt(u64, args.next() orelse "1", 10);
    current.iteration = try std.fmt.parseInt(u64, args.next() orelse "0", 10);

    const t0 = std.Io.Timestamp.now(io, .awake);
    var runs: u64 = 0;
    var ns: u64 = 0;
    while (runs == 0 or ns < seconds * std.time.ns_per_s) : (current.iteration += 1) {
        var prng: std.Random.DefaultPrng = .init(current.seed +% current.iteration);
        const g: Rng = .{ .r = prng.random() };
        inline for (entry_points) |entry| entry(g) catch |err| std.debug.panic("{t}", .{err});
        runs += 1;
        ns = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
    }
    std.debug.print("fuzz: {d} iterations x {d} entry points in {d}.{d:0>3} s, seed {d}, no crash\n", .{
        runs, entry_points.len, ns / std.time.ns_per_s, (ns / std.time.ns_per_ms) % 1000, current.seed,
    });
}
