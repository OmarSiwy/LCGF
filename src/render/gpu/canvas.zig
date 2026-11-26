//! The canvas batch on a GPU, written once against `lcgf_render.gpu`: every GPU back end's
//! `drawCanvas` (src/render/iface.zig) is this type, so vk, metal, d3d12, gles, wgpu and web
//! draw canvases with the same pipeline, the same uploads and the same shader
//! (src/render/shaders/canvas.wgsl; sw's twin is src/render/sw/canvas.zig).
//!
//!     var cv: Canvas(gpu, source) = undefined;
//!     try cv.init(dev, target, .{ .rows = 100_000, .verts = 20_000 });
//!     cv.prepare(&up, list, slot, scale, size, atlas);  // with the renderer's `prepare`
//!     cv.draw(&pass, k);                                 // the renderer's `drawCanvas(pass, k)`
//!     shapes.clearDirty();                               // the host, after every `prepare`
//!
//! Rows live on the GPU between frames. `prepare` writes only what changed: the rows of
//! `Instances.dirty` (everything when `dirty_all`), polygon vertices appended since the last
//! upload, and per draw the camera, palette and overrides (about 100 bytes and 16 a layer), so
//! a pan writes no rows. It never clears the dirty list (`Frame.canvas` takes the instances
//! `const`): the host calls `clearDirty` once every renderer that draws them has prepared.
//!
//! Two ways to write, chosen by the memory the back end gives (`gpu.Buffer.mapped`):
//!   - Queue-ordered writes (gles, wgpu, web): one copy of everything, written with
//!     `Upload.writeBuffer`, which the API orders before the frame's draws.
//!   - Mapped memory with frames in flight (vk, d3d12, metal): `frames` copies, one per ring slot
//!     of the renderer, written with memcpy. A slot the GPU may still read is never written;
//!     the rows a frame dirties are queued for every other slot, which writes them when its turn
//!     comes, so each slot catches up without a full upload.
//!
//! Up to `max_batches` distinct `Instances` per frame (a schematic and its overlay), up to
//! `max_draws` canvas commands per frame; past them a canvas draws nothing. A batch's rows
//! sit at a fixed place in the row buffers while it keeps being drawn every frame; one missing
//! for a frame (its dirty list may have been cleared unseen) or one that no longer fits is
//! uploaded whole.

const std = @import("std");
const canvas = @import("../../draw/canvas.zig");
const shader = @import("../shaders/canvas.zig");
const draw_list = @import("../../draw/draw_list.zig");
const desc = @import("desc.zig");
const Instances = canvas.Instances;
const Range = canvas.Range;

pub const max_batches = 4;
pub const max_draws = 8;
pub const max_frames = 3;
/// Rows a slot remembers to catch up on, per batch; past it, the batch is uploaded whole.
const pending_cap = 32;

pub const Capacity = struct {
    /// Instance rows across all batches of a frame, and polygon vertices.
    rows: u32,
    verts: u32 = 0,
    /// Copies (ring slots); more than 1 needs mapped memory.
    frames: u32 = 1,
};

/// What one slot still owes a batch: rows dirtied while another slot was being written.
const Owed = struct {
    all: bool = true,
    len: u32 = 0,
    ranges: [pending_cap]Range = undefined,
    /// Vertices this slot holds, from the start of the batch's list.
    verts: u32 = 0,

    fn add(o: *Owed, r: Range) void {
        if (o.all or r.count == 0) return;
        if (o.len == pending_cap) {
            o.all = true;
            return;
        }
        o.ranges[o.len] = r;
        o.len += 1;
    }
};

const Batch = struct {
    shapes: ?*const Instances = null,
    /// Its place in the row and vertex buffers, and what it was given.
    row_base: u32 = 0,
    rows: u32 = 0,
    vert_base: u32 = 0,
    verts: u32 = 0,
    /// The `prepare` it was last drawn in.
    seen: u64 = 0,
};

