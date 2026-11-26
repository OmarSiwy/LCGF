//! What every example's host does, shared by the window runner (window.zig) and the smoke
//! tests: draw a frame in software, letting the application draw under the UI and into its
//! custom rects (src/shell/iface.zig, "embedding": a host that renders itself skips `present`).
//!
//! An application is a type with `pub fn build(*App, *Frame, *const Events) void` (the shells'
//! contract), and optionally
//!
//!   pub fn under(*App, *sw.Framebuffer) void                      drawn before the UI
//!   pub fn drawCustom(*App, *sw.Framebuffer, *const CustomDraw) void   at each custom command
//!   pub const images: fn (*App) []const sw.Image                  textures 0.. for the UI
//!
//! This file is the root of the `host` module (build.zig), shared by every example.

const std = @import("std");
const lcgf = @import("lcgf");
const context = lcgf.context;
const sw = lcgf.render_sw;
const Quad = lcgf.draw_list.Quad;
const Replay = lcgf.input.Replay;
const Input = lcgf.input.Input;
const Color = lcgf.types.Color;
const Mono = lcgf.protocol.Mono;
const mem = lcgf.mem;
const DrawList = lcgf.draw_list.DrawList;
const TextRun = lcgf.draw_list.TextRun;
const atlas = @import("font.zig");
pub const Events = lcgf.shell_iface.Events;
pub const CustomDraw = lcgf.draw_list.CustomDraw;

/// Caller-owned rows for the glyph quads of one frame.
pub const Glyphs = struct { quads: []Quad, first: []u32, count: []u32 };

/// Draws the complete `out` into `fb`, even if a previous frame was identical. Only text
/// runs actually submitted by draw commands are expanded. Use Incremental explicitly when
/// the caller retains and exclusively owns both the framebuffer and glyph storage.
pub fn draw(app: anytype, gfx: *sw.Software, fb: *sw.Framebuffer, g: Glyphs, out: *const context.Output, scale: f32, background: Color) void {
    const n = expandGlyphs(g, out.draw);
    prepare(app, gfx, g, out.draw, scale, n);
    renderPrepared(app, gfx, fb, out.draw, background, fb.all());
}

fn expandGlyphs(g: Glyphs, d: *const DrawList) u32 {
    return (Mono{}).quadsForCommands(atlas, d, g.quads, .{ .first = g.first, .count = g.count }) catch unreachable;
}

fn prepare(app: anytype, gfx: *sw.Software, g: Glyphs, d: *const DrawList, scale: f32, n: u32) void {
    if (@hasDecl(@TypeOf(app.*), "images")) gfx.images = app.images();
    gfx.prepare({}, d, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, scale);
}

fn renderPrepared(app: anytype, gfx: *const sw.Software, fb: *sw.Framebuffer, d: *const DrawList, background: Color, scissor: [4]u32) void {
    const App = @TypeOf(app.*);
    var text = gfx.*;
    text.images = &.{atlas.image};
    fb.fill(scissor, background);
    // Incremental rejects underlays/custom drawing because those hooks have no damage or
    // clipping contract. Such applications arrive here only with the full target scissor.
    if (@hasDecl(App, "under")) app.under(fb);
    const pass: sw.Target = .{ .fb = fb, .scissor = scissor };
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .quads => |batch| gfx.drawBatch(pass, batch),
        .text => |run| text.drawText(pass, run),
        .custom => |row| if (@hasDecl(App, "drawCustom")) app.drawCustom(fb, &d.customs[row]),
        .canvas => |row| if (comptime @hasDecl(sw.Software, "drawCanvas")) gfx.drawCanvas(pass, row),
    };
}

/// Physical pixel boxes (x0, y0, x1, y1) to upload after Incremental.draw. One conservative
/// union avoids overlapping updates, reduces presentation calls, and never blends a pixel
/// twice without clearing it first. An unchanged frame returns len = 0.
pub const Update = struct {
    boxes: [1][4]u32 = .{.{ 0, 0, 0, 0 }},
    len: u32 = 0,
    full: bool = false,
    glyphs_rebuilt: bool = false,

    pub fn pixelCount(update: *const Update) u64 {
        const r = update.boxes[0];
        return @as(u64, r[2] - r[0]) * (r[3] - r[1]);
    }
};

