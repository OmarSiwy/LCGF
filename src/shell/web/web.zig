//! The web shell: a `<canvas>` in a browser page. The page's JavaScript (shell.js) turns DOM
//! events into calls on this struct through the wasm module's exports, and drives frames with
//! `requestAnimationFrame`; this struct turns those calls into `Events` and the frame's effects
//! back into calls on `host`, the module's imports.
//!
//! A browser never lets wasm block, so the loop is the host page's and each animation frame runs
//! one turn of `iface.run`'s body (route 2 of src/shell/iface.zig, "Embedding"):
//!
//!     export fn lcgr_frame(ms: f64) void {           // shell.js calls it from requestAnimationFrame
//!         shell.time(ms / 1000);
//!         if (!shell.poll(&ev)) return;
//!         if (ctx.needsFrame(&ev.in)) { ...build; shell.apply(&out.platform); shell.present(&out); }
//!         shell.wait(scheduler.wake(&ctx, &ev.in), scheduler.pace(&ctx));
//!     }
//!
//! `wait` cannot block either: it asks the page for the next animation frame, or for none
//! until the next event, and returns.
//!
//! Generic over `host`, a namespace of the functions below, so this file is plain Zig: the wasm
//! example passes its imports (main.zig), the tests a recording stand-in.
//!
//!   fn present(*const Output) void          draw the frame (WebGPU or the 2D canvas)
//!   fn schedule(seconds: f32, pace: Pace) void
//!        when the next animation frame is wanted: in `seconds`, never for inf (only after an
//!        event)
const std = @import("std");
const types = @import("../../core/types.zig");
const Input = @import("../../core/input.zig").Input;
const context = @import("../../runtime/context.zig");
const scheduler = @import("../../runtime/scheduler.zig");
const iface = @import("../iface.zig");
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = scheduler.Pace;
const none = types.none;

