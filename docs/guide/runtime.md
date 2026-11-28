# The runtime front end

The runtime front end rebuilds the tree every frame from your own data: you call `open`,
`leaf`, `text` and `close` on a `Frame`, and the layout and paint passes turn it into a
`DrawList`. Use it for any UI whose shape depends on data; the comptime front end
(`docs/guide/comptime.md`) is for UIs whose shape is fixed when you compile.

To write a desktop application, run your `build` through `lcgf_app.run` (`lcgf.addApp` in
build.zig) and leave `-Drender` at its default ("A window in one call" below). `lcgf_app` draws
on the GPU where it has a window for it and falls back to software by itself, so your code
names no back end. The rest of this page is what it runs, and what a host that owns its loop
calls itself.

Every code block below is a piece of `docs/guide/runtime.zig`, which `zig build docs` compiles
and runs. The example builds a toolbar through the production package. It follows the original `buildUi` fixture. [Archived example](https://github.com/OmarSiwy/LCGF/blob/b6c1319/prototype/example.zig)

| File | What it gives you |
|---|---|
| `src/runtime/context.zig` (`lcgf.context`) | `Context` (what outlives a frame), `Limits`, `Output`, `Platform`, `Status` |
| `src/runtime/frame.zig` (`lcgf.frame`) | `Frame`: building, input queries, `end` |
| `src/runtime/signals.zig` (`lcgf.runtime_signals`) | `Signals`, `Cell`, `Derived`, `Effect` |
| `src/runtime/reuse.zig` (`lcgf.reuse`) | `Frame.reuse`: skip subtrees whose signals did not change |
| `src/runtime/scheduler.zig` (`lcgf.scheduler`) | `needsFrame`, `wake`, `Pace`, timers |
| `src/widgets/` (`lcgf.widgets_*`) | ready widgets, each a function over `Frame` |

## Memory: one buffer, sized by you

Every capacity is a field of `Limits`, and `Context.requiredBytes` gives the bytes they take. It
runs at compile time, so the buffer can be static:

```zig
const Context = lcgf.context.Context;
const limits: lcgf.context.Limits = .{ .nodes = 256, .texts = 64, .customs = 4 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
```

`Context.init` carves every column from that buffer and never allocates again; a buffer that is
too short is `error.BufferTooSmall`. Running out of a limit during a frame is not fatal: nothing
is written out of bounds, and the frame's `Output.status` says which limit was hit
(`status.ok()` is true when none was).

```zig
var ctx = try Context.init(&buffer, limits);
var app: App = .{ .layers = .init(&ctx.signals, 3) };
var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
```

## Building a frame

The UI is a function of your state. Containers are `open` ... `close`; ids are hashed names
(`Id.from("reset")`, or `.from("reset")` where the type is known), and the widgets in
`lcgf.widgets_*` are functions that build a few nodes and return what input did to them:

```zig
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const w = lcgf.widgets_base;

const App = struct {
    theme: w.Theme = .default,
    resets: u32 = 0,
    wireframe: bool = false,
    exposure: f32 = 1,
    layers: lcgf.runtime_signals.Cell(u32),
    sidebar_builds: u32 = 0,

    fn build(app: *App, f: *Frame) void {
        const th = &app.theme;
        _ = f.open(.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .fill = th.panel });
        if (w.button(f, th, .from("reset"), "Reset").clicked) app.resets += 1;
        _ = w.checkbox(f, th, .from("wire"), &app.wireframe, "Wireframe");
        _ = w.slider(f, th, .from("exposure"), &app.exposure, 0, 4);
        f.close();

        _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        // Rebuilt only when `layers` changes or the pointer is on one of its widgets.
        if (!f.reuse(.from("sidebar"), &.{app.layers.signal})) {
            app.sidebar_builds += 1;
            _ = f.open(.from("sidebar"), .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4 });
            var name: [24]u8 = undefined;
            for (0..app.layers.get()) |i| {
                _ = w.label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
            }
            f.close();
        }
        // The UI only reserves this rect; the host draws into it.
        _ = f.custom(.from("viewport"), .{ .size = .{ .fill, .fill } }, 0);
        f.close();
    }
};
```

State lives in `App`, not in the widgets: the checkbox writes `app.wireframe` through its
pointer, and the button's click is a field of the `Response` it returns. Text is copied into the
frame, so a temporary such as the `bufPrint` result above is fine.

`f.custom` reserves a rectangle that you draw yourself. It comes back in the draw list as a
`custom` command, in paint order, carrying the `u64` you passed.

## The loop is yours

There is no framework loop and nothing calls you back. Each turn of your loop fills an `Input`
(a shell does it from window events, or a test does it by hand) and builds a frame only when one
is needed:

```zig
if (ctx.needsFrame(&in)) {
    var f = ctx.begin(&in);
    app.build(&f);
    out = f.end(.{}); // measure with the built-in monospace font, lay out, paint
    frames += 1;

    for (0..out.draw.cmd_len) |i| switch (out.draw.command(@intCast(i))) {
        .quads => |batch| _ = batch, // renderer.drawBatch(pass, batch)
        .text => |run| _ = run, // renderer.drawText(pass, run)
        .canvas => |k| _ = k, // renderer.drawCanvas(pass, k), on back ends with one
        .custom => |k| { // your own pipeline, in paint order
            customs += 1;
            viewport = out.draw.customs[k].rect;
        },
    };
}
```

- `begin` steps interaction against last frame's geometry, so a widget's `Response` this frame
  answers for the rectangles it had last frame.
- `end` takes a `Mono` font, measures text, runs the layout passes and paints. Its body is a list
  of public tier-0 calls; copy it to put your own shaper or pass between two of them, and call
  `finish` to paint.
- `Output` is data: the draw list, the laid-out tree (also what an accessibility bridge reads),
  `platform` (cursor, IME rectangle, clipboard request), `wake` (seconds until a frame is due
  without input: 0 now, `inf` sleep until the next event) and `pace` (why).

After input changes, one settle frame follows; then `needsFrame` is false and `wake` is `inf`, and
the host can block on its event queue. The test in `docs/guide/runtime.zig` builds two frames
over three turns of the loop above and checks that.

## Signals and reuse

A `Cell(T)` is a value with a signal. Setting it to a different value bumps the signal and wakes
the host:

```zig
app.layers.set(&ctx.signals, 5); // wakes the host: needsFrame is now true
```

`f.reuse(id, deps)` returns true when the subtree rooted at `id` can be copied from last frame:
no dependency changed, the pointer is not over it or holding something in it, and nothing in it
animates. The caller then skips building it. Otherwise it returns false and the caller builds the
subtree, whose root must carry the same id. In the example the sidebar is built once and then
copied until `layers` changes. `Derived(T)` and `Effect` in `lcgf.runtime_signals` cover values
computed from signals and work that is due once per frame in which an input changed.

Neither needs setting up: `count: Cell(i32) = .of(0)` and `doubled: Derived(i32) = .of(0)` are
field defaults, and a signal is created by its cell's first change (a dependency list holding one
not created yet reads it as version 0). `doubled.update(sig, &.{count.signal}, double, .{n})`
names the inputs once and calls `double` on the first update and then only after an input
changed; examples/counter uses it.