/// Explicit retained software output. The host keeps the framebuffer, Glyphs buffers, and
/// this state alive and unmoved; no allocator, callbacks, timer, or global cache is hidden here.
/// `draw` consumes a complete, unculled DrawList from Frame.end. Call invalidate() after any
/// outside write to framebuffer/glyph memory or whenever an external effect changes pixels.
/// New buffers, dimensions, format, scale, and background invalidate automatically.
///
/// Snapshots contain exact concrete draw inputs, not hashes or tree identities. Ordered
/// primitive streams ignore batch boundaries and storage indices, preserving an unchanged
/// semantic prefix/suffix. Old/new bounds of the changed middle form the repaint region.
/// Identity-transform solid quads and the host's immutable Mono atlas support partial updates;
/// shadows, other features, arbitrary images, underlays, and custom draws conservatively use
/// the full path. This keeps unknown effect bounds and mutable texture bytes out of the cache.
/// Text geometry is cached independently of quad colors, so hover/focus changes reuse glyphs.
///
/// Not `Context.trackDamage`, which the shells use: that hashes nodes and repaints their
/// bounds, and a text run is clipped by its parent, not its node, so Mono glyphs that overflow
/// a text node's rect would stay stale; it also culls the list this host's underlay and custom
/// hooks draw from. Both feed the same upload, `x11.Window.presentPixelsRegions`.
pub const Incremental = struct {
    quads: []Quad,
    runs: []TextRun,
    strings: []u8,
    cmd: DrawList.CmdColumns,
    quad_len: u32 = 0,
    run_len: u32 = 0,
    string_len: usize = 0,
    cmd_len: u32 = 0,
    valid: bool = false,
    glyph_valid: bool = false,
    glyph_len: u32 = 0,
    glyph_addresses: [3]usize = @splat(0),
    glyph_capacities: [3]usize = @splat(0),
    target: usize = 0,
    size: [3]u32 = @splat(0),
    format: sw.Format = .rgba8,
    scale_bits: u32 = 0,
    background_bits: u32 = 0,

    pub fn requiredBytes(limits: context.Limits) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = init(&counter, limits);
        return counter.off;
    }

    pub fn init(carver: *mem.Carver, limits: context.Limits) Incremental {
        return .{
            .quads = carver.slice(Quad, limits.nodes + 1),
            .runs = carver.slice(TextRun, limits.texts + 1),
            .strings = carver.slice(u8, limits.strings),
            .cmd = carver.columns(DrawList.CmdColumns, limits.nodes + limits.texts + limits.customs + 4),
        };
    }

    pub fn invalidate(self: *Incremental) void {
        self.valid = false;
        self.glyph_valid = false;
    }

    pub fn draw(self: *Incremental, app: anytype, gfx: *sw.Software, fb: *sw.Framebuffer, g: Glyphs, out: *const context.Output, scale: f32, background: Color) Update {
        const d = out.draw;
        const fits = d.quad_len <= self.quads.len and d.run_len <= self.runs.len and
            d.strings.len <= self.strings.len and d.cmd_len <= self.cmd.kind.len;
        const same_text = self.valid and self.glyph_valid and fits and
            self.run_len == d.run_len and self.string_len == d.strings.len and
            std.mem.eql(u8, std.mem.sliceAsBytes(self.runs[0..self.run_len]), std.mem.sliceAsBytes(d.runs[0..d.run_len])) and
            std.mem.eql(u8, self.strings[0..self.string_len], d.strings) and self.sameTextCommands(d);
        const addresses = [3]usize{ @intFromPtr(g.quads.ptr), @intFromPtr(g.first.ptr), @intFromPtr(g.count.ptr) };
        const capacities = [3]usize{ g.quads.len, g.first.len, g.count.len };
        const same_storage = std.mem.eql(usize, &self.glyph_addresses, &addresses) and
            std.mem.eql(usize, &self.glyph_capacities, &capacities);
        const same_glyphs = same_text and same_storage;
        const eligible = out.status.ok() and supportsIncremental(@TypeOf(app.*), gfx, d);
        const same_target = self.target == @intFromPtr(fb.pixels.ptr) and
            std.mem.eql(u32, &self.size, &.{ fb.width, fb.height, fb.stride }) and
            self.format == fb.format and self.scale_bits == @as(u32, @bitCast(scale)) and
            self.background_bits == background.bitsOf();
        // Glyph capacity is shared across submitted runs. A longer earlier run can consume
        // a later unchanged run's rows; a shorter one can reveal them. When either frame
        // can fill the buffer, text changes therefore invalidate pixels beyond that run.
        const limited_text = !same_text and
            (self.glyph_len == (g.quads.len -| 1) or submittedGlyphsMayFill(d, g.quads.len));
        var update: Update = .{};
        update.full = !self.valid or !fits or !eligible or !same_target or !same_storage or limited_text;
        if (update.full) {
            update.boxes[0] = fb.all();
            update.len = @intFromBool(fb.width != 0 and fb.height != 0);
        } else {
            const before: DrawView = .{
                .quads = self.quads[0..self.quad_len],
                .runs = self.runs[0..self.run_len],
                .strings = self.strings[0..self.string_len],
                .cmd = self.cmd,
                .cmd_len = self.cmd_len,
            };
            const now: DrawView = .{
                .quads = d.quads[0..d.quad_len],
                .runs = d.runs[0..d.run_len],
                .strings = d.strings,
                .cmd = d.cmd,
                .cmd_len = d.cmd_len,
            };
            const dirty = changedBounds(before, now);
            update.boxes[0] = dirty.pixels(fb, scale);
            const r = update.boxes[0];
            update.len = @intFromBool(r[0] < r[2] and r[1] < r[3]);
        }

        if (update.len != 0) {
            if (!same_glyphs) {
                self.glyph_len = expandGlyphs(g, d);
                update.glyphs_rebuilt = true;
            }
            prepare(app, gfx, g, d, scale, self.glyph_len);
            renderPrepared(app, gfx, fb, d, background, update.boxes[0]);
            self.glyph_valid = fits;
            self.glyph_addresses = addresses;
            self.glyph_capacities = capacities;
        } else if (!same_glyphs) {
            // An offscreen text change can leave the target untouched. Delay expansion
            // until a frame actually paints, without claiming the old glyphs are current.
            self.glyph_valid = false;
        }
        if (fits) self.capture(d);
        self.valid = fits and eligible;
        self.target = @intFromPtr(fb.pixels.ptr);
        self.size = .{ fb.width, fb.height, fb.stride };
        self.format = fb.format;
        self.scale_bits = @bitCast(scale);
        self.background_bits = background.bitsOf();
        return update;
    }

    /// Quad batching does not affect Mono expansion. Text commands do: their ordered run
    /// indices determine first/count spans and which unique runs consume glyph capacity.
    fn sameTextCommands(self: *const Incremental, d: *const DrawList) bool {
        var a: u32 = 0;
        var b: u32 = 0;
        while (true) {
            while (a < self.cmd_len and self.cmd.kind[a] != @backingInt(DrawList.Kind.text)) : (a += 1) {}
            while (b < d.cmd_len and d.cmd.kind[b] != @backingInt(DrawList.Kind.text)) : (b += 1) {}
            if (a == self.cmd_len or b == d.cmd_len) return a == self.cmd_len and b == d.cmd_len;
            if (self.cmd.first[a] != d.cmd.first[b]) return false;
            a += 1;
            b += 1;
        }
    }

    fn capture(self: *Incremental, d: *const DrawList) void {
        @memcpy(self.quads[0..d.quad_len], d.quads[0..d.quad_len]);
        @memcpy(self.runs[0..d.run_len], d.runs[0..d.run_len]);
        @memcpy(self.strings[0..d.strings.len], d.strings);
        inline for (.{ "kind", "first", "count", "key" }) |name|
            @memcpy(@field(self.cmd, name)[0..d.cmd_len], @field(d.cmd, name)[0..d.cmd_len]);
        self.quad_len = d.quad_len;
        self.run_len = d.run_len;
        self.string_len = d.strings.len;
        self.cmd_len = d.cmd_len;
    }
};

/// Read-only columns of one complete frame. Primitive indices locate data; they are not
/// identities. Matching the ordered semantic stream lets batch splits and moved rows reuse
/// pixels without hiding a painter-order change.
const DrawView = struct {
    quads: []const Quad,
    runs: []const TextRun,
    strings: []const u8,
    cmd: DrawList.CmdColumns,
    cmd_len: u32,

    fn primitiveCount(view: DrawView) u64 {
        var count: u64 = 0;
        for (0..view.cmd_len) |i|
            count += if (view.cmd.kind[i] == @backingInt(DrawList.Kind.quads)) view.cmd.count[i] else @as(u32, 1);
        return count;
    }
};

const Primitive = struct { kind: DrawList.Kind, row: u32, key: u32 };

