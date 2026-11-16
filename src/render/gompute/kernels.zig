//! The Gompute back end's kernels. This file is compiled twice (Gompute's model): as part of the
//! host module, where every `pub fn` below is an ordinary function the CPU path calls, and once
//! per GPU target (PTX for CUDA, HSACO for HIP), where the `comptime` block at the end exports
//! thin entry points that call the same functions per thread. One source, the same results.

const g = @import("gompute");

/// Threads per block in every launch (a multiple of both vendors' 32-lane groups).
pub const block = 256;

/// Pixel `i` of a clear: the colour, already in the framebuffer's byte order. Buffers are
/// `g.GlobalPtr`, a plain `[*]T` on the host, so the CPU path passes its own slices' pointers.
pub fn fill(px: g.GlobalPtr(u32), i: usize, value: u32) void {
    px[i] = value;
}

fn fillKernel(px: g.GlobalPtr(u32), len: u32, value: u32) callconv(g.kernel_callconv) void {
    const i = g.globalIdX(block);
    if (i < len) fill(px, i, value);
}

comptime {
    if (g.is_device) g.exportRaw("lcgr_fill", &fillKernel);
}
