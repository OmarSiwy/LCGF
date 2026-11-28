# The text protocol

The core never calls into a font. There is no `measure(node)` hook, no shaper interface and no
re-measure loop that layout drives. Text runs are rows of a side list, `Texts`, and a font is
anything that reads some of its columns and writes others, at two points you sequence. That is
the whole protocol. As the header of `src/text/protocol.zig` explains, a callback per run is an indirect call per row, hides the
loop from SIMD and hands control flow to the framework, while columns let one font measure every
run in one vector loop, let a real shaper run elsewhere or cache by string, and let a test write
the numbers by hand.

Every code block below is a piece of `docs/guide/text.zig`, which `zig build docs` compiles and
runs.

## The columns

`Frame.text(str, style)` copies the bytes into the frame's `Strings` and pushes one row of
`Texts` (`src/core/texts.zig`) linked to its leaf node:

| Column | Written by | Meaning |
|---|---|---|
| `start`, `bytes` | `Frame.text` | the run's bytes in `Strings` |
| `px`, `color`, `font` | `Frame.text`, from `TextStyle` | size in pixels, colour, which font serves it |
| `wrap` | `Frame.text` | 1.0 when the run may wrap |
| `w`, `h` | the fonts | the run's extent in pixels |
| `avail` | `layout.textAvail` | the width layout gave the run |

## The two points

1. **Measure.** After the tree is built and before layout, fill `w` and `h` of every run: its
   single-line extent.
2. **Wrap.** After the widths are resolved, layout has written `avail`. For runs whose `wrap` is
   1.0, rewrite `w` and `h` for that width; layout reads them for the vertical axis.

`Frame.end(font)` does both with a `Mono` (`protocol.Mono`: every byte `advance` ems wide, every
line `line` ems tall). `Mono` is the font that needs no font file: for tests, microcontrollers,
a host with no faces, and the bundled bitmap font that `lcgf_app` falls back to. It is a byte to
a cell, so text past ASCII goes through `Mono.encode` first. Real fonts go in through the text
stack below, and an `lcgf_app` window already does that for you. To put any other font in, run
the passes yourself and call `Frame.finish`, which paints. These are the calls `end` makes when
no subtree is reused:

```zig
const t = f.tree();
const tx = f.texts();
t.seal(0);
mono.measure(tx); // every run, as if all were mono
squares.measure(tx); // then the runs in its font, over what mono wrote
layout.prepare(t);
layout.applyText(t, tx, .x);
layout.fit(t, .x);
layout.resolve(t, .x, in.viewport[0]);
layout.textAvail(t, tx); // the width each run was given
mono.wrap(tx); // re-flow the wrapping runs into it
layout.applyText(t, tx, .y);
layout.fit(t, .y);
layout.resolve(t, .y, in.viewport[1]);
layout.place(t);
layout.finalize(t);
const out = f.finish(); // paint and bookkeeping
```

## A font of your own

Which font a run uses is a column, not a type, so several fonts are several passes over the same
rows, each keeping only the rows whose `font` names it:

```zig
/// A display face whose every byte is a square: 1 em wide, 1 em tall. It serves only the runs
/// whose `font` column names it and leaves every other row as it found it.
const Squares = struct {
    id: types.Font,

    fn measure(font: Squares, tx: *lcgf.texts.Texts) void {
        const c = &tx.c;
        for (0..tx.len) |k| {
            const mine = c.font[k] == @backingInt(font.id);
            const w: f32 = @as(f32, @floatFromInt(c.bytes[k])) * c.px[k];
            c.w[k] = lcgf.simd.selF(mine, w, c.w[k]);
            c.h[k] = lcgf.simd.selF(mine, c.px[k], c.h[k]);
        }
    }
};
```

`Mono.measure` writes every row (a vector loop with no mask), so run `Mono` first and the other
fonts after it. `Mono.wrap` rewrites only the runs whose `wrap` is set and leaves every other row
as measured, so `Squares`, which never wraps, has nothing to do at the second point; a font that
wraps its own runs runs its wrap after `Mono.wrap`.

A run picks its font through `TextStyle.font`:

```zig
const squares: Squares = .{ .id = @fromBackingInt(1) };
const mono: Mono = .{ .advance = 0.5, .line = 1.2 };

var f = ctx.begin(&in);
_ = f.open(.from("page"), .{ .size = .{ .px(100), .fit } });
const title = f.text("LCGF", .{ .px = 20, .font = squares.id });
const body = f.text("twenty-four characters!!", .{ .px = 10, .wrap = true });
f.close();
```

The test checks the result: the title is 80 x 20, and the body's 24 bytes of 5 px wrap into
100 px as two lines of 12 px.

`protocol.MonoParagraphs` is `Mono` with paragraph styles on some runs: line height,
letter and word spacing, a line clamp and an ellipsis from `text_stack.Paragraph`, for the texts
rows it lists. `Frame.endParagraphs` and `spec.paragraph` use it; it rewrites only the listed
rows after Mono's passes, and its `quads(draw, texts, out, glyphs)` places their glyphs by the
same walk, from each run's wrap flag and width in the frame's `Texts`. Its `decorate`
puts their underlines, overlines and line-throughs (`spec.decorated`) into the draw list after
`paint.emit`, as solid quads right after each run's text. Its `spans` give a run several styles
(`protocol.Span`: from a byte on, another size, colour and font), as one paragraph.

