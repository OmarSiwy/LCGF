# API index

Generated from the sources: every public type with its fields, and every public function and constant with the first sentence of its doc comment. The sources are the definitions; this is the map.

## ui.zig (core, tiers 0 to 2)

### Top level

- `inf = std.math.inf(f32)`
- `none: u32 = 0xffff_ffff`: "No index" for every u32 link in this file.
- `Axis = enum(u1) { x = 0, y = 1 }`
- `Texture = enum(u16) { white = 0, _ }`: Handles the renderer gives out.
- `Material = enum(u16) { solid = 0, _ }`
- `Font = enum(u16) { default = 0, _ }`
- `Role = enum(u8) { none, group, label, button, checkbox, slider, image, text_input }`
- `Span = struct { start: u32 = 0, bytes: u32 = 0 }`
- `Batch = struct { first: u32, count: u32, texture: Texture, material: Material }`
- `Signal = enum(u32) { _ }`
- `Cursor = enum(u8) { arrow, pointer, text, grab, resize_h, resize_v }`
- `root_id = Id.from("ui.root")`
- `fn Cell(comptime T: type) type`: A value paired with its signal.

### `simd` (struct)

- `lanes: comptime_int = std.simd.suggestVectorLength(f32) orelse 4`: f32/u32 lanes per vector on the build target (8 with AVX2, 4 with SSE2/NEON).
- `F = @Vector(lanes, f32)`
- `U = @Vector(lanes, u32)`
- `B = @Vector(lanes, bool)`
- `Bytes = @Vector(lanes, u8)`
- `Mask = @Int(.unsigned, lanes)`: One bit per lane.
- `iota: U = std.simd.iota(u32, lanes)`
- `fn padded(n: usize) usize`: Rows are rounded up to whole vectors so batch loops need no scalar tail.
- `fn loadF(col: []const f32, i: usize) F`
- `fn storeF(col: []f32, i: usize, v: F) void`
- `fn loadU(col: []const u32, i: usize) U`
- `fn storeU(col: []u32, i: usize, v: U) void`
- `fn f(x: f32) F`
- `fn u(x: u32) U`
- `fn bits(m: B) Mask`
- `fn selU(c: bool, a: u32, b: u32) u32`: `c ? a : b` without a branch.
- `fn selF(c: bool, a: f32, b: f32) f32`: `c ? a : b` without a branch.
- `fn b2f(c: bool) f32`: 1.0 or 0.0, built from the bit pattern so that it stays a mask operation instead of becoming a compare-and-jump.
- `fn andB(a: bool, b: bool) bool`: `a and b` as one bitwise AND, with no short-circuit jump.
- `fn orB(a: bool, b: bool) bool`: `a or b` as one bitwise OR.
- `fn find(col: []const u32, len: u32, needle: u32) u32`: First index of `needle` in `col[0..len]`, or `none`.
- `fn rank(col: []const u32, len: u32, bound: u32) u32`: Number of values in `col[0..len]` that are below `bound`.

### `Id` (enum)
Stable identity of a widget across frames.

- `fn from(comptime name: []const u8) Id`: Compile-time hash of a name: `Id.from("save")`.
- `fn src(comptime loc: std.lang.SourceLocation) Id`: Compile-time hash of a call site: `Id.src(@src())`.
- `fn hash(bytes: []const u8) Id`: Run-time hash, for ids built from data.
- `fn with(self: Id, n: u32) Id`: Derives a child id, for widgets created in a loop: `row_id.with(i)`.

### `Node` (enum)
Index of a node in the current frame's `Tree`.

- `fn ix(n: Node) u32`

### `Color` (struct)
RGBA8, laid out so the bytes in memory are r, g, b, a on little-endian hosts.

Fields: `r`, `g`, `b`, `a`

- `transparent: Color = .{}`
- `white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }`
- `black: Color = .{ .a = 255 }`
- `fn rgb(r: u8, g: u8, b: u8) Color`
- `fn rgba(r: u8, g: u8, b: u8, a: u8) Color`
- `fn hex(v: u32) Color`: 0xRRGGBBAA
- `fn bitsOf(c: Color) u32`

### `Rect` (struct)

Fields: `x0`, `y0`, `x1`, `y1`

- `fn w(r: Rect) f32`
- `fn h(r: Rect) f32`
- `fn array(r: Rect) [4]f32`
- `fn intersect(a: Rect, b: Rect) Rect`: Stored as (x0, y0, -x1, -y1), the intersection of two rects is one @max.
- `fn contains(r: Rect, x: f32, y: f32) bool`