/// Forward or reverse cursor over virtual primitives, with no expanded command buffer.
/// In reverse, command is the exclusive upper command index. The traversal direction is
/// selected once at compile time; empty batches are skipped without inventing primitives.
const Cursor = struct {
    command: u32 = 0,
    offset: u32 = 0,

    fn next(cursor: *Cursor, view: DrawView, comptime reverse: bool) ?Primitive {
        while (if (reverse) cursor.command != 0 else cursor.command < view.cmd_len) {
            const i = if (reverse) cursor.command - 1 else cursor.command;
            const kind: DrawList.Kind = @fromBackingInt(view.cmd.kind[i]);
            const count = if (kind == .quads) view.cmd.count[i] else @as(u32, 1);
            if (cursor.offset < count) {
                const offset = if (reverse) count - 1 - cursor.offset else cursor.offset;
                cursor.offset += 1;
                return .{
                    .kind = kind,
                    .row = view.cmd.first[i] + if (kind == .quads) offset else @as(u32, 0),
                    .key = view.cmd.key[i],
                };
            }
            if (reverse) cursor.command -= 1 else cursor.command += 1;
            cursor.offset = 0;
        }
        return null;
    }
};

fn samePrimitive(a: DrawView, left: Primitive, b: DrawView, right: Primitive) bool {
    if (left.kind != right.kind) return false;
    return switch (left.kind) {
        .quads => left.key == right.key and sameRow(Quad, &a.quads[left.row], &b.quads[right.row]),
        .text => blk: {
            var first = a.runs[left.row];
            var second = b.runs[right.row];
            const first_start = first.start;
            const second_start = second.start;
            // Byte offsets only locate storage. All geometry/style/count fields and the
            // referenced bytes must still agree before an index change is considered equal.
            first.start = 0;
            second.start = 0;
            break :blk sameRow(TextRun, &first, &second) and
                std.mem.eql(u8, a.strings[first_start..][0..first.bytes], b.strings[second_start..][0..second.bytes]);
        },
        .custom, .canvas => unreachable, // supportsIncremental rejects custom commands.
    };
}

fn addPrimitiveBounds(bounds: *Bounds, view: DrawView, primitive: Primitive) void {
    switch (primitive.kind) {
        .quads => {
            const q = view.quads[primitive.row];
            bounds.add(q.rect, q.clip, true);
        },
        .text => {
            const r = &view.runs[primitive.row];
            bounds.add(textBounds(r), r.clip, true);
        },
        .custom, .canvas => unreachable,
    }
}

/// Equal prefixes and suffixes keep their painter order. Only the unmatched middle can
/// change pixels, so union its old/new bounds and replay all current commands through that
/// region. The suffix never crosses the matched prefix, including empty/identical streams.
/// Each primitive is visited a bounded number of times; all scratch is a few scalar cursors.
fn changedBounds(before: DrawView, now: DrawView) Bounds {
    const old_count = before.primitiveCount();
    const new_count = now.primitiveCount();
    const common = @min(old_count, new_count);
    var old_front: Cursor = .{};
    var new_front: Cursor = .{};
    var prefix: u64 = 0;
    while (prefix < common) : (prefix += 1) {
        const saved_old = old_front;
        const saved_new = new_front;
        if (!samePrimitive(before, old_front.next(before, false).?, now, new_front.next(now, false).?)) {
            old_front = saved_old;
            new_front = saved_new;
            break;
        }
    }
    var old_back: Cursor = .{ .command = before.cmd_len };
    var new_back: Cursor = .{ .command = now.cmd_len };
    var suffix: u64 = 0;
    while (suffix < common - prefix) : (suffix += 1)
        if (!samePrimitive(before, old_back.next(before, true).?, now, new_back.next(now, true).?)) break;
    var dirty: Bounds = .{};
    var old_middle = old_count - prefix - suffix;
    var new_middle = new_count - prefix - suffix;
    while (old_middle != 0) : (old_middle -= 1)
        addPrimitiveBounds(&dirty, before, old_front.next(before, false).?);
    while (new_middle != 0) : (new_middle -= 1)
        addPrimitiveBounds(&dirty, now, new_front.next(now, false).?);
    return dirty;
}

/// Conservative current-frame capacity check. Repeated text commands can count a run more
/// than once; that only causes an earlier full fallback, without another visited-run buffer.
fn submittedGlyphsMayFill(d: *const DrawList, capacity: usize) bool {
    var remaining = capacity -| 1; // Mono reserves the last output row for quiet overflow.
    for (0..d.cmd_len) |i| {
        if (d.cmd.kind[i] != @backingInt(DrawList.Kind.text)) continue;
        const bytes = d.runs[d.cmd.first[i]].bytes;
        if (bytes >= remaining) return true;
        remaining -= bytes;
    }
    return false;
}

/// Exact bit comparisons vectorize independent words and distinguish signed zero/NaN
/// payloads. Quad and TextRun are padding-free extern rows with explicit size tests.
inline fn sameRow(comptime T: type, a: *const T, b: *const T) bool {
    comptime {
        var offset: usize = 0;
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |name, Field| {
            if (@offsetOf(T, name) != offset) @compileError("draw snapshots require padding-free rows");
            offset += @sizeOf(Field);
        }
        if (offset != @sizeOf(T) or offset % @sizeOf(u32) != 0)
            @compileError("draw snapshots require padding-free u32 words");
    }
    const count = @sizeOf(T) / @sizeOf(u32);
    const Words = @Vector(count, u32);
    const left: *align(1) const [count]u32 = @ptrCast(std.mem.asBytes(a));
    const right: *align(1) const [count]u32 = @ptrCast(std.mem.asBytes(b));
    return @reduce(.And, @as(Words, left.*) == @as(Words, right.*));
}

fn supportsIncremental(comptime App: type, gfx: *const sw.Software, d: *const DrawList) bool {
    if (@hasDecl(App, "under") or @hasDecl(App, "drawCustom") or @hasDecl(App, "images")) return false;
    if (d.custom_len != 0 or gfx.images.len != 1) return false;
    const image = gfx.images[0];
    if (image.pixels.ptr != sw.Image.white.pixels.ptr or image.width != 1 or image.height != 1 or image.alpha8.len != 0) return false;
    for (d.cmd.kind[0..d.cmd_len]) |kind| if (kind == @backingInt(DrawList.Kind.custom)) return false;
    var eligible = true;
    for (d.quads[0..d.quad_len]) |q| {
        eligible = eligible and @as(u32, @bitCast(q.params[0])) == 0 and
            std.mem.eql(f32, &q.xform, &.{ 1, 0, 0, 1, 0, 0 }) and finite4(q.rect) and finite4(q.clip);
    }
    for (d.runs[0..d.run_len]) |r|
        eligible = eligible and finite4(r.rect) and finite4(r.clip) and r.px >= 0 and std.math.isFinite(r.px);
    return eligible;
}

inline fn finite4(values: [4]f32) bool {
    return @reduce(.And, @abs(@as(@Vector(4, f32), values)) < @as(@Vector(4, f32), @splat(std.math.inf(f32))));
}

