//! The device, its command queue and a CAMetalLayer: what a macOS (or iOS) host owns before
//! the renderer exists. Follows GPUI's Metal renderer: one system default device, one queue,
//! a layer the window's view hosts, drawn into once per frame through `nextDrawable`.
//!
//!     try objc.load();
//!     var dev = try Device.init();
//!     defer dev.deinit();
//!     var layer = Layer.init(&dev, .{ .size = .{ 800, 600 }, .scale = 2 });
//!     defer layer.deinit();
//!     layer.attach(ns_view); // the shell's NSView
//!
//! WHO OWNS WHAT: you own both; the renderer only borrows the device to create its objects.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const Id = objc.Id;
const msg = objc.msg;

pub const Error = objc.Error || error{NoDevice};

pub const Device = struct {
    device: Id,
    queue: Id,

    /// The system default device and a command queue on it. `objc.load` must have succeeded.
    pub fn init() Error!Device {
        const device = objc.createSystemDefaultDevice() orelse return error.NoDevice;
        errdefer objc.release(device);
        const queue = msg(?Id, device, "newCommandQueue", .{}) orelse return error.NoDevice;
        return .{ .device = device, .queue = queue };
    }

    pub fn deinit(d: *Device) void {
        objc.release(d.queue);
        objc.release(d.device);
    }

    /// The device's name, for logs ("Apple M2", "AMD Radeon Pro 5500M").
    pub fn name(d: *const Device) [*:0]const u8 {
        return msg([*:0]const u8, msg(Id, d.device, "name", .{}), "UTF8String", .{});
    }
};

pub const LayerDesc = struct {
    /// The view's size in logical pixels (points).
    size: [2]f32,
    /// Physical pixels per logical pixel (the window's backingScaleFactor).
    scale: f32 = 1,
    format: mtl.PixelFormat = .bgra8_unorm,
    /// Drawables in flight: 3 lets the CPU prepare a frame while two are queued (GPUI uses 3).
    drawables: objc.NSUInteger = 3,
};

/// A CAMetalLayer on the device. Its drawables are the swapchain: `nextDrawable` blocks until
/// one is free, which paces the loop to the display when the layer syncs to it (the default).
pub const Layer = struct {
    layer: Id,
    format: mtl.PixelFormat,
    /// What the layer was last set to: drawable pixels and contents scale.
    px: [2]u32 = .{ 0, 0 },
    scale: f32 = 0,

    pub fn init(d: *const Device, desc: LayerDesc) Layer {
        const layer = msg(Id, objc.class("CAMetalLayer"), "new", .{});
        msg(void, layer, "setDevice:", .{d.device});
        msg(void, layer, "setPixelFormat:", .{desc.format});
        // Render target only: lets Metal pick the fastest drawable storage.
        msg(void, layer, "setFramebufferOnly:", .{@as(objc.BOOL, true)});
        msg(void, layer, "setMaximumDrawableCount:", .{desc.drawables});
        // Opaque: the UI's first quad covers the window; skips compositor blending.
        msg(void, layer, "setOpaque:", .{@as(objc.BOOL, true)});
        var l: Layer = .{ .layer = layer, .format = desc.format };
        _ = l.resize(desc.size, desc.scale);
        return l;
    }

    pub fn deinit(l: *Layer) void {
        objc.release(l.layer);
    }

    /// Makes the layer the backing layer of an NSView (macOS). On iOS the view's class decides
    /// its layer; set `layerClass` to CAMetalLayer there instead.
    pub fn attach(l: *const Layer, view: Id) void {
        msg(void, view, "setLayer:", .{l.layer});
        msg(void, view, "setWantsLayer:", .{@as(objc.BOOL, true)});
    }

    /// Follows the view: call it each frame (or on the shell's resize and scale events) with the
    /// view's logical size and backing scale, and pass the same two to the renderer's `prepare`.
    /// Touches the layer only when the drawable size or the scale changed, since a new drawable
    /// size reallocates the drawables. Drawables taken after a change have the new size; the
    /// renderer's viewport and scissor come from the same `drawableSize`, so they match.
    /// Returns whether anything changed (a moved window between displays changes only `scale`).
    pub fn resize(l: *Layer, size: [2]f32, scale: f32) bool {
        const px = drawableSize(size, scale);
        if (!l.changes(px, scale)) return false;
        if (scale != l.scale) msg(void, l.layer, "setContentsScale:", .{@as(objc.CGFloat, scale)});
        if (px[0] != l.px[0] or px[1] != l.px[1]) msg(void, l.layer, "setDrawableSize:", .{objc.CGSize{ .width = @floatFromInt(px[0]), .height = @floatFromInt(px[1]) }});
        l.px = px;
        l.scale = scale;
        return true;
    }

    fn changes(l: *const Layer, px: [2]u32, scale: f32) bool {
        return px[0] != l.px[0] or px[1] != l.px[1] or scale != l.scale;
    }

    /// During a live window resize, presenting inside the window's Core Animation transaction
    /// keeps the content in step with the frame (GPUI turns this on while resizing); use
    /// `present.Frames.presentInTransaction` while it is on.
    pub fn setPresentsWithTransaction(l: *const Layer, on: bool) void {
        msg(void, l.layer, "setPresentsWithTransaction:", .{@as(objc.BOOL, on)});
    }
};