pub fn Web(comptime host: type) type {
    return struct {
        const Self = @This();

        /// Held state and what arrived since the last `poll`.
        in: Input = .{},
        /// Time of the previous frame, seconds; `time` sets `in.dt` from it.
        last: f64 = -1,
        /// False after `close` (the page is going away): `poll` gives no more frames.
        open: bool = true,
        /// Set by `wake`; the next `poll` reports it in `wakes`.
        woken: std.atomic.Value(bool) = .init(false),
        polls: u32 = 0,
        wakes: u32 = 0,
        /// The canvas's backing store in device pixels: what `present` draws.
        pixels: [2]u32 = .{ 800, 600 },
        /// This frame's typed bytes, key and text events, and the contacts held (rows stay
        /// until lifted). Full buffers drop what does not fit, counted in `dropped`.
        text: [max_text]u8 = undefined,
        text_len: u32 = 0,
        events: [max_events]Input.Event = undefined,
        event_len: u32 = 0,
        contacts: [max_contacts]Input.Contact = undefined,
        contact_len: u32 = 0,
        /// Per `contacts` row: `lift` marked it (`lifting`); the next `poll` reports it once
        /// more and marks it `gone`; the poll after that removes it, once its frame is over.
        lifting: [max_contacts]bool = @splat(false),
        gone: [max_contacts]bool = @splat(false),
        dropped: u32 = 0,

        pub const max_text = 256;
        pub const max_events = 64;
        pub const max_contacts = 16;
        /// `wheel`'s `mode`, the DOM's WheelEvent.deltaMode.
        pub const WheelMode = enum(u32) { pixel, line, page };

        /// The canvas's size in CSS pixels (logical, `Input.viewport`), the device pixel ratio
        /// (`Input.scale`) and its backing store in device pixels (`pixels`). The browser
        /// reports the device pixels exactly (ResizeObserver's devicePixelContentBoxSize); they
        /// can differ from css * dpr by a pixel, and the frame is drawn at the exact size so it
        /// maps one to one onto the screen.
        pub fn resize(s: *Self, css_w: f32, css_h: f32, dpr: f32, px_w: u32, px_h: u32) void {
            s.in.viewport = .{ css_w, css_h };
            s.in.scale = dpr;
            s.pixels = .{ px_w, px_h };
        }

        /// The pointer moved to (x, y), CSS pixels from the canvas's top left.
        pub fn pointer(s: *Self, x: f32, y: f32) void {
            s.in.pointer = .{ x, y };
        }

        /// The pointer left the canvas.
        pub fn leave(s: *Self) void {
            s.in.pointer = .{ -1, -1 };
        }

        /// Mouse button `button` (DOM numbering: 0 left, 1 middle, 2 right) went down or up.
        pub fn button(s: *Self, b: u32, down: bool) void {
            const bit: u8 = switch (b) {
                0 => 1, // left
                1 => 4, // middle
                2 => 2, // right
                else => 0,
            };
            const held: u8 = @bitCast(s.in.buttons);
            s.in.buttons = @bitCast(if (down) held | bit else held & ~bit);
        }

        /// Modifier keys held, from any event's shiftKey, ctrlKey, altKey and metaKey.
        pub fn mods(s: *Self, m: Input.Mods) void {
            s.in.mods = m;
        }

        /// A key went down (`.press`, `.repeat`) or up (`.release`). `code` is a USB HID usage
        /// (shell.js maps KeyboardEvent.code), the default the core's key maps use.
        pub fn key(s: *Self, kind: Input.Event.Kind, code: u8, m: Input.Mods) void {
            s.mods(m);
            const bit = @as(u64, 1) << @as(u6, @truncate(code));
            const word = &s.in.keys.bits[code >> 6];
            word.* = if (kind == .release) word.* & ~bit else word.* | bit;
            s.event(.{ .kind = kind, .code = code, .mods = m });
        }

        /// The canvas lost focus: keys held now will never see their key-up, so none is held.
        pub fn blur(s: *Self) void {
            s.in.keys = .{};
            s.in.mods = .{};
        }

        /// Text typed (UTF-8), one `.text` event.
        pub fn typed(s: *Self, bytes: []const u8, m: Input.Mods) void {
            if (bytes.len > max_text - s.text_len or s.event_len == max_events) {
                s.dropped += 1;
                return;
            }
            @memcpy(s.text[s.text_len..][0..bytes.len], bytes);
            s.event(.{ .kind = .text, .mods = m, .at = s.text_len, .len = @intCast(bytes.len) });
            s.text_len += @intCast(bytes.len);
        }

        fn event(s: *Self, e: Input.Event) void {
            if (s.event_len == max_events) {
                s.dropped += 1;
                return;
            }
            s.events[s.event_len] = e;
            s.event_len += 1;
        }

        /// A wheel event's deltas. Pixel deltas (touchpads, and most mice in Chromium) become
        /// `Input.scroll`; line and page deltas become `Input.wheel` notches, a page counted as
        /// one. The DOM's y grows downwards, the core's wheel upwards, so the sign flips.
        pub fn wheel(s: *Self, dx: f32, dy: f32, mode: WheelMode) void {
            const d: [2]f32 = .{ -dx, -dy };
            if (mode == .pixel) {
                s.in.scroll = .{ s.in.scroll[0] + d[0], s.in.scroll[1] + d[1] };
            } else {
                s.in.wheel = .{ s.in.wheel[0] + d[0], s.in.wheel[1] + d[1] };
            }
        }

        /// A finger or pen (PointerEvent with pointerType touch or pen) went down, moved or
        /// hovers: its row is added or updated. `tilt` is in radians.
        pub fn contact(s: *Self, c: Input.Contact) void {
            const at = s.find(c.id);
            if (at == none and s.contact_len == max_contacts) {
                s.dropped += 1;
                return;
            }
            const row = if (at == none) s.contact_len else at;
            s.contacts[row] = c;
            s.contact_len += @intFromBool(at == none);
            s.lifting[row] = false;
            s.gone[row] = false;
        }

        /// Contact `id` lifted or was cancelled: reported with `down = false` in the next frame,
        /// then removed.
        pub fn lift(s: *Self, id: u32) void {
            const at = s.find(id);
            if (at == none) return;
            s.contacts[at].down = false;
            s.lifting[at] = true;
        }

        fn find(s: *const Self, id: u32) u32 {
            for (s.contacts[0..s.contact_len], 0..) |c, i| if (c.id == id) return @intCast(i);
            return none;
        }

        /// The animation frame's timestamp, seconds. Call before `poll`.
        pub fn time(s: *Self, seconds: f64) void {
            s.in.dt = if (s.last < 0) 1.0 / 60.0 else @floatCast(@max(seconds - s.last, 0));
            s.in.time = seconds;
            s.last = seconds;
        }

        pub fn close(s: *Self) void {
            s.open = false;
        }

        /// What arrived since the last poll. Never blocks; false after `close`.
        pub fn poll(s: *Self, ev: *Events) bool {
            if (!s.open) return false;
            s.wakes += @intFromBool(s.woken.swap(false, .acq_rel));
            s.polls += 1;
            s.dropGone();
            ev.in = s.in;
            ev.in.text = s.text[0..s.text_len];
            ev.in.events = s.events[0..s.event_len];
            ev.in.contacts = s.contacts[0..s.contact_len];
            // The slices stay valid until the next event or poll: the page delivers no event
            // while a frame runs. What belongs to one frame starts again empty.
            s.text_len = 0;
            s.event_len = 0;
            s.in.wheel = .{ 0, 0 };
            s.in.scroll = .{ 0, 0 };
            s.gone = s.lifting;
            s.lifting = @splat(false);
            // A lifted contact leaves the input at the next poll: make sure there is one.
            if (std.mem.indexOfScalar(bool, &s.gone, true) != null) host.schedule(0, .once);
            return true;
        }

        /// Removes the rows the previous poll reported lifted; the others keep their order.
        fn dropGone(s: *Self) void {
            var n: u32 = 0;
            for (0..s.contact_len) |i| {
                s.contacts[n] = s.contacts[i];
                s.lifting[n] = s.lifting[i];
                n += @intFromBool(!s.gone[i]);
            }
            s.contact_len = n;
            s.gone = @splat(false);
        }

        pub fn apply(_: *Self, _: *const Platform) void {}

        pub fn present(_: *Self, out: *const Output) void {
            host.present(out);
        }

        /// Asks the page for the next animation frame, unless `seconds` is inf (idle: the next
        /// event asks for one). Never blocks: a page's script may not.
        pub fn wait(_: *Self, seconds: f32, pace: Pace) void {
            host.schedule(seconds, pace);
        }

        /// The next `poll` gives a frame even with no event, and the page runs one soon.
        pub fn wake(s: *Self) void {
            s.woken.store(true, .release);
            host.schedule(0, .once);
        }
    };
}

