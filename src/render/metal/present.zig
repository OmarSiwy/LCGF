//! A frame on the host's side: command buffer, render pass, present, and the timing of the
//! present. What GPUI's Metal renderer does per frame, as calls the host makes in its own loop:
//!
//!     var frames = Frames.init(dev.queue, 3); // same count as Desc.frames_in_flight
//!     ...each frame, inside an objc.Pool:
//!     gfx.prepare({}, &draw, glyphs, size, scale);   // after begin: the slot is free again
//!     const drawable = layer.nextDrawable() orelse continue;
//!     const cmd = frames.begin();
//!     const pass = beginPass(cmd, drawableTexture(drawable), .{ 0, 0, 0, 1 });
//!     gfx.render(pass, &draw);
//!     endPass(pass);
//!     frames.present(cmd, drawable, link.target(mediaTime(), 0.004));
//!
//! `Frames.begin` blocks until the GPU has finished the frame that last used the slot, so the
//! CPU never runs more than `count` frames ahead and never overwrites instances in use.
//! `DisplayLink` reports the display's vsync; presenting at `target` shows the frame at the
//! first vsync after the time the host needs, instead of whenever the GPU finishes.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const Id = objc.Id;
const msg = objc.msg;
const U = objc.NSUInteger;

pub const max_in_flight = 4;

pub const Frames = struct {
    queue: Id,
    count: u32,
    slot: u32 = 0,
    /// The committed command buffer of each slot, retained until the slot is reused.
    in_flight: [max_in_flight]?Id = @splat(null),

    pub fn init(queue: Id, count: u32) Frames {
        std.debug.assert(count >= 1 and count <= max_in_flight);
        return .{ .queue = queue, .count = count };
    }

    /// Waits for every frame in flight.
    pub fn deinit(f: *Frames) void {
        for (&f.in_flight) |*c| if (c.*) |cmd| {
            msg(void, cmd, "waitUntilCompleted", .{});
            objc.release(cmd);
            c.* = null;
        };
    }

    /// Waits until the GPU is done with this slot's previous frame, then returns a command
    /// buffer for the next one (autoreleased: call inside a pool).
    pub fn begin(f: *Frames) Id {
        if (f.in_flight[f.slot]) |old| {
            msg(void, old, "waitUntilCompleted", .{});
            objc.release(old);
            f.in_flight[f.slot] = null;
        }
        return msg(Id, f.queue, "commandBuffer", .{});
    }

    /// Schedules `drawable` for display, at host time `at` (seconds, CACurrentMediaTime's
    /// clock) when given, else as soon as the GPU is done, and commits `cmd`.
    pub fn present(f: *Frames, cmd: Id, drawable: Id, at: ?f64) void {
        if (at) |t| msg(void, cmd, "presentDrawable:atTime:", .{ drawable, t }) else msg(void, cmd, "presentDrawable:", .{drawable});
        msg(void, cmd, "commit", .{});
        f.in_flight[f.slot] = objc.retain(cmd);
        f.slot = (f.slot + 1) % f.count;
    }

    /// Presents inside the current Core Animation transaction, for a layer with
    /// `presentsWithTransaction` on (device.zig `setPresentsWithTransaction`, during a live
    /// resize): commits, waits until the GPU work is scheduled, then presents from the CPU, as
    /// Apple documents for that mode.
    pub fn presentInTransaction(f: *Frames, cmd: Id, drawable: Id) void {
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilScheduled", .{});
        msg(void, drawable, "present", .{});
        f.in_flight[f.slot] = objc.retain(cmd);
        f.slot = (f.slot + 1) % f.count;
    }
};

/// The layer's next drawable (autoreleased), or null when none came within a second.
pub fn nextDrawable(layer: Id) ?Id {
    return msg(?Id, layer, "nextDrawable", .{});
}

pub fn drawableTexture(drawable: Id) Id {
    return msg(Id, drawable, "texture", .{});
}