/// The actual Mono glyph extent can exceed a fixed text node's nominal height. Account
/// for generated line rows, then clip; damaging only TextRun.rect would leave stale glyphs.
fn textBounds(r: *const TextRun) [4]f32 {
    const adv = @max(r.px * @as(f32, 0.6), 1e-6);
    const line = r.px * @as(f32, 1.25);
    const per_line: u32 = @intFromFloat(@min(@max(@floor((r.rect[2] - r.rect[0]) / adv + 0.5), 1), 1e6));
    if (r.bytes == 0) return .{ r.rect[0], r.rect[1], r.rect[0], r.rect[1] };
    const col: f32 = @floatFromInt(@min(r.bytes, per_line) - 1);
    const row: f32 = @floatFromInt((r.bytes - 1) / per_line);
    // Preserve appendRun's association at the extreme cell, including large coordinates.
    return .{ r.rect[0], r.rect[1], (r.rect[0] + col * adv) + adv, (r.rect[1] + row * line) + line };
}

const Bounds = struct {
    low: @Vector(2, f32) = @splat(std.math.inf(f32)),
    high: @Vector(2, f32) = @splat(-std.math.inf(f32)),

    fn add(bounds: *Bounds, rect: [4]f32, clip: [4]f32, changed: bool) void {
        const lo: @Vector(2, f32) = .{ @max(rect[0], clip[0]), @max(rect[1], clip[1]) };
        const hi: @Vector(2, f32) = .{ @min(rect[2], clip[2]), @min(rect[3], clip[3]) };
        // Hard clips include their upper edge: a zero-width clip through a pixel centre
        // can still paint a column (or a row). Keep those equal bounds until pixel rounding.
        const include: @Vector(2, bool) = @splat(changed and @reduce(.And, lo <= hi));
        bounds.low = @min(bounds.low, @select(f32, include, lo, @as(@Vector(2, f32), @splat(std.math.inf(f32)))));
        bounds.high = @max(bounds.high, @select(f32, include, hi, @as(@Vector(2, f32), @splat(-std.math.inf(f32)))));
    }

    fn pixels(bounds: Bounds, fb: *const sw.Framebuffer, scale: f32) [4]u32 {
        if (!@reduce(.And, bounds.low <= bounds.high)) return .{ 0, 0, 0, 0 };
        const V = @Vector(2, f32);
        const top: V = .{ @floatFromInt(fb.width), @floatFromInt(fb.height) };
        // One extra physical pixel on each side conservatively includes the shader's
        // floor(upper + 1) loop and fractional edge/clip rounding. Clamp before conversion.
        const lo = @min(@max(@floor(bounds.low * @as(V, @splat(scale))) - @as(V, @splat(1)), @as(V, @splat(0))), top);
        const hi = @max(lo, @min(@ceil(bounds.high * @as(V, @splat(scale))) + @as(V, @splat(1)), top));
        return .{ @intFromFloat(lo[0]), @intFromFloat(lo[1]), @intFromFloat(hi[0]), @intFromFloat(hi[1]) };
    }
};

/// Pixel box of a logical rect at `scale`, clamped at 0.
pub fn box(r: [4]f32, scale: f32) [4]u32 {
    var b: [4]u32 = undefined;
    for (&b, r) |*o, v| o.* = @intFromFloat(@max(v * scale, 0));
    return b;
}

pub const smoke_w = 800;
pub const smoke_h = 600;
pub const smoke_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

/// A smoke run: an application driven by a recording at 800 x 600, every built frame drawn.
pub const Smoke = struct {
    var ctx_buffer: [context.Context.requiredBytes(smoke_limits)]u8 align(lcgf.mem.column_align) = undefined;
    var pixels: [sw.Framebuffer.len(smoke_w, smoke_h)]u32 = undefined;
    var quads: [4096]Quad = undefined;
    var first: [smoke_limits.texts]u32 = undefined;
    var count: [smoke_limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;

    ctx: context.Context,
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},
    /// Recorded frames, frames built (drawn), and the last built frame.
    frames: u32 = 0,
    builds: u32 = 0,
    out: ?context.Output = null,

    /// Plays `recording` (src/core/input.zig `Replay`) into `app`. Fails on a bad recording or
    /// a frame that did not fit its limits.
    pub fn run(app: anytype, recording: []const u8) !Smoke {
        var s: Smoke = .{ .ctx = try .init(&ctx_buffer, smoke_limits), .fb = .init(&pixels, smoke_w, smoke_h, .rgba8) };
        var replay: Replay = .{ .src = recording };
        var ev: Events = .{};
        while (try replay.next(.{ .text = &text, .events = &events, .contacts = &contacts })) |in| {
            s.frames += 1;
            ev.in = in.*;
            if (!s.ctx.needsFrame(&ev.in)) continue;
            var f = s.ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            if (!out.status.ok()) return error.FrameDidNotFit;
            s.builds += 1;
            draw(app, &s.gfx, &s.fb, .{ .quads = &quads, .first = &first, .count = &count }, &out, ev.in.scale, .rgb(0, 0, 0));
            s.out = out;
        }
        return s;
    }

    /// Where the node `id` was laid out in the last built frame.
    pub fn rect(s: *const Smoke, id: lcgf.types.Id) lcgf.types.Rect {
        const t = s.out.?.tree;
        return t.rect(t.find(id));
    }

    /// Pixel (x, y) of the last drawn frame.
    pub fn at(s: *const Smoke, x: u32, y: u32) Color {
        return s.fb.at(x, y);
    }
};

/// A recording that clicks each point in turn at 800 x 600: move, press, release, one frame
/// each, after a first frame that only lays out, and one settle frame at the end.
pub fn clicks(buf: []u8, points: []const [2]f32) ![]const u8 {
    var wr = std.Io.Writer.fixed(buf);
    try wr.writeAll("frame\nviewport 800 600\n");
    for (points) |p| try wr.print("frame\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\n", .{ p[0], p[1] });
    try wr.writeAll("frame\n");
    return wr.buffered();
}

/// The centre of a rect, to click it.
pub fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}

const testing = std.testing;
const test_limits: context.Limits = .{ .nodes = 8, .texts = 4, .customs = 1, .strings = 64 };
const test_draw_bytes = blk: {
    var counter: mem.Carver = .{ .buf = null };
    _ = DrawList.init(&counter, test_limits.nodes, test_limits.texts, test_limits.customs);
    break :blk counter.off;
};

