//! The device and its direct queue, and a flip-model swapchain: what a Direct3D 12 host owns
//! before it draws anything. Not part of the renderer: it keeps none of these, it is given the
//! device and draws into the host's command list.
//!
//! Flip model (DXGI_SWAP_EFFECT_FLIP_DISCARD) is the only kind D3D12 allows: the swapchain's
//! buffers are handed to the compositor without a copy, which is also what makes the waitable
//! latency object of frame.zig possible.

const std = @import("std");
const com = @import("com.zig");
const c = com.c;
const Error = com.Error;

pub const AdapterChoice = enum {
    /// The WARP software rasteriser. Wine has none (EnumWarpAdapter is a stub there); `init`
    /// then takes the first adapter, which under Wine is vkd3d over whatever Vulkan driver the
    /// host has (Mesa lavapipe in ci/jobs/d3d12.sh: a software rasteriser too).
    warp,
    /// The first adapter DXGI lists: the primary GPU.
    default,
};

pub const Desc = struct {
    adapter: AdapterChoice = .default,
    /// Enables the D3D12 debug layer when the system has it.
    debug: bool = false,
};

pub const Device = struct {
    factory: *com.Factory,
    adapter: *com.Adapter,
    handle: *com.Device,
    queue: *com.CommandQueue,
    /// Signalled by the queue after each `submit`; `waitIdle` waits for its last value.
    fence: *com.Fence,
    fence_value: u64 = 0,
    event: c.HANDLE,
    /// True when `.warp` was asked for and DXGI gave the WARP adapter.
    warp: bool = false,

    pub fn init(desc: Desc) Error!Device {
        if (desc.debug) _ = com.Debug.enable();
        const factory = try com.Factory.create(desc.debug);
        errdefer com.release(factory);
        var adapter: ?*com.Adapter = null;
        var warp = false;
        if (desc.adapter == .warp) {
            const result = factory.enumWarpAdapter(&adapter);
            if (result != com.E_NOTIMPL) try com.check(result);
            warp = adapter != null;
        }
        if (adapter == null) try com.check(factory.enumAdapters1(0, &adapter));
        errdefer com.release(adapter);
        const handle = try com.Device.create(adapter);
        errdefer com.release(handle);
        const queue = try handle.createCommandQueue(&.{ .Type = c.D3D12_COMMAND_LIST_TYPE_DIRECT, .Priority = 0, .Flags = c.D3D12_COMMAND_QUEUE_FLAG_NONE, .NodeMask = 0 });
        errdefer com.release(queue);
        const fence = try handle.createFence(0);
        errdefer com.release(fence);
        const event = c.CreateEventW(null, 0, 0, null) orelse return error.D3D12Failed;
        return .{ .factory = factory, .adapter = adapter.?, .handle = handle, .queue = queue, .fence = fence, .event = event, .warp = warp };
    }

    pub fn deinit(d: *Device) void {
        d.waitIdle() catch {};
        _ = c.CloseHandle(d.event);
        com.release(d.fence);
        com.release(d.queue);
        com.release(d.handle);
        com.release(d.adapter);
        com.release(d.factory);
    }

    /// The adapter's name, as UTF-8 into `buf` ("Microsoft Basic Render Driver" for WARP).
    pub fn adapterName(d: *const Device, buf: []u8) []const u8 {
        const desc = d.adapter.getDesc1() catch return "";
        const wide = std.mem.sliceTo(&desc.Description, 0);
        var n: usize = 0;
        for (wide) |ch| {
            if (n == buf.len) break;
            buf[n] = if (ch < 0x80) @intCast(ch) else '?';
            n += 1;
        }
        return buf[0..n];
    }

    /// Submits closed command lists and signals the fence after them; returns the value that
    /// marks their completion (`wait`).
    pub fn submit(d: *Device, lists: []const *com.GraphicsCommandList) Error!u64 {
        d.queue.executeCommandLists(lists);
        d.fence_value += 1;
        try d.queue.signal(d.fence, d.fence_value);
        return d.fence_value;
    }

    /// Blocks until the queue has passed `value`. A lost device never gets there: the fence
    /// then reads UINT64_MAX, and this returns `error.DeviceLost`.
    pub fn wait(d: *Device, value: u64) Error!void {
        var done = d.fence.getCompletedValue();
        if (done < value) {
            try d.fence.setEventOnCompletion(value, d.event);
            _ = c.WaitForSingleObject(d.event, c.INFINITE);
            done = d.fence.getCompletedValue();
        }
        if (done == std.math.maxInt(u64)) return error.DeviceLost;
        try com.check(d.handle.getDeviceRemovedReason());
    }

    pub fn waitIdle(d: *Device) Error!void {
        d.fence_value += 1;
        try d.queue.signal(d.fence, d.fence_value);
        try d.wait(d.fence_value);
    }

    /// Why the device was lost, or S_OK while it works.
    ///
    /// DEVICE REMOVAL. A driver update, a GPU reset, a TDR or an unplugged eGPU removes the
    /// device; every call then fails or does nothing, and the next present, fence wait or
    /// submit returns `error.DeviceLost` (com.check maps DXGI_ERROR_DEVICE_REMOVED, _RESET and
    /// _HUNG to it; `wait` sees the fence jump to UINT64_MAX). Nothing made from the device can
    /// be reused: the host releases everything in reverse order (renderer, frames, swapchain,
    /// textures, device; `deinit` does not wait on a lost device past the fence) and creates
    /// them again on a new `Device.init`, against the same window. scenes.zig's
    /// "device removal" test does exactly that.
    pub fn removedReason(d: *const Device) com.HRESULT {
        return d.handle.getDeviceRemovedReason();
    }

    /// Puts the device in the removed state (ID3D12Device5::RemoveDevice), to test recovery.
    pub fn remove(d: *Device) Error!void {
        try com.Device5.removeDevice(d.handle);
    }

    /// A committed buffer. `upload` puts it in an UPLOAD heap (CPU-written, GPU-read, in the
    /// GENERIC_READ state for its whole life); otherwise in a READBACK heap (GPU-written by
    /// copies, in COPY_DEST).
    pub fn createBuffer(d: *const Device, bytes: u64, heap: c.D3D12_HEAP_TYPE) Error!*com.Resource {
        const desc: c.D3D12_RESOURCE_DESC = .{
            .Dimension = c.D3D12_RESOURCE_DIMENSION_BUFFER,
            .Alignment = 0,
            .Width = bytes,
            .Height = 1,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = c.DXGI_FORMAT_UNKNOWN,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = c.D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
            .Flags = c.D3D12_RESOURCE_FLAG_NONE,
        };
        const state: c.D3D12_RESOURCE_STATES = if (heap == c.D3D12_HEAP_TYPE_UPLOAD) c.D3D12_RESOURCE_STATE_GENERIC_READ else c.D3D12_RESOURCE_STATE_COPY_DEST;
        return d.handle.createCommittedResource(&heapProps(heap), &desc, state, null);
    }

    /// A 2D RGBA8 texture in a DEFAULT heap, in `state`. `render_target` allows RTVs on it.
    pub fn createTexture(d: *const Device, width: u32, height: u32, format: c.DXGI_FORMAT, render_target: bool, state: c.D3D12_RESOURCE_STATES) Error!*com.Resource {
        const desc: c.D3D12_RESOURCE_DESC = .{
            .Dimension = c.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .Alignment = 0,
            .Width = width,
            .Height = height,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = c.D3D12_TEXTURE_LAYOUT_UNKNOWN,
            .Flags = if (render_target) c.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET else c.D3D12_RESOURCE_FLAG_NONE,
        };
        return d.handle.createCommittedResource(&heapProps(c.D3D12_HEAP_TYPE_DEFAULT), &desc, state, null);
    }
};

