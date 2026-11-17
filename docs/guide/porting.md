# Porting to a new platform

The core touches no OS: tiers 0 to 2 import no allocator, no `std.Io` and no platform API, so
they already build for any target Zig supports (`ci/run.sh cross` compiles the tests for
aarch64-linux, aarch64-macos, x86_64-windows, wasm32-wasi and riscv64-linux; `ci/run.sh
baremetal` links the example for Cortex-M7 and RV32IMAC with no OS). A new platform therefore
needs at most two things, both outside the core:

- a **shell**, which turns the platform's events into `Input` and applies what a frame asks for;
- a **render back end**, if none of the existing ones (software, Vulkan, Metal, Direct3D 12,
  GL ES, web, wgpu) can draw there.

Neither is a plugin: there is no registry, vtable or callback. Each is a type with a few
declarations, checked at compile time, and the host calls it. The contracts are written up in the
headers of `src/shell/iface.zig` and `src/render/iface.zig`; read those first.

Every code block below is a piece of `docs/guide/porting.zig`, which `zig build docs` compiles
and runs.

## The shell contract

| Declaration | What it does |
|---|---|
| `fn poll(*S, *Events) bool` | drains pending events into `Events` without blocking; false when there are no more frames (the window closed) |
| `fn apply(*S, *const Platform) void` | applies a frame's effects: cursor shape, on-screen keyboard and IME rectangle, clipboard |
| `fn present(*S, *const Output) void` | draws `out.draw` with the shell's back end and shows it |
| `fn wait(*S, seconds: f32, pace: Pace) void` | blocks until the next event or `seconds` (`inf`: until an event); `pace` says why |
| `fn wake(*S) void` | thread-safe: ends a `wait` in progress and makes the next `poll` give a frame |

`Events` is the `Input` the core reads plus two things only some widgets read: the IME's
composition and files dragged over the window. Slices in it point into the shell's own buffers
and stay valid until the next `poll`.

## A shell, end to end

This shell's platform is a queue of pretend native events; a real one reads window messages, xcb
or Wayland events, DOM events or a touch controller. It draws with the software back end into a
framebuffer it owns:

```zig
const ToyShell = struct {
    queue: []const Native,
    at: usize = 0,
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},
    /// Room for one frame's glyph quads, and where each text run's start (Mono.quads).
    glyphs: []lcgf.draw_list.Quad,
    first: []u32,
    count: []u32,
    cursor: lcgf.context.Cursor = .arrow,
    presents: u32 = 0,

    /// Drains pending events without blocking. Held state (pointer, buttons, viewport) stays
    /// in `ev.in` from poll to poll; per-frame state would be cleared here.
    pub fn poll(s: *ToyShell, ev: *shell.Events) bool {
        while (s.at < s.queue.len) {
            const e = s.queue[s.at];
            s.at += 1;
            switch (e) {
                .resize => |size| ev.in.viewport = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
                .motion => |p| ev.in.pointer = p,
                .press => ev.in.buttons.left = true,
                .release => ev.in.buttons.left = false,
                .sync => return true,
                .close => return false,
            }
        }
        return false;
    }

    /// The effects a frame asks for: here only the cursor shape.
    pub fn apply(s: *ToyShell, p: *const lcgf.context.Platform) void {
        s.cursor = p.cursor;
    }

    /// Draws the frame with the software back end: text as `Mono` glyph quads on the white
    /// texture (solid cells; a real shell rasterises glyphs, docs/guide/text.md). Custom
    /// commands are skipped: they are the host's.
    pub fn present(s: *ToyShell, out: *const lcgf.context.Output) void {
        s.presents += 1;
        const n = (lcgf.protocol.Mono{}).quads(out.draw, s.glyphs, .{ .first = s.first, .count = s.count });
        s.gfx.prepare({}, out.draw, .{ .quads = s.glyphs[0..n], .first = s.first, .count = s.count }, .{ 0, 0 }, 1);
        s.fb.clear(.rgb(0, 0, 0));
        lcgf.render_iface.render(&s.gfx, .{ .fb = &s.fb, .scissor = s.fb.all() }, out.draw);
    }

    /// Blocks until the next event or `seconds`; the queue is always ready, so it returns.
    pub fn wait(_: *ToyShell, seconds: f32, pace: lcgf.scheduler.Pace) void {
        _ = seconds;
        _ = pace;
    }

    /// Thread-safe in a real shell: makes a `wait` return and the next `poll` give a frame.
    pub fn wake(_: *ToyShell) void {}
};

comptime {
    shell.check(ToyShell);
}
```

