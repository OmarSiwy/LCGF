//! Scheduler: when the host must run a frame and when it may sleep (tier 1). The host asks
//! `Context.needsFrame` before building a frame and sleeps until the next event when it is false.
//! Ported from prototype/ui.zig (`Context.needsFrame`).

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;
const Context = @import("context.zig").Context;
const Limits = @import("context.zig").Limits;

/// False when a frame built from `in` would be identical to the last one: the input is unchanged
/// (its stamp leaves out the clock), nothing moves, no settle frame is owed and no signal changed.
/// The host can then sleep until the next event.
pub fn needsFrame(ctx: *const Context, in: *const Input) bool {
    const changed = simd.orB(ctx.frame == 0, in.stamp() != ctx.last_stamp);
    const pending = simd.orB(ctx.motion > 0, simd.orB(ctx.settle > 0, ctx.dirty));
    return simd.orB(changed, pending);
}

const testing = std.testing;

/// A context over a static buffer, for tests.
fn Fixture(comptime limits: Limits) type {
    return struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        fn context() !Context {
            return Context.init(&buffer, limits);
        }
    };
}

const small: Limits = .{ .nodes = 16, .texts = 2, .customs = 1, .strings = 64, .depth = 4 };

fn frame(ctx: *Context, in: *const Input) f32 {
    var f = ctx.begin(in);
    _ = f.leaf(.from("box"), .{ .size = .{ .px(10), .px(10) } });
    return f.end(.{}).wake;
}

test "needsFrame: the first frame, then only input changes, motion and signals" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    // Nothing was ever built.
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    // The settle frame after the change is still owed.
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    // The clock is not input: time passing alone wakes nothing.
    in.time += 10;
    try testing.expect(!ctx.needsFrame(&in));

    in.pointer = .{ 5, 5 };
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    // A moving spring keeps frames coming until it rests.
    ctx.motion = 0.5;
    try testing.expect(ctx.needsFrame(&in));
    ctx.motion = 0;

    // A signal bumped between frames wakes the host; the frame that sees it clears it.
    ctx.dirty = true;
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));
}

test "needsFrame: moving springs ask for a frame now through wake" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 100 } };
    _ = frame(&ctx, &in);
    try testing.expectEqual(types.inf, frame(&ctx, &in));
    var f = ctx.begin(&in);
    ctx.motion = 0.25;
    try testing.expectEqual(@as(f32, 0), f.end(.{}).wake);
}

/// What an event-driven host did over `ticks` turns of its loop with no new input: frames it
/// built (`needsFrame` held) and timed wakeups it would have armed (a finite `wake`).
const Idle = struct { frames: u32 = 0, wakeups: u32 = 0 };

fn idle(ctx: *Context, in: *Input, ticks: u32) Idle {
    var r: Idle = .{};
    for (0..ticks) |_| {
        in.time += in.dt;
        if (!ctx.needsFrame(in)) continue;
        r.frames += 1;
        r.wakeups += @intFromBool(frame(ctx, in) != types.inf);
    }
    return r;
}

test "idle: zero frames and zero wakeups without input" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    // Start-up: the first frame and its settle frame, which asks for no timed wake.
    try testing.expectEqual(Idle{ .frames = 2, .wakeups = 1 }, idle(&ctx, &in, 2));
    try testing.expectEqual(Idle{}, idle(&ctx, &in, 600));
    // One input change: one frame and one settle frame, then idle again.
    in.pointer = .{ 3, 3 };
    try testing.expectEqual(Idle{ .frames = 2, .wakeups = 1 }, idle(&ctx, &in, 600));
}