## The widget kit

`lcgf.widgets.on(f, th)` holds the frame and the theme for the common widgets, each with its
options by name; an id is an enum literal (or an `Id` made at run time). `ui.text` and
`f.textf` format straight into the frame's strings (`std.fmt`), so no buffer of yours is needed.
State needs no setting up either, and `animate` moves a `Rect` as it moves an f32:

```zig
const Mixer = struct {
    theme: w.Theme = .default,
    gain: f32 = 1,
    count: lcgf.runtime_signals.Cell(u32) = .of(0),
    doubled: lcgf.runtime_signals.Derived(u32) = .of(0),
    box: lcgf.types.Rect = .{ .x1 = 40, .y1 = 10 },

    fn build(app: *Mixer, f: *Frame) void {
        const sig = &f.ctx.signals;
        const ui = lcgf.widgets.on(f, &app.theme);
        if (ui.button(.add, .{ .label = "Add" }).clicked) app.count.set(sig, app.count.get() + 1);
        _ = ui.slider(.gain, &app.gain, .{ .min = 0, .max = 4 });
        const twice = app.doubled.update(sig, &.{app.count.signal}, double, .{app.count.get()});
        _ = ui.text("{d} added, {d} doubled, gain {d:.1}", .{ app.count.get(), twice, app.gain });
        // Any value made of numbers moves on springs, one per number.
        const r = f.animate(.from("box"), app.box, .{});
        _ = f.leaf(.from("swatch"), .{ .size = .{ .px(r.x1 - r.x0), .px(r.y1 - r.y0) }, .fill = th_accent });
    }
```

