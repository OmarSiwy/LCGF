//! The Gompute back end (experimental, docs/DESIGN.md): the renderer's work as compute kernels
//! written in Zig (kernels.zig), launched on CUDA or HIP through Gompute, or called as plain
//! functions on the CPU when there is no driver or card. Outside the tiers and not exported from
//! lcgr.zig: it needs the Gompute package (build.zig.zon, lazy), so it is a module of its own over
//! lcgr (`zig build gompute`), never imported by it. Decisions and measurements: DECISION.md.

const std = @import("std");
const g = @import("gompute");
pub const kernels = @import("kernels.zig");

/// Clears `px` to `value` on the CPU: the kernel's per-thread function, once per pixel.
pub fn fillCpu(px: []u32, value: u32) void {
    for (0..px.len) |i| kernels.fill(px.ptr, i, value);
}

/// Blocks of `kernels.block` threads covering `n` items.
pub fn grid(n: usize) g.Dim3 {
    return g.Dim3.linear(n, kernels.block);
}

const testing = std.testing;

test "fill: the CPU path and, when present, the CUDA device write the same pixels" {
    var cpu: [1000]u32 = @splat(0);
    fillCpu(&cpu, 0xff20_4060);
    for (cpu) |p| try testing.expectEqual(0xff20_4060, p);

    if (comptime !g.available(.cuda)) return;
    var k = g.RawKernel("lcgr_fill", .cuda).init(0) catch return; // no driver or no card
    defer k.deinit();
    var buf = try k.alloc(@sizeOf(@TypeOf(cpu)));
    defer buf.free();
    var len: u32 = cpu.len;
    var value: u32 = 0xff20_4060;
    try k.launch(grid(len), .{ .x = kernels.block }, 0, &.{ buf.argPtr(), g.interface.arg(&len), g.interface.arg(&value) });
    try k.synchronize();
    var gpu: [1000]u32 = @splat(0);
    try buf.download(&gpu, @sizeOf(@TypeOf(gpu)));
    try testing.expectEqualSlices(u32, &cpu, &gpu);
}