const Differential = struct {
    const width = 79; // Deliberately leave SIMD padding at each row's end.
    const height = 64;
    draw_buffer: [test_draw_bytes]u8 align(mem.column_align) = undefined,
    cache_buffer: [Incremental.requiredBytes(test_limits)]u8 align(mem.column_align) = undefined,
    list: DrawList = undefined,
    cache: Incremental = undefined,
    bytes: [64]u8 = undefined,
    pixels: [sw.Framebuffer.len(width, height)]u32 = undefined,
    reference_pixels: [sw.Framebuffer.len(width, height)]u32 = undefined,
    fb: sw.Framebuffer = undefined,
    reference_fb: sw.Framebuffer = undefined,
    gfx: sw.Software = .{},
    reference_gfx: sw.Software = .{},
    glyph_quads: [65]Quad = undefined,
    glyph_first: [4]u32 = undefined,
    glyph_count: [4]u32 = undefined,
    reference_quads: [65]Quad = undefined,
    reference_first: [4]u32 = undefined,
    reference_count: [4]u32 = undefined,

    fn init(fixture: *Differential, format: sw.Format) void {
        var dc: mem.Carver = .{ .buf = &fixture.draw_buffer };
        fixture.list = DrawList.init(&dc, test_limits.nodes, test_limits.texts, test_limits.customs);
        var cc: mem.Carver = .{ .buf = &fixture.cache_buffer };
        fixture.cache = Incremental.init(&cc, test_limits);
        @memset(&fixture.pixels, 0x12345678);
        @memset(&fixture.reference_pixels, 0x12345678);
        fixture.fb = .init(&fixture.pixels, width, height, format);
        fixture.reference_fb = .init(&fixture.reference_pixels, width, height, format);
        fixture.setText("HELLO");
        fixture.list.quads[0] = .{
            .rect = .{ 4, 4, 60, 52 },
            .clip = .{ 0, 0, 79, 64 },
            .params = @splat(0),
            .uv = .{ 0, 0, 1, 1 },
            .radii = @splat(4),
            .fill = Color.rgba(22, 31, 45, 220).bitsOf(),
            .border_color = Color.rgba(90, 100, 110, 130).bitsOf(),
            .border = 1,
            .opacity = 1,
        };
        fixture.list.quads[1] = fixture.list.quads[0];
        fixture.list.quads[1].rect = .{ 20, 10, 48, 26 };
        fixture.list.quads[1].fill = Color.rgba(200, 30, 80, 85).bitsOf();
        fixture.list.quads[1].border = 0;
        fixture.list.quad_len = 2;
        fixture.list.runs[0] = .{
            .rect = .{ 8, 15, 52, 17 },
            .clip = .{ 0, 0, 79, 64 },
            .start = 0,
            .bytes = 5,
            .px = 10,
            .color = Color.rgba(230, 220, 210, 190).bitsOf(),
            .font = 0,
        };
        fixture.list.run_len = 1;
        fixture.list.cmd_len = 3;
        fixture.list.cmd.kind[0..3].* = .{ @backingInt(DrawList.Kind.quads), @backingInt(DrawList.Kind.text), @backingInt(DrawList.Kind.quads) };
        fixture.list.cmd.first[0..3].* = .{ 0, 0, 1 };
        fixture.list.cmd.count[0..3].* = .{ 1, 1, 1 };
        fixture.list.cmd.key[0..3].* = .{ 0, 0, 0 };
    }

    fn setText(fixture: *Differential, value: []const u8) void {
        @memcpy(fixture.bytes[0..value.len], value);
        fixture.list.strings = fixture.bytes[0..value.len];
    }

    fn glyphs(fixture: *Differential) Glyphs {
        return .{ .quads = &fixture.glyph_quads, .first = &fixture.glyph_first, .count = &fixture.glyph_count };
    }

    fn command(fixture: *Differential, i: u32, kind: DrawList.Kind, first: u32, count: u32) void {
        fixture.list.cmd.kind[i] = @backingInt(kind);
        fixture.list.cmd.first[i] = first;
        fixture.list.cmd.count[i] = count;
        fixture.list.cmd.key[i] = 0;
    }

    fn output(fixture: *Differential) context.Output {
        return .{ .draw = &fixture.list, .tree = undefined, .texts = undefined, .platform = .{}, .status = .{}, .wake = 0, .pace = .idle };
    }

    fn compare(fixture: *Differential, app: anytype, scale: f32, background: Color) !Update {
        return fixture.compareCapacity(app, scale, background, fixture.glyph_quads.len);
    }

    fn compareCapacity(fixture: *Differential, app: anytype, scale: f32, background: Color, capacity: usize) !Update {
        const out = fixture.output();
        var g = fixture.glyphs();
        g.quads = g.quads[0..capacity];
        const update = fixture.cache.draw(app, &fixture.gfx, &fixture.fb, g, &out, scale, background);
        draw(app, &fixture.reference_gfx, &fixture.reference_fb, .{
            .quads = fixture.reference_quads[0..capacity],
            .first = &fixture.reference_first,
            .count = &fixture.reference_count,
        }, &out, scale, background);
        try testing.expectEqualSlices(u32, &fixture.reference_pixels, &fixture.pixels);
        return update;
    }
};

test "incremental host matches full drawing through opacity, motion, clipping and text overflow" {
    for ([_]sw.Format{ .rgba8, .bgra8 }) |format| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        var fixture: Differential = .{};
        fixture.init(format);
        var app = struct {}{};
        const background: Color = .rgba(7, 11, 17, 90);
        const first = try fixture.compare(&app, scale, background);
        try testing.expect(first.full and first.glyphs_rebuilt);
        try testing.expectEqual(@as(u64, Differential.width * Differential.height), first.pixelCount());
        const same = try fixture.compare(&app, scale, background);
        try testing.expectEqual(0, same.len);
        try testing.expect(!same.glyphs_rebuilt);

        fixture.list.quads[1].fill = Color.rgba(10, 230, 50, 110).bitsOf();
        const hover = try fixture.compare(&app, scale, background);
        try testing.expect(!hover.full and !hover.glyphs_rebuilt);
        try testing.expect(hover.pixelCount() < first.pixelCount());

        fixture.setText("BYE!!");
        const changed_text = try fixture.compare(&app, scale, background);
        try testing.expect(!changed_text.full and changed_text.glyphs_rebuilt);
        // Nominal text height stays 2 pixels, but Mono emits several actual lines.
        fixture.setText("ABCDEFAB");
        fixture.list.runs[0].bytes = 8;
        fixture.list.runs[0].rect[2] = 20;
        _ = try fixture.compare(&app, scale, background);
        fixture.setText("X");
        fixture.list.runs[0].bytes = 1;
        _ = try fixture.compare(&app, scale, background);
        fixture.list.quads[1].rect = .{ 29.25, 31.5, 45.75, 49.25 };
        _ = try fixture.compare(&app, scale, background);
        fixture.list.quads[0].clip = .{ 0, 0, 33.5, 30.5 };
        _ = try fixture.compare(&app, scale, background);
        fixture.list.quads[0].opacity = 0.375;
        fixture.list.quads[0].radii = .{ 0, 3, 8, 1 };
        _ = try fixture.compare(&app, scale, background);
        // Background and scale are output dependencies even when no draw input changes.
        try testing.expect((try fixture.compare(&app, scale, .rgba(2, 4, 6, 20))).full);
        try testing.expect((try fixture.compare(&app, scale + 0.25, background)).full);
    };
}

