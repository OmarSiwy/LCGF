//! PNG decoding into premultiplied RGBA8, over the caller's memory (https://www.w3.org/TR/png/).
//!
//! `src/assets/` sits outside tiers 0 to 2, beside the renderers: the core never imports it, and
//! a host hands the pixels to its back end (in the prototype, a GPU texture registered with
//! `Renderer.addTexture` and shown with `Style.texture`; prototype/ui_wgpu.zig). The decoder
//! itself allocates nothing and touches no OS: `info` says how many bytes `decode` needs, the
//! caller provides them. Inflate is `std.compress.flate` over in-memory readers and writers.
//!
//! Output is premultiplied RGBA8, row by row, `w * 4` bytes a row: the stock material multiplies
//! the fill by the texel (src/render/shaders/quad.wgsl) and its output is premultiplied, and
//! bilinear filtering and mipmaps average correctly only premultiplied texels. Premultiplying
//! is done on the stored (sRGB-encoded) values, as browsers and most toolkits do.
//!
//! Everything the spec defines for decoding is read: colour types 0, 2, 3, 4, 6 at every
//! allowed bit depth, PLTE, tRNS and Adam7 interlacing; chunk CRCs and the zlib checksum are
//! checked. 16-bit samples are rounded to 8. Ancillary chunks other than tRNS (gAMA, iCCP,
//! sRGB, text) are skipped: the image is drawn as stored. A file is untrusted input: any bytes
//! end in an image or an error, never a crash or a read out of bounds.
//!
//! Decoding is not a per-row pass over tree columns, so the branchless rule does not bind it;
//! the per-byte loops still avoid data-dependent branches (Paeth is selects, palette lookups go
//! through a 256-entry table).

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{
    /// No PNG signature.
    NotPng,
    /// The file ends inside a chunk, or before IEND.
    Truncated,
    /// A chunk's CRC does not match.
    BadCrc,
    /// IHDR is missing, misplaced or holds values the spec does not allow.
    BadHeader,
    /// A chunk is malformed or out of order (PLTE after IDAT, tRNS of the wrong size, a
    /// palette image without PLTE, no IDAT).
    BadChunk,
    /// An unknown critical chunk: the image cannot be decoded without understanding it.
    Unsupported,
    /// Wider or taller than `max_side`.
    TooLarge,
    /// The zlib stream is corrupt, or decompresses to more or less than the image needs.
    BadData,
    /// A scanline starts with a filter type other than 0 to 4.
    BadFilter,
    /// `pixels` or `scratch` is shorter than `Info` says.
    NoSpace,
};

/// Largest width or height decoded. It keeps every size below 2^31 bytes, so the arithmetic
/// fits a 32-bit usize (wasm32), and it is the common GPU texture limit.
pub const max_side = 16384;

pub const Color = enum(u8) { gray = 0, rgb = 2, palette = 3, gray_alpha = 4, rgba = 6, _ };

/// What a file holds and how much memory decoding it takes.
pub const Info = struct {
    w: u32,
    h: u32,
    depth: u8,
    color: Color,
    interlaced: bool,
    /// The PLTE entries, 3 bytes each (empty when there is none), and the tRNS data (empty when
    /// there is none); slices into the file.
    plte: []const u8 = &.{},
    trns: []const u8 = &.{},
    /// Bytes of compressed image data: all IDAT chunks together.
    zlib_len: usize = 0,
    /// Bytes of filtered scanlines, every pass, filter bytes included.
    raw_len: usize = 0,

    /// Size of `decode`'s `pixels`: `w * h * 4`.
    pub fn pixelBytes(i: Info) usize {
        return @as(usize, i.w) * i.h * 4;
    }

    /// Size of `decode`'s `scratch`.
    pub fn scratchBytes(i: Info) usize {
        return i.zlib_len + i.raw_len;
    }

    fn channels(i: Info) u32 {
        return switch (i.color) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            else => 4,
        };
    }
};

const signature = "\x89PNG\r\n\x1a\n";

fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// One chunk: its type and data, a slice into the file.
const Chunk = struct { type: u32, data: []const u8 };