### `Size` (struct)
How a node is sized along one axis.

Fields: `kind`, `v`

- `Kind = enum(u8) { fit, px, grow, pct }`
- `fit: Size = .{}`: As large as the content.
- `fill: Size = .{ .kind = .grow, .v = 1 }`: Take all free space (weight 1).
- `fn px(v: f32) Size`: Exactly `v` pixels.
- `fn grow(weight: f32) Size`: A share of the parent's free space on its main axis; stretch on its cross axis.
- `fn pct(fraction: f32) Size`: A fraction (0..1) of the parent's inner size.

### `Sense` (struct)
What kinds of pointer interaction a node takes part in.

Fields: `hover`, `click`, `drag`, `focus`

- `button: Sense = .{ .hover = true, .click = true, .focus = true }`
- `any: Sense = .{ .hover = true, .click = true, .drag = true, .focus = true }`

### `Response` (struct)
Result of `Frame.interact`.

Fields: `hovered`, `held`, `pressed`, `released`, `clicked`, `focused`


### `Style` (struct)
Everything a node can be told at creation.

Fields: `dir`, `size`, `min`, `max`, `pad`, `gap`, `main`, `cross`, `shrink`, `float`, `offset`, `clip`, `scroll`, `fill`, `border_color`, `border`, `radius`, `texture`, `material`, `params`, `role`, `value`


### `TextStyle` (struct)

Fields: `px`, `color`, `font`, `wrap`


### `mem` (struct)

- `column_align = 64`: Each column starts on its own cache line.
- `fn copyRows(comptime S: type, dst: *const S, dst_at: usize, src: *const S, src_at: usize, n: usize) void`: Copies rows [src_at, src_at + n) of every column in `src` to rows starting at `dst_at` in `dst`.

### `mem.Carver` (struct)
Bump pointer over a caller-owned buffer.

Fields: `buf`, `off`

- `fn slice(c: *Carver, comptime T: type, n: usize) []T`
- `fn columns(c: *Carver, comptime S: type, n: usize) S`: Fills a struct whose fields are `[]T` or `[k][]T` with zeroed columns of `n` rows each.

### `Input` (struct)

Fields: `time`, `dt`, `viewport`, `scale`, `pointer`, `buttons`, `wheel`, `mods`, `keys`, `text`

- `Buttons = packed struct(u8) { left: bool = false, right: bool = false, middle: bool = false, _: u5 = 0 }`
- `Mods = packed struct(u8) { shift: bool = false, ctrl: bool = false, alt: bool = false, cmd: bool = false, _: u4 = 0 }`
- `fn stamp(in: *const Input) u64`: Fingerprint of everything except the clock.

### `Input.Keys` (struct)
256 key states as a bit set.

Fields: `bits`

- `fn press(k: *Keys, code: u8) void`
- `fn down(k: *const Keys, code: u8) bool`

### `Look` (struct)
How a node is painted.

Fields: `fill`, `border_color`, `border`, `radius`, `params`, `texture`, `material`


### `Tree` (struct)

Fields: `len`, `cap`, `overflow`, `c`

- `fn rows(cap: u32) usize`: Rows allocated for `cap` nodes: whole vectors plus one spare, so batch passes may read and write one vector past `len`.
- `fn init(carver: *mem.Carver, cap: u32) Tree`
- `fn reset(t: *Tree) void`
- `fn push(t: *Tree, parent: u32, id: Id, s: *const Style) u32`: Appends a node as the last child of `parent` and returns its row.
- `fn seal(t: *Tree, i: u32) void`: Closes node `i`: everything pushed since belongs to its subtree.
- `fn rect(t: *const Tree, i: u32) Rect`
- `fn find(t: *const Tree, id: Id) u32`: Row of the node with `id`, or `none`.

### `Tree.Columns` (struct)

Fields: `id`, `parent`, `end`, `min`, `max`, `grow`, `pct`, `pad_lo`, `pad_hi`, `offset`, `scroll`, `gap`, `nkids`, `flow`, `shrink`, `align_main`, `align_cross`, `main`, `fit`, `nat`, `grow_sum`, `grow_inv`, `used`, `gap_total`, `cursor`, `size`, `pos`, `rect`, `vis`, `child_clip`, `visible`, `clips`, `sense`, `look`, `role`, `value`, `text`, `custom`


