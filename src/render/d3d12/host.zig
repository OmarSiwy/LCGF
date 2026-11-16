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
