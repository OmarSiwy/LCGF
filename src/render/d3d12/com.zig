//! Direct3D 12 and DXGI through hand-written COM vtables. Structs, enums and constants come from
//! Zig's own MinGW-w64 headers, translated in build.zig (`d3d12_c`); the interfaces do not: each
//! one is an opaque type with an enum of the vtable slots this back end calls, and a call loads
//! the slot and casts it to the method's signature. The test at the bottom checks every slot
//! against the translated header's `<Interface>Vtbl`, so a wrong index is a test failure, not a
//! call into the wrong method.
//!
//! Methods that return a struct (`GetCPUDescriptorHandleForHeapStart`, `ID3D12Resource::GetDesc`)
//! take the result pointer as their second argument: the MSVC C++ ABI, which the MinGW headers
//! spell out the same way.

const std = @import("std");
pub const c = @import("d3d12_c");

pub const HRESULT = c.HRESULT;
pub const GUID = c.GUID;

pub const Error = error{
    /// DXGI_ERROR_DEVICE_REMOVED, _RESET or _HUNG: everything made from the device is gone and
    /// the host recreates the device, swapchain and renderer (device.zig `removedReason`).
    DeviceLost,
    OutOfMemory,
    /// E_NOTIMPL or DXGI_ERROR_UNSUPPORTED: the implementation lacks it (Wine has no WARP
    /// adapter, for one).
    Unsupported,
    /// D3DCompile rejected the HLSL; the compiler's message went to the log.
    ShaderCompile,
    D3D12Failed,
};

fn hr(comptime v: u32) HRESULT {
    return @bitCast(v);
}
pub const E_NOTIMPL = hr(0x80004001);
/// A success code: the present went nowhere, as no part of the window is visible.
pub const DXGI_STATUS_OCCLUDED = hr(0x087A0001);
pub const E_OUTOFMEMORY = hr(0x8007000E);
pub const DXGI_ERROR_UNSUPPORTED = hr(0x887A0004);
pub const DXGI_ERROR_DEVICE_REMOVED = hr(0x887A0005);
pub const DXGI_ERROR_DEVICE_HUNG = hr(0x887A0006);
pub const DXGI_ERROR_DEVICE_RESET = hr(0x887A0007);

/// The error for a failed HRESULT (success codes, S_FALSE included, pass).
pub fn check(result: HRESULT) Error!void {
    if (result >= 0) return;
    std.log.warn("d3d12: HRESULT 0x{x:0>8}", .{@as(u32, @bitCast(result))});
    return switch (result) {
        DXGI_ERROR_DEVICE_REMOVED, DXGI_ERROR_DEVICE_RESET, DXGI_ERROR_DEVICE_HUNG => error.DeviceLost,
        E_OUTOFMEMORY => error.OutOfMemory,
        E_NOTIMPL, DXGI_ERROR_UNSUPPORTED => error.Unsupported,
        else => error.D3D12Failed,
    };
}

fn guid(a: u32, b: u16, d: u16, e: [8]u8) GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = d, .Data4 = e };
}

/// Method `slot` of a COM object, as `F`.
inline fn method(obj: anytype, slot: anytype, comptime F: type) *const F {
    const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(table.*[@backingInt(slot)]);
}

/// IUnknown::Release on any interface (slot 2 everywhere). Null is ignored, so `deinit` can
/// release whatever `init` got to.
pub fn release(obj: anytype) void {
    const p = switch (@typeInfo(@TypeOf(obj))) {
        .optional => obj orelse return,
        else => obj,
    };
    _ = method(p, @as(enum(u8) { Release = 2 }, .Release), fn (*anyopaque) callconv(.c) u32)(@ptrCast(p));
}

