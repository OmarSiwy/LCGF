//! Fuzz entry points: hostile input streams and style values driven through whole frames.
//!
//! The model is the prototype test "running out of rows is reported, not fatal": whatever the host
//! or the caller hands in (NaN, infinities, huge sizes, unbalanced open/close, too many rows), a
//! frame must end without a crash.
//!
//! The core is imported as the named module "ui". Today build.zig points it at prototype/ui.zig;
//! when the core lands in src/, point the module there and keep these entry points.
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
//! Why two: on 0.17.1 the built-in fuzzer stops after a number of iterations, not a time, and the
//! build still exits 0 when a fuzzed test crashes. The seeded loop runs for a set time, exits
//! non-zero on a crash and prints the iteration that reproduces it.
const std = @import("std");
const ui = @import("ui");
const Smith = std.testing.Smith;

// Small limits so the overflow paths (rows, texts, strings, depth) are reached quickly.
const limits: ui.Limits = .{ .nodes = 64, .texts = 16, .customs = 4, .strings = 256, .anims = 8, .signals = 8, .memos = 4, .depth = 8 };
var buffer: [ui.Context.requiredBytes(limits)]u8 align(ui.mem.column_align) = undefined;

/// One frame's worth of host input. `text` backs `Input.text`.
fn input(s: anytype, text: []u8) ui.Input {
    return .{
        .time = s.value(f64),
        .dt = s.value(f32),
        .viewport = s.value([2]f32),
        .scale = s.value(f32),
        .pointer = s.value([2]f32),
        .buttons = s.value(ui.Input.Buttons),
        .wheel = s.value([2]f32),
        .mods = s.value(ui.Input.Mods),
        .keys = .{ .bits = s.value([4]u64) },
        .text = text[0..s.slice(text)],
    };
}

/// Walks the draw list the way a renderer does, so every command is decoded.
fn drain(out: ui.Output) !void {
    try std.testing.expect(out.tree.len <= limits.nodes);
    for (0..out.draw.cmd_len) |i| _ = out.draw.command(@intCast(i));
    _ = out.draw.quadBytes();
}

/// Entry point: many frames of arbitrary host input over a fixed UI.
pub fn inputStream(s: anytype) !void {
    var ctx = try ui.Context.init(&buffer, limits);
    const th: ui.Theme = .{};
    var flag = false;
    var level: f32 = 0;
    var text: [32]u8 = undefined;
    while (!s.eosWeightedSimple(16, 1)) {
        const in = input(s, &text);
        _ = ctx.needsFrame(&in);
        var f = ctx.begin(&in);
        _ = f.open(ui.Id.from("fuzz.row"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .clip = true });
        _ = ui.widgets.button(&f, &th, ui.Id.from("fuzz.button"), "button");
        _ = ui.widgets.checkbox(&f, &th, ui.Id.from("fuzz.check"), &flag, "check");
        _ = ui.widgets.slider(&f, &th, ui.Id.from("fuzz.slider"), &level, 0, 1);
        _ = f.animate(ui.Id.from("fuzz.spring"), level, .{});
        f.close();
        try drain(f.end(.{}));
    }
}

/// Entry point: arbitrary trees of arbitrary styles, built in any call order, under arbitrary input.
pub fn styleValues(s: anytype) !void {
    var ctx = try ui.Context.init(&buffer, limits);
    const th: ui.Theme = .{};
    var text: [32]u8 = undefined;
    var label: [48]u8 = undefined;
    var flag = false;
    var level: f32 = 0;
    while (!s.eosWeightedSimple(4, 1)) {
        const in = input(s, &text);
        var f = ctx.begin(&in);
        while (!s.eosWeightedSimple(32, 1)) {
            const id: ui.Id = @fromBackingInt(s.value(u32));
            switch (s.valueRangeLessThan(u8, 0, 10)) {
                0 => _ = f.open(id, s.value(ui.Style)),
                1 => f.close(),
                2 => _ = f.leaf(id, s.value(ui.Style)),
                3 => _ = f.textStyled(label[0..s.slice(&label)], s.value(ui.TextStyle), s.value(ui.Style)),
                4 => _ = f.custom(id, s.value(ui.Style), s.value(u64)),
                5 => _ = f.interact(f.open(id, s.value(ui.Style)), s.value(ui.Sense)),
                6 => _ = f.animate(id, s.value(f32), s.value(ui.Spring)),
                7 => _ = ui.widgets.button(&f, &th, id, label[0..s.slice(&label)]),
                8 => _ = ui.widgets.checkbox(&f, &th, id, &flag, label[0..s.slice(&label)]),
                9 => _ = ui.widgets.slider(&f, &th, id, &level, s.value(f32), s.value(f32)),
                else => unreachable,
            }
        }
        try drain(f.end(.{}));
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
