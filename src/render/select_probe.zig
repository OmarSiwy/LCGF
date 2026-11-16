//! The selector's zero-cost check (ci/jobs/render-select.sh). Built twice for one back end:
//! once naming the renderer through `lcgr_render` (src/render/select.zig), once by importing
//! the back end's own module, as a program without the selector would. The job requires the
//! two objects' .text to be byte-identical.

const lcgr = @import("lcgr");
const iface = lcgr.render_iface;
const DrawList = lcgr.draw_list.DrawList;
const probe = @import("probe_options");

const R = if (probe.selector) @import("lcgr_render").Renderer else switch (@import("render_options").render) {
    .sw => lcgr.render_sw.Software,
    .web => @import("render_backend").webgpu.Renderer,
    else => @import("render_backend").Renderer,
};

/// One frame: upload, then the whole command loop. Opaque pointers keep the C ABI.
export fn lcgr_render_probe(r: *anyopaque, queue: *const anyopaque, pass: *const anyopaque, draw: *const anyopaque, glyphs: *const anyopaque) void {
    const gfx: *R = @ptrCast(@alignCast(r));
    const list: *const DrawList = @ptrCast(@alignCast(draw));
    gfx.prepare(load(R.Queue, queue), list, load(iface.Glyphs, glyphs), .{ 800, 600 }, 1);
    iface.render(gfx, load(R.Pass, pass), list);
}

fn load(comptime T: type, p: *const anyopaque) T {
    if (@sizeOf(T) == 0) return undefined;
    return @as(*const T, @ptrCast(@alignCast(p))).*;
}