/// Walks the chunks after the signature, checking each one's bounds and CRC.
const Chunks = struct {
    png: []const u8,
    at: usize = signature.len,

    fn next(c: *Chunks) Error!Chunk {
        if (c.png.len - c.at < 12) return error.Truncated;
        const len = std.mem.readInt(u32, c.png[c.at..][0..4], .big);
        if (len > c.png.len - c.at - 12) return error.Truncated;
        const body = c.png[c.at + 4 ..][0 .. 4 + len];
        const crc = std.mem.readInt(u32, c.png[c.at + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(body) != crc) return error.BadCrc;
        c.at += 12 + len;
        return .{ .type = std.mem.readInt(u32, body[0..4], .big), .data = body[4..] };
    }
};

/// Adam7 passes as x0, y0, dx, dy; a plain image is one pass of the whole grid.
const adam7 = [7][4]u32{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
const whole = [1][4]u32{.{ 0, 0, 1, 1 }};

fn passes(i: Info) []const [4]u32 {
    return if (i.interlaced) &adam7 else &whole;
}

/// Pixels of a pass along a side of `n`: the ones at `x0 + k * dx`.
fn passLen(n: u32, x0: u32, dx: u32) u32 {
    return if (n > x0) (n - x0 + dx - 1) / dx else 0;
}

fn rowBytes(i: Info, pw: u32) usize {
    return (@as(usize, pw) * i.channels() * i.depth + 7) / 8;
}

/// Reads the header and walks every chunk. Cheap next to `decode`: no inflate.
pub fn info(png: []const u8) Error!Info {
    if (png.len < signature.len or !std.mem.eql(u8, png[0..signature.len], signature)) return error.NotPng;
    var chunks: Chunks = .{ .png = png };
    const ihdr = try chunks.next();
    if (ihdr.type != tag("IHDR") or ihdr.data.len != 13) return error.BadHeader;
    const d = ihdr.data;
    var i: Info = .{
        .w = std.mem.readInt(u32, d[0..4], .big),
        .h = std.mem.readInt(u32, d[4..8], .big),
        .depth = d[8],
        .color = @fromBackingInt(@intCast(d[9])),
        .interlaced = d[12] == 1,
    };
    const depth_ok = switch (i.color) {
        .gray => i.depth == 1 or i.depth == 2 or i.depth == 4 or i.depth == 8 or i.depth == 16,
        .palette => i.depth == 1 or i.depth == 2 or i.depth == 4 or i.depth == 8,
        .rgb, .gray_alpha, .rgba => i.depth == 8 or i.depth == 16,
        _ => false,
    };
    if (!depth_ok or d[10] != 0 or d[11] != 0 or d[12] > 1 or i.w == 0 or i.h == 0) return error.BadHeader;
    if (i.w > max_side or i.h > max_side) return error.TooLarge;

    var seen_idat = false;
    while (true) {
        const c = try chunks.next();
        switch (c.type) {
            tag("IEND") => break,
            tag("IDAT") => {
                seen_idat = true;
                i.zlib_len += c.data.len;
            },
            tag("PLTE") => {
                if (seen_idat or c.data.len == 0 or c.data.len % 3 != 0 or c.data.len > 3 * 256) return error.BadChunk;
                i.plte = c.data;
            },
            tag("tRNS") => {
                if (seen_idat) return error.BadChunk;
                const ok = switch (i.color) {
                    .gray => c.data.len == 2,
                    .rgb => c.data.len == 6,
                    .palette => i.plte.len > 0 and c.data.len <= i.plte.len / 3,
                    else => false,
                };
                if (!ok) return error.BadChunk;
                i.trns = c.data;
            },
            tag("IHDR") => return error.BadChunk,
            // Bit 5 of the first byte clear: critical, and unknown.
            else => if (c.type & 0x2000_0000 == 0) return error.Unsupported,
        }
    }
    if (!seen_idat or (i.color == .palette and i.plte.len == 0)) return error.BadChunk;
    for (passes(i)) |p| {
        const pw = passLen(i.w, p[0], p[2]);
        const ph = passLen(i.h, p[1], p[3]);
        if (pw != 0) i.raw_len += (1 + rowBytes(i, pw)) * ph;
    }
    return i;
}

/// Decodes `png` into `pixels` (`info(png).pixelBytes()`, premultiplied RGBA8, row by row),
/// using `scratch` (`scratchBytes()`). Returns the image's `Info`.
pub fn decode(png: []const u8, pixels: []u8, scratch: []u8) Error!Info {
    const i = try info(png);
    if (pixels.len < i.pixelBytes() or scratch.len < i.scratchBytes()) return error.NoSpace;
    const zlib = scratch[0..i.zlib_len];
    const raw = scratch[i.zlib_len..][0..i.raw_len];

    var chunks: Chunks = .{ .png = png };
    var at: usize = 0;
    while (true) {
        const c = chunks.next() catch unreachable; // `info` walked these already
        if (c.type == tag("IEND")) break;
        if (c.type != tag("IDAT")) continue;
        @memcpy(zlib[at..][0..c.data.len], c.data);
        at += c.data.len;
    }

    var in: std.Io.Reader = .fixed(zlib);
    var z: flate.Decompress = .init(&in, .zlib, &.{});
    var out: std.Io.Writer = .fixed(raw);
    const n = z.reader.streamRemaining(&out) catch return error.BadData;
    if (n != raw.len) return error.BadData;

    const lut = paletteTable(i);
    var row_at: usize = 0;
    for (passes(i)) |p| {
        const pw = passLen(i.w, p[0], p[2]);
        const ph = passLen(i.h, p[1], p[3]);
        if (pw == 0) continue;
        const len = rowBytes(i, pw);
        const step: usize = @max(1, i.channels() * i.depth / 8);
        var prev: []const u8 = &.{};
        for (0..ph) |row| {
            const line = raw[row_at + 1 ..][0..len];
            switch (raw[row_at]) {
                0 => {},
                1 => unfilter(1, line, prev, step),
                2 => unfilter(2, line, prev, step),
                3 => unfilter(3, line, prev, step),
                4 => unfilter(4, line, prev, step),
                else => return error.BadFilter,
            }
            const y = p[1] + @as(u32, @intCast(row)) * p[3];
            expand(i, &lut, line, pixels, y, p[0], p[2], pw);
            prev = line;
            row_at += 1 + len;
        }
    }
    return i;
}

/// Reverses one scanline's filter in place. `prev` is the pass's previous scanline, unfiltered,
/// or empty on its first; `step` is bytes per pixel, at least 1.
inline fn unfilter(comptime filter: u8, line: []u8, prev: []const u8, step: usize) void {
    if (prev.len == 0) {
        // Above the first scanline is a row of zeros: Up is None, Paeth is Sub.
        switch (filter) {
            1, 4 => for (step..line.len) |x| {
                line[x] +%= line[x - step];
            },
            3 => for (0..line.len) |x| {
                const left: u8 = if (x >= step) line[x - step] else 0;
                line[x] +%= left >> 1;
            },
            else => {},
        }
        return;
    }
    switch (filter) {
        1 => for (step..line.len) |x| {
            line[x] +%= line[x - step];
        },
        2 => for (line, prev) |*b, up| {
            b.* +%= up;
        },
        3 => {
            for (0..step) |x| line[x] +%= prev[x] >> 1;
            for (step..line.len) |x| line[x] +%= @intCast((@as(u16, line[x - step]) + prev[x]) >> 1);
        },
        else => {
            for (0..step) |x| line[x] +%= prev[x];
            for (step..line.len) |x| line[x] +%= paeth(line[x - step], prev[x], prev[x - step]);
        },
    }
}

/// The Paeth predictor, as selects: whichever of left, up and up-left is nearest to
/// left + up - up-left, ties in that order.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const ia: i16 = a;
    const ib: i16 = b;
    const ic: i16 = c;
    const pa = @abs(ib - ic);
    const pb = @abs(ia - ic);
    const pc = @abs(ia + ib - 2 * ic);
    const bc = if (pb <= pc) b else c;
    return if (pa <= pb and pa <= pc) a else bc;
}

/// Premultiplied RGBA of every palette index; indices past the palette are transparent black
/// (the spec calls them an error; browsers draw them black).
fn paletteTable(i: Info) [256][4]u8 {
    var lut: [256][4]u8 = @splat(.{ 0, 0, 0, 0 });
    for (0..i.plte.len / 3) |k| {
        const a: u8 = if (k < i.trns.len) i.trns[k] else 255;
        lut[k] = premultiply(.{ i.plte[3 * k], i.plte[3 * k + 1], i.plte[3 * k + 2], a });
    }
    return lut;
}

fn premultiply(c: [4]u8) [4]u8 {
    const a: u16 = c[3];
    return .{
        @intCast((@as(u16, c[0]) * a + 127) / 255),
        @intCast((@as(u16, c[1]) * a + 127) / 255),
        @intCast((@as(u16, c[2]) * a + 127) / 255),
        c[3],
    };
}

/// Sample `s` of an unfiltered scanline, at its own bit depth.
fn sample(line: []const u8, s: usize, depth: u8) u16 {
    if (depth == 16) return std.mem.readInt(u16, line[2 * s ..][0..2], .big);
    if (depth == 8) return line[s];
    const bit = s * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    return (line[bit / 8] >> shift) & ((@as(u8, 1) << @intCast(depth)) - 1);
}

/// A sample scaled to 8 bits, rounding.
fn to8(v: u16, depth: u8) u8 {
    const max: u32 = (@as(u32, 1) << @intCast(depth)) - 1;
    return @intCast((@as(u32, v) * 255 + max / 2) / max);
}

/// Writes one unfiltered scanline of a pass into `pixels` at row `y`, columns `x0 + k * dx`.
fn expand(i: Info, lut: *const [256][4]u8, line: []const u8, pixels: []u8, y: u32, x0: u32, dx: u32, pw: u32) void {
    const ch = i.channels();
    const key: [3]u16 = if (i.trns.len == 6)
        .{ std.mem.readInt(u16, i.trns[0..2], .big), std.mem.readInt(u16, i.trns[2..4], .big), std.mem.readInt(u16, i.trns[4..6], .big) }
    else if (i.trns.len == 2 and i.color == .gray)
        @splat(std.mem.readInt(u16, i.trns[0..2], .big))
    else
        // No key: a value no sample can have.
        @splat(0xffff);
    const keyed = i.trns.len > 0 and i.color != .palette;
    for (0..pw) |k| {
        const s = k * ch;
        const v0 = sample(line, s, i.depth);
        const rgba: [4]u8 = switch (i.color) {
            .palette => lut[v0 & 0xff],
            .gray => blk: {
                const g = to8(v0, i.depth);
                const a: u8 = if (keyed and v0 == key[0]) 0 else 255;
                break :blk premultiply(.{ g, g, g, a });
            },
            .gray_alpha => blk: {
                const g = to8(v0, i.depth);
                break :blk premultiply(.{ g, g, g, to8(sample(line, s + 1, i.depth), i.depth) });
            },
            .rgb => blk: {
                const v1 = sample(line, s + 1, i.depth);
                const v2 = sample(line, s + 2, i.depth);
                const clear = keyed and v0 == key[0] and v1 == key[1] and v2 == key[2];
                const a: u8 = if (clear) 0 else 255;
                break :blk premultiply(.{ to8(v0, i.depth), to8(v1, i.depth), to8(v2, i.depth), a });
            },
            else => premultiply(.{
                to8(v0, i.depth),
                to8(sample(line, s + 1, i.depth), i.depth),
                to8(sample(line, s + 2, i.depth), i.depth),
                to8(sample(line, s + 3, i.depth), i.depth),
            }),
        };
        const x = x0 + @as(u32, @intCast(k)) * dx;
        pixels[(@as(usize, y) * i.w + x) * 4 ..][0..4].* = rgba;
    }
}

// ---- tests

/// Test encoder: a PNG of `raw` (filtered scanlines, every pass, filter bytes included) with
/// the given header and extra chunks before IDAT, compressed by std's deflate.
pub fn encodeForTest(gpa: std.mem.Allocator, w: u32, h: u32, depth: u8, color: Color, interlaced: bool, extra: []const Chunk, raw: []const u8) ![]u8 {
    var zbuf: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer zbuf.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        const c = try gpa.create(flate.Compress);
        defer gpa.destroy(c);
        c.* = try .init(&zbuf.writer, window, .zlib, .default);
        try c.writer.writeAll(raw);
        try c.finish();
    }
    var file: std.Io.Writer.Allocating = .init(gpa);
    errdefer file.deinit();
    const fw = &file.writer;
    try fw.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = @backingInt(color);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = @intFromBool(interlaced);
    try writeChunk(fw, tag("IHDR"), &ihdr);
    for (extra) |c| try writeChunk(fw, c.type, c.data);
    // Two IDAT chunks when there is enough data, to cover the concatenation.
    const z = zbuf.written();
    const half = z.len / 2;
    try writeChunk(fw, tag("IDAT"), z[0..half]);
    try writeChunk(fw, tag("IDAT"), z[half..]);
    try writeChunk(fw, tag("IEND"), "");
    return file.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, t: u32, data: []const u8) !void {
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(data.len), .big);
    std.mem.writeInt(u32, head[4..8], t, .big);
    var crc: std.hash.Crc32 = .init();
    crc.update(head[4..8]);
    crc.update(data);
    try w.writeAll(&head);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Decodes with exactly the memory `info` asks for; the caller frees the pixels.