pub const Factory = opaque {
    pub const iid = guid(0x1bc6ea02, 0xef36, 0x464f, .{ 0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a });
    pub const Vtbl = c.IDXGIFactory4Vtbl;
    pub const Slot = enum(u8) { MakeWindowAssociation = 8, EnumAdapters1 = 12, CreateSwapChainForHwnd = 15, EnumWarpAdapter = 27 };

    pub fn create(debug: bool) Error!*Factory {
        var f: ?*Factory = null;
        try check(c.CreateDXGIFactory2(if (debug) c.DXGI_CREATE_FACTORY_DEBUG else 0, &iid, @ptrCast(&f)));
        return f.?;
    }
    /// DXGI_ERROR_NOT_FOUND past the last adapter.
    pub fn enumAdapters1(f: *Factory, i: u32, out: *?*Adapter) HRESULT {
        return method(f, Slot.EnumAdapters1, fn (*Factory, u32, *?*Adapter) callconv(.c) HRESULT)(f, i, out);
    }
    /// E_NOTIMPL where there is no WARP (Wine).
    pub fn enumWarpAdapter(f: *Factory, out: *?*Adapter) HRESULT {
        return method(f, Slot.EnumWarpAdapter, fn (*Factory, *const GUID, *?*Adapter) callconv(.c) HRESULT)(f, &Adapter.iid, out);
    }
    pub fn createSwapChainForHwnd(f: *Factory, queue: *CommandQueue, hwnd: c.HWND, desc: *const c.DXGI_SWAP_CHAIN_DESC1, out: *?*SwapChain) Error!void {
        try check(method(f, Slot.CreateSwapChainForHwnd, fn (*Factory, *CommandQueue, c.HWND, *const c.DXGI_SWAP_CHAIN_DESC1, ?*const anyopaque, ?*anyopaque, *?*SwapChain) callconv(.c) HRESULT)(f, queue, hwnd, desc, null, null, out));
    }
    pub fn makeWindowAssociation(f: *Factory, hwnd: c.HWND, flags: u32) Error!void {
        try check(method(f, Slot.MakeWindowAssociation, fn (*Factory, c.HWND, u32) callconv(.c) HRESULT)(f, hwnd, flags));
    }
};

pub const Adapter = opaque {
    pub const iid = guid(0x29038f61, 0x3839, 0x4626, .{ 0x91, 0xfd, 0x08, 0x68, 0x79, 0x01, 0x1a, 0x05 });
    pub const Vtbl = c.IDXGIAdapter1Vtbl;
    pub const Slot = enum(u8) { GetDesc1 = 10 };

    pub fn getDesc1(a: *Adapter) Error!c.DXGI_ADAPTER_DESC1 {
        var desc: c.DXGI_ADAPTER_DESC1 = undefined;
        try check(method(a, Slot.GetDesc1, fn (*Adapter, *c.DXGI_ADAPTER_DESC1) callconv(.c) HRESULT)(a, &desc));
        return desc;
    }
};