The same styled runs reach a real shaper. `protocol.Styled` is the description without the
font (`MonoParagraphs.styled()`), `Stack.style(tx, styled, rows)` writes it into the stack's
paragraph and rich rows (caller-owned `StyledRows`), and `Stack.decorate` paints the decorations
from each run's laid-out lines with the face's metrics. `Frame.endTextStyled(stack, ascent,
styled, rows, rects)` does all three around `endText`; on a comptime page,
`ComptimeUi.frameText(in, .{ .stack = &stack, .ascent = &ascent, .rows = rows, .rects = &rects })`
does the same for the page's styled labels.

## Drawing text

The draw list's `text` commands carry run indices; the glyphs themselves are yours. A back end
takes them as `render_iface.Glyphs`: glyph quads, where run k's start and count are, and the
atlas texture. `Mono.quads` makes them for a 16 x 16 byte-indexed atlas:

```zig
var quads: [64]lcgf.draw_list.Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
const n = mono.quads(out.draw, &quads, .{ .first = &first, .count = &count });
const glyphs: lcgf.render_iface.Glyphs = .{
    .quads = quads[0..n],
    .first = &first,
    .count = &count,
    .texture = @fromBackingInt(2), // the atlas, as the back end registered it
};
// gfx.prepare(queue, out.draw, glyphs, viewport, scale); then each `text` command draws run k
```

## Measuring less

`protocol.Cache` keeps extents across frames, keyed by a hash of the run's bytes, font and size.
It sits around whatever fills `w` and `h`, so an expensive shaper only sees text it has not seen:

```zig
var misses: [limits.texts]u32 = undefined;
const m = cache.lookup(tx, strings, &misses); // hits get w, h; misses are listed
for (misses[0..m]) |k| shape(tx, k); // the expensive part, for unseen runs only
cache.store(tx, strings, misses[0..m]);
```

It is direct-mapped with one entry per slot (a new key evicts the old one) and carved from your
buffer, so it never grows.

## The full text stack

The package has a real text stack built on the same two points. Each part is tier 0, works on
columns you own, and has its own header:

| Export | File | What it does |
|---|---|---|
| `opentype` | `src/text/font/opentype.zig` | parses OpenType / TrueType from your bytes; every read is bounds checked |
| `shape` | `src/text/shape/shape.zig` | a simple shaper: cmap, ligatures, kerning, mark attachment, for one left-to-right run of one script |
| `shape_cache` | `src/text/shape/cache.zig` | shaped runs kept across frames |
| `unicode_*` | `src/text/unicode/` | grapheme, word and line breaks, bidi, scripts (UCD 16.0.0) |
| `fallback` | `src/text/fallback/fallback.zig` | splits text into runs of one face and one script from your chain of faces |
| `text_lines`, `text_stack` | `src/text/layout/` | line breaking and placement; `Stack` runs shaping and breaking for every run of `Texts` |
| `raster`, `raster_atlas` | `src/text/raster/` | glyph outlines to 8-bit coverage, packed into an atlas you upload |

`text_stack.Stack` slots into the two points in place of a `Mono`:
`stack.measure(tx, strings, ascent)` and `stack.wrap(tx, strings, ascent)`, where `ascent` is one
row per run (the first baseline below the run's top). Like `Squares` above, it serves only the
runs whose font it has a shaper for. Complex scripts beyond the simple shaper go through the
HarfBuzz adapter in `src/text/shape/` (`zig build harfbuzz`), a module of its own that the core
never imports.

## Text in an `lcgf_app` window

`src/app/text.zig` is the text service the window layer runs: font files in, measured runs and
each frame's glyph quads over one coverage atlas out. It joins the stack above into three calls
(`Text.init`, `Frame.endText` with its stack, `Text.glyphs` at the window's scale), and its
header shows them. A run's `TextStyle.font` k is file k; every face is in every run's fallback
chain, its own first, and on a build that can ask the system (`can_discover`: not a Linux build
without libc) `cover` adds a system face for a character no face has. Glyph images are
rasterised at physical pixels and keep their place in the atlas while it lives, so only new
glyphs change texels. Every table is carved from your buffer (`Text.requiredBytes`).

`lcgf_app` runs it for you (`Options.fonts`, `Options.text`; see [runtime.md](runtime.md), "A
window in one call"). A host with its own loop can run it the same way.

Canvas labels (`Frame.canvas`) that must stay sharp under any camera zoom take their glyphs from
`text.labels` (`src/app/labels.zig`): it shapes a label with the service's faces and appends
canvas glyph rows that sample a distance atlas (`bit.distance` in `src/draw/canvas.zig`), each
glyph's image made once. A back end reads that atlas through `Glyphs.canvas`. In an
`lcgf_app` window, give the `App` a field `labels: lcgf_app.Labels` and the window hands it the
service and an atlas (`Options.labels`) before the first `build`, and draws the canvas glyphs
from that atlas ([runtime.md](runtime.md), "A window in one call"). Without the field, or on
the bitmap font, canvas glyphs sample the bundled font's cells (`Instances.glyphs`).
`bench/micro/canvastext.zig` measures the choice of distance images over rasterising again at
each zoom.