pub fn decodeForTest(gpa: std.mem.Allocator, file: []const u8) ![]u8 {
    const i = try info(file);
    const pixels = try gpa.alloc(u8, i.pixelBytes());
    errdefer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, i.scratchBytes());
    defer gpa.free(scratch);
    _ = try decode(file, pixels, scratch);
    return pixels;
}

const testing = std.testing;

test "8-bit RGBA, every filter type, premultiplied" {
    const gpa = testing.allocator;
    // 2x5, one scanline per filter type. The source pixels are row r, column c:
    // (10r + c, 50 + c, 200 - r, 255 or 128).
    var src: [5][2][4]u8 = undefined;
    for (0..5) |r| for (0..2) |c| {
        src[r][c] = .{ @intCast(10 * r + c), @intCast(50 + c), @intCast(200 - r), if (c == 0) 255 else 128 };
    };
    var raw: [5 * 9]u8 = undefined;
    var prev: [8]u8 = @splat(0);
    for (0..5) |r| {
        const cur: [8]u8 = @bitCast(src[r]);
        const line = raw[r * 9 ..][0..9];
        line[0] = @intCast(r);
        for (0..8) |x| {
            const a: u8 = if (x >= 4) cur[x - 4] else 0;
            const b = prev[x];
            const c: u8 = if (x >= 4) prev[x - 4] else 0;
            const pred: u8 = switch (r) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                else => paeth(a, b, c),
            };
            line[1 + x] = cur[x] -% pred;
        }
        prev = cur;
    }
    const file = try encodeForTest(gpa, 2, 5, 8, .rgba, false, &.{}, &raw);
    defer gpa.free(file);
    const i = try info(file);
    try testing.expectEqual(2, i.w);
    try testing.expectEqual(5, i.h);
    try testing.expectEqual(40, i.pixelBytes());
    const px = try decodeForTest(gpa, file);
    defer gpa.free(px);
    for (0..5) |r| for (0..2) |c| {
        try testing.expectEqualSlices(u8, &premultiply(src[r][c]), px[(r * 2 + c) * 4 ..][0..4]);
    };
}