pub const Device = opaque {
    pub const iid = guid(0x189819f1, 0x1db6, 0x4b57, .{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 });
    pub const Vtbl = c.ID3D12DeviceVtbl;
    pub const Slot = enum(u8) {
        CreateCommandQueue = 8,
        CreateCommandAllocator = 9,
        CreateGraphicsPipelineState = 10,
        CreateCommandList = 12,
        CreateDescriptorHeap = 14,
        GetDescriptorHandleIncrementSize = 15,
        CreateRootSignature = 16,
        CreateShaderResourceView = 18,
        CreateRenderTargetView = 20,
        CreateCommittedResource = 27,
        CreateFence = 36,
        GetDeviceRemovedReason = 37,
        GetCopyableFootprints = 38,
    };

    pub fn create(adapter: ?*Adapter) Error!*Device {
        var d: ?*Device = null;
        try check(c.D3D12CreateDevice(@ptrCast(@alignCast(adapter)), c.D3D_FEATURE_LEVEL_11_0, &iid, @ptrCast(&d)));
        return d.?;
    }
    pub fn createCommandQueue(d: *Device, desc: *const c.D3D12_COMMAND_QUEUE_DESC) Error!*CommandQueue {
        var q: ?*CommandQueue = null;
        try check(method(d, Slot.CreateCommandQueue, fn (*Device, *const c.D3D12_COMMAND_QUEUE_DESC, *const GUID, *?*CommandQueue) callconv(.c) HRESULT)(d, desc, &CommandQueue.iid, &q));
        return q.?;
    }
    pub fn createCommandAllocator(d: *Device, kind: c.D3D12_COMMAND_LIST_TYPE) Error!*CommandAllocator {
        var a: ?*CommandAllocator = null;
        try check(method(d, Slot.CreateCommandAllocator, fn (*Device, c.D3D12_COMMAND_LIST_TYPE, *const GUID, *?*CommandAllocator) callconv(.c) HRESULT)(d, kind, &CommandAllocator.iid, &a));
        return a.?;
    }
    pub fn createGraphicsPipelineState(d: *Device, desc: *const c.D3D12_GRAPHICS_PIPELINE_STATE_DESC) Error!*PipelineState {
        var p: ?*PipelineState = null;
        try check(method(d, Slot.CreateGraphicsPipelineState, fn (*Device, *const c.D3D12_GRAPHICS_PIPELINE_STATE_DESC, *const GUID, *?*PipelineState) callconv(.c) HRESULT)(d, desc, &PipelineState.iid, &p));
        return p.?;
    }
    /// A list in the recording state, as D3D12 creates it.
    pub fn createCommandList(d: *Device, kind: c.D3D12_COMMAND_LIST_TYPE, allocator: *CommandAllocator, initial: ?*PipelineState) Error!*GraphicsCommandList {
        var l: ?*GraphicsCommandList = null;
        try check(method(d, Slot.CreateCommandList, fn (*Device, u32, c.D3D12_COMMAND_LIST_TYPE, *CommandAllocator, ?*PipelineState, *const GUID, *?*GraphicsCommandList) callconv(.c) HRESULT)(d, 0, kind, allocator, initial, &GraphicsCommandList.iid, &l));
        return l.?;
    }
    pub fn createDescriptorHeap(d: *Device, desc: *const c.D3D12_DESCRIPTOR_HEAP_DESC) Error!*DescriptorHeap {
        var h: ?*DescriptorHeap = null;
        try check(method(d, Slot.CreateDescriptorHeap, fn (*Device, *const c.D3D12_DESCRIPTOR_HEAP_DESC, *const GUID, *?*DescriptorHeap) callconv(.c) HRESULT)(d, desc, &DescriptorHeap.iid, &h));
        return h.?;
    }
    pub fn getDescriptorHandleIncrementSize(d: *Device, kind: c.D3D12_DESCRIPTOR_HEAP_TYPE) u32 {
        return method(d, Slot.GetDescriptorHandleIncrementSize, fn (*Device, c.D3D12_DESCRIPTOR_HEAP_TYPE) callconv(.c) u32)(d, kind);
    }
    pub fn createRootSignature(d: *Device, blob: []const u8) Error!*RootSignature {
        var r: ?*RootSignature = null;
        try check(method(d, Slot.CreateRootSignature, fn (*Device, u32, [*]const u8, usize, *const GUID, *?*RootSignature) callconv(.c) HRESULT)(d, 0, blob.ptr, blob.len, &RootSignature.iid, &r));
        return r.?;
    }
    pub fn createShaderResourceView(d: *Device, res: ?*Resource, desc: ?*const c.D3D12_SHADER_RESOURCE_VIEW_DESC, at: c.D3D12_CPU_DESCRIPTOR_HANDLE) void {
        method(d, Slot.CreateShaderResourceView, fn (*Device, ?*Resource, ?*const c.D3D12_SHADER_RESOURCE_VIEW_DESC, c.D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.c) void)(d, res, desc, at);
    }
    pub fn createRenderTargetView(d: *Device, res: *Resource, desc: ?*const c.D3D12_RENDER_TARGET_VIEW_DESC, at: c.D3D12_CPU_DESCRIPTOR_HANDLE) void {
        method(d, Slot.CreateRenderTargetView, fn (*Device, *Resource, ?*const c.D3D12_RENDER_TARGET_VIEW_DESC, c.D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.c) void)(d, res, desc, at);
    }
    pub fn createCommittedResource(d: *Device, heap: *const c.D3D12_HEAP_PROPERTIES, desc: *const c.D3D12_RESOURCE_DESC, state: c.D3D12_RESOURCE_STATES, clear: ?*const c.D3D12_CLEAR_VALUE) Error!*Resource {
        var r: ?*Resource = null;
        try check(method(d, Slot.CreateCommittedResource, fn (*Device, *const c.D3D12_HEAP_PROPERTIES, c.D3D12_HEAP_FLAGS, *const c.D3D12_RESOURCE_DESC, c.D3D12_RESOURCE_STATES, ?*const c.D3D12_CLEAR_VALUE, *const GUID, *?*Resource) callconv(.c) HRESULT)(d, heap, c.D3D12_HEAP_FLAG_NONE, desc, state, clear, &Resource.iid, &r));
        return r.?;
    }
    pub fn createFence(d: *Device, initial: u64) Error!*Fence {
        var f: ?*Fence = null;
        try check(method(d, Slot.CreateFence, fn (*Device, u64, c.D3D12_FENCE_FLAGS, *const GUID, *?*Fence) callconv(.c) HRESULT)(d, initial, c.D3D12_FENCE_FLAG_NONE, &Fence.iid, &f));
        return f.?;
    }
    /// S_OK while the device works; the removal reason once it is lost.
    pub fn getDeviceRemovedReason(d: *Device) HRESULT {
        return method(d, Slot.GetDeviceRemovedReason, fn (*Device) callconv(.c) HRESULT)(d);
    }
    pub fn getCopyableFootprints(d: *Device, desc: *const c.D3D12_RESOURCE_DESC, footprint: *c.D3D12_PLACED_SUBRESOURCE_FOOTPRINT, total: *u64) void {
        method(d, Slot.GetCopyableFootprints, fn (*Device, *const c.D3D12_RESOURCE_DESC, u32, u32, u64, *c.D3D12_PLACED_SUBRESOURCE_FOOTPRINT, ?*u32, ?*u64, *u64) callconv(.c) void)(d, desc, 0, 1, 0, footprint, null, null, total);
    }
};