### `Strings` (struct)
Frame-lifetime byte storage for text, so callers may pass temporaries.

Fields: `buf`, `len`, `overflow`

- `fn add(s: *Strings, bytes: []const u8) Span`
- `fn get(s: *const Strings, span: Span) []const u8`

### `Texts` (struct)

Fields: `len`, `cap`, `overflow`, `c`

- `fn init(carver: *mem.Carver, cap: u32) Texts`
- `fn reset(tx: *Texts) void`
- `fn push(tx: *Texts, node: u32, span: Span, ts: *const TextStyle) u32`

### `Texts.Columns` (struct)

Fields: `node`, `start`, `bytes`, `px`, `color`, `font`, `wrap`, `w`, `h`, `avail`


### `Customs` (struct)

Fields: `len`, `cap`, `overflow`, `c`

- `fn init(carver: *mem.Carver, cap: u32) Customs`
- `fn reset(cu: *Customs) void`
- `fn push(cu: *Customs, node: u32, id: Id, data: u64) u32`

### `Customs.Columns` (struct)

Fields: `node`, `id`, `data`


### `layout` (struct)

- `fn prepare(t: *Tree) void`: SIMD.
- `fn applyText(t: *Tree, tx: *const Texts, axis: Axis) void`: Scatters measured text extents into their leaf nodes for one axis.
- `fn fit(t: *Tree, axis: Axis) void`: Bottom-up: natural size of every node on one axis.
- `fn resolve(t: *Tree, axis: Axis, viewport: f32) void`: Top-down: final size of every node on one axis.
- `fn textAvail(t: *const Tree, tx: *Texts) void`: Gathers the width layout gave each text run.
- `fn place(t: *Tree) void`: Top-down: position of every node on both axes.
- `fn finalize(t: *Tree) void`: Pixel-snapped rects (SIMD), then clip rects and visibility (one forward sweep with a 4-lane op per node).
- `fn run(t: *Tree, tx: *Texts, viewport: [2]f32) void`: Diagonal: every pass in order, for text that does not wrap (or whose `w`/`h` the caller has already settled).

### `hit` (struct)

- `fn at(t: *const Tree, x: f32, y: f32, want: Sense) u32`: Topmost node under (x, y) that takes part in any interaction in `want`, or `none`.

### `Interaction` (struct)

Fields: `hot`, `active`, `focus`, `pressed`, `released`, `clicked`, `hot_node`, `active_node`, `pointer`, `delta`, `buttons`

- `fn step(s: *Interaction, prev: *const Tree, in: *const Input) void`: Advances by one frame, from last frame's geometry and this frame's pointer.
- `fn response(s: *const Interaction, id: Id) Response`: What happened to widget `id` this frame.

### `Quad` (struct)
One instance of the quad pipeline.

Fields: `rect`, `clip`, `params`, `uv`, `fill`, `border_color`, `radius`, `border`


### `TextRun` (struct)

Fields: `rect`, `clip`, `start`, `bytes`, `px`, `color`, `font`


### `CustomDraw` (struct)

Fields: `rect`, `clip`, `data`, `id`, `node`


### `Cmd` (union)
One step for the renderer, in paint order.

Fields: `quads`, `text`, `custom`


### `DrawList` (struct)

Fields: `quads`, `quad_len`, `runs`, `run_len`, `customs`, `custom_len`, `strings`, `cmd`, `cmd_len`, `op`

- `Kind = enum(u8) { quads, text, custom }`
- `CmdColumns = struct { kind: []u8, first: []u32, count: []u32, key: []u32 }`
- `fn init(carver: *mem.Carver, nodes: u32, texts: u32, customs: u32) DrawList`
- `fn command(d: *const DrawList, i: u32) Cmd`
- `fn quadBytes(d: *const DrawList) []const u8`: The instance data, ready for one buffer write.

### `paint` (struct)

- `fn emit(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, d: *DrawList) void`: Tree and side lists in, draw list out.

### `fonts.Mono` (struct)

Fields: `advance`, `line`

- `Glyphs = struct { first: []u32, count: []u32 }`: Where glyph quads for run k landed in the output of `quads`.
- `fn measure(font: Mono, tx: *Texts) void`: SIMD.
- `fn wrap(font: Mono, tx: *Texts) void`: SIMD.
- `fn quads(font: Mono, d: *const DrawList, out: []Quad, glyphs: Glyphs) u32`: Expands text runs into glyph quads for a 16x16 byte-indexed atlas.