`shell_iface.run` is the whole host loop over those five calls. Every shell runs the same
application, `shell_example.App` (the prototype's `buildUi`), so its tests compare like with like:

```zig
var ctx = try Context.init(&ctx_buffer, limits);
var app: lcgf.shell_example.App = .{};
var toy: ToyShell = .{ .queue = &queue, .fb = .init(&pixels, 320, 240, .rgba8), .glyphs = &glyphs, .first = &first, .count = &count };
shell.run(&toy, &ctx, &app); // poll, build when needed, apply, present, wait; until poll is false
```

The test feeds it a resize, a move over the Reset button, a press and a release, and checks that
the click reached the application, the button's pointer cursor reached `apply`, four frames were
presented and the toolbar's colour is in the framebuffer.

## What a real shell adds

- **Keys.** `Input.keys` is a 256-bit set indexed by the platform's scancodes, and `Input.events`
  carries each key transition (`press`, `release`, `repeat`) and each piece of typed text in
  order, with the modifiers. The text a key typed comes from the platform's own keyboard layout
  and IME, as `.text` events, never from the scancode.
- **IME.** When `Platform.wants_text` is set, show the input method or on-screen keyboard at
  `Platform.ime_rect`, laid out for `Platform.purpose` and told the field's text and caret
  (`surrounding`, `selection`) where the platform takes them; report the uncommitted
  composition in `Events.composition` and committed text in `Input.text`.
- **Clipboard.** Put `Platform.clipboard` on the clipboard when it is non-empty; when
  `Platform.paste` is set, type the clipboard's text into a later frame as a `.text` event.
- **Mobile and system state.** `Input.safe_area` is what system bars and cutouts cover,
  `Input.appearance` the dark mode and accent colour, and `Input.redraw` asks for one frame
  after the shell lost its picture (back from the background). All are input: nothing beside
  `poll` and `apply` is called by the host.
- **Scale.** `Input.viewport` is in logical pixels and `Input.scale` is physical pixels per
  logical pixel; the back end draws at `viewport * scale`.
- **Time.** `Input.time` and `Input.dt` drive timers, springs and long presses.
- **Sleeping.** `wait` should block in the platform's event wait (GetMessage, `poll` on the
  display fd, a `wfi` on a microcontroller), so an idle UI costs nothing. `wake` must be safe from
  any thread; a worker that posts a result calls `ctx.waker.post()` and then `wake` (the header of
  `src/shell/iface.zig` shows why both are needed).
- **Recording.** `input.Replay` reads a text recording of frames (`src/shell/testdata/example.replay`
  is the example's); replaying it through a shell is how the shells test their translation
  against the same expectations.

The existing shells are the reference for each kind of platform: `src/shell/x11/` and
`src/shell/win32/` for desktop window systems, `src/shell/web/` for the browser, `src/shell/baremetal/`
for a board with no OS (its header follows LVGL's driver model: flush, input, tick), and
`src/shell/headless.zig` for tests. The part of a shell that calls a platform API
(`src/shell/x11/x11.zig`, `src/shell/win32/win32.zig`) is built as its own module over `lcgf` in
`build.zig` and is not exported from `src/lcgf.zig`, so the core never imports it; the pure parts
(the X11 wire format, the Win32 message translation) are exported and tested with the core.

## A new render back end

A back end is any type with `Queue`, `Pass`, `prepare`, `drawBatch` and `drawText`
(`render_iface.check`). Two rules matter:

- **Full state rebinding.** `drawBatch` and `drawText` set every piece of pass state they depend
  on, on every call, because the host's custom draws between them may have changed anything.
  `render_null.rebindsAfterHost` checks a recorded call stream for it.
- **One shader.** Every GPU back end draws quads with `src/render/shaders/quad.wgsl` plus a
  material function; the translated sources for SPIR-V, MSL, HLSL and GLSL ES are committed in
  `src/render/shaders/gen/` (`ci/run.sh shaders` fails when they are stale), so a new back end
  needs no shader of its own.

`src/render/conformance.zig` has the scenes every back end must draw the same way, with the
expected draw calls and golden images; a new back end passes them before anything else. The
software back end (`src/render/sw/`) needs no GPU at all and is the fallback on any platform with
a framebuffer.
