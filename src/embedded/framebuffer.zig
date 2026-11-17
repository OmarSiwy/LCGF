//! RGB565 and 1-bit framebuffers for the embedded profile. The software back end (src/render/sw)
//! draws u32 pixels into the bare-metal shell's band buffer; this converts each flushed area to
//! the panel's format as it leaves, so the u32 band is the only u32 memory. No read-back is
//! needed: the shell clears and redraws every area it flushes (src/shell/baremetal/flush.zig).
//!
//! - `rgb565`: one u16 a pixel, red in the top five bits, as SPI TFT controllers (ILI9341, ST7789)
//!   take it, in native byte order (the bus driver orders the bytes).
//! - `mono`: one bit a pixel, eight a byte, the leftmost in the top bit, 1 for white, as memory
//!   LCDs and e-paper take a row; a pixel is white when its luminance (BT.601 weights 77, 150,
//!   29 out of 256) is at least 128.
//!
//! `convert` turns one row; `Framebuffer` keeps a whole panel in the format (a board whose
//! display reads from MCU memory, or a simulator), and is itself a board-side `flush` target.

const std = @import("std");
const types = @import("../core/types.zig");
const sw = @import("../render/sw/sw.zig");
const Area = @import("../shell/baremetal/flush.zig").Area;
const Color = types.Color;

pub const Format = enum { rgb565, mono };

/// The storage unit of a row: a pixel, or for `mono` a byte of eight.
pub fn Unit(comptime format: Format) type {
    return switch (format) {
        .rgb565 => u16,
        .mono => u8,
    };
}

/// Units a row of `width` pixels takes.
pub fn units(comptime format: Format, width: u32) u32 {
    return if (format == .mono) width / 8 + @intFromBool(width % 8 != 0) else width;
}

/// Pixel `p` of a framebuffer in `src` byte order as a colour.
inline fn color(p: u32, src: sw.Format) Color {
    const c: Color = @bitCast(p);
    return if (src == .rgba8) c else .{ .r = c.b, .g = c.g, .b = c.r, .a = c.a };
}

pub fn pack565(c: Color) u16 {
    return (@as(u16, c.r >> 3) << 11) | (@as(u16, c.g >> 2) << 5) | (c.b >> 3);
}