The kit adds no behaviour: `ui.button(.add, .{ .label = "Add" })` is
`widgets_button.button(f, th, .from("add"), "Add")`, and the positional functions stay.

## A window in one call

`lcgf_app.run(App, &app, init, .{ .title = "Hello" })` opens a desktop window and runs `App`'s
`build` in it until it closes: Wayland or X11 on Linux, Win32, or AppKit with Metal on macOS,
chosen from the target and the environment, with the shells' loop above. In build.zig,
`lcgf.addApp(b, dep, .{ .name = "hello", .root_source_file = b.path("main.zig"), .target =
target, .optimize = optimize })` gives the executable the `lcgf_app` module with the shells its
target needs, in your package as in LCGF's own. examples/app is a whole application as a
package of its own: its build.zig takes LCGF as a dependency with the back end left at its
default and calls `addApp`. From the checkout root, `zig build app-example
-Dtarget=x86_64-windows` builds it for Windows from anywhere. Every desktop example in
[examples/](../../examples/README.md) is written the same way. The web, Android and iOS start an
application their own way: see their shells' examples.

Leave `-Drender` at its default for an application. `-Drender=sw` is for microcontrollers,
for machines that must not load a GPU driver, and for the smallest static binary; it is not the
starting point for a desktop application. What you draw names no back end either: no
`render_sw` type in application code. Images go through `lcgf_app.Image`, a widget you draw
yourself through `Surface`, and 2D primitives through `Frame.canvas`.

- **Text** is drawn in real fonts at the window's scale (src/app/text.zig): the files of
  `Options.fonts` (`.fonts = &.{.{ .bytes = @embedFile("Inter.ttf") }}`, font k the k-th), else
  the system's default faces where the build can ask for them (not a Linux build without
  libc), else, and on macOS for now, the bundled bitmap font. `Options.text` sizes the service
  ([text.md](text.md), "Text in an `lcgf_app` window").
