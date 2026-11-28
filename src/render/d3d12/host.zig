//! What a Direct3D 12 host owns besides the device, for tests and tools: a one-shot command
//! list and pixel read-back. Not part of the back end: the renderer creates or keeps none of these.

const std = @import("std");
const com = @import("com.zig");
const device_mod = @import("device.zig");
const c = com.c;
const Error = com.Error;
const Device = device_mod.Device;

/// One allocator and one command list, recorded, submitted and waited for at once.
pub const Once = struct {
    allocator: *com.CommandAllocator,
    list: *com.GraphicsCommandList,

    pub fn init(d: *const Device) Error!Once {
        const a = try d.handle.createCommandAllocator(c.D3D12_COMMAND_LIST_TYPE_DIRECT);
        errdefer com.release(a);
        const l = try d.handle.createCommandList(c.D3D12_COMMAND_LIST_TYPE_DIRECT, a, null);
        try l.close(); // created recording; `begin` resets it
        return .{ .allocator = a, .list = l };
    }

    pub fn deinit(o: *Once) void {
        com.release(o.list);
        com.release(o.allocator);
    }

    /// The list, reset and recording. The previous submit has finished (`submit` waits).
    pub fn begin(o: *Once) Error!*com.GraphicsCommandList {
        try o.allocator.reset();
        try o.list.reset(o.allocator, null);
        return o.list;
    }

    /// Closes the list, runs it and waits for it.
    pub fn submit(o: *Once, d: *Device) Error!void {
        try o.list.close();
        try d.wait(try d.submit(&.{o.list}));
    }
};

