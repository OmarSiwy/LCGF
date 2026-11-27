# The runtime front end

The runtime front end rebuilds the tree every frame from your own data: you call `open`,
`leaf`, `text` and `close` on a `Frame`, and the layout and paint passes turn it into a
`DrawList`. Use it for any UI whose shape depends on data; the comptime front end
(`docs/guide/comptime.md`) is for UIs whose shape is fixed when you compile.

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
chosen from the target and the environment, with the shells' loop above and text from the
bundled bitmap font. In build.zig, `lcgf.addApp(b, dep, .{ .name = "hello", .root_source_file
= b.path("main.zig"), .target = target, .optimize = optimize })` gives the executable the
`lcgf_app` module with the shells its target needs. examples/app/main.zig is a whole program;
`zig build app-example -Dtarget=x86_64-windows` builds it for Windows from anywhere. The web,
Android and iOS start an application their own way: see their shells' examples.

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
src/widgets/dock.zig does against the same page built all at run time. bench/scenes/data.zig
times a 450-node table of all 25 kinds (`data`, `data-idle`) and the same table in a comptime
page's region (`mixed`).