test "palette with tRNS, 1-bit and 4-bit, out-of-range index" {
    const gpa = testing.allocator;
    const plte = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    const trns = [_]u8{ 0, 128 }; // entry 0 clear, 1 half, 2 opaque
    // 1 bit: 10 pixels 1010110000 in two bytes.
    const raw1 = [_]u8{ 0, 0b1010_1100, 0b0000_0000 };
    const f1 = try encodeForTest(gpa, 10, 1, 1, .palette, false, &.{ .{ .type = tag("PLTE"), .data = &plte }, .{ .type = tag("tRNS"), .data = &trns } }, &raw1);
    defer gpa.free(f1);
    const p1 = try decodeForTest(gpa, f1);
    defer gpa.free(p1);
    const half_green = [4]u8{ 0, 128, 0, 128 };
    const clear = [4]u8{ 0, 0, 0, 0 };
    for ([_]u8{ 1, 0, 1, 0, 1, 1, 0, 0, 0, 0 }, 0..) |bit, x|
        try testing.expectEqualSlices(u8, if (bit == 1) &half_green else &clear, p1[x * 4 ..][0..4]);
    // 4 bit: indices 2, 1, 0, 9 (past the palette).
    const raw4 = [_]u8{ 0, 0x21, 0x09 };
    const f4 = try encodeForTest(gpa, 4, 1, 4, .palette, false, &.{ .{ .type = tag("PLTE"), .data = &plte }, .{ .type = tag("tRNS"), .data = &trns } }, &raw4);
    defer gpa.free(f4);
    const p4 = try decodeForTest(gpa, f4);
    defer gpa.free(p4);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255, 0, 128, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0 }, p4);
}