/// A READBACK buffer for one RGBA8 image, rows padded to D3D12's 256-byte copy pitch.
pub const Readback = struct {
    buffer: *com.Resource,
    width: u32,
    height: u32,
    pitch: u32,

    pub fn init(d: *const Device, width: u32, height: u32) Error!Readback {
        const pitch = std.mem.alignForward(u32, width * 4, c.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        return .{ .buffer = try d.createBuffer(@as(u64, pitch) * height, c.D3D12_HEAP_TYPE_READBACK), .width = width, .height = height, .pitch = pitch };
    }

    pub fn deinit(r: *Readback) void {
        com.release(r.buffer);
    }

    /// Records a copy of `texture` (in COPY_SOURCE, `width` x `height`, RGBA8 or BGRA8) into the buffer.
    pub fn copy(r: *const Readback, l: *com.GraphicsCommandList, texture: *com.Resource) void {
        var dst: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
        dst.pResource = @ptrCast(@alignCast(r.buffer));
        dst.Type = c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        dst.unnamed_0.PlacedFootprint = .{ .Offset = 0, .Footprint = .{ .Format = texture.getDesc().Format, .Width = r.width, .Height = r.height, .Depth = 1, .RowPitch = r.pitch } };
        var src: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
        src.pResource = @ptrCast(@alignCast(texture));
        src.Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.unnamed_0.SubresourceIndex = 0;
        l.copyTextureRegion(&dst, &src);
    }

    /// The copied pixels as tight rows, after the copy has finished.
    pub fn read(r: *const Readback, px: []u8) Error!void {
        const row = r.width * 4;
        std.debug.assert(px.len == @as(usize, row) * r.height);
        const p = try r.buffer.map(true);
        defer r.buffer.unmap();
        for (0..r.height) |y| @memcpy(px[y * row ..][0..row], p[y * r.pitch ..][0..row]);
    }
};

/// A rectangle of a texture, in texels.
pub const Rect = struct { x: u32 = 0, y: u32 = 0, w: u32, h: u32 };

/// Bytes between the rows of `r` in a staging buffer, `texel` bytes a texel: D3D12 copies
/// from rows 256-byte aligned.
pub fn rowPitch(r: Rect, texel: u32) u32 {
    return std.mem.alignForward(u32, r.w * texel, c.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
}

/// Records a copy of `region` of `texture` from `buffer` at `offset` (512-byte aligned, its
/// rows `rowPitch` apart), the texture moved from `from` to COPY_DEST and left in
/// PIXEL_SHADER_RESOURCE. The buffer stays alive and unwritten until the list has run.
/// Asserts that `offset` is aligned and the region is inside the texture.
pub fn uploadRegion(
    l: *com.GraphicsCommandList,
    texture: *com.Resource,
    from: c.D3D12_RESOURCE_STATES,
    buffer: *com.Resource,
    offset: u64,
    region: Rect,
) void {
    std.debug.assert(offset % c.D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT == 0);
    const desc = texture.getDesc();
    std.debug.assert(region.x + region.w <= desc.Width);
    std.debug.assert(region.y + region.h <= desc.Height);
    const texel: u32 = if (desc.Format == c.DXGI_FORMAT_R8_UNORM) 1 else 4;
    const copy_dest = c.D3D12_RESOURCE_STATE_COPY_DEST;
    if (from != copy_dest) l.resourceBarrier(&.{device_mod.transition(texture, from, copy_dest)});
    var dst: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
    dst.pResource = @ptrCast(@alignCast(texture));
    dst.Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    var src: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
    src.pResource = @ptrCast(@alignCast(buffer));
    src.Type = c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.unnamed_0.PlacedFootprint = .{ .Offset = offset, .Footprint = .{
        .Format = desc.Format,
        .Width = region.w,
        .Height = region.h,
        .Depth = 1,
        .RowPitch = rowPitch(region, texel),
    } };
    l.copyTextureRegionAt(&dst, region.x, region.y, &src);
    const readable = c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    l.resourceBarrier(&.{device_mod.transition(texture, copy_dest, readable)});
}

/// An RGBA8 texture filled with `rgba` (tight rows) through an upload buffer, left in
/// PIXEL_SHADER_RESOURCE for sampling. Waits for the copy.
pub fn sampled(d: *Device, once: *Once, width: u32, height: u32, rgba: []const u8) Error!*com.Resource {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    const tex = try d.createTexture(width, height, c.DXGI_FORMAT_R8G8B8A8_UNORM, false, c.D3D12_RESOURCE_STATE_COPY_DEST);
    errdefer com.release(tex);
    const desc = tex.getDesc();
    var footprint: c.D3D12_PLACED_SUBRESOURCE_FOOTPRINT = undefined;
    var total: u64 = 0;
    d.handle.getCopyableFootprints(&desc, &footprint, &total);
    const staging = try d.createBuffer(total, c.D3D12_HEAP_TYPE_UPLOAD);
    defer com.release(staging);
    const p = try staging.map(false);
    const row = width * 4;
    for (0..height) |y| @memcpy(p[@intCast(footprint.Offset + y * footprint.Footprint.RowPitch)..][0..row], rgba[y * row ..][0..row]);
    staging.unmap();
    const l = try once.begin();
    var dst: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
    dst.pResource = @ptrCast(@alignCast(tex));
    dst.Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    var src: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
    src.pResource = @ptrCast(@alignCast(staging));
    src.Type = c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.unnamed_0.PlacedFootprint = footprint;
    l.copyTextureRegion(&dst, &src);
    l.resourceBarrier(&.{device_mod.transition(tex, c.D3D12_RESOURCE_STATE_COPY_DEST, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)});
    try once.submit(d);
    return tex;
}

/// An offscreen RGBA8 render target and its RTV, in RENDER_TARGET between `begin` and the
/// host's transition out.
pub const Target = struct {
    texture: *com.Resource,
    heap: *com.DescriptorHeap,

    pub fn init(d: *const Device, width: u32, height: u32) Error!Target {
        const texture = try d.createTexture(width, height, c.DXGI_FORMAT_R8G8B8A8_UNORM, true, c.D3D12_RESOURCE_STATE_RENDER_TARGET);
        errdefer com.release(texture);
        const heap = try d.handle.createDescriptorHeap(&.{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = 1, .Flags = c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE, .NodeMask = 0 });
        d.handle.createRenderTargetView(texture, null, heap.cpuStart());
        return .{ .texture = texture, .heap = heap };
    }

    pub fn deinit(t: *Target) void {
        com.release(t.heap);
        com.release(t.texture);
    }

    pub fn rtv(t: *const Target) c.D3D12_CPU_DESCRIPTOR_HANDLE {
        return t.heap.cpuStart();
    }
};
