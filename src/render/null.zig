//! The null back end: meets the contract in iface.zig, draws nothing, and records every call a
//! GPU back end would make into a log the caller owns. Ported from the recording binding `Mock`
//! in prototype/ui_wgpu.zig, folded into a back end: `prepare` logs one write per buffer and
//! every draw logs the full bind of prototype `Renderer.bind` (pipeline, group 0, group 1,
//! vertex buffer) before the draw itself. Use it to test a host's command loop, and as the
//! reference call stream the conformance scenes check.

const std = @import("std");
const types = @import("../core/types.zig");
const draw_list = @import("../draw/draw_list.zig");
const iface = @import("iface.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;

/// The buffers a GPU back end owns, as the handles the log names them by.
pub const Buffer = enum(u32) { quads, glyphs, globals };

/// Prototype `Globals`: group 0, binding 0.
pub const Globals = extern struct {
    /// Logical pixels.
    viewport: [2]f32,
    /// Physical pixels per logical pixel.
    scale: f32,
    _pad: f32 = 0,
};

pub const Call = union(enum) {
    write: struct { buffer: Buffer, bytes: usize },
    /// The material's pipeline.
    pipeline: types.Material,
    /// Group 0 is the globals; group 1 is the texture with this index.
    group: struct { index: u32, texture: types.Texture },
    vertex_buffer: Buffer,
    draw: struct { vertices: u32, instances: u32, first_instance: u32 },
    /// Pushed by the host (not the back end) where its own draws ran: pass state unknown.
    host,
};

/// True when every draw after a `host` call is preceded, since that call, by a pipeline, both
/// bind groups and a vertex buffer: the full state rebinding iface.zig requires.
pub fn rebindsAfterHost(calls: []const Call) bool {
    const all: u4 = 0b1111;
    var set: u4 = all; // nothing foreign has run yet
    for (calls) |call| switch (call) {
        .host => set = 0,
        .pipeline => set |= 0b0001,
        .group => |g| set |= @as(u4, 0b0010) << @intCast(@min(g.index, 1)),
        .vertex_buffer => set |= 0b1000,
        .draw => if (set != all) return false,
        .write => {},
    };
    return true;
}

/// Caller-owned call log. Calls past `calls.len` overwrite the last row; `len` keeps counting,
/// so `len > calls.len` means the log was too short.
pub const Log = struct {
    calls: []Call,
    len: u32 = 0,

    pub fn push(l: *Log, c: Call) void {
        l.calls[@min(l.len, l.calls.len - 1)] = c;
        l.len += 1;
    }

    pub fn recorded(l: *const Log) []const Call {
        return l.calls[0..@min(l.len, l.calls.len)];
    }
};

pub const Null = struct {
    pub const Queue = *Log;
    pub const Pass = *Log;

    glyphs: iface.Glyphs = .{},

    pub fn prepare(n: *Null, queue: Queue, draw: *const DrawList, glyphs: iface.Glyphs, viewport: [2]f32, scale: f32) void {
        _ = viewport;
        _ = scale;
        queue.push(.{ .write = .{ .buffer = .quads, .bytes = draw.quadBytes().len } });
        queue.push(.{ .write = .{ .buffer = .glyphs, .bytes = std.mem.sliceAsBytes(glyphs.quads).len } });
        queue.push(.{ .write = .{ .buffer = .globals, .bytes = @sizeOf(Globals) } });
        n.glyphs = glyphs;
    }

    fn bind(pass: Pass, material: types.Material, texture: types.Texture, instances: Buffer) void {
        pass.push(.{ .pipeline = material });
        pass.push(.{ .group = .{ .index = 0, .texture = .white } });
        pass.push(.{ .group = .{ .index = 1, .texture = texture } });
        pass.push(.{ .vertex_buffer = instances });
    }

    pub fn drawBatch(_: *const Null, pass: Pass, batch: draw_list.Batch) void {
        bind(pass, batch.material, batch.texture, .quads);
        pass.push(.{ .draw = .{ .vertices = 4, .instances = batch.count, .first_instance = batch.first } });
    }

    pub fn drawText(n: *const Null, pass: Pass, run: u32) void {
        bind(pass, .solid, n.glyphs.texture, .glyphs);
        pass.push(.{ .draw = .{ .vertices = 4, .instances = n.glyphs.count[run], .first_instance = n.glyphs.first[run] } });
    }
};

comptime {
    iface.check(Null);
}

const testing = std.testing;
const conformance = @import("conformance.zig");

test "null: one upload per buffer, one draw per command, state rebound every time" {
    var st: conformance.Storage = .{};
    const scene = &conformance.scenes[2]; // text: batch | text | text | batch
    try testing.expectEqualStrings("text", scene.name);
    st.load(scene);
    var calls: [64]Call = undefined;
    var log: Log = .{ .calls = &calls };
    var gfx: Null = .{};
    const atlas: types.Texture = @fromBackingInt(1);
    var glyphs = st.glyphs();
    glyphs.texture = atlas;
    gfx.prepare(&log, &st.draw, glyphs, scene.viewport, 1);
    try testing.expectEqualSlices(Call, &.{
        .{ .write = .{ .buffer = .quads, .bytes = 2 * @sizeOf(Quad) } },
        .{ .write = .{ .buffer = .glyphs, .bytes = 8 * @sizeOf(Quad) } },
        .{ .write = .{ .buffer = .globals, .bytes = @sizeOf(Globals) } },
    }, log.recorded());

    log.len = 0;
    iface.render(&gfx, &log, &st.draw);
    try testing.expectEqual(4 * 5, log.len);
    try testing.expectEqualSlices(Call, &.{
        .{ .pipeline = .solid },
        .{ .group = .{ .index = 0, .texture = .white } },
        .{ .group = .{ .index = 1, .texture = atlas } },
        .{ .vertex_buffer = .glyphs },
        .{ .draw = .{ .vertices = 4, .instances = 3, .first_instance = 0 } },
    }, log.recorded()[5..10]);
}

test "null: full state is rebound after the host's custom draw" {
    var st: conformance.Storage = .{};
    const scene = &conformance.scenes[3];
    try testing.expectEqualStrings("custom", scene.name);
    st.load(scene);
    var calls: [64]Call = undefined;
    var log: Log = .{ .calls = &calls };
    var gfx: Null = .{};
    gfx.prepare(&log, &st.draw, st.glyphs(), scene.viewport, 1);
    // The host's loop: its own draw at each stop, marked in the log.
    var i = iface.drawUntilCustom(&gfx, &log, &st.draw, 0);
    while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, &log, &st.draw, i + 1)) log.push(.host);
    try testing.expectEqual(3 + 5 + 1 + 5, log.len);
    try testing.expectEqual(Call.host, log.recorded()[8]);
    try testing.expect(rebindsAfterHost(log.recorded()));
}

test "null: rebindsAfterHost rejects a draw that trusts state from before the host's draw" {
    const draw: Call = .{ .draw = .{ .vertices = 4, .instances = 1, .first_instance = 0 } };
    const full = [_]Call{ .{ .pipeline = .solid }, .{ .group = .{ .index = 0, .texture = .white } }, .{ .group = .{ .index = 1, .texture = .white } }, .{ .vertex_buffer = .quads } };
    try testing.expect(rebindsAfterHost(&(full ++ .{ draw, draw, .host } ++ full ++ .{draw})));
    // Only the vertex buffer rebound after the host: a caching back end.
    try testing.expect(!rebindsAfterHost(&(full ++ .{ draw, .host, Call{ .vertex_buffer = .quads }, draw })));
    // Group 1 missing.
    try testing.expect(!rebindsAfterHost(&(.{.host} ++ full[0..2].* ++ .{ full[3], draw })));
}

test "null: a short log keeps counting and never writes past its end" {
    var calls: [2]Call = undefined;
    var log: Log = .{ .calls = &calls };
    for (0..5) |_| log.push(.{ .vertex_buffer = .quads });
    try testing.expectEqual(5, log.len);
    try testing.expectEqual(2, log.recorded().len);
}
