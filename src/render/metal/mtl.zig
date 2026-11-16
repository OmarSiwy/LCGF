//! Metal's enumerations and structs, by hand from the Metal headers (MTLPixelFormat.h,
//! MTLRenderPipeline.h, MTLRenderCommandEncoder.h, ...): only the values this back end uses.

const objc = @import("objc.zig");

pub const PixelFormat = enum(objc.NSUInteger) {
    rgba8_unorm = 70,
    bgra8_unorm = 80,
    _,
};
