//! The shell example on the web: the example UI (src/shell/example.zig) in a browser page,
//! through the web shell (web.zig) and drawn with the web back end's 2D-canvas path
//! (src/render/web/canvas.zig). Built by `zig build web` into zig-out/web/shell.wasm; index.html
//! is the page.
const std = @import("std");
const lcgr = @import("lcgr");
const rweb = @import("render_web");
const context = lcgr.context;
const scheduler = lcgr.scheduler;
const example = lcgr.shell_example;
const sw = lcgr.render_sw;
const Output = context.Output;
const Pace = scheduler.Pace;

pub const panic = rweb.js.panic;

const imports = struct {
    extern "lcgr" fn shell_schedule(seconds: f32, pace: u32) void;
    extern "lcgr" fn shell_cursor(cursor: u32) void;
    extern "lcgr" fn shell_clipboard(ptr: [*]const u8, len: usize) void;
    extern "lcgr" fn shell_ime(on: bool, x0: f32, y0: f32, x1: f32, y1: f32) void;
};

/// The page, as web.zig's `host`.
const host = struct {
    pub fn schedule(seconds: f32, pace: Pace) void {
        imports.shell_schedule(seconds, @backingInt(pace));
    }
    pub fn cursor(c: context.Cursor) void {
        imports.shell_cursor(@backingInt(c));
    }
    pub fn clipboard(text: []const u8) void {
        imports.shell_clipboard(text.ptr, text.len);
    }
    pub fn ime(on: bool, r: lcgr.types.Rect) void {
        imports.shell_ime(on, r.x0, r.y0, r.x1, r.y1);
    }
    pub fn present(out: *const Output) void {
        const n = font.quads(out.draw, &glyph_quads, .{ .first = &glyph_first, .count = &glyph_count });
        const glyphs: lcgr.render_iface.Glyphs = .{ .quads = glyph_quads[0..n], .first = &glyph_first, .count = &glyph_count };
        const scale = shell.in.scale;
        // The framebuffer is the canvas's backing store, up to what `pixels` holds.
        const w = @max(@min(shell.pixels[0], max_w), 1);
        const h = @max(@min(shell.pixels[1], @as(u32, @intCast(pixels.len / sw.Framebuffer.len(w, 1)))), 1);
        var c: rweb.canvas.Canvas = .init(&pixels, w, h);
        c.gfx.prepare({}, out.draw, glyphs, shell.in.viewport, scale);
        c.fb.clear(background);
        lcgr.render_iface.render(&c.gfx, c.target(), out.draw);
        c.present();
    }
};

const Shell = lcgr.shell_web.Web(host);

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var ctx: context.Context = undefined;
var app: example.App = .{};
var shell: Shell = .{};
var ev: lcgr.shell_iface.Events = .{};
const font: lcgr.protocol.Mono = .{};
var glyph_quads: [4096]lcgr.draw_list.Quad = undefined;
var glyph_first: [limits.texts]u32 = undefined;
var glyph_count: [limits.texts]u32 = undefined;
/// The 2D-canvas framebuffer: up to 2560 x 1600 physical pixels, 16 MB of zero-initialised
/// memory; a bigger canvas shows its top left.
const max_w = 2560;
var pixels: [sw.Framebuffer.len(max_w, 1600)]u32 = undefined;
const background: lcgr.types.Color = .rgb(0, 0, 0);

export fn lcgr_init() bool {
    ctx = context.Context.init(&buffer, limits) catch return false;
    return true;
}

/// One animation frame: one turn of iface.run's body (web.zig).
export fn lcgr_frame(ms: f64) void {
    shell.time(ms / 1000);
    if (!shell.poll(&ev)) return;
    see(&ev);
    if (ctx.needsFrame(&ev.in)) {
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(font);
        shell.apply(&withTestTextInput(out.platform));
        shell.present(&out);
    }
    shell.wait(scheduler.wake(&ctx, &ev.in), scheduler.pace(&ctx));
}

export fn lcgr_resize(css_w: f32, css_h: f32, dpr: f32, px_w: u32, px_h: u32) void {
    shell.resize(css_w, css_h, dpr, px_w, px_h);
}
export fn lcgr_pointer(x: f32, y: f32) void {
    shell.pointer(x, y);
}
export fn lcgr_leave() void {
    shell.leave();
}
export fn lcgr_button(b: u32, down: bool) void {
    shell.button(b, down);
}
export fn lcgr_close() void {
    shell.close();
}
export fn lcgr_blur() void {
    shell.blur();
}
export fn lcgr_mods(m: u32) void {
    shell.mods(@bitCast(@as(u8, @truncate(m))));
}
/// `kind`: 0 press, 1 release, 2 repeat (Input.Event.Kind).
export fn lcgr_key(kind: u32, code: u32, m: u32) void {
    shell.key(@fromBackingInt(@intCast(kind)), @truncate(code), @bitCast(@as(u8, @truncate(m))));
}
/// Where the page encodes typed text before `lcgr_typed`.
export fn lcgr_text_buffer() [*]u8 {
    return &staging;
}
export fn lcgr_text_capacity() u32 {
    return staging.len;
}
export fn lcgr_typed(len: u32, m: u32) void {
    shell.typed(staging[0..@min(len, staging.len)], @bitCast(@as(u8, @truncate(m))));
}
export fn lcgr_wheel(dx: f32, dy: f32, mode: u32) void {
    shell.wheel(dx, dy, @fromBackingInt(@intCast(@min(mode, 2))));
}
/// `kind`: 0 touch, 1 pen, 2 eraser (Input.Contact.Kind).
export fn lcgr_contact(id: u32, kind: u32, down: bool, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32) void {
    shell.contact(.{ .id = id, .kind = @fromBackingInt(@intCast(@min(kind, 2))), .down = down, .pos = .{ x, y }, .pressure = pressure, .tilt = .{ tilt_x, tilt_y } });
}
export fn lcgr_lift(id: u32) void {
    shell.lift(id);
}

