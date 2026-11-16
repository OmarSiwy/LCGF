//! The smallest web example: the shell example's UI (src/shell/example.zig) built in wasm, one
//! frame at a time, with nothing drawn. It shows the core runs as wasm32-freestanding with the
//! glue in lcgr.js: no allocator, no std.Io, no libc; memory is one static buffer.
//!
//!     const ui = await load("hello.wasm");
//!     ui.exports.lcgr_hello(800, 600);   // nodes in the frame, and logs the sidebar's rect
//!
//! Built by `zig build web` into zig-out/web/hello.wasm; run in a browser by test_glue.html
//! (ci/jobs/web.sh).
const std = @import("std");
const lcgr = @import("lcgr");
const js = @import("js.zig");
const context = lcgr.context;
const example = lcgr.shell_example;

pub const panic = js.panic;

const limits: context.Limits = .{ .nodes = 256, .texts = 64, .customs = 4 };
var buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var ctx: context.Context = undefined;
var app: example.App = .{};
var started = false;

/// Builds one frame of the example at `width` x `height` logical pixels. Returns the number of
/// nodes in it, 0 when the buffer is too small, and logs the sidebar's rect.
export fn lcgr_hello(width: f32, height: f32) u32 {
    if (!started) {
        ctx = context.Context.init(&buffer, limits) catch return 0;
        started = true;
    }
    const in: lcgr.input.Input = .{ .viewport = .{ width, height } };
    var f = ctx.begin(&in);
    app.build(&f, &.{ .in = in });
    const out = f.end(.{});
    const t = out.tree;
    const r = t.rect(t.find(example.id_sidebar));
    js.print("sidebar {d} {d} {d} {d}", .{ r.x0, r.y0, r.x1, r.y1 });
    return t.len * @intFromBool(out.status.ok());
}
