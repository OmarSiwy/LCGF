//! One frame drawn by several threads, a band of rows each: pixels of different bands are
//! independent, so the threads share nothing but a counter of the next band (Blend2D's and
//! vello_cpu's multithreaded contexts split the target the same way). The caller's thread works
//! too; the others are spawned once and sleep between frames.
//!
//! Bands are taken from a counter, so more bands than threads balance a load whose rows are not
//! equally busy. But every band walks the whole draw list: a quad wholly above or below a band
//! costs two compares there (`Software.drawQuads`) and the read of its 136 bytes, so with
//! thousands of quads one band a thread is fastest.
//!
//!     var pool: bands.Pool = undefined;
//!     try pool.init(io, 4);
//!     defer pool.deinit();
//!     pool.run(pool.count, &frame_args, drawBand); // drawBand(args, k, n): gfx.frame(.{ .fb, .scissor = sw.tile(fb, k, n) }, ...)
//!
//! The renderer itself stays free of threads and of the OS; this file is for hosts that have both.

const std = @import("std");
const builtin = @import("builtin");

pub const max_threads = 16;

pub const Pool = struct {
    io: std.Io,
    /// Threads at work on a frame, the caller's included.
    count: u32,
    workers: [max_threads - 1]std.Thread = undefined,
    /// Bumped to start a frame; workers sleep on it.
    generation: std.atomic.Value(u32) = .init(0),
    /// Workers still on the current frame; the caller sleeps on it.
    pending: std.atomic.Value(u32) = .init(0),
    /// The next band to draw.
    next: std.atomic.Value(u32) = .init(0),
    bands: u32 = 0,
    context: *anyopaque = undefined,
    band: *const fn (context: *anyopaque, k: u32, n: u32) void = undefined,
    quit: bool = false,

    /// Spins before sleeping: a frame is a few hundred microseconds, a futex wake about ten.
    const spins = 1 << 12;

    /// Starts `count - 1` worker threads (at most `max_threads - 1`).
    /// A single-threaded build gets a pool of the caller's thread alone.
    pub fn init(pool: *Pool, io: std.Io, count: u32) std.Thread.SpawnError!void {
        pool.* = .{ .io = io, .count = if (builtin.single_threaded) 1 else std.math.clamp(count, 1, max_threads) };
        if (builtin.single_threaded) return;
        for (pool.workers[0 .. pool.count - 1], 0..) |*w, i| {
            w.* = std.Thread.spawn(.{ .stack_size = 1 << 18 }, worker, .{pool}) catch |err| {
                pool.count = @intCast(i + 1);
                pool.deinit();
                return err;
            };
        }
    }

    pub fn deinit(pool: *Pool) void {
        if (builtin.single_threaded) return;
        pool.quit = true;
        _ = pool.generation.fetchAdd(1, .release);
        pool.io.futexWake(u32, &pool.generation.raw, max_threads);
        for (pool.workers[0 .. pool.count - 1]) |w| w.join();
        pool.count = 1;
    }

    /// Calls `band(context, k, n)` once for each k < n, `count` at a time, and returns when all
    /// have. `context` must outlive the call.
    pub fn run(pool: *Pool, n: u32, context: anytype, comptime band: fn (@TypeOf(context), u32, u32) void) void {
        const erased = struct {
            fn call(c: *anyopaque, k: u32, total: u32) void {
                band(@ptrCast(@alignCast(c)), k, total);
            }
        };
        if (pool.count == 1 or n <= 1) {
            for (0..n) |k| band(context, @intCast(k), n);
            return;
        }
        pool.context = @ptrCast(@constCast(context));
        pool.band = erased.call;
        pool.bands = n;
        pool.next.store(0, .monotonic);
        pool.pending.store(pool.count - 1, .monotonic);
        _ = pool.generation.fetchAdd(1, .release);
        pool.io.futexWake(u32, &pool.generation.raw, max_threads);
        pool.work();
        var left = pool.pending.load(.acquire);
        var i: u32 = 0;
        while (left != 0) : (left = pool.pending.load(.acquire)) {
            if (i < spins) {
                std.atomic.spinLoopHint();
                i += 1;
            } else pool.io.futexWaitUncancelable(u32, &pool.pending.raw, left);
        }
    }

    fn work(pool: *Pool) void {
        while (true) {
            const k = pool.next.fetchAdd(1, .monotonic);
            if (k >= pool.bands) return;
            pool.band(pool.context, k, pool.bands);
        }
    }

    fn worker(pool: *Pool) void {
        var seen: u32 = 0;
        while (true) {
            var now = pool.generation.load(.acquire);
            var i: u32 = 0;
            while (now == seen) : (now = pool.generation.load(.acquire)) {
                if (i < spins) {
                    std.atomic.spinLoopHint();
                    i += 1;
                } else pool.io.futexWaitUncancelable(u32, &pool.generation.raw, seen);
            }
            seen = now;
            if (pool.quit) return;
            pool.work();
            if (pool.pending.fetchSub(1, .acq_rel) == 1) pool.io.futexWake(u32, &pool.pending.raw, 1);
        }
    }
};

test "every band drawn once" {
    var pool: Pool = undefined;
    try pool.init(std.testing.io, 3);
    defer pool.deinit();
    var hits: [37]std.atomic.Value(u32) = @splat(.init(0));
    for (0..50) |_| {
        pool.run(37, &hits, struct {
            fn band(h: *[37]std.atomic.Value(u32), k: u32, n: u32) void {
                std.debug.assert(n == 37);
                _ = h[k].fetchAdd(1, .monotonic);
            }
        }.band);
    }
    for (&hits) |*h| try std.testing.expectEqual(50, h.load(.monotonic));
}