pub fn heapProps(kind: c.D3D12_HEAP_TYPE) c.D3D12_HEAP_PROPERTIES {
    return .{ .Type = kind, .CPUPageProperty = c.D3D12_CPU_PAGE_PROPERTY_UNKNOWN, .MemoryPoolPreference = c.D3D12_MEMORY_POOL_UNKNOWN, .CreationNodeMask = 1, .VisibleNodeMask = 1 };
}

/// A transition barrier for all subresources of `res`.
pub fn transition(res: *com.Resource, before: c.D3D12_RESOURCE_STATES, after: c.D3D12_RESOURCE_STATES) c.D3D12_RESOURCE_BARRIER {
    var b: c.D3D12_RESOURCE_BARRIER = std.mem.zeroes(c.D3D12_RESOURCE_BARRIER);
    b.Type = c.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.unnamed_0.Transition = .{ .pResource = @ptrCast(@alignCast(res)), .Subresource = c.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, .StateBefore = before, .StateAfter = after };
    return b;
}

/// CPU descriptor `i` of a heap whose entries are `stride` bytes apart.
pub fn cpuAt(start: c.D3D12_CPU_DESCRIPTOR_HANDLE, stride: u32, i: u32) c.D3D12_CPU_DESCRIPTOR_HANDLE {
    return .{ .ptr = start.ptr + @as(usize, stride) * i };
}