test "incremental host repaints command removal, reordering, unsupported effects and invalidation" {
    var fixture: Differential = .{};
    fixture.init(.rgba8);
    var app = struct {}{};
    const background = Color.rgb(3, 5, 9);
    _ = try fixture.compare(&app, 1.25, background);
    fixture.list.cmd.kind[1] = @backingInt(DrawList.Kind.quads);
    fixture.list.cmd.first[1] = 1;
    fixture.list.cmd_len = 2;
    const removed = try fixture.compare(&app, 1.25, background);
    try testing.expect(!removed.full and removed.pixelCount() > 0);
    fixture.list.cmd.first[0] = 1;
    fixture.list.cmd.first[1] = 0;
    const reordered = try fixture.compare(&app, 1.25, background);
    try testing.expect(!reordered.full and reordered.pixelCount() > 0);
    fixture.list.quads[0].xform = .{ 1, 0, 0, 1, 8, 5 };
    try testing.expect((try fixture.compare(&app, 1.25, background)).full);
    fixture.list.quads[0].xform = .{ 1, 0, 0, 1, 0, 0 };
    try testing.expect((try fixture.compare(&app, 1.25, background)).full);
    fixture.list.quads[0].params = lcgf.features.shadow(4);
    try testing.expect((try fixture.compare(&app, 1.25, background)).full);
    fixture.list.quads[0].params = @splat(0);
    try testing.expect((try fixture.compare(&app, 1.25, background)).full);
    fixture.cache.invalidate();
    @memset(&fixture.pixels, 0x12345678);
    try testing.expect((try fixture.compare(&app, 1.25, background)).full);

    // Resizing the retained target while keeping the same backing storage also invalidates.
    fixture.fb = .init(&fixture.pixels, 70, 50, .rgba8);
    fixture.reference_fb = .init(&fixture.reference_pixels, 70, 50, .rgba8);
    try testing.expect((try fixture.compare(&app, 1.25, background)).full);
}

test "incremental host preserves inclusive degenerate clip edges" {
    for ([_]sw.Format{ .rgba8, .bgra8 }) |format| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        var fixture: Differential = .{};
        fixture.init(format);
        var app = struct {}{};
        const background = Color.rgb(3, 5, 9);
        const centre = @as(f32, 20.5) * (1 / scale);
        fixture.list.quads[0].clip = .{ centre, 0, centre, 64 };
        _ = try fixture.compare(&app, scale, background);
        fixture.list.quads[0].fill = Color.rgba(210, 70, 40, 220).bitsOf();
        const column = try fixture.compare(&app, scale, background);
        try testing.expect(!column.full and column.pixelCount() > 0);
        fixture.list.quads[0].clip = .{ 0, centre, 79, centre };
        _ = try fixture.compare(&app, scale, background);
        fixture.list.quads[0].fill = Color.rgba(40, 180, 75, 220).bitsOf();
        const row = try fixture.compare(&app, scale, background);
        try testing.expect(!row.full and row.pixelCount() > 0);
        fixture.list.quads[0].clip = .{ centre, centre, centre, centre };
        _ = try fixture.compare(&app, scale, background);
        fixture.list.quads[0].fill = Color.rgba(130, 90, 205, 220).bitsOf();
        const point = try fixture.compare(&app, scale, background);
        try testing.expect(!point.full and point.pixelCount() > 0);
    };
}

test "incremental host retains full drawing for mutable images and application underlays" {
    const ImageApp = struct {
        texel: [1]u32 = .{0xffffffff},
        image: [1]sw.Image = undefined,
        pub fn images(app: *@This()) []const sw.Image {
            app.image[0] = .{ .pixels = &app.texel, .width = 1, .height = 1 };
            return &app.image;
        }
    };
    var images: ImageApp = .{};
    var fixture: Differential = .{};
    fixture.init(.bgra8);
    try testing.expect((try fixture.compare(&images, 1, .black)).full);
    images.texel[0] = Color.rgba(150, 40, 200, 130).bitsOf();
    try testing.expect((try fixture.compare(&images, 1, .black)).full);

    const UnderApp = struct {
        color: Color = .rgb(11, 43, 79),
        pub fn under(app: *@This(), fb: *sw.Framebuffer) void {
            fb.fill(.{ 0, 0, 79, 64 }, app.color);
        }
    };
    var under: UnderApp = .{};
    var other: Differential = .{};
    other.init(.rgba8);
    try testing.expect((try other.compare(&under, 1, .black)).full);
    under.color = .rgb(21, 63, 99);
    try testing.expect((try other.compare(&under, 1, .black)).full);
}