/// Physical pixels of a view of `size` logical pixels at `scale`, rounded, at least 1x1
/// (Metal rejects an empty drawable).
pub fn drawableSize(size: [2]f32, scale: f32) [2]u32 {
    return .{
        @intFromFloat(@max(@round(size[0] * scale), 1)),
        @intFromFloat(@max(@round(size[1] * scale), 1)),
    };
}

const testing = std.testing;

test "device: drawable size is the view in physical pixels, never empty" {
    try testing.expectEqual([2]u32{ 1600, 1200 }, drawableSize(.{ 800, 600 }, 2));
    try testing.expectEqual([2]u32{ 1201, 1 }, drawableSize(.{ 800.5, 0 }, 1.5));
}

test "device: the layer is touched only when its pixels or scale change" {
    var l: Layer = .{ .layer = undefined, .format = .bgra8_unorm, .px = .{ 1600, 1200 }, .scale = 2 };
    try testing.expect(!l.changes(drawableSize(.{ 800, 600 }, 2), 2));
    try testing.expect(!l.changes(drawableSize(.{ 800.1, 600 }, 2), 2)); // same pixels after rounding
    try testing.expect(l.changes(drawableSize(.{ 801, 600 }, 2), 2)); // resized
    try testing.expect(l.changes(drawableSize(.{ 1600, 1200 }, 1), 1)); // moved to a 1x display: same pixels, new scale
}

test "device: a device, a queue and a layer on a real Metal implementation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var dev = try Device.init();
    defer dev.deinit();
    var layer = Layer.init(&dev, .{ .size = .{ 160, 120 }, .scale = 2 });
    defer layer.deinit();
    try testing.expectEqual(mtl.PixelFormat.bgra8_unorm, msg(mtl.PixelFormat, layer.layer, "pixelFormat", .{}));
    const size = msg(objc.CGSize, layer.layer, "drawableSize", .{});
    try testing.expectEqual(objc.CGSize{ .width = 320, .height = 240 }, size);
    try testing.expect(std.mem.len(dev.name()) > 0);
    try testing.expect(!layer.resize(.{ 160, 120 }, 2));
    try testing.expect(layer.resize(.{ 200, 100 }, 1.5));
    try testing.expectEqual(objc.CGSize{ .width = 300, .height = 150 }, msg(objc.CGSize, layer.layer, "drawableSize", .{}));
    try testing.expectEqual(@as(objc.CGFloat, 1.5), msg(objc.CGFloat, layer.layer, "contentsScale", .{}));
}