var staging: [256]u8 = undefined;

/// The IME's composition, encoded in the staging buffer; `a`..`b` the highlighted byte range.
export fn lcgr_compose(len: u32, a: u32, b: u32) void {
    shell.compose(staging[0..@min(len, staging.len)], .{ a, b });
}

/// For the tests: from now on every frame asks for text input at (x0, y0, x1, y1), as a
/// focused text field would (the example has none); `on` false stops it. Applied at once.
export fn lcgr_test_ime(on: bool, x0: f32, y0: f32, x1: f32, y1: f32) void {
    test_text_input = if (on) .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } else null;
    shell.apply(&withTestTextInput(.{ .cursor = shell.cursor }));
}

var test_text_input: ?lcgr.types.Rect = null;

fn withTestTextInput(p: context.Platform) context.Platform {
    var q = p;
    if (test_text_input) |r| {
        q.wants_text = true;
        q.ime_rect = r;
    }
    return q;
}

/// For the tests: a frame's effects asking to copy `text` (the example itself copies nothing).
export fn lcgr_test_copy(len: u32) void {
    shell.apply(&.{ .clipboard = staging[0..@min(len, staging.len)] });
}

/// What the frames saw, for the tests (test_shell.py): totals since the page loaded.
const Seen = struct {
    presses: u32 = 0,
    releases: u32 = 0,
    last_code: u32 = 0,
    last_mods: u32 = 0,
    text: [64]u8 = @splat(0),
    text_len: u32 = 0,
    wheel_y: f32 = 0,
    scroll_y: f32 = 0,
    contacts: u32 = 0,
    contact_x: f32 = 0,
    keys_held: u32 = 0,
    composition: [64]u8 = @splat(0),
    composition_len: u32 = 0,
    range: [2]u32 = .{ 0, 0 },
};
var seen: Seen = .{};

fn see(frame_ev: *const lcgr.shell_iface.Events) void {
    const in = &frame_ev.in;
    for (in.events) |e| {
        seen.presses += @intFromBool(e.kind == .press);
        seen.releases += @intFromBool(e.kind == .release);
        if (e.kind != .text) {
            seen.last_code = e.code;
            seen.last_mods = @as(u8, @bitCast(e.mods));
        }
        const t = in.typed(e);
        const n = @min(t.len, seen.text.len - seen.text_len);
        @memcpy(seen.text[seen.text_len..][0..n], t[0..n]);
        seen.text_len += @intCast(n);
    }
    seen.wheel_y += in.wheel[1];
    seen.scroll_y += in.scroll[1];
    seen.contacts = @intCast(in.contacts.len);
    if (in.contacts.len > 0) seen.contact_x = in.contacts[0].pos[0];
    var held: u32 = 0;
    for (in.keys.bits) |w| held += @popCount(w);
    seen.keys_held = held;
    const c = frame_ev.composition;
    seen.composition_len = @intCast(@min(c.text.len, seen.composition.len));
    @memcpy(seen.composition[0..seen.composition_len], c.text[0..seen.composition_len]);
    seen.range = c.range;
}

/// `seen`'s fields in order (floats times 1000), the text as bytes from field 100, the
/// composition's from 200.
export fn lcgr_seen(i: u32) i32 {
    const s = seen;
    const v = [_]i32{ @intCast(s.presses), @intCast(s.releases), @intCast(s.last_code), @intCast(s.last_mods), @intCast(s.text_len), @intFromFloat(s.wheel_y * 1000), @intFromFloat(s.scroll_y * 1000), @intCast(s.contacts), @intFromFloat(s.contact_x * 1000), @intCast(s.keys_held), @intCast(s.composition_len), @intCast(s.range[0]), @intCast(s.range[1]) };
    if (i >= 200) return s.composition[@min(i - 200, s.composition.len - 1)];
    if (i >= 100) return s.text[@min(i - 100, s.text.len - 1)];
    return v[@min(i, v.len - 1)];
}

/// The example's state, for the tests: builds, resets, layers, exposure * 1000, the theme's
/// panel colour (RGBA bytes, little-endian), polls, scale * 1000, backing store width, height.
export fn lcgr_example_state(i: u32) u32 {
    const s = [_]u32{ app.builds, app.resets, app.layers, @intFromFloat(@round(app.exposure * 1000)), app.theme.panel.bitsOf(), shell.polls, @intFromFloat(@round(shell.in.scale * 1000)), shell.pixels[0], shell.pixels[1] };
    return s[@min(i, s.len - 1)];
}