pub fn Canvas(comptime gpu: type, comptime source: type) type {
    return struct {
        const C = @This();
        pub const Shader = gpu.Shader(source);
        /// GL ES: vertices in a texture (shader.wgsl_es).
        const es = for (Shader.module.bindings) |b| {
            if (std.mem.eql(u8, b.name, "verts")) break b.kind == .texture;
        } else @compileError("canvas shader without `verts`");

        const Slot = struct {
            pos: gpu.Buffer,
            look: gpu.Buffer,
            verts: if (es) gpu.Texture else gpu.Buffer,
            uniforms: [max_draws]gpu.Buffer,
            groups: [max_draws]gpu.BindGroup(Shader, 0),
            owed: [max_batches]Owed = @splat(.{}),
        };
        const Draw = struct { k: u32, batch: u32 };

        arena: gpu.Arena,
        pipeline: gpu.RenderPipeline(Shader),
        cap: Capacity,
        slots: [max_frames]Slot,
        row: gpu.Buffer,
        row_written: bool = false,
        atlas: [4]struct { key: u64, group: gpu.BindGroup(Shader, 1) } = undefined,
        atlas_len: u32 = 0,
        batches: [max_batches]Batch = @splat(.{}),
        next_row: u32 = 0,
        next_vert: u32 = 0,
        frame: u64 = 0,
        // The last `prepare`'s slot, draws, target and atlas.
        slot: u32 = 0,
        draws: [max_draws]Draw = undefined,
        draw_len: u32 = 0,
        atlas_group: u32 = 0,
        size: [2]u32 = .{ 0, 0 },
        scale: f32 = 1,
        /// Bytes the last `prepare` wrote: rows, vertices and uniforms.
        uploaded: usize = 0,

        /// Fills `cv` in place (its arena must not move). `target` is the pass's format and
        /// sample count.
        pub fn init(cv: *C, dev: gpu.Device, target: desc.Target, cap: Capacity) !void {
            std.debug.assert(cap.frames >= 1 and cap.frames <= max_frames and cap.rows > 0);
            const rows: u64 = cap.rows;
            const verts: u64 = @max(cap.verts, 1) + if (es) max_batches * shader.verts_width / 2 else 0;
            const uni = std.mem.alignForward(u64, @sizeOf(shader.Uniforms), 256);
            const per_slot = 32 * rows + 8 * verts + max_draws * uni;
            cv.* = .{ .arena = undefined, .pipeline = undefined, .cap = cap, .slots = undefined, .row = undefined };
            cv.arena = try .init(dev, .{ .bytes = cap.frames * (per_slot + 64 * 1024) + 4 * rows + 64 * 1024, .memory = .host, .bind_groups = max_frames * max_draws + cv.atlas.len });
            errdefer cv.arena.deinit();
            cv.pipeline = try dev.createRenderPipeline(Shader, .{
                .vertex = .{ .buffers = &.{
                    .{ .array_stride = 16, .step_mode = .instance, .attributes = &.{.{ .format = .sint32x4, .offset = 0, .shader_location = 0 }} },
                    .{ .array_stride = 16, .step_mode = .instance, .attributes = &.{.{ .format = .uint32x4, .offset = 0, .shader_location = 1 }} },
                    .{ .array_stride = 4, .step_mode = .instance, .attributes = &.{.{ .format = .uint32, .offset = 0, .shader_location = 2 }} },
                } },
                .primitive = .{ .topology = .triangle_strip },
                .fragment = .{ .targets = &.{.{ .format = target.format, .blend = .premultiplied }} },
                .multisample = .{ .count = target.samples },
            });
            const vb: desc.BufferUsage = .{ .vertex = true, .copy_dst = true };
            cv.row = try dev.createBuffer(&cv.arena, .{ .size = 4 * rows, .usage = vb });
            for (cv.slots[0..cap.frames]) |*s| {
                s.* = .{ .pos = undefined, .look = undefined, .verts = undefined, .uniforms = undefined, .groups = undefined };
                s.pos = try dev.createBuffer(&cv.arena, .{ .size = 16 * rows, .usage = vb });
                s.look = try dev.createBuffer(&cv.arena, .{ .size = 16 * rows, .usage = vb });
                s.verts = if (es)
                    try dev.createTexture(&cv.arena, .{ .size = .{ .width = shader.verts_width, .height = (2 * @as(u32, @intCast(verts)) + shader.verts_width - 1) / shader.verts_width }, .format = .r32_uint, .usage = .{ .texture_binding = true, .copy_dst = true } })
                else
                    try dev.createBuffer(&cv.arena, .{ .size = 8 * verts, .usage = .{ .storage = true, .copy_dst = true } });
                for (&s.uniforms, &s.groups) |*b, *g| {
                    b.* = try dev.createBuffer(&cv.arena, .{ .size = @sizeOf(shader.Uniforms), .usage = .{ .uniform = true, .copy_dst = true } });
                    g.* = try dev.createBindGroup(&cv.arena, cv.pipeline, 0, .{ .u = b.*, .verts = if (es) s.verts.createView() else s.verts });
                }
            }
            if (cv.row.mapped) |m| {
                for (std.mem.bytesAsSlice(u32, m[0 .. 4 * cap.rows]), 0..) |*x, i| x.* = @intCast(i);
                cv.row_written = true;
            }
        }

        pub fn deinit(cv: *C, dev: gpu.Device) void {
            for (cv.slots[0..cv.cap.frames]) |s| {
                for (s.uniforms) |b| dev.destroyBuffer(b);
                if (es) dev.destroyTexture(s.verts) else dev.destroyBuffer(s.verts);
                dev.destroyBuffer(s.look);
                dev.destroyBuffer(s.pos);
            }
            dev.destroyBuffer(cv.row);
            dev.destroyRenderPipeline(cv.pipeline);
            cv.arena.deinit();
        }

        /// Uploads the canvas commands of `list` for ring slot `slot` (0 when `frames` is 1),
        /// before the pass: `up` writes when the memory is not mapped. `size` is the target in
        /// physical pixels, `scale` physical pixels per logical one; glyphs sample `atlas`, whose
        /// bind group is kept per `atlas_key` (the renderer's texture handle).
        pub fn prepare(cv: *C, dev: gpu.Device, up: ?*gpu.Upload, list: *const draw_list.DrawList, slot: u32, scale: f32, size: [2]u32, atlas: gpu.TextureView, atlas_key: u64) void {
            cv.frame += 1;
            cv.slot = slot % cv.cap.frames;
            cv.size = size;
            cv.scale = scale;
            cv.draw_len = 0;
            cv.uploaded = 0;
            if (!cv.row_written) {
                var iota: [1024]u32 = undefined;
                var at: u32 = 0;
                while (at < cv.cap.rows) : (at += iota.len) {
                    const n = @min(iota.len, cv.cap.rows - at);
                    for (iota[0..n], 0..) |*x, i| x.* = at + @as(u32, @intCast(i));
                    cv.write(up, cv.row, 4 * @as(u64, at), std.mem.sliceAsBytes(iota[0..n]));
                }
                cv.row_written = true;
            }
            cv.atlas_group = cv.atlasGroup(dev, atlas, atlas_key) orelse return;
            const s = &cv.slots[cv.slot];
            var uniforms: shader.Uniforms = undefined;
            for (0..list.cmd_len) |i| {
                const k = switch (list.command(@intCast(i))) {
                    .canvas => |k| k,
                    else => continue,
                };
                if (cv.draw_len == max_draws) break;
                const shapes = list.canvases[k].instances;
                const b = cv.batchOf(shapes) orelse continue;
                if (cv.batches[b].seen != cv.frame) cv.uploadBatch(up, b);
                cv.batches[b].seen = cv.frame;
                const j = cv.draw_len;
                shader.fill(&uniforms, list, k, scale, .{ @floatFromInt(size[0]), @floatFromInt(size[1]) }, cv.batches[b].row_base, cv.batches[b].vert_base);
                cv.write(up, s.uniforms[j], 0, std.mem.asBytes(&uniforms)[0..shader.Uniforms.headBytes(uniforms.layers)]);
                const marks = @offsetOf(shader.Uniforms, "marks");
                cv.write(up, s.uniforms[j], marks, std.mem.sliceAsBytes(uniforms.marks[0..uniforms.overrides]));
                cv.draws[j] = .{ .k = k, .batch = b };
                cv.draw_len += 1;
            }
        }

        /// Draws canvas command `k` of the last `prepare` into `pass`: one instanced draw per
        /// range, scissored to the node. Sets every piece of state it uses.
        pub fn draw(cv: *const C, pass: *gpu.RenderPass, list: *const draw_list.DrawList, k: u32) void {
            const j = for (cv.draws[0..cv.draw_len], 0..) |d, i| {
                if (d.k == k) break i;
            } else return;
            const node = list.customs[k];
            const sc = desc.scissor(node.rect, node.clip, cv.scale, cv.size[0], cv.size[1]);
            if (sc.width == 0 or sc.height == 0) return;
            const s = &cv.slots[cv.slot];
            const batch = cv.batches[cv.draws[j].batch];
            const shapes = batch.shapes.?;
            pass.setViewport(0, 0, @floatFromInt(cv.size[0]), @floatFromInt(cv.size[1]), 0, 1);
            pass.setScissorRect(sc.x, sc.y, sc.width, sc.height);
            pass.setPipeline(cv.pipeline);
            pass.setBindGroup(0, &s.groups[j]);
            pass.setBindGroup(1, &cv.atlas[cv.atlas_group].group);
            pass.setVertexBuffer(0, s.pos, 0);
            pass.setVertexBuffer(1, s.look, 0);
            pass.setVertexBuffer(2, cv.row, 0);
            const len = @min(shapes.len, batch.rows);
            for (list.canvases[k].ranges) |r| {
                const end = @min(r.first +| r.count, len);
                const first = @min(r.first, end);
                if (end > first) pass.draw(4, end - first, 0, batch.row_base + first);
            }
        }

        fn write(cv: *C, up: ?*gpu.Upload, b: gpu.Buffer, offset: u64, bytes: []const u8) void {
            if (bytes.len == 0) return;
            cv.uploaded += bytes.len;
            if (b.mapped) |m| {
                @memcpy(m[@intCast(offset)..][0..bytes.len], bytes);
            } else up.?.writeBuffer(b, offset, bytes);
        }

        fn atlasGroup(cv: *C, dev: gpu.Device, atlas: gpu.TextureView, key: u64) ?u32 {
            for (cv.atlas[0..cv.atlas_len], 0..) |a, i| if (a.key == key) return @intCast(i);
            // ponytail: four atlases kept; a fifth takes the last place, its old group leaked in
            // the arena until it runs out (an atlas changes rarely).
            const i = @min(cv.atlas_len, cv.atlas.len - 1);
            const group = dev.createBindGroup(&cv.arena, cv.pipeline, 1, .{ .atlas = atlas }) catch return null;
            cv.atlas[i] = .{ .key = key, .group = group };
            cv.atlas_len = @intCast(i + 1);
            return @intCast(i);
        }

        /// The batch `shapes` is drawn from, placed in the buffers if it is new.
        fn batchOf(cv: *C, shapes: *const Instances) ?u32 {
            for (&cv.batches, 0..) |*b, i| {
                if (b.shapes != shapes) continue;
                if (b.rows == shapes.cap and b.verts == shapes.vert_cap) return @intCast(i);
                b.shapes = null; // re-initialised in place: placed again
            }
            if (shapes.cap > cv.cap.rows or shapes.vert_cap > @max(cv.cap.verts, 1)) return null;
            // A free entry, or else one not drawn this frame.
            var pick: ?usize = null;
            for (&cv.batches, 0..) |*b, i| if (b.shapes == null or b.seen != cv.frame) {
                pick = i;
                if (b.shapes == null) break;
            };
            const i = pick orelse return null;
            if (cv.next_row + shapes.cap > cv.cap.rows or vertAt(cv.next_vert) + shapes.vert_cap > cv.vertCap()) {
                // Out of room: start the buffers over with the batches drawn this frame.
                cv.next_row = 0;
                cv.next_vert = 0;
                for (&cv.batches) |*b| if (b.shapes != null and b.seen == cv.frame) {
                    cv.place(b, b.shapes.?);
                } else {
                    b.shapes = null;
                };
            }
            cv.place(&cv.batches[i], shapes);
            return @intCast(i);
        }

        /// Where a batch's vertices start: on GL ES at a texture row, so a row is one batch's.
        fn vertAt(v: u32) u32 {
            return if (es) std.mem.alignForward(u32, v, shader.verts_width / 2) else v;
        }

        fn vertCap(cv: *const C) u32 {
            return @max(cv.cap.verts, 1) + if (es) max_batches * shader.verts_width / 2 else 0;
        }

        fn place(cv: *C, b: *Batch, shapes: *const Instances) void {
            const vb = vertAt(cv.next_vert);
            b.* = .{ .shapes = shapes, .row_base = cv.next_row, .rows = shapes.cap, .vert_base = vb, .verts = shapes.vert_cap, .seen = 0 };
            cv.next_row += shapes.cap;
            cv.next_vert = vb + shapes.vert_cap;
            const at = (b - &cv.batches[0]);
            for (cv.slots[0..cv.cap.frames]) |*s| s.owed[at] = .{};
        }

        /// Writes batch `b` into this frame's slot: what the slot owes it and what is dirty now;
        /// the new dirt is owed to every other slot.
        fn uploadBatch(cv: *C, up: ?*gpu.Upload, b: u32) void {
            const batch = &cv.batches[b];
            const shapes = batch.shapes.?;
            // Not drawn last frame: its dirty list may have been cleared without us.
            const missed = batch.seen + 1 != cv.frame;
            const s = &cv.slots[cv.slot];
            const owed = &s.owed[b];
            const len = @min(shapes.len, batch.rows);
            const all = owed.all or shapes.dirty_all or missed;
            if (all) {
                cv.writeRows(up, s, batch, .{ .first = 0, .count = len });
            } else {
                for (owed.ranges[0..owed.len]) |r| cv.writeRows(up, s, batch, r);
                for (shapes.dirty[0..shapes.dirty_len]) |r| cv.writeRows(up, s, batch, r);
            }
            const vlen = @min(shapes.vert_len, batch.verts);
            const from = if (all or owed.verts > vlen) 0 else owed.verts;
            if (from < vlen) cv.writeVerts(up, s, batch, shapes, from, vlen);
            owed.* = .{ .all = false, .verts = vlen };
            for (cv.slots[0..cv.cap.frames], 0..) |*o, i| {
                if (i == cv.slot) continue;
                const other = &o.owed[b];
                if (shapes.dirty_all or missed) other.all = true;
                for (shapes.dirty[0..shapes.dirty_len]) |r| other.add(r);
            }
        }

        fn writeRows(cv: *C, up: ?*gpu.Upload, s: *const Slot, batch: *const Batch, r: Range) void {
            const shapes = batch.shapes.?;
            const end = @min(r.first +| r.count, @min(shapes.len, batch.rows));
            const first = @min(r.first, end);
            const at = 16 * @as(u64, batch.row_base + first);
            cv.write(up, s.pos, at, std.mem.sliceAsBytes(shapes.c.pos[first..end]));
            cv.write(up, s.look, at, std.mem.sliceAsBytes(shapes.c.look[first..end]));
        }

        fn writeVerts(cv: *C, up: ?*gpu.Upload, s: *const Slot, batch: *const Batch, shapes: *const Instances, from: u32, to: u32) void {
            if (es) {
                // Whole texture rows, from the one holding vertex `from` to the one holding
                // `to - 1`, each through a row of scratch (a batch starts on a row: `vertAt`).
                const w = shader.verts_width;
                const texels: []const u32 = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(shapes.verts[0..to]));
                const first_row = batch.vert_base * 2 / w;
                var row = 2 * from / w;
                var scratch: [w]u32 = undefined;
                while (row * w < 2 * to) : (row += 1) {
                    const hi = @min((row + 1) * w, 2 * to);
                    @memset(&scratch, 0);
                    @memcpy(scratch[0 .. hi - row * w], texels[row * w .. hi]);
                    up.?.writeTextureRows(s.verts, first_row + row, 1, std.mem.sliceAsBytes(&scratch)) catch return;
                    cv.uploaded += w * 4;
                }
            } else cv.write(up, s.verts, 8 * @as(u64, batch.vert_base + from), std.mem.sliceAsBytes(shapes.verts[from..to]));
        }
    };
}