- **Images**: an `App` with `pub fn images(*App) []const lcgf_app.Image` has image k drawn by
  `Style.texture` k + 1 (at most `images_max`). An image is straight RGBA8 `pixels`, or
  `alpha`, one coverage byte a texel (an icon), read as white with that alpha so the node's
  `fill` colours it; a size; and a `generation` you change when the texels do, in a frame you
  ask for (`build` changes it, or you post `ctx.waker`). A new generation redraws only the nodes that show the image; a change in the
  number of images or an image's size redraws the whole window, and so does, on the GPU, a new
  generation in a frame with no `build` (a surface's). macOS does not draw images yet.
- **Canvases**: `Frame.canvas` draws many 2D rows (segments, rects, arcs, polygons, glyphs)
  under a camera, the same on every back end. A row has its own colour or its layer's, from an
  optional palette; the header of src/draw/canvas.zig describes the rows and their limits. On
  the GPU window a changed row uploads 36 bytes. `Options.canvas` sizes
  the instance buffers (`rows`, `verts`, 4096 each by default); past them a canvas draws short.
  The software windows take any number.
- **Canvas labels**: an `App` with a field `labels: lcgf_app.Labels` gets, before its first
  `build`, what makes canvas labels in the window's fonts, sharp at any zoom
  (`app.labels.label(&shapes, str, .{ .origin, .px })`; `Options.labels` sizes the atlas).
  When the atlas fills, `label` fails with `error.Full` and `generation` moves on: make every
  label again. On the bitmap font it fails with `error.Unavailable`. The header of
  src/app/app.zig shows the loop ([text.md](text.md), "Text in an `lcgf_app` window").
- **A page of your own**: an `App` whose window is a compiled page (`ComptimeUi`) with the
  runtime frame in one region has both `pub fn page(*App, *const Input, lcgf_app.PageText)
  [4]f32`, which lays the page out and returns the region, and `pub fn compose(*App, *const
  Output) lcgf_app.Composed`, which returns the composed list (`ct_interop.compose`) and each
  side's text rows. The frame is built in the region's coordinates; the window draws and
  uploads only the union of both sides' damage. `run`'s doc comment has the two functions.
- **Damage** is on: the window keeps last frame's pixels and redraws only what changed
  (`Context.trackDamage` on the software window, `trackDamageWhole` on the GPU one); macOS
  draws every frame whole. An idle window presents nothing.
- **The GPU**: a Vulkan build on Linux draws the window with Vulkan over X11, and an `App`
  with `pub fn draw` draws its own `Surface`s there ([surface.md](surface.md)).
  `LCGF_RENDER=sw`, no `DISPLAY`, an X server that cannot be reached or no Vulkan device
  gives the software window, where every `App` runs and `Surface.live()` is false
  ([backends.md](backends.md), "When you bring no device").

### Which window, and running under a test

On Windows `run` opens a Win32 window and on macOS an AppKit one. On Linux it reads the
environment:

- **A Vulkan build** (the default), unless `LCGF_RENDER` is `sw`, opens a native Wayland
  window with Vulkan when `WAYLAND_DISPLAY` is set and not empty, then X11 with Vulkan when
  `DISPLAY` is. Each falls through to the next when it cannot open (no compositor or X server
  there, no dma-buf the compositor takes, no Vulkan device), and the last to the software
  path below. With `LCGF_RENDER=sw`, or neither set, it takes the software path at once.
- **The software path** (and every `-Drender=sw` build) opens Wayland when `WAYLAND_DISPLAY`
  is set and not empty, and X11 on `DISPLAY` only when it is not, or when the compositor
  cannot be reached and `DISPLAY` is set. If neither can be reached, `run` returns the error.

So a test that runs a program on an Xvfb sets `DISPLAY` to it and unsets `WAYLAND_DISPLAY`
(or sets it empty): otherwise a software window opens on the session's compositor.
`ci/jobs/app.sh` runs examples/app that way: `DISPLAY=:N XAUTHORITY=/dev/null
WAYLAND_DISPLAY= LCGF_APP_SECONDS=1 zig-out/bin/app-example`. `LCGF_APP_SECONDS` closes the
window after that many seconds and `run` returns; without it, or if it is not a number, the
window stays open until it is closed.

### Testing it without a window

The `App` you give `run` is a plain struct, so a test drives it with no window at all.
`lcgf_app.replay` (src/app/replay.zig) plays a recording (`input.Replay`: `frame`,
`viewport 800 600`, `scale 2`, `pointer x y`, `buttons left`, `text abc`) into it through the
frame path `run` takes on a software window, the same code: `build`, or `page`, `build` and
`compose` for a composing App, its `images`, its canvases (an `lcgf_app.Canvas` too), and its
canvas labels when the replay has font files. Each frame is drawn by the software back end
into a framebuffer that keeps the last frame's pixels, as a window does.

- `replay.run(&app, recording)` plays at 800 x 600, scale 1, in the bundled bitmap font;
  `replay.runWith(&app, recording, .{ .size = .{ 300, 200 }, .scale = 2, .fonts = &files })`
  chooses the size, the scale and font files for the text service (never the system's, so a
  replay draws the same on every machine).
- The result gives `rect(id)`, where a node of the last frame is in the window, in the
  coordinates of the recording and of `at`, so a click at `center(rect(id))` hits it, a
  composing App's region included; `origin`, where that region's corner is; `out`, that
  frame's output (its tree in the frame's own coordinates); `list()`, the list it drew (the
  composed one); `at(x, y)`, a pixel; `frames` and `builds`.
- `replay.draw(&fb, list, images, scale, background)` paints a list the test composed itself,
  as a replay would, for pixel parity; `replay.clicks` and `replay.center` write a recording
  that clicks points in turn.

A `Surface` is never live in a replay, so the test sees the software window's path. Since it
is part of `lcgf_app`, an application's build.zig tests the executable's own module:
`b.addTest(.{ .root_module = exe.root_module })`, as every example does.

## A widget of your own

A widget is a function over `Frame`, written with the same calls the built-in widgets use:

```zig
/// A widget is a function over `Frame`: build its nodes, ask what input did to them.
fn swatch(f: *Frame, id: Id, color: *lcgf.types.Color, other: lcgf.types.Color) bool {
    const node = f.leaf(id, .{ .size = .{ .px(24), .px(24) }, .radius = 4, .fill = color.*, .role = .button });
    const r = f.interact(node, .button);
    f.setCursor(.pointer, r.hovered);
    if (r.clicked) color.* = other;
    return r.clicked;
}
```