/// ID3D12Device5, for `RemoveDevice`: the documented way to put a device in the removed state
/// on purpose, which is how the recovery path is tested.
pub const Device5 = opaque {
    pub const iid = guid(0x8b4f173b, 0x2fea, 0x4b80, .{ 0x8f, 0x58, 0x43, 0x07, 0x19, 0x1a, 0xb9, 0x5d });
    pub const Vtbl = c.ID3D12Device5Vtbl;
    pub const Slot = enum(u8) { QueryInterface = 0, RemoveDevice = 58 };

    /// Removes `d`; `error.Unsupported` when the runtime has no ID3D12Device5.
    pub fn removeDevice(d: *Device) Error!void {
        var d5: ?*Device5 = null;
        try check(method(d, Slot.QueryInterface, fn (*Device, *const GUID, *?*Device5) callconv(.c) HRESULT)(d, &iid, &d5));
        defer release(d5);
        method(d5.?, Slot.RemoveDevice, fn (*Device5) callconv(.c) void)(d5.?);
    }
};

pub const CommandQueue = opaque {
    pub const iid = guid(0x0ec870a6, 0x5d7e, 0x4c22, .{ 0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed });
    pub const Vtbl = c.ID3D12CommandQueueVtbl;
    pub const Slot = enum(u8) { ExecuteCommandLists = 10, Signal = 14 };

    pub fn executeCommandLists(q: *CommandQueue, lists: []const *GraphicsCommandList) void {
        method(q, Slot.ExecuteCommandLists, fn (*CommandQueue, u32, [*]const *GraphicsCommandList) callconv(.c) void)(q, @intCast(lists.len), lists.ptr);
    }
    pub fn signal(q: *CommandQueue, f: *Fence, value: u64) Error!void {
        try check(method(q, Slot.Signal, fn (*CommandQueue, *Fence, u64) callconv(.c) HRESULT)(q, f, value));
    }
};