### `Spring` (struct)

Fields: `stiffness`, `damping`


### `Anims` (struct)

Fields: `len`, `cap`, `c`

- `fn init(carver: *mem.Carver, cap: u32) Anims`
- `fn slot(a: *Anims, id: Id, initial: f32) u32`: Row for `id`, created resting at `initial` on first use.
- `fn step(a: *Anims, dt: f32) f32`: SIMD.
- `fn sweep(a: *Anims, frame: u32) void`: Drops springs nobody asked for in frame `frame`.

### `Anims.Columns` (struct)

Fields: `id`, `x`, `v`, `target`, `stiffness`, `damping`, `seen`


### `Signals` (struct)

Fields: `version`, `len`, `cap`, `dirty`

- `fn init(carver: *mem.Carver, cap: u32) Signals`
- `fn create(s: *Signals) Signal`
- `fn bump(s: *Signals, sig: Signal, changed: bool) void`: Records that the data behind `sig` changed (or did not: `changed` is folded in arithmetically, so callers need no `if`).
- `fn touch(s: *Signals, sig: Signal) void`
- `fn stamp(s: *const Signals, deps: []const Signal) u64`: Fingerprint of a dependency list at its current versions.

### `Cell(..)` (generic struct)
A value paired with its signal.

Fields: `value`, `signal`

- `fn init(signals: *Signals, value: T) Self`
- `fn get(self: *const Self) T`
- `fn set(self: *Self, signals: *Signals, value: T) void`

### `Memos` (struct)
One row per memoized subtree.

Fields: `len`, `cap`, `c`

- `fn init(carver: *mem.Carver, cap: u32) Memos`

### `Memos.Columns` (struct)

Fields: `id`, `node`, `frame`, `stamp`


### `Platform` (struct)

Fields: `cursor`, `wants_text`, `ime_rect`, `clipboard`


### `Status` (struct)
Capacity problems this frame.

Fields: `nodes`, `texts`, `customs`, `strings`, `depth`

- `fn ok(s: Status) bool`

### `Output` (struct)

Fields: `draw`, `tree`, `texts`, `platform`, `status`, `wake`


### `Limits` (struct)

Fields: `nodes`, `texts`, `customs`, `strings`, `anims`, `signals`, `memos`, `depth`


### `Context` (struct)
Everything that outlives a frame.

Fields: `limits`, `trees`, `texts`, `customs`, `strings`, `cur`, `draw`, `anims`, `signals`, `memos`, `stack`, `depth`, `inter`, `platform`, `status`, `frame`, `motion`, `settle`, `last_stamp`

- `fn requiredBytes(limits: Limits) usize`: Bytes `init` needs.
- `fn init(buffer: []align(mem.column_align) u8, limits: Limits) error{BufferTooSmall}!Context`: The buffer is the only memory the library will ever use.
- `fn needsFrame(ctx: *const Context, in: *const Input) bool`: False when a frame built from `in` would be identical to the last one.
- `fn begin(ctx: *Context, in: *const Input) Frame`

### `Frame` (struct)
One frame under construction.

Fields: `ctx`, `in`

- `fn tree(f: *const Frame) *Tree`
- `fn texts(f: *const Frame) *Texts`
- `fn prevTree(f: *const Frame) *const Tree`
- `fn open(f: *Frame, id: Id, style: Style) Node`: Starts a node.
- `fn close(f: *Frame) void`
- `fn leaf(f: *Frame, id: Id, style: Style) Node`: A node with no children.
- `fn text(f: *Frame, str: []const u8, ts: TextStyle) Node`: A text leaf.
- `fn textStyled(f: *Frame, str: []const u8, ts: TextStyle, style: Style) Node`: `text` with full control over the leaf (padding, sizing, background).
- `fn custom(f: *Frame, id: Id, style: Style, data: u64) Node`: Reserves a rect that the caller draws itself.
- `fn interact(f: *Frame, node: Node, sense: Sense) Response`: Makes `node` interactive and reports what happened to it this frame.
- `fn drag(f: *const Frame, id: Id) [2]f32`: Pointer movement this frame while `id` is held; zero otherwise.
- `fn lastRect(f: *const Frame, id: Id) Rect`: Where `id` was laid out last frame.
- `fn heldRect(f: *const Frame) Rect`: Last frame's rect of the widget the pointer is holding.
- `fn setFill(f: *Frame, node: Node, color: Color) void`
- `fn setCursor(f: *Frame, cursor: Cursor, when: bool) void`: Requests `cursor` if `when` holds.
- `fn animate(f: *Frame, id: Id, target: f32, spring: Spring) f32`: A value that eases toward `target` across frames.
- `fn reuse(f: *Frame, id: Id, deps: []const Signal) bool`: Signals-driven skipping.
- `fn end(f: *Frame, font: fonts.Mono) Output`: Diagonal: measure with `font`, lay out, paint.
- `fn finish(f: *Frame) Output`: Paint and bookkeeping only, for callers who ran layout themselves.

