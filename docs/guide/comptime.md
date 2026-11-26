# The comptime front end

A UI whose structure is known when you write it can be a compile-time value. The compiler then
turns it into read-only tables: the parent links, the widget enum, and for every state field the
constant mask of nodes a change to it touches. At run time only the state, the rectangles and the
dirty masks are in RAM.

Every code block below is a piece of `docs/guide/comptime.zig`, which `zig build docs` compiles
and runs. The reference for each name is its doc comment; `zig build docs` also writes the index
of all of them to `zig-out/docs/API.md`.

| File | What it gives you |
|---|---|
| `src/comptime/spec.zig` (`lcgf.spec`) | `Spec` and the builders `col`, `row`, `label`, `checkbox`, `slider`, `named` |
| `src/comptime/validate.zig` (`lcgf.validate`) | `check`: mistakes in a spec become compile errors |
| `src/comptime/flatten.zig` (`lcgf.flatten`) | `Flat(spec)`: the structure as read-only tables |
| `src/comptime/signals.zig` (`lcgf.signals`) | `Signals(State, spec)`: dirty masks, setters, derived fields, effects |
| `src/comptime/events.zig` (`lcgf.events`) | `Events(spec)`: the `Widget` enum, hit testing, pointer and keyboard events |
| `src/widgets/base.zig` (`lcgf.widgets_base`) | `ComptimeUi(State, spec, theme)`: all of the above running the reference widgets, one call per frame |

## State and spec

The state is a plain struct with defaults. The spec is a tree of builder calls; ids and bindings
are enum literals, so a widget is named `.mute` and its field `.muted`.

```zig
const s = lcgf.spec;

const Mixer = struct {
    title: []const u8 = "Mixer",
    volume: f32 = 0.5,
    muted: bool = false,
    pan: f32 = 0,
};

const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.named(s.checkbox(.mute, .muted), "Mute"), s.named(s.slider(.volume, .volume), "Volume") }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.named(s.slider(.pan, .pan), "Pan") }),
});

comptime {
    lcgf.validate.check(Mixer, mixer, .{});
}
```

`col` and `row` take the same `Style` the runtime front end's `Tree.push` takes (`dir` is fixed by
the builder). `validate.check` fails the build on a duplicate id, a binding to a missing field, a
slider bound to anything but `f32` or a checkbox to anything but `bool`, an interactive widget
without an accessible name (turn that off with `.require_names = false`), and, when you pass
`.viewport`, fixed sizes that do not fit the screen. Each message starts with the node's path,
such as `col > row[1] > slider[0]: ...`.

### Options and formatted text

A checkbox's or slider's second argument can be options instead of the field: `.bind` (the id
when left out) and `.name`, the accessible name. A misspelt option is a compile error that
names it. `styled` sets a node's style with the types checked (`size`, `fill`, ...), and `text`
writes fields into a format, so a number needs no string field of its own:

```zig
const Meter = struct { name: []const u8 = "Gain", level: f32 = 0.5, clips: u32 = 0 };

const meter_spec = s.col(.{ .pad = @splat(6), .gap = 4 }, .{
    s.text("{}: {.1} dB, {} clips", .{ .name, .level, .clips }),
    s.styled(s.slider(.level, .{ .name = "Level" }), .{ .size = .{ .px(120), .px(10) } }),
});

comptime {
    lcgf.validate.check(Meter, meter_spec, .{});
}
```

The format has one meaning in every engine (src/core/fmt.zig), Zig's and the C++ and Rust
ones a `.zon` UI compiles to, so their draw lists stay byte for byte the same: `{}` writes a
string, a bool, a u32, a u8 or an enum(u8) as its number; `{.N}` writes an f32 with N decimals,
0 to 6, rounded half away from zero; `{{` and `}}` are braces. A wrong count, an f32 without a
precision or a field of another type fails the build. A change of any argument lays the label
out again (`relayout`), as a change of a bound label's field does.

## What the compiler resolves

