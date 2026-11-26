// Internal check tool: builds a frame and writes what a renderer needs to
// file descriptors, so a real wgpu device (driven from Python) can draw it.
const std = @import("std");
const lcgf = @import("lcgf");
const gfx = lcgf.quad_shader;
const linux = std.os.linux;

const limits: lcgf.context.Limits = .{ .nodes = 512, .texts = 128 };
var buffer: [lcgf.context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var glyph_quads: [4096]lcgf.draw_list.Quad = undefined;
var first: [128]u32 = undefined;
var count: [128]u32 = undefined;

fn out(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) off += linux.write(fd, bytes.ptr + off, bytes.len - off);
}
fn print(fd: i32, comptime fmt: []const u8, args: anytype) void {
    var tmp: [512]u8 = undefined;
    out(fd, std.fmt.bufPrint(&tmp, fmt, args) catch unreachable);
}

var exposure: f32 = 2.5;
var wire: bool = true;

fn build(f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme) void {
    _ = f.open(lcgf.types.Id.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
    _ = lcgf.widgets_base.button(f, th, lcgf.types.Id.from("reset"), "Reset");
    _ = lcgf.widgets_base.checkbox(f, th, lcgf.types.Id.from("wire"), &wire, "Wireframe");
    _ = lcgf.widgets_base.slider(f, th, lcgf.types.Id.from("exposure"), &exposure, 0, 4);
    f.close();
    _ = f.open(lcgf.types.Id.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
    _ = f.open(lcgf.types.Id.from("sidebar"), .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4, .fill = th.panel });
    _ = lcgf.widgets_base.button(f, th, lcgf.types.Id.from("add"), "Add layer");
    var name: [24]u8 = undefined;
    for (0..4) |i| _ = lcgf.widgets_base.label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
    f.close();
    // The custom viewport, with a floating panel over it and a clipped child.
    _ = f.open(.none, .{ .size = .{ .fill, .fill } });
    _ = f.custom(lcgf.types.Id.from("viewport"), .{ .size = .{ .fill, .fill } }, 7);
    _ = f.open(.none, .{ .float = true, .offset = .{ 24, 24 }, .size = .{ .px(220), .px(90) }, .pad = @splat(12), .gap = 8, .radius = 12, .fill = lcgf.types.Color.rgba(20, 22, 28, 235), .border = 2, .border_color = th.accent, .clip = true });
    _ = lcgf.widgets_base.label(f, th, "Overlay on your pass");
    _ = f.leaf(.none, .{ .size = .{ .px(400), .px(24) }, .radius = 6, .fill = lcgf.types.Color.rgb(200, 90, 60) }); // wider than the panel: clipped
    f.close();
    f.close();
    f.close();
}

pub fn main() void {
    var ctx = lcgf.context.Context.init(&buffer, limits) catch unreachable;
    const th: lcgf.widgets_base.Theme = .{};
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    var result: lcgf.context.Output = undefined;
    for (0..3) |k| {
        var f = ctx.begin(&in);
        build(&f, &th);
        result = f.end(.{});
        if (k == 0) { // hover the Reset button from the second frame on
            const r = result.tree.rect(result.tree.find(lcgf.types.Id.from("reset")));
            in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
        }
    }
    const d = result.draw;
    const font: lcgf.protocol.Mono = .{};
    const n = font.quads(d, &glyph_quads, .{ .first = &first, .count = &count });

    // The reference atlas uses interpolated UVs for nearest sampling. The stock
    // material resolves texel ties from screen coordinates for backend conformance.
    out(3, gfx.shader(
        \\fn material(in: Frag) -> vec4f {
        \\    return in.fill * textureSample(tex, samp, in.uv);
        \\}
    ));
    out(4, d.quadBytes());
    out(5, std.mem.sliceAsBytes(glyph_quads[0..n]));
    print(6, "stride {d}\n", .{gfx.stride});
    for (gfx.attrs) |a| print(6, "attr {d} {d} {s}\n", .{ a.location, a.offset, a.format });
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .quads => |b| print(6, "quads {d} {d} {d} {d}\n", .{ b.first, b.count, @backingInt(b.texture), @backingInt(b.material) }),
        .text => |k| print(6, "text {d} {d}\n", .{ first[k], count[k] }),
        .custom, .canvas => |k| print(6, "custom {d} {d} {d} {d} {d}\n", .{ d.customs[k].rect[0], d.customs[k].rect[1], d.customs[k].rect[2], d.customs[k].rect[3], d.customs[k].data }),
    };
    const rr = result.tree.rect(result.tree.find(lcgf.types.Id.from("reset")));
    print(6, "reset {d} {d} {d} {d}\n", .{ rr.x0, rr.y0, rr.x1, rr.y1 });
    print(6, "cursor {s}\n", .{@tagName(result.platform.cursor)});
}
