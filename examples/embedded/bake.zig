//! Build-host renderer for the fixed counter panel. Store only the pixels
//! that differ from its base frame for each button state and decimal cell.
const std = @import("std");
const lcgr = @import("lcgr");
const demo = @import("demo.zig");
const width = demo.width;
const height = demo.height;
const Font = demo.Board.Font;
const sw = lcgr.render_sw;
const panel = lcgr.embedded_framebuffer;
const Theme = lcgr.widgets_base.Theme;
const blank = "Count           ";

var memory: [lcgr.context.Context.requiredBytes(demo.limits)]u8 align(lcgr.mem.column_align) = undefined;
var rgba: [sw.Framebuffer.len(width, height)]u32 = undefined;
var base: [width * height]u16 = undefined;
var current: [width * height]u16 = undefined;

fn render(caption: []const u8, face: usize) ![4]u32 {
    var ctx = try lcgr.context.Context.init(&memory, demo.limits);
    var theme: Theme = .default;
    theme.control = theme.controlFills()[face];
    const in: lcgr.input.Input = .{ .viewport = .{ width, height } };
    var f = ctx.begin(&in);
    _ = demo.counter(&f, &theme, caption);
    const out = f.end(.{});
    var quads: [32]lcgr.draw_list.Quad = undefined;
    var first: [demo.limits.texts]u32 = undefined;
    var count: [demo.limits.texts]u32 = undefined;
    const spans: lcgr.protocol.Mono.Glyphs = .{ .first = &first, .count = &count };
    const n = (lcgr.protocol.Mono{}).quads(out.draw, &quads, spans);
    Font.remap(out.draw, quads[0..n], spans);
    var atlas: Font.Pixels = undefined;
    const images = [_]sw.Image{ .white, Font.image(&atlas) };
    var gfx: sw.SoftwareOf(demo.kinds) = .{ .images = &images };
    gfx.prepare({}, out.draw, .{ .quads = quads[0..n], .first = &first, .count = &count, .texture = @fromBackingInt(1) }, .{ 0, 0 }, 1);
    var fb: sw.Framebuffer = .init(&rgba, width, height, .rgba8);
    fb.clear(.black);
    lcgr.render_iface.render(&gfx, .{ .fb = &fb, .scissor = fb.all() }, out.draw);
    for (0..height) |y| panel.convert(.rgb565, current[y * width ..], rgba[y * fb.stride ..], width, .rgba8);
    return lcgr.damage.Region.scissor(out.tree.rect(out.tree.find(demo.id_add)).array(), .{ width, height }, 1);
}

fn emit(w: *std.Io.Writer, name: []const u8) !void {
    try w.print("pub const {s} = [_]Span{{", .{name});
    for (0..height) |y| {
        var x: usize = 0;
        while (x < width) {
            const i = y * width + x;
            const pixel = current[i];
            if (pixel == base[i]) {
                x += 1;
                continue;
            }
            const start = x;
            x += 1;
            while (x < width and current[y * width + x] == pixel and base[y * width + x] != pixel) x += 1;
            try w.print(".{{ .y={d}, .x={d}, .len={d}, .color={d} }},", .{ y, start, x - start, pixel });
        }
    }
    try w.writeAll("};\n");
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(alloc);
    _ = args.next();
    const path = args.next().?;
    var output: std.Io.Writer.Allocating = .init(alloc);
    const w = &output.writer;
    const bounds = try render(blank, 0);
    const background = current[current.len - 1];
    try w.print("pub const Span=extern struct {{ y:u16,x:u16,len:u16,color:u16 }};\npub const background:u16={d};\npub const button=[4]u16{{{d},{d},{d},{d}}};\n", .{ background, bounds[0], bounds[1], bounds[2], bounds[3] });
    @memset(&base, background);
    try emit(w, "base");
    @memcpy(&base, &current);
    for (0..3) |state| {
        _ = try render(blank, state);
        try emit(w, try std.fmt.allocPrint(alloc, "button_{d}", .{state}));
    }
    try w.writeAll("pub const faces=[3][]const Span{&button_0,&button_1,&button_2};\n");
    for (0..10) |pos| for (0..10) |digit| {
        var caption = blank.*;
        caption[6 + pos] = '0' + @as(u8, @intCast(digit));
        _ = try render(&caption, 0);
        try emit(w, try std.fmt.allocPrint(alloc, "digit_{d}_{d}", .{ pos, digit }));
    };
    try w.writeAll("pub const digits=[10][10][]const Span{");
    for (0..10) |pos| {
        try w.writeAll(".{");
        for (0..10) |digit| try w.print("&digit_{d}_{d},", .{ pos, digit });
        try w.writeAll("},");
    }
    try w.writeAll("};\npub const checks=[_]struct{ u32,u2,u32 }{");
    for ([_]u32{ 0, 3, 10, 101, 3849207516 }) |value| for (0..3) |state| {
        var buf: [16]u8 = undefined;
        _ = try render(demo.decimal(&buf, "Count ", value), state);
        var sum: u32 = 0;
        for (current) |pixel| sum = sum *% 31 +% pixel;
        try w.print(".{{{d},{d},{d}}},", .{ value, state, sum });
    };
    try w.writeAll("};\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = output.written() });
}