test "2-bit gray with a tRNS key, 16-bit gray-alpha rounding" {
    const gpa = testing.allocator;
    // 2 bits: 0, 1, 2, 3 -> 0, 85, 170, 255; key 2 is clear.
    const raw2 = [_]u8{ 0, 0b00_01_10_11 };
    const f2 = try encodeForTest(gpa, 4, 1, 2, .gray, false, &.{.{ .type = tag("tRNS"), .data = &.{ 0, 2 } }}, &raw2);
    defer gpa.free(f2);
    const p2 = try decodeForTest(gpa, f2);
    defer gpa.free(p2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255, 85, 85, 85, 255, 0, 0, 0, 0, 255, 255, 255, 255 }, p2);
    // 16 bits: 0x8080 -> 128, 0xffff -> 255; gray-alpha 16.
    const raw16 = [_]u8{ 0, 0x80, 0x80, 0xff, 0xff, 0x00, 0x00, 0x80, 0x00 };
    const file16 = try encodeForTest(gpa, 2, 1, 16, .gray_alpha, false, &.{}, &raw16);
    defer gpa.free(file16);
    const px16 = try decodeForTest(gpa, file16);
    defer gpa.free(px16);
    try testing.expectEqualSlices(u8, &[_]u8{ 128, 128, 128, 255, 0, 0, 0, 128 }, px16);
}