pub const CommandAllocator = opaque {
    pub const iid = guid(0x6102dee4, 0xaf59, 0x4b09, .{ 0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24 });
    pub const Vtbl = c.ID3D12CommandAllocatorVtbl;
    pub const Slot = enum(u8) { Reset = 8 };

    pub fn reset(a: *CommandAllocator) Error!void {
        try check(method(a, Slot.Reset, fn (*CommandAllocator) callconv(.c) HRESULT)(a));
    }
};

pub const Fence = opaque {
    pub const iid = guid(0x0a753dcf, 0xc4d8, 0x4b91, .{ 0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76 });
    pub const Vtbl = c.ID3D12FenceVtbl;
    pub const Slot = enum(u8) { GetCompletedValue = 8, SetEventOnCompletion = 9 };

    pub fn getCompletedValue(f: *Fence) u64 {
        return method(f, Slot.GetCompletedValue, fn (*Fence) callconv(.c) u64)(f);
    }
    pub fn setEventOnCompletion(f: *Fence, value: u64, event: c.HANDLE) Error!void {
        try check(method(f, Slot.SetEventOnCompletion, fn (*Fence, u64, c.HANDLE) callconv(.c) HRESULT)(f, value, event));
    }
};

pub const Resource = opaque {
    pub const iid = guid(0x696442be, 0xa72e, 0x4059, .{ 0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad });
    pub const Vtbl = c.ID3D12ResourceVtbl;
    pub const Slot = enum(u8) { Map = 8, Unmap = 9, GetDesc = 10, GetGPUVirtualAddress = 11 };

    /// Maps subresource 0 for writing (no read range: the CPU reads nothing back) or, with
    /// `read`, for reading the whole resource.
    pub fn map(r: *Resource, read: bool) Error![*]u8 {
        var p: ?*anyopaque = null;
        const none: c.D3D12_RANGE = .{ .Begin = 0, .End = 0 };
        try check(method(r, Slot.Map, fn (*Resource, u32, ?*const c.D3D12_RANGE, *?*anyopaque) callconv(.c) HRESULT)(r, 0, if (read) null else &none, &p));
        return @ptrCast(p.?);
    }
    pub fn unmap(r: *Resource) void {
        method(r, Slot.Unmap, fn (*Resource, u32, ?*const c.D3D12_RANGE) callconv(.c) void)(r, 0, null);
    }
    pub fn getDesc(r: *Resource) c.D3D12_RESOURCE_DESC {
        var desc: c.D3D12_RESOURCE_DESC = undefined;
        _ = method(r, Slot.GetDesc, fn (*Resource, *c.D3D12_RESOURCE_DESC) callconv(.c) *c.D3D12_RESOURCE_DESC)(r, &desc);
        return desc;
    }
    pub fn getGPUVirtualAddress(r: *Resource) u64 {
        return method(r, Slot.GetGPUVirtualAddress, fn (*Resource) callconv(.c) u64)(r);
    }
};

pub const DescriptorHeap = opaque {
    pub const iid = guid(0x8efb471d, 0x616c, 0x4f49, .{ 0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51 });
    pub const Vtbl = c.ID3D12DescriptorHeapVtbl;
    pub const Slot = enum(u8) { GetCPUDescriptorHandleForHeapStart = 9, GetGPUDescriptorHandleForHeapStart = 10 };

    pub fn cpuStart(h: *DescriptorHeap) c.D3D12_CPU_DESCRIPTOR_HANDLE {
        var out: c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = method(h, Slot.GetCPUDescriptorHandleForHeapStart, fn (*DescriptorHeap, *c.D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.c) *c.D3D12_CPU_DESCRIPTOR_HANDLE)(h, &out);
        return out;
    }
    pub fn gpuStart(h: *DescriptorHeap) c.D3D12_GPU_DESCRIPTOR_HANDLE {
        var out: c.D3D12_GPU_DESCRIPTOR_HANDLE = undefined;
        _ = method(h, Slot.GetGPUDescriptorHandleForHeapStart, fn (*DescriptorHeap, *c.D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.c) *c.D3D12_GPU_DESCRIPTOR_HANDLE)(h, &out);
        return out;
    }
};

