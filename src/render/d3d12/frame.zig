//! The frame loop over a waitable flip-model swapchain, as a host would write it. Not part of
//! the renderer: it is the host's synchronisation, shown once so every application need not
//! rediscover it.
//!
//! The swapchain is created with DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT and a
//! maximum latency of one frame. `begin` first waits on the swapchain's latency object, which
//! DXGI signals when the compositor can take another frame: the CPU starts a frame only when it
//! will be shown next, so input sampled at `begin` is at most one frame old on screen (the
//! reason the GPUI DirectX renderer and Windows Terminal use it). Then it waits on the fence of
//! the frame slot it reuses, so the slot's allocator and the renderer's ring slot are free.
//! A render thread runs this loop on its own (target F3); the latency wait is its only
//! blocking call besides the slot fence.
//!
//!     const f = try frames.begin(&d, &chain);
//!     gfx.prepare(f.slot, &draw, glyphs, viewport, scale);
//!     f.list.omSetRenderTarget(f.rtv);  f.list.clearRenderTargetView(f.rtv, .{ 0, 0, 0, 1 });
//!     gfx.render(f.list, &draw);
//!     _ = try frames.present(&d, &chain, f, 1);

const std = @import("std");
const com = @import("com.zig");
const device_mod = @import("device.zig");
const c = com.c;
const Error = com.Error;
const Device = device_mod.Device;
const Swapchain = device_mod.Swapchain;
const transition = device_mod.transition;

/// The swapchain flags the loop needs: pass to `Swapchain.init` (`.flags = frame.flags`).
pub const flags: u32 = c.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

pub const max_frames = 3;

/// One frame being recorded.
pub const Frame = struct {
    /// The frame slot: pass to `Renderer.prepare`.
    slot: u32,
    /// Recording, its back buffer already in RENDER_TARGET.
    list: *com.GraphicsCommandList,
    /// The back buffer and its RTV.
    buffer: *com.Resource,
    rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE,
};

pub const Frames = struct {
    allocators: [max_frames]*com.CommandAllocator = undefined,
    list: *com.GraphicsCommandList,
    /// Fence value that marks the end of the last frame recorded in each slot.
    done: [max_frames]u64 = @splat(0),
    count: u32,
    next: u32 = 0,
    latency: c.HANDLE,
    /// How long `begin` waits on the latency object before `error.Timeout`.
    wait_ms: u32 = 1000,

    /// `count` frames in flight (match the renderer's `Desc.frames`). The swapchain must have
    /// been made with `flags`.
    pub fn init(d: *const Device, chain: *const Swapchain, count: u32) Error!Frames {
        std.debug.assert(count >= 1 and count <= max_frames);
        std.debug.assert(chain.flags & flags != 0);
        var f: Frames = .{ .list = undefined, .count = count, .latency = undefined };
        var made: u32 = 0;
        errdefer for (f.allocators[0..made]) |a| com.release(a);
        while (made < count) : (made += 1) f.allocators[made] = try d.handle.createCommandAllocator(c.D3D12_COMMAND_LIST_TYPE_DIRECT);
        f.list = try d.handle.createCommandList(c.D3D12_COMMAND_LIST_TYPE_DIRECT, f.allocators[0], null);
        errdefer com.release(f.list);
        try f.list.close();
        try chain.handle.setMaximumFrameLatency(1);
        f.latency = chain.handle.getFrameLatencyWaitableObject();
        return f;
    }

    /// The GPU must be idle (`Device.waitIdle`).
    pub fn deinit(f: *Frames) void {
        _ = c.CloseHandle(f.latency);
        com.release(f.list);
        for (f.allocators[0..f.count]) |a| com.release(a);
    }

    /// Waits until the compositor can take a frame and the next slot is free, then returns
    /// the frame, recording, with its back buffer in RENDER_TARGET. `error.Timeout` when
    /// the latency object stays unsignalled for `wait_ms` (a hidden or minimised window may
    /// never signal it; the host skips the frame).
    pub fn begin(f: *Frames, d: *Device, chain: *const Swapchain) (Error || error{Timeout})!Frame {
        const signalled = c.WaitForSingleObjectEx(f.latency, f.wait_ms, 1) == c.WAIT_OBJECT_0;
        if (!signalled) return error.Timeout;
        const slot = f.next;
        try d.wait(f.done[slot]);
        try f.allocators[slot].reset();
        try f.list.reset(f.allocators[slot], null);
        const i = chain.current();
        f.list.resourceBarrier(&.{transition(chain.buffers[i], c.D3D12_RESOURCE_STATE_PRESENT, c.D3D12_RESOURCE_STATE_RENDER_TARGET)});
        return .{ .slot = slot, .list = f.list, .buffer = chain.buffers[i], .rtv = chain.rtv(i) };
    }

    /// Returns the back buffer to PRESENT, submits the frame and presents it, vsync'd
    /// (`sync_interval` 1) or at once (0). `error.DeviceLost` when the device is gone: the
    /// host then recreates device, swapchain, frames and renderer (device.zig). Whether the
    /// window showed it (`Swapchain.Shown`).
    pub fn present(
        f: *Frames,
        d: *Device,
        chain: *const Swapchain,
        frame: Frame,
        sync_interval: u32,
    ) Error!Swapchain.Shown {
        frame.list.resourceBarrier(&.{transition(frame.buffer, c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_PRESENT)});
        try frame.list.close();
        f.done[frame.slot] = try d.submit(&.{frame.list});
        f.next = (frame.slot + 1) % f.count;
        return chain.present(sync_interval);
    }
};

const testing = std.testing;

test "frame: the latency object paces a loop of presented frames" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var w = try device_mod.Window.init(64, 48, false);
    defer w.deinit();
    var chain = try Swapchain.init(&d, w.hwnd, .{ .width = 64, .height = 48, .flags = flags });
    defer chain.deinit();
    var frames = try Frames.init(&d, &chain, 2);
    defer frames.deinit();
    for (0..6) |n| {
        const f = try frames.begin(&d, &chain);
        try testing.expectEqual(@as(u32, @intCast(n % 2)), f.slot);
        f.list.omSetRenderTarget(f.rtv);
        f.list.clearRenderTargetView(f.rtv, .{ 0, 0, 0, 1 });
        _ = try frames.present(&d, &chain, f, 0);
    }
    try d.waitIdle();
    // Every frame's slot fence has passed.
    try testing.expect(d.fence.getCompletedValue() >= frames.done[0] and d.fence.getCompletedValue() >= frames.done[1]);
}