`Flat` numbers the nodes depth-first, exactly as `Tree.push` does, so a tier-0 pass cannot tell
a flattened spec from a tree built at run time. The index type is the smallest that fits:

```zig
const F = lcgf.flatten.Flat(mixer);
try testing.expectEqual(8, F.node_count);
try testing.expectEqual(u4, F.Index);
try testing.expectEqualSlices(F.Index, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &F.parent);
try testing.expectEqualSlices(F.Index, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &F.end);
```

`Signals` makes every state field a signal. Which nodes a field affects is a constant, so a setter
is one store and one OR per pass it touches; there is no subscriber list. Masks are split by pass:
a slider keeps its size, so changing its value only repaints it, while a label's text can change
its size, so it is laid out again with its ancestors.

```zig
const S = lcgf.signals.Signals(Mixer, mixer);
var rt: S.Runtime = .{};
_ = rt.takeDirty(); // every node starts dirty: the first frame does everything

rt.set(.volume, 0.9); // a slider keeps its size: repaint it, lay out nothing
var d = rt.takeDirty();
try testing.expectEqual(0, d.layout);
try testing.expectEqual(0b0001_0000, d.paint);

rt.set(.title, "Desk"); // a label's text sizes it: both labels, row 5 and the root
d = rt.takeDirty();
try testing.expectEqual(0b0110_0011, d.layout);
```

The mask is the smallest integer with one bit per node up to 32 nodes, and an array of `u32` words
past that; a setter then ORs only the words its nodes are in.

### Derived fields and effects

A state struct may declare `derived` fields, computed from other fields, and `effects`, named
reactions you run yourself:

```zig
const Channel = struct {
    volume: f32 = 0.5,
    muted: bool = false,
    gain: f32 = 0.5,

    pub const derived = .{ .gain = .{ .from = .{ .volume, .muted }, .compute = gainOf } };
    pub const effects = .{ .save = .{ .volume, .muted }, .meter = .{.gain} };

    fn gainOf(c: *const Channel) f32 {
        return if (c.muted) 0 else c.volume;
    }
};
```

The compiler orders derived fields so every input comes first (a cycle is a compile error), and
`set` recomputes exactly the fields that read the one you set. `stage` and `commit` batch several
changes so each derived field is recomputed once. Effects come back as a generated `Effect` enum:

```zig
var rt: S.Runtime = .{};
rt.stage(.volume, 0.8);
rt.stage(.muted, true);
rt.commit(); // gain is recomputed once for the batch

while (rt.takeEffect()) |e| switch (e) { // forgetting an effect is a compile error
    .save => saves += 1,
    .meter => meter = rt.state.gain,
};
```

### Widgets are an enum

Every node with an id becomes a tag of `Events(spec).Widget`, valued by its row. Handling input
is an exhaustive switch:

```zig
const E = lcgf.events.Events(mixer);
try testing.expectEqual(4, @backingInt(E.Widget.volume)); // the tag's value is its row
const hit: E.Widget = .mute;
const label = switch (hit) { // a widget missing here is a compile error
    .mute => "mute",
    .volume, .pan => "slider",
};
```

