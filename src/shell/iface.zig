//! The shell contract: what every platform shell (Win32, macOS, Wayland, X11, web, Android, iOS,
//! bare metal, headless) provides so one host loop runs on any of them. A shell turns the
//! platform's events into `Input` and applies the effects a frame asks for; it never builds a
//! frame and never owns the loop (docs/DESIGN.md: the host owns the loop, the memory and the
//! GPU objects).
//!
//! No vtable and no callback: a shell is any type `S` with the declarations below, checked at
//! compile time by `check`, the way src/render/iface.zig checks a back end.
//!
//!   fn poll(*S, *Events) bool
//!        Drains the platform's pending events into `ev` without blocking: held state (pointer,
//!        buttons, keys, viewport, scale) is updated in place, per-frame state (wheel, scroll,
//!        typed text, key events, contacts, a drop) is replaced. False once the shell has no more
//!        frames to give (the window closed, the recording ended); the shell says why itself.
//!        Slices in `ev` point into the shell's own buffers and stay valid until the next `poll`.
//!   fn apply(*S, *const Platform) void
//!        Applies a frame's platform effects: the cursor shape, showing the on-screen keyboard or
//!        IME at `ime_rect`, setting the clipboard. Called once per built frame, after `end`.
//!
//! One frame through the contract, which is all a host loop is:
//!
//!     while (shell.poll(&ev)) {
//!         if (!ctx.needsFrame(&ev.in)) continue; // and sleep, see `Output.wake`
//!         var f = ctx.begin(&ev.in);
//!         app.build(&f, &ev);
//!         const out = f.end(.{});
//!         shell.apply(&out.platform);
//!         // render out.draw with any back end (src/render/iface.zig)
//!     }

const std = @import("std");
const Input = @import("../core/input.zig").Input;
const keyboard = @import("../interact/keyboard.zig");
const gestures = @import("../interact/gestures.zig");
const Platform = @import("../runtime/context.zig").Platform;

/// Everything a shell reports for one frame. `Input` is what the core reads; the IME's
/// composition and dragged files ride next to it, since only the widgets that ask for them read
/// them (`keyboard.Keyboard.composition`, `gestures.Files.route`).
pub const Events = struct {
    in: Input = .{},
    /// Text the IME is composing, not yet committed (committed text arrives in `in.text`).
    composition: keyboard.Composition = .{},
    /// Files dragged over or dropped on the window this frame.
    files: gestures.Files = .{},
};

/// The declarations `check` requires of a shell.
pub const required = [_][]const u8{ "poll", "apply" };

/// Compile error unless `S` declares everything in `required`.
pub fn check(comptime S: type) void {
    for (required) |name| {
        if (!@hasDecl(S, name)) @compileError(@typeName(S) ++ " is not a shell: missing `" ++ name ++ "` (src/shell/iface.zig)");
    }
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const context = @import("../runtime/context.zig");
const example = @import("example.zig");

/// Smallest shell that meets the contract: the test is the platform. It sets `next` before each
/// poll and reads back what was applied.
const Manual = struct {
    next: Input = .{},
    open: bool = true,
    applied: Platform = .{},
    applies: u32 = 0,

    pub fn poll(m: *Manual, ev: *Events) bool {
        ev.in = m.next;
        return m.open;
    }
    pub fn apply(m: *Manual, p: *const Platform) void {
        m.applied = p.*;
        m.applies += 1;
    }
};

comptime {
    check(Manual);
}

/// One turn of the loop in the header, for the tests: false when the shell is done.
fn turn(shell: anytype, ctx: *context.Context, app: *example.App, ev: *Events) ?context.Output {
    if (!shell.poll(ev)) return null;
    if (!ctx.needsFrame(&ev.in)) return null;
    var f = ctx.begin(&ev.in);
    app.build(&f, ev);
    const out = f.end(.{});
    shell.apply(&out.platform);
    return out;
}

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var example_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;

test "contract: a shell runs the example through poll and apply" {
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var shell: Manual = .{ .next = .{ .viewport = .{ 800, 600 } } };
    var ev: Events = .{};

    var out = turn(&shell, &ctx, &app, &ev).?;
    try testing.expect(out.status.ok());
    const t = out.tree;
    try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 50, .x1 = 160, .y1 = 600 }, t.rect(t.find(example.id_sidebar)));
    try testing.expectEqual(types.Rect{ .x0 = 160, .y0 = 50, .x1 = 800, .y1 = 600 }, t.rect(t.find(example.id_viewport)));

    // Idle: one settle frame, then unchanged input builds nothing and applies nothing.
    out = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual(types.inf, out.wake);
    try testing.expectEqual(null, turn(&shell, &ctx, &app, &ev));
    try testing.expectEqual(@as(u32, 2), app.builds);
    try testing.expectEqual(@as(u32, 2), shell.applies);

    // Hover: the cursor the button asks for reaches the shell.
    shell.next.pointer = example.center(out.tree.rect(out.tree.find(example.id_reset)));
    out = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual(context.Cursor.pointer, shell.applied.cursor);
    // Click: press, then release over the button.
    shell.next.buttons.left = true;
    _ = turn(&shell, &ctx, &app, &ev).?;
    shell.next.buttons.left = false;
    out = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual(@as(u32, 1), app.resets);

    // Drag: holding the slider at 75% of its track sets the value to 3 of 0..4.
    const track = out.tree.rect(out.tree.find(example.id_exposure));
    shell.next.pointer = .{ track.x0 + 0.75 * track.w(), (track.y0 + track.y1) * 0.5 };
    _ = turn(&shell, &ctx, &app, &ev).?;
    shell.next.buttons.left = true;
    _ = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);

    // Leaving the button: the shell is told to put the arrow back.
    shell.next = .{ .viewport = .{ 800, 600 }, .pointer = .{ 400, 400 } };
    _ = turn(&shell, &ctx, &app, &ev).?;
    try testing.expectEqual(context.Cursor.arrow, shell.applied.cursor);

    shell.open = false;
    try testing.expectEqual(null, turn(&shell, &ctx, &app, &ev));
}