### `Theme` (struct)

Fields: `text`, `text_px`, `panel`, `control`, `control_hot`, `control_held`, `accent`, `radius`, `pad`, `gap`


### `widgets` (struct)

- `fn label(f: *Frame, th: *const Theme, str: []const u8) Node`
- `fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response`
- `fn checkbox(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response`
- `fn slider(f: *Frame, th: *const Theme, id: Id, value: *f32, lo: f32, hi: f32) Response`

## ui_wgpu.zig (renderer tier)

### Top level

- `BufferUse = enum { vertex, uniform }`
- `AttrFormat = enum { float32x2, float32x4, unorm8x4 }`
- `Attr = struct { location: u32, offset: u32, format: AttrFormat }`
- `quad_stride: u32 = @sizeOf(ui.Quad)`: Per-instance vertex layout, derived from `ui.Quad` so the two cannot drift.
- `fn Renderer(comptime gpu: type) type`
- `fn shader(comptime material_fn: []const u8) [:0]const u8`: Full quad shader around your `fn material(in: Frag) -> vec4f`.

### `Globals` (struct)
Group 0, binding 0.

Fields: `viewport`, `scale`, `_pad`


### `Binding` (struct)
The functions and types `Renderer(gpu)` uses.

- `types = [_][]const u8{ "Device", "Queue", "RenderPass", "Buffer", "Pipeline", "BindGroup", "TextureView", "Sampler", "TextureFormat" }`
- `functions = [_][]const u8{ "createBuffer", "destroyBuffer", "writeBuffer", "createPipeline", "globalsBindGroup", "textureBindGroup", "setPipeline", "setBindG…`

### `Glyphs` (struct)
Glyph quads for the frame's text runs, produced by `ui.fonts.Mono.quads` or by your own shaper.

Fields: `quads`, `first`, `count`, `texture`


### `Renderer(..)` (generic struct)

Fields: `desc`, `quads`, `glyph_quads`, `globals`, `globals_group`, `pipelines`, `material_count`, `textures`, `texture_count`, `glyphs`

- `max_textures = 64`
- `max_materials = 16`
- `fn init(device: gpu.Device, desc: Desc, white: gpu.TextureView, sampler: gpu.Sampler) Self`: `white` is a 1x1 opaque white texture; it becomes `ui.Texture.white`.
- `fn deinit(self: *Self) void`
- `fn addTexture(self: *Self, device: gpu.Device, view: gpu.TextureView, sampler: gpu.Sampler) ui.Texture`: Texture in: makes a view usable as `Style.texture`.
- `fn addMaterial(self: *Self, device: gpu.Device, wgsl: [:0]const u8) ui.Material`: A quad pipeline with your fragment logic.
- `fn prepare(self: *Self, queue: gpu.Queue, draw: *const ui.DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void`: Uploads the frame: one write per buffer.
- `fn drawBatch(self: *const Self, pass: gpu.RenderPass, batch: ui.Batch) void`: One instanced draw call for a run of quads.
- `fn drawText(self: *const Self, pass: gpu.RenderPass, run: u32) void`: One instanced draw call for a text run's glyphs.
- `fn render(self: *const Self, pass: gpu.RenderPass, draw: *const ui.DrawList) void`: Diagonal: the whole list, skipping custom draws.

### `Renderer(..).Desc` (struct)

Fields: `format`, `sample_count`, `max_quads`, `max_glyphs`


### `Renderer(..).PipelineDesc` (struct)
Plain description the binding turns into a wgpu pipeline.

Fields: `wgsl`, `vertex_entry`, `fragment_entry`, `format`, `sample_count`, `instance_stride`, `attrs`

