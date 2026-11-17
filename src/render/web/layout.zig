//! The size probe for "layout alone" (Clay's README: about 15 kB of wasm for its layout): the
//! runtime front end with layout and paint and no widgets, no renderer and no text. A toolbar,
//! a sidebar and a filling view, like the shell example's frame; size.py measures the module
//! (ci/jobs/web-size.sh).
const lcgf = @import("lcgf");
const js = @import("js.zig");
const context = lcgf.context;
const Id = lcgf.types.Id;

pub const panic = js.panic;

const limits: context.Limits = .{ .nodes = 64, .texts = 4, .customs = 1 };
var buffer: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var ctx: context.Context = undefined;

/// Lays out one frame at `width` x `height`; returns the view's width, 0 if the buffer is too
/// small.
export fn lcgf_layout(width: f32, height: f32) f32 {
    ctx = context.Context.init(&buffer, limits) catch return 0;
    const in: lcgf.input.Input = .{ .viewport = .{ width, height } };
    var f = ctx.begin(&in);
    _ = f.open(.from("root"), .{ .size = .{ .fill, .fill } });
    _ = f.leaf(.from("toolbar"), .{ .size = .{ .fill, .px(50) }, .fill = .rgb(40, 40, 48) });
    _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
    _ = f.leaf(.from("sidebar"), .{ .size = .{ .px(160), .fill }, .fill = .rgb(30, 30, 36) });
    _ = f.leaf(.from("view"), .{ .size = .{ .fill, .fill } });
    f.close();
    f.close();
    const out = f.end(.{});
    const r = out.tree.rect(out.tree.find(.from("view")));
    return r.x1 - r.x0;
}