/// Opens a render pass on `cmd` that clears `target` to `clear` and stores it, and returns
/// its encoder, the renderer's `Pass` (autoreleased).
pub fn beginPass(cmd: Id, target: Id, clear: [4]f64) mtl.RenderEncoder {
    const rp = msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
    const color = msg(Id, msg(Id, rp, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(U, 0)});
    msg(void, color, "setTexture:", .{target});
    msg(void, color, "setLoadAction:", .{mtl.LoadAction.clear});
    msg(void, color, "setStoreAction:", .{mtl.StoreAction.store});
    msg(void, color, "setClearColor:", .{mtl.ClearColor{ .r = clear[0], .g = clear[1], .b = clear[2], .a = clear[3] }});
    return .{ .id = msg(Id, cmd, "renderCommandEncoderWithDescriptor:", .{rp}) };
}

pub fn endPass(pass: mtl.RenderEncoder) void {
    msg(void, pass.id, "endEncoding", .{});
}

/// When the display refreshes: a recent vsync and the refresh period, both in seconds of
/// CACurrentMediaTime's clock.
pub const Timing = struct {
    vsync: f64,
    period: f64,

    /// The first vsync at least `budget` seconds after `now`: the present time for a frame
    /// that needs `budget` more seconds of CPU and GPU work.
    pub fn target(t: Timing, now: f64, budget: f64) f64 {
        const k = @max(@ceil((now + budget - t.vsync) / t.period), 0);
        return t.vsync + k * t.period;
    }
};

/// CVTimeStamp, up to the fields read here (CVBase.h).
pub const CVTimeStamp = extern struct {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
};

comptime {
    std.debug.assert(@offsetOf(CVTimeStamp, "host_time") == 16);
    std.debug.assert(@offsetOf(CVTimeStamp, "video_refresh_period") == 32);
}

/// Seconds of `host` mach_absolute_time ticks, for a timebase of `numer` / `denom` ns per tick.
pub fn hostSeconds(host: u64, numer: u32, denom: u32) f64 {
    return @as(f64, @floatFromInt(host)) * @as(f64, @floatFromInt(numer)) / @as(f64, @floatFromInt(denom)) / 1e9;
}

/// The main display's vsync, from a CVDisplayLink (CoreVideo, opened at run time). Its thread
/// stores each output time here and, when set, calls `wake` (the shell's wake, so a waiting loop
/// runs); nothing else runs on it. Read the latest with `timing`.
pub const DisplayLink = struct {
    link: ?*anyopaque = null,
    stop_fn: *const fn (?*anyopaque) callconv(.c) i32 = undefined,
    release_fn: *const fn (?*anyopaque) callconv(.c) void = undefined,
    /// Host time of the latest vsync the link reported, in mach ticks; 0 before the first.
    latest: std.atomic.Value(u64) = .init(0),
    period_ticks: std.atomic.Value(u64) = .init(0),
    numer: u32 = 1,
    denom: u32 = 1,
    wake: ?*const fn (?*anyopaque) callconv(.c) void = null,
    wake_ctx: ?*anyopaque = null,

    pub const Error = error{ NoLibrary, MissingFunction, LinkFailed };
    const core_video = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo";

    /// Starts the link. `dl` must not move until `deinit`.
    pub fn start(dl: *DisplayLink) Error!void {
        const lib = std.c.dlopen(core_video, .{ .NOW = true }) orelse return error.NoLibrary;
        const create: *const fn (*?*anyopaque) callconv(.c) i32 = @ptrCast(@alignCast(std.c.dlsym(lib, "CVDisplayLinkCreateWithActiveCGDisplays") orelse return error.MissingFunction));
        const set_cb: *const fn (?*anyopaque, *const Callback, ?*anyopaque) callconv(.c) i32 = @ptrCast(@alignCast(std.c.dlsym(lib, "CVDisplayLinkSetOutputCallback") orelse return error.MissingFunction));
        const start_fn: *const fn (?*anyopaque) callconv(.c) i32 = @ptrCast(@alignCast(std.c.dlsym(lib, "CVDisplayLinkStart") orelse return error.MissingFunction));
        dl.stop_fn = @ptrCast(@alignCast(std.c.dlsym(lib, "CVDisplayLinkStop") orelse return error.MissingFunction));
        dl.release_fn = @ptrCast(@alignCast(std.c.dlsym(lib, "CVDisplayLinkRelease") orelse return error.MissingFunction));
        dl.numer, dl.denom = mach.timebase();
        if (create(&dl.link) != 0) return error.LinkFailed;
        errdefer dl.release_fn(dl.link);
        if (set_cb(dl.link, &output, dl) != 0 or start_fn(dl.link) != 0) return error.LinkFailed;
    }

    pub fn deinit(dl: *DisplayLink) void {
        if (dl.link == null) return;
        _ = dl.stop_fn(dl.link);
        dl.release_fn(dl.link);
        dl.link = null;
    }

    /// The latest vsync and period, or null before the link first fired.
    pub fn timing(dl: *const DisplayLink) ?Timing {
        const host = dl.latest.load(.acquire);
        if (host == 0) return null;
        return .{ .vsync = hostSeconds(host, dl.numer, dl.denom), .period = hostSeconds(dl.period_ticks.load(.monotonic), dl.numer, dl.denom) };
    }

    /// The present time for a frame needing `budget` seconds from `now`, or null (present at
    /// once) before the link first fired.
    pub fn target(dl: *const DisplayLink, now: f64, budget: f64) ?f64 {
        const t = dl.timing() orelse return null;
        return t.target(now, budget);
    }

    const Callback = fn (?*anyopaque, *const CVTimeStamp, *const CVTimeStamp, u64, *u64, ?*anyopaque) callconv(.c) i32;

    fn output(_: ?*anyopaque, now: *const CVTimeStamp, out: *const CVTimeStamp, _: u64, _: *u64, ctx: ?*anyopaque) callconv(.c) i32 {
        const dl: *DisplayLink = @ptrCast(@alignCast(ctx.?));
        // The period in host ticks: the gap between this output time and the current one is
        // not one period, so derive it from the video clock.
        const period_ns = @as(f64, @floatFromInt(out.video_refresh_period)) / @as(f64, @floatFromInt(@max(out.video_time_scale, 1))) * 1e9;
        dl.period_ticks.store(@intFromFloat(period_ns * @as(f64, @floatFromInt(dl.denom)) / @as(f64, @floatFromInt(dl.numer))), .monotonic);
        dl.latest.store(out.host_time, .release);
        _ = now;
        if (dl.wake) |w| w(dl.wake_ctx);
        return 0;
    }
};