`interact` needs a node with an id; `Sense` says what it reacts to (`.button` is hover, click and
focus; `.any` adds drag). Other queries: `drag(id)` for movement while dragged, `heldRect()` for
the held widget's last rectangle, `lastRect(id)` for any widget's. Animation is asked for the
same way: `f.animate(id, target, spring)` returns this frame's value of a spring,
`f.tween` an eased value, `f.timer(id, seconds, mode)` whether a timer fired, and each keeps the
host awake only while it moves. `animate` and `tween` move more than f32s: a `Color`, a `Rect`,
`[2]f32`, a vector or any struct of numbers, each component on its own spring or tween
(`f.animate(.from("card"), app.target_rect, .{})`). An argument whose type comes from its result,
such as `@floatFromInt(k)`, needs an `@as(f32, ...)` there.

The header of `src/widgets/base.zig` lists the five parts every built-in widget has (spec, look,
behaviour, accessibility, tests), which is a good checklist for your own.

## Building a frame from data

When the UI itself is data (rows loaded from a file, written by a plugin, or generated by
your own build step), keep it in columns and walk them each frame. `lcgf.widgets_records` is
that walk: a `Table` has one row per node in depth-first order (its kind, its depth, its text
and the index of its look), and `records.build` opens and closes the containers as the depth
moves and calls each kind's widget with the row's look. Row `r`'s id is `base.with(r)`.

```zig
const records = lcgf.widgets_records;
const theme = lcgf.theme;

/// A settings panel as data: one row per node, depth-first, its look an index into `looks`.
const panel: records.Table = .{
    .kind = &.{ .col, .label, .row, .checkbox, .button },
    .depth = &.{ 0, 1, 1, 2, 2 },
    .text = &.{ "", "Display", "", "Grid", "Apply" },
    .look = &.{ 0, 1, 2, 3, 4 },
};

const Settings = struct {
    tokens: lcgf.theme_table.ThemeTable(theme.Tokens) = .{},
    seen: u32 = 0,
    state: records.SceneState(panel.kind.len) = .{},

    fn build(s: *Settings, f: *Frame) void {
        // Styles come from the tokens each frame: a changed token shows on the next one.
        const th = theme.widgets(&s.tokens.values);
        const k = records.kindLooks(&th);
        var looks = [_]records.Look{ k[@backingInt(records.Kind.col)], k[@backingInt(records.Kind.label)], k[@backingInt(records.Kind.row)], k[@backingInt(records.Kind.checkbox)], k[@backingInt(records.Kind.button)] };
        looks[1].text.px = s.tokens.values.textAt(.lg); // the heading
        records.build(f, &th, .from("settings"), panel, &looks, s.state.state());
        s.seen = s.tokens.generation;
    }
};
```

A look is a `Style` and a `TextStyle`, and every widget the walk calls has a `…Face` variant that
takes them from the caller (`listFace`, `tabs.openFace`, `dock.openFace` and so on), so a
widget given its theme's styles draws what its theme function draws. Derive the looks from
tokens (`theme.widgets` turns `theme.Tokens` into a `Theme`; `kindLooks` gives each kind its
theme look) and a token changed at run time shows on the next frame with nothing rebuilt but
the looks. A `ThemeTable` is not a signal, so tell the host it changed:

```zig
    var palette = s.tokens.values.palette;
    palette[@backingInt(theme.Role.surface)] = .rgb(40, 60, 90);
    s.tokens.set(.palette, palette);
    in.redraw = s.tokens.changedSince(s.seen); // the table is not a signal: tell the host
```

The same widgets have comptime forms (`ct.list`, `ct.dock`, `menubar.ct.bar` and the rest),
restyled with `spec.styled` and `spec.textStyled` (or the overlays' `ct.…Face`), which draw the
same frames as their `…Face` twins. A compiled page keeps its fixed parts there and builds the
parts written at run time in `ct_interop` regions (`fitRegion` when the content sizes the
region), as the test "regions in a comptime page's dock and toolbar ..." in
src/widgets/dock.zig does against the same page built all at run time. A region's rect is
snapped to the pixel grid and its content laid out from that corner, so a runtime page that
builds the same content in place calls `layout.snapSubtree` on the content's node between
`layoutWith` and `finish` to paint the same pixels at any origin. bench/scenes/data.zig
times a 450-node table of all 25 kinds (`data`, `data-idle`) and the same table in a comptime
page's region (`mixed`).