pub const RootSignature = opaque {
    pub const iid = guid(0xc54a6b66, 0x72df, 0x4ee8, .{ 0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14 });
    pub const Vtbl = c.ID3D12RootSignatureVtbl;
    pub const Slot = enum(u8) { Release = 2 };
};

pub const PipelineState = opaque {
    pub const iid = guid(0x765a30f3, 0xf624, 0x4c6f, .{ 0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45 });
    pub const Vtbl = c.ID3D12PipelineStateVtbl;
    pub const Slot = enum(u8) { Release = 2 };
};

pub const GraphicsCommandList = opaque {
    pub const iid = guid(0x5b160d0f, 0xac1b, 0x4185, .{ 0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55 });
    pub const Vtbl = c.ID3D12GraphicsCommandListVtbl;
    pub const Slot = enum(u8) {
        Close = 9,
        Reset = 10,
        DrawInstanced = 12,
        CopyTextureRegion = 16,
        IASetPrimitiveTopology = 20,
        RSSetViewports = 21,
        RSSetScissorRects = 22,
        SetPipelineState = 25,
        ResourceBarrier = 26,
        SetDescriptorHeaps = 28,
        SetGraphicsRootSignature = 30,
        SetGraphicsRootDescriptorTable = 32,
        SetGraphicsRoot32BitConstants = 36,
        SetGraphicsRootConstantBufferView = 38,
        IASetVertexBuffers = 44,
        OMSetRenderTargets = 46,
        ClearRenderTargetView = 48,
    };
    const L = GraphicsCommandList;

    pub fn close(l: *L) Error!void {
        try check(method(l, Slot.Close, fn (*L) callconv(.c) HRESULT)(l));
    }
    pub fn reset(l: *L, a: *CommandAllocator, initial: ?*PipelineState) Error!void {
        try check(method(l, Slot.Reset, fn (*L, *CommandAllocator, ?*PipelineState) callconv(.c) HRESULT)(l, a, initial));
    }
    pub fn drawInstanced(l: *L, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        method(l, Slot.DrawInstanced, fn (*L, u32, u32, u32, u32) callconv(.c) void)(l, vertices, instances, first_vertex, first_instance);
    }
    pub fn copyTextureRegion(l: *L, dst: *const c.D3D12_TEXTURE_COPY_LOCATION, src: *const c.D3D12_TEXTURE_COPY_LOCATION) void {
        l.copyTextureRegionAt(dst, 0, 0, src);
    }
    /// `copyTextureRegion` with `src` placed at texel (`x`, `y`) of `dst`.
    pub fn copyTextureRegionAt(
        l: *L,
        dst: *const c.D3D12_TEXTURE_COPY_LOCATION,
        x: u32,
        y: u32,
        src: *const c.D3D12_TEXTURE_COPY_LOCATION,
    ) void {
        const Loc = *const c.D3D12_TEXTURE_COPY_LOCATION;
        const F = fn (*L, Loc, u32, u32, u32, Loc, ?*const c.D3D12_BOX) callconv(.c) void;
        method(l, Slot.CopyTextureRegion, F)(l, dst, x, y, 0, src, null);
    }
    pub fn iaSetPrimitiveTopology(l: *L, t: c.D3D12_PRIMITIVE_TOPOLOGY) void {
        method(l, Slot.IASetPrimitiveTopology, fn (*L, c.D3D12_PRIMITIVE_TOPOLOGY) callconv(.c) void)(l, t);
    }
    pub fn rsSetViewport(l: *L, v: c.D3D12_VIEWPORT) void {
        method(l, Slot.RSSetViewports, fn (*L, u32, *const c.D3D12_VIEWPORT) callconv(.c) void)(l, 1, &v);
    }
    pub fn rsSetScissorRect(l: *L, r: c.D3D12_RECT) void {
        method(l, Slot.RSSetScissorRects, fn (*L, u32, *const c.D3D12_RECT) callconv(.c) void)(l, 1, &r);
    }
    pub fn setPipelineState(l: *L, p: *PipelineState) void {
        method(l, Slot.SetPipelineState, fn (*L, *PipelineState) callconv(.c) void)(l, p);
    }
    pub fn resourceBarrier(l: *L, barriers: []const c.D3D12_RESOURCE_BARRIER) void {
        method(l, Slot.ResourceBarrier, fn (*L, u32, [*]const c.D3D12_RESOURCE_BARRIER) callconv(.c) void)(l, @intCast(barriers.len), barriers.ptr);
    }
    pub fn setDescriptorHeaps(l: *L, heaps: []const *DescriptorHeap) void {
        method(l, Slot.SetDescriptorHeaps, fn (*L, u32, [*]const *DescriptorHeap) callconv(.c) void)(l, @intCast(heaps.len), heaps.ptr);
    }
    pub fn setGraphicsRootSignature(l: *L, r: *RootSignature) void {
        method(l, Slot.SetGraphicsRootSignature, fn (*L, *RootSignature) callconv(.c) void)(l, r);
    }
    pub fn setGraphicsRootDescriptorTable(l: *L, param: u32, at: c.D3D12_GPU_DESCRIPTOR_HANDLE) void {
        method(l, Slot.SetGraphicsRootDescriptorTable, fn (*L, u32, c.D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.c) void)(l, param, at);
    }
    pub fn setGraphicsRoot32BitConstants(l: *L, param: u32, values: []const u32, first: u32) void {
        method(l, Slot.SetGraphicsRoot32BitConstants, fn (*L, u32, u32, [*]const u32, u32) callconv(.c) void)(l, param, @intCast(values.len), values.ptr, first);
    }
    pub fn setGraphicsRootConstantBufferView(l: *L, param: u32, address: u64) void {
        method(l, Slot.SetGraphicsRootConstantBufferView, fn (*L, u32, u64) callconv(.c) void)(l, param, address);
    }
    pub fn iaSetVertexBuffer(l: *L, view: c.D3D12_VERTEX_BUFFER_VIEW) void {
        method(l, Slot.IASetVertexBuffers, fn (*L, u32, u32, *const c.D3D12_VERTEX_BUFFER_VIEW) callconv(.c) void)(l, 0, 1, &view);
    }
    pub fn omSetRenderTarget(l: *L, rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE) void {
        method(l, Slot.OMSetRenderTargets, fn (*L, u32, *const c.D3D12_CPU_DESCRIPTOR_HANDLE, c.BOOL, ?*const c.D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.c) void)(l, 1, &rtv, 0, null);
    }
    pub fn clearRenderTargetView(l: *L, rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE, rgba: [4]f32) void {
        method(l, Slot.ClearRenderTargetView, fn (*L, c.D3D12_CPU_DESCRIPTOR_HANDLE, *const [4]f32, u32, ?*const c.D3D12_RECT) callconv(.c) void)(l, rtv, &rgba, 0, null);
    }
};