const testing = std.testing;
const mem = @import("../../core/mem.zig");
const Replay = @import("../../core/input.zig").Replay;
const example = @import("../example.zig");

/// The page, recorded: what the shell asked of it.
const Page = struct {
    var presents: u32 = 0;
    var scheduled: f32 = -1;
    var pace: Pace = .idle;

    pub fn present(_: *const Output) void {
        presents += 1;
    }
    pub fn schedule(seconds: f32, p: Pace) void {
        scheduled = seconds;
        pace = p;
    }
};

comptime {
    iface.check(Web(Page));
}

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var example_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;

/// One animation frame of the example, as lcgr_frame runs it.
fn animationFrame(shell: anytype, ctx: *context.Context, app: *example.App, ms: f64) void {
    var ev: Events = .{};
    shell.time(ms / 1000);
    if (!shell.poll(&ev)) return;
    if (ctx.needsFrame(&ev.in)) {
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        shell.apply(&out.platform);
        shell.present(&out);
    }
    shell.wait(scheduler.wake(ctx, &ev.in), scheduler.pace(ctx));
}

/// Plays a recording (src/core/input.zig `Replay`) into the shell the way shell.js forwards DOM
/// events: what changed since the previous frame becomes one call each, then one animation frame.
pub fn replay(shell: anytype, ctx: *context.Context, app: *example.App, recording: []const u8) !u32 {
    var r: Replay = .{ .src = recording };
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    var prev: Input = .{};
    var frames: u32 = 0;
    while (try r.next(.{ .text = &text, .events = &events, .contacts = &contacts })) |in| : (frames += 1) {
        if (!std.meta.eql(in.viewport, prev.viewport) or in.scale != prev.scale) shell.resize(in.viewport[0], in.viewport[1], in.scale, @intFromFloat(@round(in.viewport[0] * in.scale)), @intFromFloat(@round(in.viewport[1] * in.scale)));
        if (!std.meta.eql(in.pointer, prev.pointer)) shell.pointer(in.pointer[0], in.pointer[1]);
        const dom = [_]u32{ 0, 2, 1 }; // left, right, middle
        inline for (.{ "left", "right", "middle" }, dom) |name, b| {
            if (@field(in.buttons, name) != @field(prev.buttons, name)) shell.button(b, @field(in.buttons, name));
        }
        prev = in.*;
        animationFrame(shell, ctx, app, in.time * 1000);
    }
    return frames;
}

