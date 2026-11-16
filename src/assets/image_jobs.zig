//! PNG decoding off the UI thread. The host fills a `Job` (the file and the memory `png.info`
//! asks for), `start`s it, and keeps drawing; the worker decodes and then sets two events: the
//! job's own `done`, and the host's `wake` if it gave one. One `wake` can serve any number of
//! jobs and anything else that wants the host's loop to run, so a host that sleeps on a single
//! event wakes when any image is ready, without polling and without a callback.
//!
//! The order is what makes it race free: the worker sets `done` before `wake`, so a host that
//! resets `wake` and then scans its jobs' `done` flags never misses one; a job that finishes
//! during the scan sets `wake` again and the next wait returns at once.
//!
//! Threads come from the host's `std.Io` (`io.concurrent`): the library starts none of its own
//! and owns no pool. The job's memory belongs to the caller and must outlive it; after `done`
//! is set, the host `await`s the future (immediate) and reads `result` and `pixels`.

const std = @import("std");
const png = @import("png.zig");

pub const Job = struct {
    file: []const u8,
    /// `png.info(file).pixelBytes()` and `.scratchBytes()` bytes.
    pixels: []u8,
    scratch: []u8,
    /// The host's event to set when this job finishes, after `done`.
    wake: ?*std.Io.Event = null,
    /// Set when `result` and `pixels` are final.
    done: std.Io.Event = .unset,
    /// What `png.decode` returned; read it after `done`.
    result: png.Error!png.Info = error.Truncated,
};

/// Decodes the job on the calling thread and signals it: the body of the worker.
pub fn run(io: std.Io, job: *Job) void {
    job.result = png.decode(job.file, job.pixels, job.scratch);
    job.done.set(io);
    if (job.wake) |w| w.set(io);
}

/// Runs `run(io, job)` on another thread of `io`. Fails when `io` has no concurrency (a
/// single-threaded build); the host can then call `run` itself.
pub fn start(io: std.Io, job: *Job) std.Io.ConcurrentError!std.Io.Future(void) {
    return io.concurrent(run, .{ io, job });
}

test "jobs decode on other threads and wake the host" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var files: [3][]u8 = undefined;
    var jobs: [3]Job = undefined;
    var wake: std.Io.Event = .unset;
    for (&files, &jobs, 0..) |*f, *job, k| {
        // Image k is (k + 1) x 2, every byte k + 7.
        const w: u32 = @intCast(k + 1);
        const raw = try gpa.alloc(u8, 2 * (1 + 4 * w));
        defer gpa.free(raw);
        @memset(raw, @intCast(k + 7));
        raw[0] = 0;
        raw[1 + 4 * w] = 0;
        f.* = try png.encodeForTest(gpa, w, 2, 8, .rgba, false, &.{}, raw);
        const i = try png.info(f.*);
        job.* = .{ .file = f.*, .pixels = try gpa.alloc(u8, i.pixelBytes()), .scratch = try gpa.alloc(u8, i.scratchBytes()), .wake = &wake };
    }
    defer for (files, jobs) |f, job| {
        gpa.free(f);
        gpa.free(job.pixels);
        gpa.free(job.scratch);
    };

    var futures: [3]std.Io.Future(void) = undefined;
    for (&futures, &jobs) |*fut, *job| fut.* = start(io, job) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    // The host loop: sleep on `wake`, then collect whatever finished.
    var collected: u32 = 0;
    var seen: [3]bool = @splat(false);
    while (collected < jobs.len) {
        try wake.wait(io);
        wake.reset();
        for (&jobs, &futures, &seen) |*job, *fut, *s| {
            if (s.* or !job.done.isSet()) continue;
            fut.await(io);
            s.* = true;
            collected += 1;
        }
    }
    for (jobs, 0..) |job, k| {
        const i = try job.result;
        try std.testing.expectEqual(k + 1, i.w);
        // Every byte k + 7, premultiplied by alpha k + 7.
        const v: u8 = @intCast((@as(u16, @intCast(k + 7)) * (k + 7) + 127) / 255);
        for (0..i.w * 2) |p| try std.testing.expectEqualSlices(u8, &.{ v, v, v, @intCast(k + 7) }, job.pixels[p * 4 ..][0..4]);
    }
}

test "a failed decode still signals" {
    const io = std.testing.io;
    var wake: std.Io.Event = .unset;
    var job: Job = .{ .file = "not a png", .pixels = &.{}, .scratch = &.{}, .wake = &wake };
    var fut = start(io, &job) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    try wake.wait(io);
    fut.await(io);
    try std.testing.expect(job.done.isSet());
    try std.testing.expectError(error.NotPng, job.result);
}