test "RGB with a colour key" {
    const gpa = testing.allocator;
    const raw = [_]u8{ 0, 1, 2, 3, 1, 2, 4 };
    const f = try encodeForTest(gpa, 2, 1, 8, .rgb, false, &.{.{ .type = tag("tRNS"), .data = &.{ 0, 1, 0, 2, 0, 3 } }}, &raw);
    defer gpa.free(f);
    const p = try decodeForTest(gpa, f);
    defer gpa.free(p);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 1, 2, 4, 255 }, p);
}

/// Filter-0 scanlines of an Adam7 image whose pixel (x, y) is gray `x + 16 * y`.
fn adam7Raw(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);
    for (adam7) |p| {
        const pw = passLen(w, p[0], p[2]);
        const ph = passLen(h, p[1], p[3]);
        if (pw == 0) continue;
        for (0..ph) |r| {
            try raw.append(gpa, 0);
            for (0..pw) |k| try raw.append(gpa, @intCast((p[0] + k * p[2]) + 16 * (p[1] + r * p[3])));
        }
    }
    return raw.toOwnedSlice(gpa);
}

test "Adam7 interlacing, including sizes with empty passes" {
    const gpa = testing.allocator;
    for ([_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 9, 9 }, .{ 13, 15 } }) |size| {
        const raw = try adam7Raw(gpa, size[0], size[1]);
        defer gpa.free(raw);
        const f = try encodeForTest(gpa, size[0], size[1], 8, .gray, true, &.{}, raw);
        defer gpa.free(f);
        try testing.expectEqual(raw.len, (try info(f)).raw_len);
        const p = try decodeForTest(gpa, f);
        defer gpa.free(p);
        for (0..size[1]) |y| for (0..size[0]) |x| {
            const g: u8 = @intCast(x + 16 * y);
            try testing.expectEqualSlices(u8, &.{ g, g, g, 255 }, p[(y * size[0] + x) * 4 ..][0..4]);
        };
    }
}

test "malformed files are errors" {
    const gpa = testing.allocator;
    const raw = [_]u8{ 0, 1, 2, 3, 4 };
    const good = try encodeForTest(gpa, 1, 1, 8, .rgba, false, &.{}, &raw);
    defer gpa.free(good);
    var px: [4]u8 = undefined;
    var scratch: [64]u8 = undefined;
    _ = try decode(good, &px, &scratch);
    try testing.expectError(error.NoSpace, decode(good, px[0..3], &scratch));
    try testing.expectError(error.NotPng, info("GIF89a"));
    try testing.expectError(error.Truncated, info(good[0 .. good.len - 1]));
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    bad[20] ^= 1; // inside IHDR's data
    try testing.expectError(error.BadCrc, info(bad));
    // Filter type 5.
    const f5 = try encodeForTest(gpa, 1, 1, 8, .rgba, false, &.{}, &[_]u8{ 5, 1, 2, 3, 4 });
    defer gpa.free(f5);
    try testing.expectError(error.BadFilter, decode(f5, &px, &scratch));
    // Too little and too much image data.
    const short = try encodeForTest(gpa, 1, 1, 8, .rgba, false, &.{}, raw[0..4]);
    defer gpa.free(short);
    try testing.expectError(error.BadData, decode(short, &px, &scratch));
    const long = try encodeForTest(gpa, 1, 1, 8, .rgba, false, &.{}, &[_]u8{ 0, 1, 2, 3, 4, 5 });
    defer gpa.free(long);
    try testing.expectError(error.BadData, decode(long, &px, &scratch));
    // A palette image without PLTE, RGB at 4 bits, an unknown critical chunk.
    const nop = try encodeForTest(gpa, 1, 1, 8, .palette, false, &.{}, &[_]u8{ 0, 0 });
    defer gpa.free(nop);
    try testing.expectError(error.BadChunk, info(nop));
    const rgb4 = try encodeForTest(gpa, 1, 1, 4, .rgb, false, &.{}, &[_]u8{ 0, 0 });
    defer gpa.free(rgb4);
    try testing.expectError(error.BadHeader, info(rgb4));
    const crit = try encodeForTest(gpa, 1, 1, 8, .rgba, false, &.{.{ .type = tag("ABCD"), .data = "" }}, &raw);
    defer gpa.free(crit);
    try testing.expectError(error.Unsupported, info(crit));
    const anc = try encodeForTest(gpa, 1, 1, 8, .rgba, false, &.{.{ .type = tag("abCD"), .data = "x" }}, &raw);
    defer gpa.free(anc);
    _ = try decode(anc, &px, &scratch);
}