/// A flip-model swapchain on a window, with one RTV per buffer. The buffers are in the
/// PRESENT state between frames; a frame transitions its buffer to RENDER_TARGET and back.
pub const Swapchain = struct {
    handle: *com.SwapChain,
    buffers: [max_buffers]*com.Resource = undefined,
    count: u32,
    width: u32,
    height: u32,
    format: c.DXGI_FORMAT,
    flags: u32,
    rtv_heap: *com.DescriptorHeap,
    rtv_stride: u32,
    /// Buffers held: `count` except during a resize, which releases them all first.
    held: u32 = 0,

    pub const max_buffers = 4;

    pub const Desc = struct {
        width: u32,
        height: u32,
        /// 2 to `max_buffers`. Flip model needs at least 2.
        buffers: u32 = 2,
        /// RGBA8: the format every renderer pipeline is built for, and one flip model allows.
        format: c.DXGI_FORMAT = c.DXGI_FORMAT_R8G8B8A8_UNORM,
        /// DXGI_SWAP_CHAIN_FLAG_*; frame.zig adds FRAME_LATENCY_WAITABLE_OBJECT.
        flags: u32 = 0,
    };

    pub fn init(d: *const Device, hwnd: c.HWND, desc: Swapchain.Desc) Error!Swapchain {
        std.debug.assert(desc.buffers >= 2 and desc.buffers <= max_buffers);
        const sc: c.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = desc.width,
            .Height = desc.height,
            .Format = desc.format,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = desc.buffers,
            .Scaling = c.DXGI_SCALING_STRETCH,
            .SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .AlphaMode = c.DXGI_ALPHA_MODE_UNSPECIFIED,
            .Flags = desc.flags,
        };
        var s1: ?*com.SwapChain = null;
        try d.factory.createSwapChainForHwnd(d.queue, hwnd, &sc, &s1);
        const handle = try s1.?.upgrade();
        errdefer com.release(handle);
        // The application handles Alt+Enter itself, if at all.
        try d.factory.makeWindowAssociation(hwnd, c.DXGI_MWA_NO_ALT_ENTER);
        const heap = try d.handle.createDescriptorHeap(&.{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = max_buffers, .Flags = c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE, .NodeMask = 0 });
        errdefer com.release(heap);
        var s: Swapchain = .{
            .handle = handle,
            .count = desc.buffers,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .flags = desc.flags,
            .rtv_heap = heap,
            .rtv_stride = d.handle.getDescriptorHandleIncrementSize(c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV),
        };
        try s.getBuffers(d);
        return s;
    }

    fn getBuffers(s: *Swapchain, d: *const Device) Error!void {
        while (s.held < s.count) : (s.held += 1) {
            s.buffers[s.held] = try s.handle.getBuffer(s.held);
            d.handle.createRenderTargetView(s.buffers[s.held], null, s.rtv(s.held));
        }
    }

    /// New buffer sizes, after the window's client area changed (WM_SIZE). The GPU must be
    /// done with every frame that drew into the old buffers (`Device.waitIdle`): DXGI only
    /// resizes once nothing holds them, so this releases its own references first. The
    /// renderer and frame.zig hold no buffer and need nothing; the next `prepare` takes the new
    /// viewport. A zero size (a minimised window) is the host's to skip: DXGI would pick the
    /// window's size instead.
    pub fn resize(s: *Swapchain, d: *const Device, width: u32, height: u32) Error!void {
        for (s.buffers[0..s.held]) |b| com.release(b);
        s.held = 0;
        try s.handle.resizeBuffers(s.count, width, height, s.format, s.flags);
        s.width = width;
        s.height = height;
        try s.getBuffers(d);
    }

    pub fn deinit(s: *Swapchain) void {
        for (s.buffers[0..s.held]) |b| com.release(b);
        com.release(s.rtv_heap);
        com.release(s.handle);
    }

    /// The buffer the next frame draws into.
    pub fn current(s: *const Swapchain) u32 {
        return s.handle.getCurrentBackBufferIndex();
    }

    pub fn rtv(s: *const Swapchain, i: u32) c.D3D12_CPU_DESCRIPTOR_HANDLE {
        return cpuAt(s.rtv_heap.cpuStart(), s.rtv_stride, i);
    }

    /// Presents the current buffer: vsync'd with `sync_interval` 1, at once with 0.
    pub fn present(s: *const Swapchain, sync_interval: u32) Error!void {
        try com.check(s.handle.present(sync_interval, 0));
    }
};