`Events` also gives `at` (the widget under a point, from last frame's rectangles), `pointer`
(clicks and drags as an `Event` union whose payload depends on the widget kind), `focus_order` and
`nextFocus` for Tab, and `Shortcuts`, a perfect hash over key chords built at compile time.

## Components are functions

There is no component type. A function that returns a `Spec` is a component, and its parameters
are comptime arguments:

```zig
fn channelRow(comptime mute: @EnumLiteral(), comptime muted: @EnumLiteral(), comptime level: @EnumLiteral()) s.Spec {
    return s.row(.{ .gap = 8 }, .{ s.checkbox(mute, muted), s.slider(level, level) });
}
```

Its nodes flatten exactly like the same nodes written inline.

## Running frames

`ComptimeUi(State, spec, theme)` puts the pieces together for the reference widgets of
`src/widgets/base.zig`. Their builders live in `widgets_base.ct` and take the theme:

```zig
const w = lcgf.widgets_base;
const th: w.Theme = .default;

const Toolbar = struct {
    reset_text: []const u8 = "Reset",
    wireframe: bool = false,
    wire_text: []const u8 = "Wireframe",
    exposure: f32 = 0.25,
};

const toolbar = s.row(.{ .gap = 8 }, .{
    w.ct.button(th, .reset, .reset_text),
    w.ct.checkbox(th, .wire, .wireframe, .wire_text),
    w.ct.slider(th, .exposure, .exposure),
});

const Ui = w.ComptimeUi(Toolbar, toolbar, th);
var ui: Ui = .{}; // the buffer is inside: no allocator, sized by the compiler
```

You own the loop. Each frame, fill an `Input` and call `frame`; it judges the input against last
frame's rectangles, applies each widget's behaviour to the state, then builds, lays out and paints
the frame:

```zig
in.pointer = .{ 5, 5 }; // over the button, which is the first child of the row
in.buttons.left = true;
out = ui.frame(&in); // input is judged against the last frame's rects
in.buttons.left = false;
out = ui.frame(&in); // a click is a press and a release over the widget
if (out.event) |e| switch (e) {
    .reset => resets += 1, // a button's click comes back to the caller
    .wire, .exposure => {}, // checkboxes and sliders have already written their field
};
const draw = out.draw; // hand it to a renderer
```

`out.draw` is the same `DrawList` the runtime front end produces, so every renderer takes it.
`widgets_base.Harness` runs one page through both front ends and fails when their draw lists
differ; the reference toolbar (`widgets_base.Reference`) is tested that way.

### A widget of your own

A node can set `Spec.widget` to a namespace that builds it. `ComptimeUi` then calls its
`push(ui, n, parent, next, in)` instead of building the node from its kind, and its optional
`step(ui, row, event, in)` each frame before building. Two optional declarations shape its
events: `pub const focusable = true` puts it in the Tab order, and `pub const Payload = T` makes
its events carry a `T`. The header of `src/widgets/base.zig` describes the contract, and the
test "Spec.widget: a custom widget's focusable, Payload and step event, end to end" there is a
complete example.

## Limits

- Signal values are run-time; only their identity, type and dependencies are comptime.
- A list of unknown length needs the runtime front end (or a bounded region).
- Changing the UI means recompiling, and compile time grows with the spec. `Flat` and
  `validate.check` raise their own branch quotas, so large specs need nothing from you; the walks
  recurse once per level, and about 2,000 levels is the compiler's stack limit (measured in
  `src/comptime/flatten.zig`).
- `ComptimeUi` keeps 1,024 bytes for strings. `frame` measures labels with the monospace `Mono`
  font. `frameText(in, shaped)` measures them on a real shaper instead: `widgets_base.Shaped`
  holds the caller's `text_stack.Stack`, ascent scratch, and the rows and rects that styled
  labels need, as `Frame.endTextStyled` takes them.

## Choosing a front end

Use a comptime spec when you know the screen's structure while writing the program.
For a settings page, declare the rows and bindings once, then change the bound
values as input arrives. A fixed display size can also reduce the width of stored
coordinates. The 32-node settings example uses 672 bytes for retained columns,
5,472 bytes for layout scratch and 3,275 bytes for constant tables. An exact-capacity
runtime tree for those nodes takes 18,304 bytes. Budget the caller's text storage,
state and draw list in addition to these figures.

Use the runtime front end for a document editor, an inspector for an unknown
schema or a plugin that supplies widget structure at runtime. Size the context
for the largest visible frame and use its usage report to check those limits.
For a long homogeneous list, keep only visible rows in memory. For a fixed
toolbar around an open-ended document, the mixed example (`zig build ct-mixed`)
shows how to host either front end inside the other and route input to its region.

Spec size also affects iteration time. Moving one label between rows took about
32 ms to rebuild at 1,000 nodes and 261 ms at 10,000 nodes on the measured host.
Measure a representative edit before committing a generated screen of that size
to a single spec. The fixture, memory accounting and commands are in the
[front-end budget](../../src/comptime/budget.md).