test "gray at 1, 4 and 8 bits scales to the full range" {
    const gpa = testing.allocator;
    for ([_]u8{ 1, 4, 8 }) |depth| {
        // Two pixels: 0 and the largest sample, packed from the top bit.
        const max: u16 = (@as(u16, 1) << @intCast(depth)) - 1;
        var raw: [3]u8 = .{ 0, 0, 0 };
        if (depth == 8) raw[2] = 0xff else raw[1] = @intCast(max << @intCast(8 - 2 * depth));
        const f = try encodeForTest(gpa, 2, 1, depth, .gray, false, &.{}, if (depth == 8) &raw else raw[0..2]);
        defer gpa.free(f);
        const p = try decodeForTest(gpa, f);
        defer gpa.free(p);
        try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 }, p);
    }
}

test "mutated files are errors, not crashes" {
    // A short seeded run; C0762's fuzzer runs the same idea for a set time.
    const gpa = testing.allocator;
    const raw = try adam7Raw(gpa, 9, 9);
    defer gpa.free(raw);
    const plte = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const seeds = [_][]u8{
        try encodeForTest(gpa, 9, 9, 8, .gray, true, &.{.{ .type = tag("tRNS"), .data = &.{ 0, 7 } }}, raw),
        try encodeForTest(gpa, 2, 2, 2, .palette, false, &.{ .{ .type = tag("PLTE"), .data = &plte }, .{ .type = tag("tRNS"), .data = &.{9} } }, &.{ 4, 0x40, 1, 0x80 }),
    };
    defer for (seeds) |s| gpa.free(s);
    var buf: [512]u8 = undefined;
    var px: [4096]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x9e3779b9);
    const r = prng.random();
    for (0..3000) |_| {
        const s = seeds[r.uintLessThan(usize, seeds.len)];
        @memcpy(buf[0..s.len], s);
        var n = s.len;
        for (0..r.intRangeAtMost(u32, 1, 3)) |_| {
            // Past the signature: a broken signature only tests one compare.
            const at = 8 + r.uintLessThan(usize, n - 8);
            switch (r.uintLessThan(u8, 8)) {
                0 => buf[at] ^= @as(u8, 1) << r.int(u3),
                1, 2, 3 => buf[at] = r.int(u8),
                4, 5, 6 => buf[at] +%= 1,
                else => n = @max(9, r.uintAtMost(usize, n)),
            }
        }
        // Mutations mostly break a CRC; fix them most of the time so the bytes reach inflate.
        if (r.uintLessThan(u8, 8) != 0) fixCrcs(buf[0..n]);
        if (decode(buf[0..n], &px, &scratch)) |i| {
            try testing.expect(i.pixelBytes() <= px.len);
        } else |_| {}
    }
}

/// Rewrites every whole chunk's CRC, so a mutated file gets past the CRC check.
pub fn fixCrcs(file: []u8) void {
    var at: usize = signature.len;
    while (file.len >= at and file.len - at >= 12) {
        const len = std.mem.readInt(u32, file[at..][0..4], .big);
        if (len > file.len - at - 12) return;
        std.mem.writeInt(u32, file[at + 8 + len ..][0..4], std.hash.Crc32.hash(file[at + 4 ..][0 .. 4 + len]), .big);
        at += 12 + len;
    }
}