/// A window for a swapchain, made the plain Win32 way. Hidden unless `show`: tests and the
/// conformance player present to it without putting anything on screen.
pub const Window = struct {
    hwnd: c.HWND,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("lcgf-d3d12");

    pub fn init(width: u32, height: u32, show: bool) Error!Window {
        const instance = c.GetModuleHandleW(null);
        const class: c.WNDCLASSEXW = .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = c.DefWindowProcW,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        _ = c.RegisterClassExW(&class); // fails harmlessly when already registered
        const hwnd = c.CreateWindowExW(0, class_name, class_name, c.WS_OVERLAPPEDWINDOW, 0, 0, @intCast(width), @intCast(height), null, null, instance, null) orelse return error.D3D12Failed;
        if (show) _ = c.ShowWindow(hwnd, c.SW_SHOW);
        return .{ .hwnd = hwnd };
    }

    pub fn deinit(w: *Window) void {
        _ = c.DestroyWindow(w.hwnd);
    }
};

const testing = std.testing;
const host = @import("host.zig");

test "device: a device on the software rasteriser, a flip-model swapchain, a cleared frame presented" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var name: [128]u8 = undefined;
    std.debug.print("d3d12 adapter: {s}{s}\n", .{ d.adapterName(&name), if (d.warp) " (WARP)" else " (no WARP here: first adapter)" });
    var w = try Window.init(64, 48, false);
    defer w.deinit();
    var s = try Swapchain.init(&d, w.hwnd, .{ .width = 64, .height = 48 });
    defer s.deinit();
    try testing.expectEqual(@as(u32, 2), s.count);

    var once = try host.Once.init(&d);
    defer once.deinit();
    var rb = try host.Readback.init(&d, 64, 48);
    defer rb.deinit();
    // Two frames, so both buffers are drawn and presented once.
    for ([_][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 1, 1 } }) |colour| {
        const i = s.current();
        const l = try once.begin();
        l.resourceBarrier(&.{transition(s.buffers[i], c.D3D12_RESOURCE_STATE_PRESENT, c.D3D12_RESOURCE_STATE_RENDER_TARGET)});
        l.clearRenderTargetView(s.rtv(i), colour);
        l.resourceBarrier(&.{transition(s.buffers[i], c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_COPY_SOURCE)});
        rb.copy(l, s.buffers[i]);
        l.resourceBarrier(&.{transition(s.buffers[i], c.D3D12_RESOURCE_STATE_COPY_SOURCE, c.D3D12_RESOURCE_STATE_PRESENT)});
        try once.submit(&d);
        try s.present(0);
        var px: [64 * 48 * 4]u8 = undefined;
        try rb.read(&px);
        const want = [4]u8{ @intFromFloat(@round(colour[0] * 255)), @intFromFloat(@round(colour[1] * 255)), @intFromFloat(@round(colour[2] * 255)), 255 };
        for (0..64 * 48) |p| try testing.expectEqualSlices(u8, &want, px[p * 4 ..][0..4]);
    }
    try testing.expectEqual(@as(com.HRESULT, 0), d.removedReason());
}