pub const SwapChain = opaque {
    pub const iid = guid(0x94d99bdb, 0xf1f8, 0x4ab0, .{ 0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1 });
    pub const Vtbl = c.IDXGISwapChain3Vtbl;
    pub const Slot = enum(u8) {
        QueryInterface = 0,
        Present = 8,
        GetBuffer = 9,
        ResizeBuffers = 13,
        SetMaximumFrameLatency = 31,
        GetFrameLatencyWaitableObject = 33,
        GetCurrentBackBufferIndex = 36,
    };

    /// CreateSwapChainForHwnd hands back an IDXGISwapChain1; this asks it for the
    /// IDXGISwapChain3 the rest of the methods need, and releases the first.
    pub fn upgrade(s1: *SwapChain) Error!*SwapChain {
        defer release(s1);
        var s: ?*SwapChain = null;
        try check(method(s1, Slot.QueryInterface, fn (*SwapChain, *const GUID, *?*SwapChain) callconv(.c) HRESULT)(s1, &iid, &s));
        return s.?;
    }
    /// The raw result: DXGI_STATUS_OCCLUDED and the device-lost codes are for the caller.
    pub fn present(s: *SwapChain, sync_interval: u32, flags: u32) HRESULT {
        return method(s, Slot.Present, fn (*SwapChain, u32, u32) callconv(.c) HRESULT)(s, sync_interval, flags);
    }
    pub fn getBuffer(s: *SwapChain, i: u32) Error!*Resource {
        var r: ?*Resource = null;
        try check(method(s, Slot.GetBuffer, fn (*SwapChain, u32, *const GUID, *?*Resource) callconv(.c) HRESULT)(s, i, &Resource.iid, &r));
        return r.?;
    }
    pub fn resizeBuffers(s: *SwapChain, count: u32, width: u32, height: u32, format: c.DXGI_FORMAT, flags: u32) Error!void {
        try check(method(s, Slot.ResizeBuffers, fn (*SwapChain, u32, u32, u32, c.DXGI_FORMAT, u32) callconv(.c) HRESULT)(s, count, width, height, format, flags));
    }
    pub fn setMaximumFrameLatency(s: *SwapChain, frames: u32) Error!void {
        try check(method(s, Slot.SetMaximumFrameLatency, fn (*SwapChain, u32) callconv(.c) HRESULT)(s, frames));
    }
    pub fn getFrameLatencyWaitableObject(s: *SwapChain) c.HANDLE {
        return method(s, Slot.GetFrameLatencyWaitableObject, fn (*SwapChain) callconv(.c) c.HANDLE)(s);
    }
    pub fn getCurrentBackBufferIndex(s: *SwapChain) u32 {
        return method(s, Slot.GetCurrentBackBufferIndex, fn (*SwapChain) callconv(.c) u32)(s);
    }
};