/// CACurrentMediaTime: now, on the clock `present` and `Timing` use.
pub fn mediaTime() f64 {
    const tb = mach.timebase();
    return hostSeconds(mach.ticks(), tb[0], tb[1]);
}

/// The Mach clock; only Apple targets have it (elsewhere the tests that call it skip).
const mach = if (builtin.os.tag.isDarwin()) struct {
    fn ticks() u64 {
        return std.c.mach_absolute_time();
    }
    /// numer, denom: nanoseconds per tick.
    fn timebase() [2]u32 {
        var tb: std.c.mach_timebase_info_data = undefined;
        _ = std.c.mach_timebase_info(&tb);
        return .{ tb.numer, tb.denom };
    }
} else struct {
    fn ticks() u64 {
        unreachable;
    }
    fn timebase() [2]u32 {
        unreachable;
    }
};

const testing = std.testing;

test "present: the target is the first vsync after the frame's budget" {
    const t: Timing = .{ .vsync = 10, .period = 1.0 / 60.0 };
    try testing.expectApproxEqAbs(10 + 1.0 / 60.0, t.target(10.001, 0.004), 1e-12);
    try testing.expectApproxEqAbs(10 + 2.0 / 60.0, t.target(10.010, 0.010), 1e-12);
    try testing.expectEqual(@as(f64, 10), t.target(10, 0)); // exactly on a vsync
    try testing.expectEqual(@as(f64, 10), t.target(9, 0.5)); // a stale clock never goes back
}

test "present: host ticks to seconds with the machine's timebase" {
    try testing.expectEqual(@as(f64, 2), hostSeconds(2_000_000_000, 1, 1)); // Intel: 1 ns ticks
    try testing.expectApproxEqAbs(@as(f64, 1), hostSeconds(24_000_000, 125, 3), 1e-12); // Apple silicon: 24 MHz
}

test "present: a display link reports vsyncs on a real display" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var dl: DisplayLink = .{};
    dl.start() catch |e| if (e == error.LinkFailed) return error.SkipZigTest else return e; // no display (CI)
    defer dl.deinit();
    var tries: u32 = 0;
    while (dl.timing() == null and tries < 100) : (tries += 1) std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    const t = dl.timing() orelse return error.NoVsync;
    try testing.expect(t.period > 0.001 and t.period < 0.1);
    try testing.expect(t.target(mediaTime(), 0) >= mediaTime() - t.period);
}