/// Each channel widened back to 8 bits by repeating its top bits, so white stays 255.
pub fn unpack565(p: u16) Color {
    const r: u8 = @intCast(p >> 11);
    const g: u8 = @intCast((p >> 5) & 63);
    const b: u8 = @intCast(p & 31);
    return .rgb((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
}

/// 1 when `c` is white on a 1-bit panel.
pub fn lit(c: Color) u1 {
    const lum = (@as(u32, c.r) * 77 + @as(u32, c.g) * 150 + @as(u32, c.b) * 29) >> 8;
    return @intFromBool(lum >= 128);
}

/// Converts `n` pixels of `src` (sw pixels in `order`) into `dst`. For `mono`, `dst[0]`'s top
/// bit is `src[0]`; bits of the last byte past `n` are written as 0.
pub fn convert(comptime format: Format, dst: []Unit(format), src: []const u32, n: u32, order: sw.Format) void {
    switch (format) {
        .rgb565 => for (dst[0..n], src[0..n]) |*d, p| {
            d.* = pack565(color(p, order));
        },
        .mono => for (dst[0..units(.mono, n)], 0..) |*d, k| {
            var byte: u8 = 0;
            for (0..8) |b| {
                const x = k * 8 + b;
                // Past `n`, read pixel n - 1 and mask it off: no branch on the column.
                const on = lit(color(src[@min(x, n - 1)], order)) & @intFromBool(x < n);
                byte |= @as(u8, on) << @intCast(7 - b);
            }
            d.* = byte;
        },
    }
}

/// A whole panel in `format`, rows `stride` units apart.
pub fn Framebuffer(comptime format: Format) type {
    return struct {
        const Self = @This();
        pub const U = Unit(format);

        pixels: []U,
        width: u32,
        height: u32,
        stride: u32,
        /// Byte order of the sw pixels `flush` receives.
        order: sw.Format = .rgba8,

        pub fn len(width: u32, height: u32) usize {
            return @as(usize, units(format, width)) * height;
        }

        pub fn init(pixels: []U, width: u32, height: u32) Self {
            std.debug.assert(pixels.len >= len(width, height));
            return .{ .pixels = pixels, .width = width, .height = height, .stride = units(format, width) };
        }

        /// Stores exactly the flushed pixels, including partial bytes on a mono panel.
        pub fn flush(fb: *Self, a: Area, pixels: []const u32, stride: u32) void {
            for (0..a.h()) |y| {
                const row = fb.pixels[(a.y0 + y) * fb.stride ..][0..fb.stride];
                const src = pixels[y * stride ..][0..a.w()];
                if (format == .rgb565) {
                    convert(format, row[a.x0..], src, a.w(), fb.order);
                    continue;
                }
                var i: u32 = 0;
                while (i < a.w()) {
                    const x = a.x0 + i;
                    const offset = x % 8;
                    const count = @min(8 - offset, a.w() - i);
                    var bits: u8 = 0;
                    for (src[i..][0..count]) |pixel| bits = (bits << 1) | lit(color(pixel, fb.order));
                    const shift: u3 = @intCast(8 - offset - count);
                    const mask: u8 = @truncate(((@as(u16, 1) << @intCast(count)) - 1) << shift);
                    row[x / 8] = (row[x / 8] & ~mask) | (bits << shift);
                    i += count;
                }
            }
        }

        /// Pixel (x, y) as a colour (`mono`: black or white).
        pub fn at(fb: *const Self, x: u32, y: u32) Color {
            const row = fb.pixels[y * fb.stride ..];
            return switch (format) {
                .rgb565 => unpack565(row[x]),
                .mono => if ((row[x / 8] >> @intCast(7 - x % 8)) & 1 == 1) Color.white else Color.black,
            };
        }
    };
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const flushing = @import("../shell/baremetal/flush.zig");
const render = @import("../render/iface.zig");
const Quad = @import("../draw/draw_list.zig").Quad;
const Mono = @import("../text/protocol.zig").Mono;
const context = @import("../runtime/context.zig");
const Events = @import("../shell/iface.zig").Events;
const example = @import("../shell/example.zig");
const Input = @import("../core/input.zig").Input;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 320;
const fb_h = 240;

const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var full: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var lines: [flushing.Display.len(fb_w, 16)]u32 = undefined;
    var half: [Framebuffer(.rgb565).len(fb_w, fb_h)]u16 = undefined;
    var bits: [Framebuffer(.mono).len(fb_w, fb_h)]u8 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
};

test "embedded framebuffer: RGB565 and 1-bit panels hold sw's u32 frame, converted, exactly" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, limits);
    var app: example.App = .{};
    const in: Input = .{ .viewport = .{ fb_w, fb_h } };
    var f = ctx.begin(&in);
    app.build(&f, &Events{});
    const out = f.end(.{});
    var gfx: sw.Software = .{};
    const n = (Mono{}).quads(out.draw, &Fixture.glyphs, .{ .first = &Fixture.first, .count = &Fixture.count });
    gfx.prepare({}, out.draw, .{ .quads = Fixture.glyphs[0..n], .first = &Fixture.first, .count = &Fixture.count }, .{ 0, 0 }, 1);
    const bg: Color = .rgb(0, 0, 0);

    // Reference: the whole frame in u32, as the headless shell draws it.
    var ref: sw.Framebuffer = .init(&Fixture.full, fb_w, fb_h, .rgba8);
    ref.clear(bg);
    render.render(&gfx, .{ .fb = &ref, .scissor = ref.all() }, out.draw);

    // The same frame through a 16-row u32 band into each format.
    const band: flushing.Display = .init(&Fixture.lines, fb_w, fb_h, 16, .rgba8);
    var half: Framebuffer(.rgb565) = .init(&Fixture.half, fb_w, fb_h);
    var bits: Framebuffer(.mono) = .init(&Fixture.bits, fb_w, fb_h);
    _ = flushing.flush(&band, &gfx, out.draw, bg, &half);
    _ = flushing.flush(&band, &gfx, out.draw, bg, &bits);
    var lit_count: u32 = 0;
    for (0..fb_h) |y| for (0..fb_w) |x| {
        const c = ref.at(@intCast(x), @intCast(y));
        try testing.expectEqual(pack565(c), Fixture.half[y * half.stride + x]);
        const want = lit(c);
        lit_count += want;
        try testing.expectEqual(want, @as(u1, @truncate(Fixture.bits[y * bits.stride + x / 8] >> @intCast(7 - x % 8))));
    };
    // Both kinds of pixel occur, so the 1-bit check saw both.
    try testing.expect(lit_count > 0 and lit_count < fb_w * fb_h);
}

test "embedded framebuffer: a row's tail, BGRA8 order, and 565 round trips" {
    const src = [_]u32{ Color.white.bitsOf(), Color.black.bitsOf(), Color.rgb(200, 200, 200).bitsOf(), Color.rgb(10, 10, 10).bitsOf(), Color.white.bitsOf(), 0, 0, 0, Color.white.bitsOf(), Color.rgb(250, 0, 0).bitsOf() };
    var bits: [2]u8 = undefined;
    convert(.mono, &bits, &src, 10, .rgba8);
    try testing.expectEqual([2]u8{ 0b1010_1000, 0b1000_0000 }, bits);
    var half: [1]u16 = undefined;
    convert(.rgb565, &half, &.{Color.rgb(0, 0, 255).bitsOf()}, 1, .bgra8);
    try testing.expectEqual(pack565(.rgb(255, 0, 0)), half[0]);
    try testing.expectEqual(Color.white, unpack565(pack565(.white)));
    try testing.expectEqual(Color.black, unpack565(pack565(.black)));
}

test "embedded framebuffer: unaligned damage preserves bits outside the area" {
    const white = Color.white.bitsOf();
    const black = Color.black.bitsOf();
    var bytes = [_]u8{ 0xaa, 0x55 };
    var fb: Framebuffer(.mono) = .init(&bytes, 13, 1);
    fb.flush(.{ .x0 = 6, .y0 = 0, .x1 = 10, .y1 = 1 }, &.{ black, white, white, black }, 4);
    try testing.expectEqual([2]u8{ 0xa9, 0x95 }, bytes);
}