test "incremental host falls back safely when snapshot capacity is smaller than the frame" {
    const small: context.Limits = .{ .nodes = 1, .texts = 1, .customs = 0, .strings = 2 };
    const used = comptime Incremental.requiredBytes(small);
    var buffer: [used + 64]u8 align(mem.column_align) = @splat(0xa5);
    var carver: mem.Carver = .{ .buf = &buffer };
    var fixture: Differential = .{};
    fixture.init(.rgba8);
    fixture.cache = Incremental.init(&carver, small);
    var app = struct {}{};
    try testing.expect((try fixture.compare(&app, 1, .black)).full);
    try testing.expect((try fixture.compare(&app, 1, .black)).full);
    for (buffer[used..]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
}

test "incremental host never caches custom output behind an unchanged custom descriptor" {
    const CustomApp = struct {
        color: Color = .rgb(111, 50, 23),
        pub fn drawCustom(app: *@This(), fb: *sw.Framebuffer, _: *const CustomDraw) void {
            // Deliberately draw outside the supplied rectangle: the existing callback
            // contract does not constrain it, so a partial repaint cannot assume it does.
            fb.fill(.{ 65, 1, 78, 7 }, app.color);
        }
    };
    var fixture: Differential = .{};
    fixture.init(.rgba8);
    fixture.list.customs[0] = .{ .rect = .{ 1, 1, 4, 4 }, .clip = .{ 0, 0, 79, 64 }, .data = 0, .id = 1, .node = 0 };
    fixture.list.custom_len = 1;
    fixture.list.cmd_len = 4;
    fixture.list.cmd.kind[3] = @backingInt(DrawList.Kind.custom);
    fixture.list.cmd.first[3] = 0;
    fixture.list.cmd.count[3] = 1;
    fixture.list.cmd.key[3] = 0;
    var app: CustomApp = .{};
    try testing.expect((try fixture.compare(&app, 1, .black)).full);
    app.color = .rgb(201, 113, 57);
    try testing.expect((try fixture.compare(&app, 1, .black)).full);
}

test "incremental host invalidates pixels when replacement glyph capacity changes truncation" {
    var fixture: Differential = .{};
    fixture.init(.rgba8);
    var app = struct {}{};
    _ = try fixture.compare(&app, 1, .black);
    var shorter: [3]Quad = undefined;
    const out = fixture.output();
    const g: Glyphs = .{ .quads = &shorter, .first = &fixture.glyph_first, .count = &fixture.glyph_count };
    const update = fixture.cache.draw(&app, &fixture.gfx, &fixture.fb, g, &out, 1, .black);
    try testing.expect(update.full and update.glyphs_rebuilt);
    var reference: [3]Quad = undefined;
    draw(&app, &fixture.reference_gfx, &fixture.reference_fb, .{
        .quads = &reference,
        .first = &fixture.reference_first,
        .count = &fixture.reference_count,
    }, &out, 1, .black);
    try testing.expectEqualSlices(u32, &fixture.reference_pixels, &fixture.pixels);
}

test "incremental host repaints unchanged later text when earlier runs exhaust glyph storage" {
    for ([_]sw.Format{ .rgba8, .bgra8 }) |format| for ([_]f32{ 1, 1.25 }) |scale| {
        var fixture: Differential = .{};
        fixture.init(format);
        var app = struct {}{};
        @memset(&fixture.bytes, ' ');
        fixture.bytes[0] = 'A';
        fixture.bytes[1] = 'B';
        fixture.bytes[16] = 'Z';
        fixture.list.strings = fixture.bytes[0..17];
        fixture.list.quad_len = 0;
        fixture.list.run_len = 2;
        fixture.list.runs[0].rect = .{ 4, 8, 25, 20 };
        fixture.list.runs[1] = fixture.list.runs[0];
        fixture.list.runs[1].rect = .{ 48, 32, 72, 48 };
        fixture.list.runs[1].start = 16;
        fixture.list.runs[1].bytes = 1;
        fixture.list.cmd_len = 2;
        fixture.list.cmd.kind[0..2].* = @splat(@backingInt(DrawList.Kind.text));
        fixture.list.cmd.first[0..2].* = .{ 0, 1 };
        fixture.list.cmd.count[0..2].* = @splat(1);
        fixture.list.cmd.key[0..2].* = @splat(0);
        // Two live glyph rows: run 1 must disappear/reappear as run 0 changes size.
        // Fixed byte spans ensure run 1 itself and all commands remain unchanged.
        // The 0 -> 2 transition also crosses from an unsaturated prior expansion.
        for ([_]u32{ 1, 2, 1, 0, 2, 0, 1 }) |bytes| {
            fixture.list.runs[0].bytes = bytes;
            const update = try fixture.compareCapacity(&app, scale, .black, 3);
            try testing.expect(update.full and update.glyphs_rebuilt);
            try testing.expectEqual(@as(u32, @intFromBool(bytes < 2)), fixture.glyph_count[1]);
            const stable = try fixture.compareCapacity(&app, scale, .black, 3);
            try testing.expectEqual(0, stable.len);
            try testing.expect(!stable.glyphs_rebuilt);
        }
    };
}

test "incremental host ignores batch splits merges and empty commands but preserves quad keys" {
    for ([_]sw.Format{ .rgba8, .bgra8 }) |format| for ([_]f32{ 1, 1.25 }) |scale| {
        var fixture: Differential = .{};
        fixture.init(format);
        var app = struct {}{};
        fixture.command(0, .quads, 0, 2);
        fixture.command(1, .text, 0, 1);
        fixture.list.cmd_len = 2;
        _ = try fixture.compare(&app, scale, .black);

        fixture.command(0, .quads, 2, 0);
        fixture.command(1, .quads, 0, 1);
        fixture.command(2, .quads, 1, 1);
        fixture.command(3, .text, 0, 1);
        fixture.command(4, .quads, 2, 0);
        fixture.list.cmd_len = 5;
        const split = try fixture.compare(&app, scale, .black);
        try testing.expectEqual(0, split.len);
        try testing.expect(!split.glyphs_rebuilt);

        fixture.command(0, .quads, 0, 2);
        fixture.command(1, .text, 0, 1);
        fixture.list.cmd_len = 2;
        const merged = try fixture.compare(&app, scale, .black);
        try testing.expectEqual(0, merged.len);
        try testing.expect(!merged.glyphs_rebuilt);
        // The software backend currently ignores Material, but the semantic boundary
        // retains the full batch key rather than assuming every consumer always does.
        fixture.list.cmd.key[0] = 1;
        const key = try fixture.compare(&app, scale, .black);
        try testing.expect(!key.full and key.pixelCount() > 0 and !key.glyphs_rebuilt);
    };
}

test "incremental host damages inserted removed and reordered translucent primitives" {
    for ([_]sw.Format{ .rgba8, .bgra8 }) |format| for ([_]f32{ 1, 1.25 }) |scale| {
        var fixture: Differential = .{};
        fixture.init(format);
        var app = struct {}{};
        const first = try fixture.compare(&app, scale, .rgba(3, 5, 9, 70));
        fixture.list.quads[2] = fixture.list.quads[1];
        fixture.list.quads[2].rect = .{ 9.5, 12.25, 31.75, 33.5 };
        fixture.list.quads[2].fill = Color.rgba(40, 190, 80, 130).bitsOf();
        fixture.list.quad_len = 3;
        fixture.command(1, .quads, 2, 1);
        fixture.command(2, .text, 0, 1);
        fixture.command(3, .quads, 1, 1);
        fixture.list.cmd_len = 4;
        const inserted = try fixture.compare(&app, scale, .rgba(3, 5, 9, 70));
        try testing.expect(!inserted.full and !inserted.glyphs_rebuilt);
        try testing.expect(inserted.pixelCount() > 0 and inserted.pixelCount() < first.pixelCount());

        fixture.command(1, .text, 0, 1);
        fixture.command(2, .quads, 2, 1);
        const reordered = try fixture.compare(&app, scale, .rgba(3, 5, 9, 70));
        try testing.expect(!reordered.full and reordered.pixelCount() > 0 and !reordered.glyphs_rebuilt);

        fixture.command(2, .quads, 1, 1);
        fixture.list.cmd_len = 3;
        fixture.list.quad_len = 2;
        const removed = try fixture.compare(&app, scale, .rgba(3, 5, 9, 70));
        try testing.expect(!removed.full and removed.pixelCount() > 0 and !removed.glyphs_rebuilt);
        // Moving source rows while retaining the same ordered inputs changes no pixels.
        std.mem.swap(Quad, &fixture.list.quads[0], &fixture.list.quads[1]);
        fixture.list.cmd.first[0] = 1;
        fixture.list.cmd.first[2] = 0;
        const moved = try fixture.compare(&app, scale, .rgba(3, 5, 9, 70));
        try testing.expectEqual(0, moved.len);
        try testing.expect(!moved.glyphs_rebuilt);
    };
}

test "incremental host handles repeated text and relocated equal run bytes" {
    for ([_]sw.Format{ .rgba8, .bgra8 }) |format| for ([_]f32{ 1, 1.25 }) |scale| {
        var fixture: Differential = .{};
        fixture.init(format);
        var app = struct {}{};
        _ = try fixture.compare(&app, scale, .black);
        fixture.command(2, .text, 0, 1);
        fixture.command(3, .quads, 1, 1);
        fixture.list.cmd_len = 4;
        const repeated = try fixture.compare(&app, scale, .black);
        try testing.expect(!repeated.full and repeated.pixelCount() > 0 and repeated.glyphs_rebuilt);
        try testing.expectEqual(5, fixture.cache.glyph_len);
        fixture.command(2, .quads, 1, 1);
        fixture.list.cmd_len = 3;
        const removed = try fixture.compare(&app, scale, .black);
        try testing.expect(!removed.full and removed.pixelCount() > 0);

        @memset(fixture.bytes[5..16], ' ');
        @memcpy(fixture.bytes[16..21], "HELLO");
        fixture.list.strings = fixture.bytes[0..21];
        fixture.list.runs[1] = fixture.list.runs[0];
        fixture.list.runs[2] = fixture.list.runs[0];
        fixture.list.runs[2].start = 16;
        fixture.list.run_len = 3;
        fixture.list.cmd.first[1] = 2;
        const relocated = try fixture.compare(&app, scale, .black);
        try testing.expectEqual(0, relocated.len);
        try testing.expect(!relocated.glyphs_rebuilt and !fixture.cache.glyph_valid);
        fixture.list.quads[1].fill = Color.rgba(210, 40, 170, 110).bitsOf();
        const mapped = try fixture.compare(&app, scale, .black);
        try testing.expect(!mapped.full and mapped.glyphs_rebuilt);
        try testing.expectEqual(0, fixture.glyph_count[0]);
        try testing.expectEqual(5, fixture.glyph_count[2]);
        fixture.bytes[16] = 'B';
        const changed = try fixture.compare(&app, scale, .black);
        try testing.expect(!changed.full and changed.pixelCount() > 0 and changed.glyphs_rebuilt);
        // These columns have no meaning for text commands in DrawList.command.
        fixture.list.cmd.count[1] = 13;
        fixture.list.cmd.key[1] = 0xabcdef01;
        const unused = try fixture.compare(&app, scale, .black);
        try testing.expectEqual(0, unused.len);
        try testing.expect(!unused.glyphs_rebuilt);
    };
}

test "incremental host handles empty streams and meeting prefix suffix boundaries" {
    var fixture: Differential = .{};
    fixture.init(.rgba8);
    var app = struct {}{};
    _ = try fixture.compare(&app, 1.25, .black);
    fixture.list.cmd_len = 0;
    const emptied = try fixture.compare(&app, 1.25, .black);
    try testing.expect(!emptied.full and emptied.pixelCount() > 0);
    try testing.expectEqual(0, (try fixture.compare(&app, 1.25, .black)).len);
    fixture.command(0, .quads, 2, 0);
    fixture.command(1, .quads, 2, 0);
    fixture.list.cmd_len = 2;
    try testing.expectEqual(0, (try fixture.compare(&app, 1.25, .black)).len);
    fixture.command(1, .text, 0, 1);
    const appeared = try fixture.compare(&app, 1.25, .black);
    try testing.expect(!appeared.full and appeared.pixelCount() > 0);
    fixture.command(0, .quads, 0, 1);
    fixture.command(2, .quads, 1, 1);
    fixture.list.cmd_len = 3;
    _ = try fixture.compare(&app, 1.25, .black);
    fixture.command(0, .text, 0, 1);
    fixture.command(1, .quads, 1, 1);
    fixture.list.cmd_len = 2;
    const prefix_removed = try fixture.compare(&app, 1.25, .black);
    try testing.expect(!prefix_removed.full and prefix_removed.pixelCount() > 0);
    fixture.list.cmd_len = 1;
    const suffix_removed = try fixture.compare(&app, 1.25, .black);
    try testing.expect(!suffix_removed.full and suffix_removed.pixelCount() > 0);
    fixture.list.cmd_len = 0;
    _ = try fixture.compare(&app, 1.25, .black);
    try testing.expectEqual(0, (try fixture.compare(&app, 1.25, .black)).len);
}

test "incremental host preserves shared glyph truncation when equal text commands change run identity" {
    var fixture: Differential = .{};
    fixture.init(.rgba8);
    var app = struct {}{};
    @memset(&fixture.bytes, ' ');
    fixture.bytes[0] = 'A';
    fixture.bytes[16] = 'Z';
    fixture.list.strings = fixture.bytes[0..17];
    fixture.list.quad_len = 0;
    fixture.list.run_len = 3;
    fixture.list.runs[0].rect = .{ 4, 8, 25, 20 };
    fixture.list.runs[0].bytes = 1;
    fixture.list.runs[1] = fixture.list.runs[0];
    fixture.list.runs[2] = fixture.list.runs[0];
    fixture.list.runs[2].rect = .{ 48, 32, 72, 48 };
    fixture.list.runs[2].start = 16;
    fixture.command(0, .text, 0, 1);
    fixture.command(1, .text, 0, 1);
    fixture.command(2, .text, 2, 1);
    _ = try fixture.compareCapacity(&app, 1, .black, 3);
    try testing.expectEqual(1, fixture.glyph_count[2]);
    // Semantic pixels of each command are equal, but distinct runs consume separate
    // glyph rows. Capacity fallback must precede the semantic prefix/suffix shortcut.
    fixture.list.cmd.first[1] = 1;
    const separate = try fixture.compareCapacity(&app, 1, .black, 3);
    try testing.expect(separate.full and separate.glyphs_rebuilt);
    try testing.expectEqual(0, fixture.glyph_count[2]);
    fixture.list.cmd.first[1] = 0;
    const shared = try fixture.compareCapacity(&app, 1, .black, 3);
    try testing.expect(shared.full and shared.glyphs_rebuilt);
    try testing.expectEqual(1, fixture.glyph_count[2]);
}