pub const Blob = opaque {
    pub const Vtbl = c.ID3D10BlobVtbl;
    pub const Slot = enum(u8) { GetBufferPointer = 3, GetBufferSize = 4 };

    pub fn bytes(b: *Blob) []const u8 {
        const p = method(b, Slot.GetBufferPointer, fn (*Blob) callconv(.c) [*]const u8)(b);
        return p[0..method(b, Slot.GetBufferSize, fn (*Blob) callconv(.c) usize)(b)];
    }
};

pub const Debug = opaque {
    pub const iid = guid(0x344488b7, 0x6846, 0x474b, .{ 0xb9, 0x89, 0xf0, 0x27, 0x44, 0x82, 0x45, 0xe0 });
    pub const Vtbl = c.ID3D12DebugVtbl;
    pub const Slot = enum(u8) { EnableDebugLayer = 3 };

    /// Turns the debug layer on for devices created afterwards, when the system has it (the
    /// Graphics Tools optional feature on Windows); false when it does not.
    pub fn enable() bool {
        var dbg: ?*Debug = null;
        if (c.D3D12GetDebugInterface(&iid, @ptrCast(&dbg)) < 0) return false;
        defer release(dbg);
        method(dbg.?, Slot.EnableDebugLayer, fn (*Debug) callconv(.c) void)(dbg.?);
        return true;
    }
};

/// Every interface above, for the slot check.
const interfaces = .{ Factory, Adapter, Device, Device5, CommandQueue, CommandAllocator, Fence, Resource, DescriptorHeap, RootSignature, PipelineState, GraphicsCommandList, SwapChain, Blob, Debug };

test "com: every vtable slot is the header's" {
    inline for (interfaces) |I| {
        const info = @typeInfo(I.Slot).@"enum";
        inline for (info.field_names, info.field_values) |name, slot| {
            const want = @offsetOf(I.Vtbl, name) / @sizeOf(usize);
            if (want != slot) std.debug.print("{s}.{s}: slot {d}, header {d}\n", .{ @typeName(I), name, slot, want });
            try std.testing.expectEqual(want, slot);
        }
    }
}

test "com: failed HRESULTs map to errors, success codes pass" {
    try check(0);
    try check(1); // S_FALSE
    try std.testing.expectError(error.DeviceLost, check(DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expectError(error.DeviceLost, check(DXGI_ERROR_DEVICE_RESET));
    try std.testing.expectError(error.Unsupported, check(E_NOTIMPL));
    try std.testing.expectError(error.D3D12Failed, check(hr(0x80070057))); // E_INVALIDARG
}