test "web: the example replays through the shell's calls with the headless shell's results" {
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var shell: Web(Page) = .{};
    Page.presents = 0;
    const frames = try replay(&shell, &ctx, &app, @embedFile("../testdata/example.replay"));
    // The same results as src/shell/headless.zig "headless: runs the example from a recording".
    try testing.expectEqual(@as(u32, 15), frames);
    try testing.expectEqual(@as(u32, 15), shell.polls);
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(app.builds, Page.presents);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    // Idle at the end: no frame until the next event.
    try testing.expectEqual(types.inf, Page.scheduled);
    try testing.expectEqual(Pace.idle, Page.pace);
}

test "web: buttons follow DOM numbering; time sets dt; close ends the frames" {
    var shell: Web(Page) = .{};
    shell.button(2, true);
    shell.button(1, true);
    try testing.expect(shell.in.buttons.right and shell.in.buttons.middle and !shell.in.buttons.left);
    shell.button(2, false);
    try testing.expect(!shell.in.buttons.right and shell.in.buttons.middle);
    shell.time(1);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), shell.in.dt, 1e-6);
    shell.time(1.25);
    try testing.expectApproxEqAbs(@as(f32, 0.25), shell.in.dt, 1e-6);
    var ev: Events = .{};
    try testing.expect(shell.poll(&ev));
    shell.close();
    try testing.expect(!shell.poll(&ev));
}

test "web: keys, text, wheel and contacts become one frame's Input, then reset" {
    var shell: Web(Page) = .{};
    var ev: Events = .{};
    const ctrl: Input.Mods = .{ .ctrl = true };
    shell.key(.press, 0x04, .{}); // KeyA
    shell.typed("a", .{});
    shell.key(.press, 0xe0, ctrl); // ControlLeft
    shell.key(.repeat, 0x04, ctrl);
    shell.wheel(0, 100, .pixel); // a Chromium mouse notch: down by 100 px
    shell.wheel(0, 3, .line);
    shell.contact(.{ .id = 7, .pos = .{ 10, 20 } });
    try testing.expect(shell.poll(&ev));
    try testing.expectEqualStrings("a", ev.in.text);
    try testing.expectEqual(@as(usize, 4), ev.in.events.len);
    try testing.expectEqual(Input.Event.Kind.text, ev.in.events[1].kind);
    try testing.expectEqualStrings("a", ev.in.typed(ev.in.events[1]));
    try testing.expectEqual(Input.Event.Kind.repeat, ev.in.events[3].kind);
    try testing.expect(ev.in.keys.down(0x04) and ev.in.keys.down(0xe0) and ev.in.mods.ctrl);
    try testing.expectEqual([2]f32{ 0, -100 }, ev.in.scroll);
    try testing.expectEqual([2]f32{ 0, -3 }, ev.in.wheel);
    try testing.expectEqual(@as(u32, 0), ev.in.contact(7));

    // Next frame: held keys stay, the per-frame state is gone; the finger moves, then lifts.
    shell.key(.release, 0x04, ctrl);
    shell.contact(.{ .id = 7, .pos = .{ 15, 25 } });
    shell.contact(.{ .id = 8, .pos = .{ 50, 50 } });
    try testing.expect(shell.poll(&ev));
    try testing.expectEqualStrings("", ev.in.text);
    try testing.expectEqual(@as(usize, 1), ev.in.events.len);
    try testing.expect(!ev.in.keys.down(0x04) and ev.in.keys.down(0xe0));
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.wheel);
    try testing.expectEqual([2]f32{ 15, 25 }, ev.in.contacts[ev.in.contact(7)].pos);
    shell.lift(7);
    try testing.expect(shell.poll(&ev));
    try testing.expectEqual(@as(usize, 2), ev.in.contacts.len);
    try testing.expect(!ev.in.contacts[ev.in.contact(7)].down);
    try testing.expect(shell.poll(&ev));
    try testing.expectEqual(@as(usize, 1), ev.in.contacts.len);
    try testing.expectEqual(none, ev.in.contact(7));
    try testing.expectEqual([2]f32{ 50, 50 }, ev.in.contacts[ev.in.contact(8)].pos);

    // Full buffers drop instead of overflowing.
    for (0..Web(Page).max_events + 3) |_| shell.key(.press, 0x05, .{});
    try testing.expectEqual(@as(u32, 3), shell.dropped);
}
