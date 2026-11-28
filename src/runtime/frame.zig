//! Frame: one frame under construction in the runtime front end (tier 1). `Context.begin`
//! returns one; the caller builds the tree through it and ends it. Ported from prototype/ui.zig
//! ("Context and Frame").

const Context = @import("context.zig").Context;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Template = @import("../core/tree.zig").Template;
const Texts = @import("../core/texts.zig").Texts;
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Id = types.Id;
const Node = types.Node;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Rect = types.Rect;
const Sense = types.Sense;
const Response = types.Response;
const Color = types.Color;
const none = types.none;
const Output = @import("context.zig").Output;
const Cursor = @import("context.zig").Cursor;
const Mono = @import("../text/protocol.zig").Mono;
const text_stack = @import("../text/layout/stack.zig");
const TextStack = text_stack.Stack;
const protocol = @import("../text/protocol.zig");
const Spring = @import("../anim/anims.zig").Spring;
const Ease = @import("../anim/tweens.zig").Ease;
const values = @import("../anim/values.zig");
const Span = @import("../core/strings.zig").Span;
const Transition = @import("../anim/tweens.zig").Transition;
const keyframes = @import("../anim/keyframes.zig");
const flip = @import("../anim/flip.zig");
const layout = @import("../layout/layout.zig");
const Flex = @import("../layout/flex.zig").Flex;
const FlexOptions = @import("../layout/flex.zig").FlexOptions;
const grid = @import("../layout/grid.zig");
const overlay = @import("../layout/overlay.zig");
const scroll = @import("../layout/scroll.zig");
const rounding = @import("../layout/rounding.zig");
const incremental = @import("../layout/incremental.zig");
const levels = @import("../layout/levels.zig");
const runs = @import("../layout/runs.zig");
/// A size build keeps the one row-by-row copy of each pass.
const by_runs = @import("builtin").mode != .small;
const paint = @import("../draw/paint.zig");
const outlines = @import("../draw/outline.zig");
const scheduler = @import("scheduler.zig");
const canvas_mod = @import("../draw/canvas.zig");

/// `Frame.canvas`'s camera, palette, the instance ranges it draws in order (layers; a
/// selection on top) and the colour overrides (the last whose range holds an instance wins).
pub const CanvasOptions = struct {
    camera: canvas_mod.Camera = .{},
    palette: *const canvas_mod.Palette,
    ranges: []const canvas_mod.Range,
    overrides: []const canvas_mod.Override = &.{},
};

// Ordinary text leaves differ only in whether they may shrink to wrap.
const label_rows = [2]Template{
    .from(&.{ .role = .label }),
    .from(&.{ .role = .label, .shrink = true }),
};

/// One frame under construction. Cheap to copy: two pointers.
const style_call = @import("../core/tree.zig").style_call;

pub const Frame = struct {
    ctx: *Context,
    in: *const Input,

    pub fn tree(f: *const Frame) *Tree {
        return &f.ctx.trees[f.ctx.cur];
    }
    pub fn texts(f: *const Frame) *Texts {
        return &f.ctx.texts[f.ctx.cur];
    }
    pub fn prevTree(f: *const Frame) *const Tree {
        return &f.ctx.trees[f.ctx.cur ^ 1];
    }

    /// Paint an outside ring at this point in the command order. It follows `node` after
    /// layout without reserving space or replacing the control's border/selected appearance.
    pub fn outline(f: *Frame, node: Node, options: outlines.Outline) Node {
        return outlines.append(f.tree(), f.ctx.stack[f.ctx.depth - 1], node, options);
    }

    // ---- building -----------------------------------------------------------

    /// Starts a node. Everything created until the matching `close` is its child.
    pub fn open(f: *Frame, id: Id, style: Style) callconv(style_call) Node {
        const ctx = f.ctx;
        return f.enter(f.tree().push(ctx.stack[ctx.depth - 1], id, &style));
    }

    fn enter(f: *Frame, i: u32) Node {
        const ctx = f.ctx;
        // Too deep: the deepest slot is reused, so the stack is never written out of bounds.
        const d = @min(ctx.depth, ctx.limits.depth - 1);
        ctx.status.depth = simd.orB(ctx.status.depth, ctx.depth >= ctx.limits.depth);
        ctx.stack[d] = i;
        ctx.depth = d + 1;
        return @fromBackingInt(i);
    }

    pub fn close(f: *Frame) void {
        const ctx = f.ctx;
        // Never pops the root, even if calls are unbalanced.
        const d = @max(ctx.depth, 2) - 1;
        f.tree().seal(ctx.stack[d]);
        ctx.depth = d;
    }

    /// A node with no children. Same as `open` then `close`.
    pub fn leaf(f: *Frame, id: Id, style: Style) callconv(style_call) Node {
        const ctx = f.ctx;
        return f.leafNode(f.tree().push(ctx.stack[ctx.depth - 1], id, &style));
    }

    /// `open` from a style already turned into its row (`Template.from`; a `*const Template`
    /// or a `*const FlatRow`): the row is pushed as it is.
    pub fn openRow(f: *Frame, id: Id, row: anytype) Node {
        const ctx = f.ctx;
        return f.enter(f.tree().pushRow(ctx.stack[ctx.depth - 1], id, row));
    }

    /// `leaf` from a row (`openRow`).
    pub fn leafRow(f: *Frame, id: Id, row: anytype) Node {
        const ctx = f.ctx;
        return f.leafNode(f.tree().pushRow(ctx.stack[ctx.depth - 1], id, row));
    }

    /// `finishLeaf(enter(i))` for the usual case, where the stack has room: a leaf's slot is
    /// written and nothing else changes, so the depth is never raised and lowered again. A
    /// full stack takes the slow way and reuses the deepest slot, as `open` does.
    inline fn leafNode(f: *Frame, i: u32) Node {
        const ctx = f.ctx;
        if (ctx.depth >= ctx.limits.depth) {
            @branchHint(.cold);
            return f.finishLeaf(f.enter(i));
        }
        ctx.stack[ctx.depth] = i;
        return @fromBackingInt(i);
    }

    fn finishLeaf(f: *Frame, n: Node) Node {
        // push set the leaf's end when it created the row. Only pop the open slot.
        f.ctx.depth = @max(f.ctx.depth, 2) - 1;
        return n;
    }

    /// A text leaf. The bytes are copied, so `str` may be a temporary.
    pub fn text(f: *Frame, str: []const u8, ts: TextStyle) Node {
        const ctx = f.ctx;
        const i = f.tree().pushRow(ctx.stack[ctx.depth - 1], .none, &label_rows[@intFromBool(ts.wrap)]);
        return f.attachText(f.leafNode(i), str, ts);
    }

    /// A text leaf of `args` formatted by `fmt` (`std.fmt`), written straight into the frame's
    /// strings: `f.textf("Count: {d}", .{n}, ts)`, no buffer of the caller's.
    pub fn textf(f: *Frame, comptime fmt: []const u8, args: anytype, ts: TextStyle) Node {
        const ctx = f.ctx;
        const i = f.tree().pushRow(ctx.stack[ctx.depth - 1], .none, &label_rows[@intFromBool(ts.wrap)]);
        const n = f.leafNode(i);
        const span = ctx.strings[ctx.cur].print(fmt, args);
        f.tree().c.text[n.ix()] = f.texts().push(n.ix(), span, &ts);
        return n;
    }

    /// The free end of the frame's strings, to write text into before `textWritten`: how a
    /// caller with its own formatter puts
    /// formatted text in the frame without a buffer of its own.
    pub fn room(f: *const Frame) []u8 {
        const s = &f.ctx.strings[f.ctx.cur];
        return s.buf[s.len..];
    }

    /// A text leaf over the `n` bytes just written at `room()`, as `text` would push them; `n`
    /// past the room is cut to it, and reported (`Status.strings`).
    pub fn textWritten(f: *Frame, n: usize, ts: TextStyle) Node {
        const ctx = f.ctx;
        const i = f.tree().pushRow(ctx.stack[ctx.depth - 1], .none, &label_rows[@intFromBool(ts.wrap)]);
        const node = f.leafNode(i);
        const s = &ctx.strings[ctx.cur];
        const k: u32 = @intCast(@min(n, s.buf.len - s.len));
        s.overflow = s.overflow or k < n;
        const span: Span = .{ .start = s.len, .bytes = k };
        s.len += k;
        f.tree().c.text[node.ix()] = f.texts().push(node.ix(), span, &ts);
        return node;
    }

    /// `textf` with full control over the leaf, as `textStyled`.
    pub fn textfStyled(f: *Frame, comptime fmt: []const u8, args: anytype, ts: TextStyle, style: Style) Node {
        const n = f.leaf(.none, style);
        const span = f.ctx.strings[f.ctx.cur].print(fmt, args);
        f.tree().c.text[n.ix()] = f.texts().push(n.ix(), span, &ts);
        return n;
    }

    /// `text` with full control over the leaf (padding, sizing, background).
    pub fn textStyled(f: *Frame, str: []const u8, ts: TextStyle, style: Style) Node {
        return f.attachText(f.leaf(.none, style), str, ts);
    }

    fn attachText(f: *Frame, n: Node, str: []const u8, ts: TextStyle) Node {
        const ctx = f.ctx;
        const span = ctx.strings[ctx.cur].add(str);
        f.tree().c.text[n.ix()] = f.texts().push(n.ix(), span, &ts);
        return n;
    }

    /// Reserves a rect that the caller draws itself. It comes back in the draw list as
    /// `Cmd.custom`, in paint order, with `data` attached. Asserts it does not float sized by
    /// a share (`.fill`): it would have no area (`Style.float`).
    pub fn custom(f: *Frame, id: Id, style: Style, data: u64) Node {
        std.debug.assert(!(style.float and (style.size[0].kind == .grow or style.size[1].kind == .grow)));
        const row: Template = .from(&style);
        return f.customRow(id, &row, data);
    }

    /// `custom` from a row (`openRow`).
    pub fn customRow(f: *Frame, id: Id, row: anytype, data: u64) Node {
        const ctx = f.ctx;
        const n = f.leafRow(id, row);
        f.tree().c.custom[n.ix()] = ctx.customs[ctx.cur].push(n.ix(), id, data);
        return n;
    }

    /// A node that draws `o.ranges` of `shapes` under `o.camera` with `o.palette`: a `canvas`
    /// command in paint order, clipped to the node. Needs `Context.enableCanvas`. It is a
    /// custom row, so it takes a `Limits.customs` row, orders, layers and damages like a
    /// custom node; its damage covers the camera, the palette, the ranges, the overrides and
    /// `shapes.revision`, so a pan, a recolour or an edit redraws it; not the batch's address, so
    /// a batch moved in memory does not redraw (bump `revision` when a node switches to another
    /// batch at the same revision). An overlay is a second
    /// canvas node over it (a float) or more ranges. Everything passed is the caller's and
    /// must outlive the frame's drawing, and a subtree `reuse` keeps draws it again as it was.
    pub fn canvas(f: *Frame, id: Id, style: Style, shapes: *const canvas_mod.Instances, o: CanvasOptions) Node {
        const ctx = f.ctx;
        std.debug.assert(ctx.canvas_hook != null);
        const view = extern struct { origin: [2]i64, scale: f32, offset: [2]f32, zoom: f32, revision: u32, len: u32, verts: u32, zoom_scale: u32 }{
            .origin = o.camera.origin,
            .scale = o.camera.scale,
            .offset = o.camera.offset,
            .zoom = o.camera.zoom,
            .zoom_scale = @intFromBool(o.palette.zoom_scale),
            .revision = shapes.revision,
            .len = shapes.len,
            .verts = shapes.vert_len,
        };
        var h = std.hash.Wyhash.init(3);
        h.update(std.mem.asBytes(&view));
        h.update(std.mem.sliceAsBytes(o.ranges));
        h.update(std.mem.sliceAsBytes(o.overrides));
        h.update(std.mem.sliceAsBytes(o.palette.layers));
        const key = h.final();
        const n = f.custom(id, style, key);
        const k = f.tree().c.custom[n.ix()];
        ctx.canvasRows()[0][k] = .{ .stamp = ctx.frame, .instances = shapes, .camera = o.camera, .ranges = o.ranges, .palette = o.palette, .overrides = o.overrides };
        return n;
    }

    // ---- queries: input is asked for, never delivered ----------------------

    /// Makes `node` interactive and reports what happened to it this frame. The node must have
    /// been created with an id; anonymous nodes report nothing.
    pub fn interact(f: *Frame, node: Node, sense: Sense) Response {
        const c = &f.tree().c;
        if (!f.tree().participation(node.ix()).hit) {
            c.sense[node.ix()] = 0;
            f.ctx.inter.cancel(@fromBackingInt(c.id[node.ix()]));
            return .{};
        }
        c.sense[node.ix()] = @bitCast(sense);
        const response = f.ctx.inter.response(@fromBackingInt(c.id[node.ix()]));
        if (f.tree().cursor(node.ix())) |cursor| f.setCursor(cursor, response.hovered);
        return response;
    }

    /// Pointer movement this frame while `id` is dragged; zero otherwise. A drag starts once the
    /// pointer has moved `Interaction.drag_threshold` (4 px) from the press, and that frame
    /// carries the whole movement so far, so a jittery click never drags (`Interaction.drag`).
    pub fn drag(f: *const Frame, id: Id) [2]f32 {
        return f.ctx.inter.drag(id);
    }

    /// Where `id` was laid out last frame. A zero rect if it did not exist. Scans the id
    /// column (SIMD, O(n)); prefer `heldRect` inside widgets.
    pub fn lastRect(f: *const Frame, id: Id) Rect {
        const prev = f.prevTree();
        return rowRect(prev, simd.find(prev.c.id, prev.len, @backingInt(id)));
    }

    /// Last frame's rect of the widget the pointer is holding. O(1): the interaction step
    /// already knows its row. A zero rect if nothing is held.
    pub fn heldRect(f: *const Frame) Rect {
        return rowRect(f.prevTree(), f.ctx.inter.active_node);
    }

    pub fn setFill(f: *Frame, node: Node, color: Color) void {
        f.tree().c.look[node.ix()].fill = color.bitsOf();
    }

    /// Requests `cursor` if `when` holds. The last request in a frame wins.
    pub fn setCursor(f: *Frame, cursor: Cursor, when: bool) void {
        const p = &f.ctx.platform;
        p.cursor = @fromBackingInt(@as(u8, @truncate(simd.selU(when, @backingInt(cursor), @backingInt(p.cursor)))));
    }

    /// Makes `node` a focus scope (`focus.Scopes`): `group` for a composite widget that is one
    /// Tab stop with arrows inside (a toolbar, a radio group), `trap` for a modal layer that
    /// keeps focus among its descendants. Read by the next frame's focus step.
    pub fn focusScope(f: *Frame, node: Node, kind: u8) void {
        f.ctx.scopes.c.kind[node.ix()] = kind;
        f.ctx.scoped = true;
    }

    pub const timer = scheduler.timer;
    pub const reuse = @import("reuse.zig").reuse;

    /// A value that eases toward `target` across frames on a spring keyed by `id`. Returns this
    /// frame's position (`target` on first use). Keeps the host awake (`Output.wake` 0,
    /// `needsFrame` true) until it lands; a spring not asked for in a frame is dropped.
    ///
    /// `target` is an f32 (or a number literal), or anything made of numbers: a `Color`, a
    /// `Rect`, `[2]f32`, a vector or a struct of them (src/anim/values.zig). Each component
    /// moves on its own spring, keyed `id.with(k)` for the k-th; an f32 is keyed `id` itself.
    /// Exhaustion returns target immediately and reports Output.status.anims.
    pub fn animate(f: *Frame, id: Id, target: anytype, spring: Spring) values.Of(@TypeOf(target)) {
        const T = values.Of(@TypeOf(target));
        if (T == f32) return f.animateOne(id, target, spring);
        const want = values.flatten(T, target);
        var got: [want.len]f32 = undefined;
        for (want, &got, 0..) |x, *g, k| g.* = f.animateOne(id.with(@intCast(k)), x, spring);
        return values.build(T, &got);
    }

    fn animateOne(f: *Frame, id: Id, target: f32, spring: Spring) f32 {
        const ctx = f.ctx;
        const a = &ctx.anims;
        // `slot` and a compare, not `reserve(...) catch`: Zig 0.18's LLVM passes that error
        // union through the stack as a 2-byte and a 4-byte store read back as one 8-byte
        // load, which cannot be forwarded from the stores and waits for them instead. On
        // bench/vs/lcgf springs (1,000 calls a frame) that load was half the frame.
        const i = a.slot(id, target);
        if (i >= a.cap) return target;
        a.c.target[i] = target;
        a.c.stiffness[i] = spring.stiffness;
        a.c.damping[i] = spring.damping;
        a.c.seen[i] = ctx.frame;
        a.c.node[i] = ctx.stack[ctx.depth - 1];
        if (ctx.settings.reduced_motion) a.land(i);
        // A new target moves the spring from next frame's step on; wake for it now.
        ctx.motion = @max(ctx.motion, @abs(target - a.c.x[i]));
        return a.c.x[i];
    }

    /// Slides `node` (and its subtree) on a spring whenever its laid-out position changes,
    /// starting from where it was shown last frame. The node needs a stable, non-`none` id.
    /// Position only: a size change still takes effect at once. `end` runs the slide
    /// (`flip.apply` between `layout.place` and `layout.finalize`); callers running layout
    /// themselves call it there too.
    /// Exhaustion keeps settled layout and reports Output.status.flips or .anims.
    pub fn animateLayout(f: *Frame, node: Node, spring: Spring) void {
        f.ctx.flips.reserve(node.ix(), @fromBackingInt(f.tree().c.id[node.ix()]), spring) catch {};
    }

    /// Plays `keys` once, from the first frame that asks for `id`, and returns its value now.
    /// The clock is a linear tween row keyed by `id`, so the host stays awake until the last
    /// key; stop asking for one frame and the next ask plays it again from the start.
    /// Exhaustion returns the final key's value and reports Output.status.tweens.
    pub fn sequence(f: *Frame, id: Id, keys: []const keyframes.Key) f32 {
        const ctx = f.ctx;
        const t = &ctx.tweens;
        const total = keyframes.duration(keys);
        // A new row rests at 0, so the first retarget starts the clock's only leg.
        // `slot` and a compare, as `animateOne` (the error union costs a stalled load).
        const i = t.slot(id, 0);
        if (i >= t.cap) return keyframes.sample(keys, total);
        t.retarget(i, total, total, .linear);
        t.c.seen[i] = ctx.frame;
        t.c.node[i] = ctx.stack[ctx.depth - 1];
        if (ctx.settings.reduced_motion) t.land(i);
        ctx.motion = @max(ctx.motion, t.c.duration[i] - t.c.elapsed[i]);
        return keyframes.sample(keys, t.c.elapsed[i]);
    }

    /// A colour that moves to `target` along `tr` whenever `target` changes, instead of
    /// jumping: one tween per channel, keyed by `id.with(0..3)`. Returns this frame's colour.
    /// All four keys are preflighted together. Exhaustion settles the whole color and reports
    /// status.tweens, without reserving a partial transition or touching unrelated controls.
    pub fn transition(f: *Frame, id: Id, target: Color, tr: Transition) Color {
        const table = &f.ctx.tweens;
        var needed: u32 = 0;
        inline for (0..4) |k| needed += @intFromBool(simd.find(table.c.id, table.len, @backingInt(id.with(k))) == none);
        if (needed > table.cap - table.len) {
            table.overflow = true;
            return target;
        }
        return f.tween(id, target, tr.seconds, tr.ease);
    }

    /// `setFill` with a transition: a fill that changes between frames (hover, press, theme)
    /// fades to the new colour along `tr`. `id` keys the transition; use the widget's id.
    pub fn setFillAnimated(f: *Frame, node: Node, id: Id, color: Color, tr: Transition) void {
        f.setFill(node, f.transition(id, color, tr));
    }

    /// A value that moves to `target` over `seconds` along `ease`, keyed by `id`: when the
    /// target changes, a new leg starts from the current value. Returns this frame's value
    /// (`target` on first use). Keeps the host awake until it lands; a tween not asked for in
    /// a frame is dropped. `target` is what `animate` takes, keyed the same way.
    /// Exhaustion returns target immediately and reports Output.status.tweens.
    pub fn tween(f: *Frame, id: Id, target: anytype, seconds: f32, ease: Ease) values.Of(@TypeOf(target)) {
        const T = values.Of(@TypeOf(target));
        if (T == f32) return f.tweenOne(id, target, seconds, ease);
        const want = values.flatten(T, target);
        var got: [want.len]f32 = undefined;
        for (want, &got, 0..) |x, *g, k| g.* = f.tweenOne(id.with(@intCast(k)), x, seconds, ease);
        return values.build(T, &got);
    }

    fn tweenOne(f: *Frame, id: Id, target: f32, seconds: f32, ease: Ease) f32 {
        const ctx = f.ctx;
        const t = &ctx.tweens;
        const i = t.slot(id, target);
        if (i >= t.cap) return target;
        t.retarget(i, target, seconds, ease);
        t.c.seen[i] = ctx.frame;
        t.c.node[i] = ctx.stack[ctx.depth - 1];
        if (ctx.settings.reduced_motion) t.land(i);
        ctx.motion = @max(ctx.motion, t.c.duration[i] - t.c.elapsed[i]);
        return t.c.x[i];
    }

    // ---- finishing ------------------------------------------------------------

    /// Diagonal: measure with `font`, lay out, paint. Each line below is a public tier-0 call;
    /// copy this body to put your own shaper, or your own pass, between any two of them.
    pub fn end(f: *Frame, font: Mono) Output {
        f.layoutWith(font);
        return f.finish();
    }

    /// Measure and arrange without painting: insert prepared textures or explicit passes,
    /// then call finish. This is exactly the layout half of end.
    pub fn layoutWith(f: *Frame, font: Mono) void {
        f.arrangeWith(font);
        f.finalizeLayout(.{}) catch unreachable;
    }

    /// `end` with the flex rules (margins, wrap, align-self, aspect, baselines) the caller wrote
    /// into `fx` this frame, one row per node: `fx.set(@backingInt(node), &.{ .margin = ... })`.
    /// `fx` is caller-owned (`Flex.init` once, for `Limits.nodes`); every row it laid out goes
    /// back to the defaults afterwards, so each frame states its own rules. A frame without
    /// flex rules calls `end` and carves nothing.
    pub fn endFlex(f: *Frame, font: Mono, fx: *Flex) Output {
        f.layoutFlex(font, fx);
        return f.finish();
    }

    /// The layout half of `endFlex`: `layout.runFlex`'s passes over the whole tree. Subtrees
    /// `reuse` copied are laid out again, and their flex rows are the defaults unless the
    /// caller writes them.
    pub fn layoutFlex(f: *Frame, font: Mono, fx: *Flex) void {
        f.layoutFlexWith(font, fx, .{});
    }

    /// `endFlex` with the flex features of `opts` compiled in (`FlexOptions`), over `font` or
    /// a `paragraphs` font.
    pub fn endFlexOpts(f: *Frame, font: anytype, fx: *Flex, comptime opts: FlexOptions) Output {
        f.layoutFlexOpts(font, fx, opts);
        return if (comptime isParagraphs(@TypeOf(font))) f.finishParagraphs(font) else f.finish();
    }

    /// The layout half of `endFlexOpts`.
    pub fn layoutFlexOpts(f: *Frame, font: anytype, fx: *Flex, comptime opts: FlexOptions) void {
        f.layoutFlexWith(if (comptime isParagraphs(@TypeOf(font))) f.withStrings(font) else font, fx, opts);
    }

    /// `end` with paragraph styles (line height, spacing, line clamp, ellipsis) and text
    /// decorations on some runs: `font` lists them (a `protocol.MonoParagraphsOf`, such as
    /// `MonoParagraphs`; its `strings` are set to this frame's). The host draws their glyphs
    /// with the same font.
    pub fn endParagraphs(f: *Frame, font: anytype) Output {
        f.layoutParagraphs(font);
        return f.finishParagraphs(font);
    }

    /// The layout half of `endParagraphs`.
    pub fn layoutParagraphs(f: *Frame, font: anytype) void {
        f.arrange(f.withStrings(font));
        f.finalizeLayout(.{}) catch unreachable;
    }

    /// `endFlex` with paragraph styles, as `endParagraphs`.
    pub fn endFlexParagraphs(f: *Frame, font: anytype, fx: *Flex) Output {
        f.layoutFlexParagraphs(font, fx);
        return f.finishParagraphs(font);
    }

    /// The layout half of `endFlexParagraphs`.
    pub fn layoutFlexParagraphs(f: *Frame, font: anytype, fx: *Flex) void {
        f.layoutFlexWith(f.withStrings(font), fx, .{});
    }

    /// The paint half of `endParagraphs`: `finish`, with `font`'s decorations painted after
    /// their runs, before the host reads the draw list.
    pub fn finishParagraphs(f: *Frame, font: anytype) Output {
        const out = f.finish();
        f.withStrings(font).decorate(&f.ctx.draw, f.texts());
        return out;
    }

    /// Whether `T` is a `protocol.MonoParagraphsOf` (its runs carry paragraph styles).
    fn isParagraphs(comptime T: type) bool {
        return @hasField(T, "table");
    }

    fn withStrings(f: *const Frame, font: anytype) @TypeOf(font) {
        const s = &f.ctx.strings[f.ctx.cur];
        var p = font;
        p.strings = s.buf[0..s.len];
        return p;
    }

    fn layoutFlexWith(f: *Frame, font: anytype, fx: *Flex, comptime opts: FlexOptions) void {
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        std.debug.assert(fx.c.aspect.len >= simd.rows(t.cap));
        // Nothing kept: the finalize below takes the complete pass too.
        f.ctx.memos.kept_len = 0;
        font.measure(tx);
        // ponytail: Mono reports no ascent, so text baselines sit at the run's bottom edge.
        @memset(fx.c.text_has, 0);
        layout.prepare(t);
        layout.applyText(t, tx, .x);
        layout.fitFlexOpts(t, fx, .x, opts);
        layout.resolveFlex(t, fx, .x, f.in.viewport[0]);
        @import("../layout/wrap.zig").wrapOpts(t, fx, opts);
        layout.textAvail(t, tx);
        font.wrap(tx);
        layout.applyText(t, tx, .y);
        layout.fitFlexOpts(t, fx, .y, opts);
        layout.resolveFlex(t, fx, .y, f.in.viewport[1]);
        layout.placeFlexOpts(t, fx, opts);
        f.finalizeLayout(.{}) catch unreachable;
        for (0..t.len) |i| fx.set(@intCast(i), &.{});
    }

    /// Caller-owned side tables for `endSides`, each null when the frame uses none. Each is
    /// filled while the frame builds and reset after it, so every frame states its own rows.
    pub const Sides = struct {
        /// Grids: `gs.declare` after opening a grid node, and `gs.place(k,
        /// @intCast(f.tree().len), item)` before pushing each of its children, which float
        /// (`.float = true`).
        grids: ?*grid.Grids = null,
        /// Anchored floating nodes (`an.place(node, p, viewport)`), moved after placement.
        anchors: ?*overlay.Anchors = null,
        /// Sticky nodes (`st.push`), held at their scroller's edge after placement.
        sticky: ?*scroll.Sticky = null,
        /// Stacking layers (`ly.c.own[node] = z`): the frame paints in layer order.
        layers: ?*overlay.Layers = null,
        /// Flex rules, as `endFlex` takes them, laid out around and inside the grids.
        flex: ?*Flex = null,
    };

    /// `end` with the side tables in `sides`. `font` is a `Mono`, or a `MonoParagraphs` for
    /// paragraph styles and decorations as `endParagraphs` takes them. A frame without side
    /// tables calls `end`.
    pub fn endSides(f: *Frame, font: anytype, sides: Sides) Output {
        f.layoutSides(font, sides);
        return f.finishSides(font, sides);
    }

    /// The layout half of `endSides`: `grid.run`'s passes when there are grids, else
    /// `layout.run`'s (with flex rules, `runFlex`'s), with the font's measure and wrap; then
    /// the anchors and the sticky nodes.
    pub fn layoutSides(f: *Frame, font: anytype, sides: Sides) void {
        f.layoutSidesOpts(font, sides, .{});
    }

    /// `layoutSides` with the flex features of `opts` compiled in (`layoutFlexOpts`).
    pub fn layoutSidesOpts(f: *Frame, font: anytype, sides: Sides, comptime opts: FlexOptions) void {
        if (comptime isParagraphs(@TypeOf(font))) f.layoutSidesWith(f.withStrings(font), sides, opts) else f.layoutSidesWith(font, sides, opts);
    }

    /// The paint half of `endSides`: in layer order when `sides.layers` is given, then a
    /// `protocol.MonoParagraphsOf` font's decorations.
    pub fn finishSides(f: *Frame, font: anytype, sides: Sides) Output {
        const out = if (sides.layers) |ly| f.finishLayered(ly) else f.finish();
        if (comptime isParagraphs(@TypeOf(font))) f.withStrings(font).decorate(&f.ctx.draw, f.texts());
        return out;
    }

    fn layoutSidesWith(f: *Frame, font: anytype, sides: Sides, comptime opts: FlexOptions) void {
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        f.ctx.memos.kept_len = 0;
        font.measure(tx);
        if (sides.flex) |fx| {
            std.debug.assert(fx.c.aspect.len >= simd.rows(t.cap));
            @memset(fx.c.text_has, 0);
        }
        layout.prepare(t);
        layout.applyText(t, tx, .x);
        inline for (.{ types.Axis.x, types.Axis.y }) |axis| {
            const a = @backingInt(axis);
            if (axis == .y) {
                layout.textAvail(t, tx);
                font.wrap(tx);
                layout.applyText(t, tx, .y);
            }
            if (sides.grids) |gs| {
                if (axis == .x) grid.autoPlace(gs);
                if (sides.flex) |fx| {
                    grid.fitWithOpts(t, gs, fx, axis, opts);
                    grid.resolveWith(t, gs, fx, axis, f.in.viewport[a]);
                } else {
                    grid.fit(t, gs, axis);
                    grid.resolve(t, gs, axis, f.in.viewport[a]);
                }
            } else if (sides.flex) |fx| {
                layout.fitFlexOpts(t, fx, axis, opts);
                layout.resolveFlex(t, fx, axis, f.in.viewport[a]);
            } else {
                layout.fit(t, axis);
                layout.resolve(t, axis, f.in.viewport[a]);
            }
            if (axis == .x) if (sides.flex) |fx| @import("../layout/wrap.zig").wrapOpts(t, fx, opts);
        }
        if (sides.flex) |fx| layout.placeFlexOpts(t, fx, opts) else layout.place(t);
        if (sides.anchors) |an| overlay.anchor(t, an, .{ .x1 = f.in.viewport[0], .y1 = f.in.viewport[1] });
        if (sides.sticky) |st| scroll.stick(t, st);
        f.finalizeLayout(.{}) catch unreachable;
        if (sides.grids) |gs| gs.reset();
        if (sides.anchors) |an| an.reset();
        if (sides.sticky) |st| st.reset();
        if (sides.flex) |fx| for (0..t.len) |i| fx.set(@intCast(i), &.{});
    }

    /// `endSides` with grids only.
    pub fn endGrid(f: *Frame, font: Mono, gs: *grid.Grids) Output {
        return f.endSides(font, .{ .grids = gs });
    }

    /// `layoutSides` with grids only.
    pub fn layoutGrid(f: *Frame, font: Mono, gs: *grid.Grids) void {
        f.layoutSides(font, .{ .grids = gs });
    }

    /// A frame on a caller-selected device grid; no second arrangement or finalization pass.
    pub fn endRounded(f: *Frame, font: Mono, options: rounding.Options) error{InvalidScale}!Output {
        try f.layoutRounded(font, options);
        return f.finish();
    }

    pub fn layoutRounded(f: *Frame, font: Mono, options: rounding.Options) error{InvalidScale}!void {
        try options.validate();
        f.arrangeWith(font);
        try f.finalizeLayout(options);
    }

    /// Measure and place, leaving original fractional positions available for explicit RTL,
    /// grid, sticky or custom placement passes. Call finalizeLayout before finish.
    pub fn arrangeWith(f: *Frame, font: Mono) void {
        f.arrange(font);
    }

    /// `arrangeWith` for any font of the text protocol (`Mono`, `MonoParagraphs`).
    fn arrange(f: *Frame, font: anytype) void {
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        font.measure(tx);
        // Subtrees `reuse` copied behind a relayout boundary are not laid out again (with none,
        // each call is its `layout` form). A tree that ran out of rows may have lost them.
        const m = &f.ctx.memos;
        const kept = m.kept[0..simd.selU(t.overflow, 0, m.kept_len)];
        // Long runs of siblings and nothing kept: the passes take a run at a time
        // (layout/runs.zig). A size build keeps the one row-by-row copy.
        if (kept.len == 0 and by_runs) runs.survey(t) else t.wide = false;
        incremental.prepareKept(t, kept);
        incremental.applyTextKept(t, tx, .x, kept);
        incremental.fitKept(t, .x, kept);
        // Nothing kept, the usual frame: resolve level by level, the same sizes bit for bit
        // and a third cheaper than the row-by-row sweep (docs/perf/port-perf.md).
        const lv = &f.ctx.levels;
        if (kept.len == 0) levels.build(t, lv);
        resolve(t, lv, .x, f.in.viewport[0], kept);
        layout.textAvail(t, tx);
        font.wrap(tx);
        incremental.applyTextKept(t, tx, .y, kept);
        incremental.fitKept(t, .y, kept);
        resolve(t, lv, .y, f.in.viewport[1], kept);
        // Nothing kept: run by run (layout/runs.zig), the same positions bit for bit.
        if (t.wide) runs.place(t) else incremental.placeKept(t, kept);
    }

    /// Apply layout transitions after all placement passes, then snap, transform and clip.
    /// Calling this once preserves FLIP's comparison with the previous final arrangement.
    pub fn finalizeLayout(f: *Frame, options: rounding.Options) error{InvalidScale}!void {
        try options.validate();
        const t = f.tree();
        if (!f.ctx.settings.reduced_motion) f.ctx.motion = @max(f.ctx.motion, flip.apply(t, f.prevTree(), &f.ctx.flips, &f.ctx.anims, f.ctx.frame));
        // The copied interiors already contain finalized columns. Ancestor clip changes or
        // fractional movement invalidate that shortcut; FLIP can edit descendant positions
        // after placement, so its frames retain the complete reference pass. The shortcut is
        // the default grid's: any other rounding takes the complete pass.
        // ponytail: assumes last frame used the default grid too; track the previous options
        // if an app alternates end and endRounded on reused subtrees.
        const m = &f.ctx.memos;
        const kept = m.kept[0..simd.selU(t.overflow, 0, m.kept_len)];
        if (f.ctx.flips.len == 0 and std.meta.eql(options, rounding.Options{})) {
            incremental.finalizeKept(t, f.prevTree(), kept, m.kept_source[0..kept.len]);
        } else {
            try layout.finalizeWith(t, options);
        }
    }

    /// Font-backed counterpart of `end`. The caller owns the shapers, paragraph options,
    /// glyph/line scratch and one ascent row per text. `stack.paragraph` and `stack.quads`
    /// use these same options when the host draws the resulting runs. Copy these public
    /// passes to insert a custom layout, grid or baseline pass at either measurement point.
    /// A scratch overflow is reported in Output.status.texts as well as stack.overflow.
    pub fn endText(f: *Frame, stack: *TextStack, ascent: []f32) Output {
        f.layoutText(stack, ascent);
        return f.finish();
    }

    /// Font-backed measurement and arrangement only, the public half of endText.
    /// `endText` over styled runs (`protocol.Styled`: the paragraph styles, decorations and
    /// spans `endParagraphs` gives `Mono`), for a real shaper: `stack.style` points the stack
    /// at them through the caller's `rows`, and `stack.decorate` paints the decorations after
    /// the runs, laid out again in `rects` scratch (at least the glyph rows). Styles that do
    /// not fit the rows are dropped (`stack.overflow`) and the runs drawn plain.
    pub fn endTextStyled(f: *Frame, stack: *TextStack, ascent: []f32, s: protocol.Styled, rows: text_stack.StyledRows, rects: []types.Rect) Output {
        stack.style(f.texts(), s, rows) catch {
            stack.overflow = true;
            stack.paragraphs = &.{};
            stack.rich = &.{};
        };
        f.layoutText(stack, ascent);
        const out = f.finish();
        stack.decorate(f.texts(), &f.ctx.strings[f.ctx.cur], s, &f.ctx.draw, rects);
        return out;
    }

    pub fn layoutText(f: *Frame, stack: *TextStack, ascent: []f32) void {
        f.arrangeText(stack, ascent);
        f.finalizeLayout(.{}) catch unreachable;
    }

    pub fn endTextRounded(f: *Frame, stack: *TextStack, ascent: []f32, options: rounding.Options) error{InvalidScale}!Output {
        try f.layoutTextRounded(stack, ascent, options);
        return f.finish();
    }

    pub fn layoutTextRounded(f: *Frame, stack: *TextStack, ascent: []f32, options: rounding.Options) error{InvalidScale}!void {
        try options.validate();
        f.arrangeText(stack, ascent);
        try f.finalizeLayout(options);
    }

    /// Font-backed measurement and placement before caller passes and finalizeLayout.
    pub fn arrangeText(f: *Frame, stack: *TextStack, ascent: []f32) void {
        const t = f.tree();
        const tx = f.texts();
        const strings = &f.ctx.strings[f.ctx.cur];
        t.seal(0);
        stack.overflow = false;
        stack.measure(tx, strings, ascent);
        layout.prepare(t);
        layout.applyText(t, tx, .x);
        layout.fit(t, .x);
        layout.resolve(t, .x, f.in.viewport[0]);
        layout.textAvail(t, tx);
        stack.wrap(tx, strings, ascent);
        layout.applyText(t, tx, .y);
        layout.fit(t, .y);
        layout.resolve(t, .y, f.in.viewport[1]);
        layout.place(t);
        tx.overflow = tx.overflow or stack.overflow;
    }

    /// Paint and bookkeeping only, for callers who ran layout themselves.
    /// `finish`, painting in the stacking-layer order of `layers`, whose rows go back to layer
    /// 0 afterwards.
    // ponytail: a copy of `finish`. Folding the two into one function, even an inline one,
    // grew every runtime frame's .text by 64 B.
    fn finishLayered(f: *Frame, layers: *overlay.Layers) Output {
        const ctx = f.ctx;
        const t = f.tree();
        const tx = f.texts();
        const strings = &ctx.strings[ctx.cur];
        t.seal(0);
        const cu = &ctx.customs[ctx.cur];
        overlay.order(t, layers);
        paint.emitLayered(t, tx, cu, strings.buf[0..strings.len], layers, &ctx.draw);
        layers.reset();
        if (ctx.canvas_hook) |mark| mark(ctx);
        if (ctx.damage_hook) |record| record(ctx, t, tx, cu, strings.buf[0..strings.len]);
        ctx.anims.sweep(ctx.frame);
        ctx.tweens.sweep(ctx.frame);
        ctx.signals.dirty = false;
        // The tables flag their own overflow; the frame reports them together.
        ctx.status = .{
            .nodes = t.overflow,
            .texts = tx.overflow,
            .customs = cu.overflow,
            .strings = strings.overflow,
            .depth = ctx.status.depth,
            .anims = ctx.anims.overflow,
            .tweens = ctx.tweens.overflow,
            .flips = ctx.flips.overflow,
        };
        ctx.timers.sweep(ctx.frame);
        return .{
            .draw = &ctx.draw,
            .tree = t,
            .texts = tx,
            .platform = ctx.platform,
            .status = ctx.status,
            .wake = scheduler.wake(ctx, f.in),
            .pace = scheduler.pace(ctx),
        };
    }

    pub fn finish(f: *Frame) Output {
        const ctx = f.ctx;
        const t = f.tree();
        const tx = f.texts();
        const strings = &ctx.strings[ctx.cur];
        t.seal(0);
        const cu = &ctx.customs[ctx.cur];
        paint.emit(t, tx, cu, strings.buf[0..strings.len], &ctx.draw);
        if (ctx.canvas_hook) |mark| mark(ctx);
        if (ctx.damage_hook) |record| record(ctx, t, tx, cu, strings.buf[0..strings.len]);
        ctx.anims.sweep(ctx.frame);
        ctx.tweens.sweep(ctx.frame);
        ctx.signals.dirty = false;
        // The tables flag their own overflow; the frame reports them together.
        ctx.status = .{
            .nodes = t.overflow,
            .texts = tx.overflow,
            .customs = cu.overflow,
            .strings = strings.overflow,
            .depth = ctx.status.depth,
            .anims = ctx.anims.overflow,
            .tweens = ctx.tweens.overflow,
            .flips = ctx.flips.overflow,
        };
        ctx.timers.sweep(ctx.frame);
        return .{
            .draw = &ctx.draw,
            .tree = t,
            .texts = tx,
            .platform = ctx.platform,
            .status = ctx.status,
            .wake = scheduler.wake(ctx, f.in),
            .pace = scheduler.pace(ctx),
        };
    }
};

/// `incremental.resolveKept`, or `levels.resolve` (`lv` built) when nothing is kept. One
/// branch per frame.
pub fn resolve(t: *Tree, lv: *const levels.Levels, axis: types.Axis, viewport: f32, kept: []const u32) void {
    if (kept.len == 0) levels.resolve(t, lv, axis, viewport) else incremental.resolveKept(t, axis, viewport, kept);
}

/// Rect of row `i` of `t`, or a zero rect for `none`. The read is clamped into bounds and the
/// result scaled by 0 or 1, so there is no branch.
fn rowRect(t: *const Tree, i: u32) Rect {
    const row = @min(i, t.cap - 1);
    const m = simd.b2f(i != none);
    return .{
        .x0 = t.c.rect[0][row] * m,
        .y0 = t.c.rect[1][row] * m,
        .x1 = t.c.rect[2][row] * m,
        .y1 = t.c.rect[3][row] * m,
    };
}

const std = @import("std");
const testing = std.testing;
const DrawKind = @import("../draw/draw_list.zig").DrawList.Kind;
const mem = @import("../core/mem.zig");

/// A context over a static buffer, for tests.
fn Fixture(comptime limits: @import("context.zig").Limits) type {
    return struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        fn context() !Context {
            return Context.init(&buffer, limits);
        }
    };
}

test "endTextStyled: paragraph styles, spans and decorations reach a real shaper" {
    const golden = @import("../text/layout/golden.zig");
    const shape = @import("../text/shape/shape.zig");
    const lines = @import("../text/layout/lines.zig");
    const spans = @import("../text/layout/spans.zig");
    const face = try @import("../text/font/opentype.zig").Face.parse(golden.font, 0);
    const shapers = [_]shape.Shaper{.init(face)};
    var para: golden.Para = .{};
    para.bind();
    var cols: golden.RunCols = .{};
    var stack: TextStack = .{ .shapers = &shapers, .run = cols.run(), .g = para.g, .l = para.l };
    var ascent: [4]f32 = undefined;
    var p_rows: [4]text_stack.Paragraph = undefined;
    var rich: [4]?text_stack.Rich = undefined;
    var sp: [2]spans.Spans = undefined;
    var start: [8]u32 = undefined;
    var font: [8]u16 = undefined;
    var px: [8]f32 = undefined;
    var color: [8]u32 = undefined;
    var metrics: [8]lines.Metrics = undefined;
    var rects: [64]types.Rect = undefined;
    const rows: text_stack.StyledRows = .{ .paragraphs = &p_rows, .rich = &rich, .spans = &sp, .start = &start, .font = &font, .px = &px, .color = &color, .metrics = &metrics };
    const big = [_]protocol.Span{.{ .start = 2, .style = .{ .px = 40, .color = .rgb(255, 0, 0) }, .decoration = .{ .strike = true } }};
    const styled: protocol.Styled = .{
        .rows = &.{ 0, 1 },
        .styles = &.{ 0, 1 },
        .table = &.{ .{ .line_height = .{ .px = 30 } }, .{} },
        .decorations = &.{ .{}, .{ .underline = true } },
        .spans = &.{ &.{}, &big },
    };
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 128, .depth = 4 });
    var ctx = try Fx.context();
    const input: Input = .{ .viewport = .{ 300, 200 } };
    // Unstyled first, for the widths the styles change.
    var frame = ctx.begin(&input);
    _ = frame.open(.none, .{});
    _ = frame.text("AVTa", .{ .px = 20 });
    _ = frame.text("AVTa", .{ .px = 20 });
    frame.close();
    const plain = frame.endText(&stack, &ascent).tree;
    const plain_w = plain.rect(3).w();
    const plain_h = plain.rect(2).h();
    frame = ctx.begin(&input);
    _ = frame.open(.none, .{});
    const tall = frame.text("AVTa", .{ .px = 20 });
    const mixed = frame.text("AVTa", .{ .px = 20 });
    frame.close();
    const out = frame.endTextStyled(&stack, &ascent, styled, rows, &rects);
    try testing.expect(!stack.overflow);
    try testing.expectEqual(@as(f32, 30), out.tree.rect(tall.ix()).h());
    try testing.expect(plain_h != 30);
    // "Ta" at 40 px instead of 20: wider and taller than plain.
    try testing.expect(out.tree.rect(mixed.ix()).w() > plain_w);
    try testing.expect(out.tree.rect(mixed.ix()).h() > plain_h);
    // The underline is in the draw list, right after its run's text.
    var after_text = false;
    var underlined = false;
    for (0..out.draw.cmd_len) |i| switch (out.draw.command(@intCast(i))) {
        .text => |k| after_text = k == 1,
        .quads => {
            underlined = underlined or after_text;
            after_text = false;
        },
        else => after_text = false,
    };
    try testing.expect(underlined);
    // The 40 px span's own line-through: a bar that starts past the run's left edge.
    var struck = false;
    for (out.draw.quads[0..out.draw.quad_len]) |q| struck = struck or q.xform[4] > out.draw.runs[1].rect[0] + 1;
    try testing.expect(struck);
}

test "endText consumes real paragraph metrics in an ordinary frame" {
    const golden = @import("../text/layout/golden.zig");
    const shape = @import("../text/shape/shape.zig");
    const face = try @import("../text/font/opentype.zig").Face.parse(golden.font, 0);
    const shapers = [_]shape.Shaper{.init(face)};
    var para: golden.Para = .{};
    para.bind();
    var cols: golden.RunCols = .{};
    var stack: TextStack = .{
        .shapers = &shapers,
        .run = cols.run(),
        .g = para.g,
        .l = para.l,
        .default_paragraph = .{ .line_height = .{ .px = 30 }, .max_lines = 2, .ellipsis = true },
    };
    var ascent: [4]f32 = undefined;
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 128, .depth = 4 });
    var ctx = try Fx.context();
    const input: Input = .{ .viewport = .{ 100, 200 } };
    var frame = ctx.begin(&input);
    _ = frame.open(.none, .{ .size = .{ .px(80), .fit }, .transform = .{ 1, 0, 0, 1, 5, 7 } });
    const label = frame.text("one two three four five six", .{ .px = 20, .wrap = true });
    frame.close();
    const output = frame.endText(&stack, &ascent);
    try testing.expect(!output.status.texts);
    try testing.expectEqual(@as(f32, 60), output.tree.rect(label.ix()).h());
    try testing.expectEqual([6]f32{ 1, 0, 0, 1, 5, 7 }, output.draw.runs[0].xform);
    try testing.expect(ascent[0] > 0);
}

test "open, close, leaf: children nest under the open node, in depth-first rows" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 4, .customs = 2, .strings = 64, .depth = 8 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    const a = f.open(.from("a"), .{});
    const a1 = f.leaf(.from("a1"), .{});
    const a2 = f.open(.from("a2"), .{});
    const a21 = f.leaf(.none, .{});
    f.close();
    f.close();
    const b = f.leaf(.from("b"), .{});
    const t = f.tree();
    try testing.expectEqual(@as(u32, 6), t.len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 3, 0 }, t.c.parent[0..6]);
    try testing.expectEqual(@as(u32, 5), t.c.end[a.ix()]);
    try testing.expectEqual(a1.ix() + 1, t.c.end[a1.ix()]);
    try testing.expectEqual(@as(u32, 5), t.c.end[a2.ix()]);
    try testing.expectEqual(a21.ix() + 1, t.c.end[a21.ix()]);
    try testing.expectEqual(@as(u32, 6), t.c.end[b.ix()]);
    try testing.expectEqual(@as(f32, 2), t.c.nkids[0]);
    try testing.expectEqual(b.ix(), t.find(.from("b")));
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    try testing.expect(ctx.status.ok());
}

test "close: unbalanced calls never pop the root" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    f.close();
    f.close();
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    const n = f.leaf(.none, .{});
    try testing.expectEqual(@as(u32, 0), f.tree().c.parent[n.ix()]);
}

test "open: nesting past the depth limit is reported, not written out of bounds" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 1, .customs = 1, .strings = 16, .depth = 3 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    for (0..2) |_| _ = f.open(.none, .{});
    try testing.expect(!ctx.status.depth);
    for (0..5) |_| _ = f.open(.none, .{});
    try testing.expect(ctx.status.depth);
    try testing.expectEqual(@as(u32, 3), ctx.depth);
    for (0..10) |_| f.close();
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    // The next frame starts clean.
    _ = ctx.begin(&in);
    try testing.expect(ctx.status.ok());
}

test "leaf at the depth limit pops the replaced slot before the next sibling" {
    const Fx = Fixture(.{ .nodes = 4, .texts = 1, .customs = 1, .strings = 16, .depth = 3 });
    var ctx = try Fx.context();
    var f = ctx.begin(&.{});
    const panel = f.open(.from("panel"), .{});
    const row = f.open(.from("row"), .{});
    const child = f.leaf(.from("child"), .{});
    const t = f.tree();
    try testing.expect(ctx.status.depth);
    try testing.expectEqual(2, ctx.depth);
    try testing.expectEqual(row.ix(), t.c.parent[child.ix()]);
    try testing.expectEqual(t.len, t.c.end[child.ix()]);

    // The tree is full too. The sibling replaces the final row under the panel.
    const sibling = f.leaf(.from("sibling"), .{});
    try testing.expect(t.overflow);
    try testing.expectEqual(child, sibling);
    try testing.expectEqual(panel.ix(), t.c.parent[sibling.ix()]);
    try testing.expectEqual(t.len, t.c.end[sibling.ix()]);
}

test "text: copies the bytes and links the leaf to its run" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 4, .customs = 1, .strings = 64, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    var tmp = "hello".*;
    const n = f.text(&tmp, .{ .px = 10, .wrap = true });
    tmp[0] = 'j';
    const t = f.tree();
    const tx = f.texts();
    const k = t.c.text[n.ix()];
    try testing.expectEqual(@as(u32, 0), k);
    try testing.expectEqual(n.ix(), tx.c.node[k]);
    try testing.expectEqualStrings("hello", ctx.strings[ctx.cur].get(.{ .start = tx.c.start[k], .bytes = tx.c.bytes[k] }));
    try testing.expectEqual(@as(f32, 10), tx.c.px[k]);
    // A wrapping label may shrink below its text; it is a label leaf.
    try testing.expectEqual(@as(f32, 1), t.c.shrink[n.ix()]);
    try testing.expectEqual(@backingInt(types.Role.label), t.c.role[n.ix()]);
    try testing.expectEqual(n.ix() + 1, t.c.end[n.ix()]);
    try testing.expectEqual(types.none, t.c.custom[n.ix()]);

    const m = f.textStyled("x", .{}, .{ .pad = @splat(4) });
    try testing.expectEqual(@as(u32, 1), t.c.text[m.ix()]);
    try testing.expectEqual(@as(f32, 4), t.c.pad_lo[0][m.ix()]);
}

test "ordinary labels retain the styled leaf's rows at the stack and storage limits" {
    const limits: @import("context.zig").Limits = .{ .nodes = 4, .texts = 2, .customs = 1, .strings = 4, .depth = 2 };
    const Fx = Fixture(limits);
    var actual_buf: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var actual_ctx = try Context.init(&actual_buf, limits);
    var expected_ctx = try Fx.context();
    var actual = actual_ctx.begin(&.{});
    var expected = expected_ctx.begin(&.{});
    _ = actual.open(.from("panel"), .{ .clip = true });
    _ = expected.open(.from("panel"), .{ .clip = true });
    for ([_]bool{ false, true, false, true }) |wrap| {
        const a = actual.text("abc", .{ .wrap = wrap });
        const b = expected.textStyled("abc", .{ .wrap = wrap }, .{ .shrink = wrap, .role = .label });
        try testing.expectEqual(a, b);
        try testing.expectEqual(actual_ctx.depth, expected_ctx.depth);
        try testing.expectEqualSlices(u32, actual_ctx.stack, expected_ctx.stack);
        try testing.expectEqual(actual_ctx.status, expected_ctx.status);
        const ac = &actual.tree().c;
        const bc = &expected.tree().c;
        inline for (.{ "parent", "end", "role", "sense", "scope", "look", "text", "shrink" }) |name| {
            try testing.expectEqual(@field(bc, name)[b.ix()], @field(ac, name)[a.ix()]);
        }
    }
}

test "custom: links the leaf to a row carrying its id and data" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 2, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    const n = f.custom(.from("view"), .{ .size = .{ .fill, .fill } }, 42);
    const cu = &ctx.customs[ctx.cur];
    const k = f.tree().c.custom[n.ix()];
    try testing.expectEqual(@as(u32, 0), k);
    try testing.expectEqual(n.ix(), cu.c.node[k]);
    try testing.expectEqual(@backingInt(Id.from("view")), cu.c.id[k]);
    try testing.expectEqual(@as(u64, 42), cu.c.data[k]);
    try testing.expectEqual(n.ix(), f.tree().find(.from("view")));
}

test "canvas: canvas commands in paint order, an overlay over them; other customs stay custom" {
    const limits: @import("context.zig").Limits = .{ .nodes = 8, .texts = 1, .customs = 3, .strings = 16, .depth = 4, .damage = true };
    const Fx = Fixture(limits);
    var ctx = try Fx.context();
    var rows: [2 * limits.customs]@import("../draw/draw_list.zig").CanvasDraw = undefined;
    ctx.enableCanvas(&rows);
    ctx.trackDamage();
    var buf: [canvas_mod.Instances.requiredBytes(4, 0, 1, .{})]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var shapes: canvas_mod.Instances = .init(&carver, 4, 0, 1, .{});
    _ = shapes.segment(.{ 0, 0 }, .{ 1_000, 0 }, .{});
    const in: Input = .{ .viewport = .{ 200, 100 } };
    var layers = [_]canvas_mod.Layer{.of(.{ .width = 2 })};
    const pal: canvas_mod.Palette = .{ .layers = &layers };

    const View = struct {
        cam: canvas_mod.Camera,
        ranges: []const canvas_mod.Range,
        selected: []const canvas_mod.Override = &.{},
        fn frame(v: @This(), c: *Context, input: *const Input, sh: *const canvas_mod.Instances, p: *const canvas_mod.Palette) Output {
            var f = c.begin(input);
            _ = f.open(.none, .{ .dir = .x, .size = .{ .fill, .fill } });
            _ = f.custom(.from("host"), .{ .size = .{ .px(50), .fill } }, 1);
            const area = f.open(.none, .{ .size = .{ .fill, .fill } });
            _ = area;
            _ = f.canvas(.from("schematic"), .{ .size = .{ .fill, .fill } }, sh, .{ .camera = v.cam, .palette = p, .ranges = v.ranges });
            // The selection overlay: a second canvas floating over the first.
            _ = f.canvas(.from("selection"), .{ .float = true, .size = .{ .px(150), .px(100) } }, sh, .{ .camera = v.cam, .palette = p, .ranges = v.ranges, .overrides = v.selected });
            f.close();
            f.close();
            return f.end(.{});
        }
    };
    const cam: canvas_mod.Camera = .{ .origin = .{ 500, 0 }, .scale = 0.1, .offset = .{ 75, 50 } };
    const wires = shapes.since(0);
    var view: View = .{ .cam = cam, .ranges = &.{wires} };
    var out = view.frame(&ctx, &in, &shapes, &pal);
    var kinds: [3]DrawKind = undefined;
    var n: u32 = 0;
    for (0..out.draw.cmd_len) |i| switch (out.draw.command(@intCast(i))) {
        .quads, .text => {},
        .custom, .canvas => {
            kinds[n] = @fromBackingInt(out.draw.cmd.kind[i]);
            n += 1;
        },
    };
    try testing.expectEqual(3, n);
    try testing.expectEqualSlices(DrawKind, &.{ .custom, .canvas, .canvas }, &kinds);
    const k = out.draw.command(out.draw.cmd_len - 2).canvas;
    try testing.expectEqual([4]f32{ 50, 0, 200, 100 }, out.draw.customs[k].rect);
    try testing.expectEqual(&shapes, out.draw.canvases[k].instances);
    try testing.expectEqual(&pal, out.draw.canvases[k].palette);
    try testing.expectEqualSlices(canvas_mod.Range, &.{wires}, out.draw.canvases[k].ranges);
    try testing.expectEqual(cam, out.draw.canvases[k].camera);

    // The same frame again changes nothing; a pan, a selection, a recolour and an edit each
    // damage the canvas nodes.
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual(0, out.draw.damage.pixels());
    view.cam.origin[0] += 10;
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual([4]f32{ 50, 0, 200, 100 }, out.draw.damage.bounds());
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual(0, out.draw.damage.pixels());
    view.selected = &.{.{ .range = wires, .color = 0xff00ff00 }};
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual([4]f32{ 50, 0, 200, 100 }, out.draw.damage.bounds());
    layers[0].width = 3;
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual([4]f32{ 50, 0, 200, 100 }, out.draw.damage.bounds());
    _ = shapes.segment(.{ 0, 0 }, .{ 0, 1_000 }, .{});
    view.ranges = &.{shapes.since(0)};
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual([4]f32{ 50, 0, 200, 100 }, out.draw.damage.bounds());
    out = view.frame(&ctx, &in, &shapes, &pal);
    try testing.expectEqual(0, out.draw.damage.pixels());

    // A frame without the canvas: its custom row is an ordinary custom draw again.
    var f = ctx.begin(&in);
    _ = f.custom(.from("host"), .{ .size = .{ .px(50), .fill } }, 1);
    _ = f.custom(.from("other"), .{ .size = .{ .px(50), .fill } }, 2);
    out = f.end(.{});
    for (0..out.draw.cmd_len) |i| try testing.expect(out.draw.command(@intCast(i)) != .canvas);
}

/// Two 40 x 40 buttons, "a" at x 0..40 and "b" at 50..90, laid out by hand (Frame.end comes later).
fn twoButtons(f: *Frame) [2]Response {
    _ = f.open(.none, .{ .dir = .x, .gap = 10 });
    const a = f.leaf(.from("a"), .{ .size = .{ .px(40), .px(40) } });
    const ra = f.interact(a, .button);
    const b = f.leaf(.from("b"), .{ .size = .{ .px(40), .px(40) } });
    const rb = f.interact(b, .any);
    f.setFill(b, .rgb(1, 2, 3));
    f.close();
    f.tree().seal(0);
    layout.run(f.tree(), f.texts(), f.in.viewport);
    return .{ ra, rb };
}

test "interact, drag, lastRect, heldRect: answers from last frame's geometry" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var f = ctx.begin(&in);
    var r = twoButtons(&f);
    try testing.expect(!r[0].hovered and !r[1].hovered);
    try testing.expectEqual(Color.rgb(1, 2, 3).bitsOf(), f.tree().c.look[f.tree().find(.from("b"))].fill);
    try testing.expectEqual(@as(u8, @bitCast(Sense.button)), f.tree().c.sense[f.tree().find(.from("a"))]);
    // Nothing existed before frame 1, and nothing is held.
    try testing.expectEqual(Rect{}, f.lastRect(.from("a")));
    try testing.expectEqual(Rect{}, f.heldRect());

    in.pointer = .{ 60, 20 };
    f = ctx.begin(&in);
    r = twoButtons(&f);
    try testing.expect(!r[0].hovered and r[1].hovered);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 40, .y1 = 40 }, f.lastRect(.from("a")));
    try testing.expectEqual(Rect{}, f.lastRect(.from("missing")));

    in.buttons.left = true;
    f = ctx.begin(&in);
    r = twoButtons(&f);
    try testing.expect(r[1].pressed and r[1].held);
    try testing.expectEqual(Rect{ .x0 = 50, .y0 = 0, .x1 = 90, .y1 = 40 }, f.heldRect());
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.from("b")));

    // Held and moved 2 px: under the threshold, not a drag yet.
    in.pointer = .{ 62, 21 };
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.from("b")));

    // Held and moved 11 px from the press, past the 4 px threshold: the drag starts with the
    // movement so far, for the held widget only.
    in.pointer = .{ 70, 25 };
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual([2]f32{ 10, 5 }, f.drag(.from("b")));
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.from("a")));
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.none));

    in.buttons.left = false;
    f = ctx.begin(&in);
    r = twoButtons(&f);
    try testing.expect(r[1].released and r[1].clicked);
    try testing.expectEqual(Rect{}, f.heldRect());
}

test "end: the tier-0 pass sequence, then paint; equal to running layout and finish by hand" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 2, .strings = 64, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 400, 300 } };

    var f = ctx.begin(&in);
    _ = f.open(.from("bar"), .{ .dir = .x, .size = .{ .fill, .px(40) }, .pad = @splat(10), .gap = 4, .fill = .rgb(9, 9, 9) });
    // 24 bytes at 10 px, 0.5 em each: 120 px wrapping into 100: two lines of 12 px.
    _ = f.open(.none, .{ .size = .{ .px(100), .fit } });
    const para = f.text("twenty-four characters!!", .{ .px = 10, .wrap = true });
    f.close();
    f.close();
    const view = f.custom(.from("view"), .{ .size = .{ .fill, .fill } }, 7);
    // Unbalanced on purpose: end seals the root anyway.
    _ = f.open(.none, .{});
    const out = f.end(.{ .advance = 0.5, .line = 1.2 });

    const t = out.tree;
    try testing.expectEqual(f.tree(), t);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 400, .y1 = 40 }, t.rect(t.find(.from("bar"))));
    try testing.expectEqual(Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 34 }, t.rect(para.ix()));
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 40, .x1 = 400, .y1 = 300 }, t.rect(view.ix()));
    try testing.expectEqual(t.len, t.c.end[0]);
    // Paint: the bar's quad, the run, the custom draw with its rect, in that order.
    const d = out.draw;
    try testing.expectEqual(@as(u32, 1), d.quad_len);
    try testing.expectEqual(@as(u32, 1), d.run_len);
    try testing.expectEqual(@as(u32, 1), d.custom_len);
    try testing.expectEqual([4]f32{ 0, 40, 400, 300 }, d.customs[0].rect);
    try testing.expectEqual(@as(u32, 3), d.cmd_len);
    // The first frame after an input change owes one more.
    try testing.expectEqual(@as(f32, 0), out.wake);

    // Same input again: rebuilt by hand with the passes run by the caller, then finish.
    f = ctx.begin(&in);
    _ = f.open(.from("bar"), .{ .dir = .x, .size = .{ .fill, .px(40) }, .pad = @splat(10), .gap = 4, .fill = .rgb(9, 9, 9) });
    _ = f.open(.none, .{ .size = .{ .px(100), .fit } });
    _ = f.text("twenty-four characters!!", .{ .px = 10, .wrap = true });
    f.close();
    f.close();
    _ = f.custom(.from("view"), .{ .size = .{ .fill, .fill } }, 7);
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(f.texts());
    f.tree().seal(0);
    layout.prepare(f.tree());
    layout.applyText(f.tree(), f.texts(), .x);
    layout.fit(f.tree(), .x);
    layout.resolve(f.tree(), .x, 400);
    layout.textAvail(f.tree(), f.texts());
    font.wrap(f.texts());
    layout.applyText(f.tree(), f.texts(), .y);
    layout.fit(f.tree(), .y);
    layout.resolve(f.tree(), .y, 300);
    layout.place(f.tree());
    layout.finalize(f.tree());
    const again = f.finish();
    try testing.expectEqual(Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 34 }, again.tree.rect(para.ix()));
    try testing.expectEqual(@as(u32, 3), again.draw.cmd_len);
    // Nothing changed and nothing moves: sleep until the next event.
    try testing.expectEqual(types.inf, again.wake);
}

test "running out of rows is reported, not fatal" {
    const tiny: @import("context.zig").Limits = .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 16, .depth = 3 };
    const Fx = Fixture(tiny);
    var ctx = try Fx.context();
    try testing.expectError(error.BufferTooSmall, Context.init(Fx.buffer[0..64], tiny));

    const in: Input = .{};
    var f = ctx.begin(&in);
    for (0..40) |i| {
        _ = f.open(Id.from("n").with(@intCast(i)), .{ .pad = @splat(1) });
        _ = f.text("a long label that will not fit", .{});
    }
    for (0..40) |_| f.close();
    _ = f.custom(.from("c1"), .{}, 0);
    _ = f.custom(.from("c2"), .{}, 0);
    const out = f.end(.{});
    try testing.expect(out.status.nodes and out.status.texts and out.status.customs and out.status.strings and out.status.depth);
    try testing.expect(!out.status.ok());
    try testing.expect(out.tree.len <= tiny.nodes);

    // A frame that fits is clean again.
    f = ctx.begin(&in);
    _ = f.text("ok", .{});
    try testing.expect(f.end(.{}).status.ok());
}

test "finish: a signal changed before the frame is consumed by it" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .signals = 2, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    const sig = ctx.signals.create();
    ctx.signals.touch(sig);
    var f = ctx.begin(&in);
    try testing.expect(ctx.signals.dirty);
    _ = f.end(.{});
    try testing.expect(!ctx.signals.dirty);
}

test "setCursor: the last request that holds wins; the next frame starts at arrow" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    f.setCursor(.pointer, true);
    f.setCursor(.grab, false);
    try testing.expectEqual(Cursor.pointer, f.end(.{}).platform.cursor);
    f = ctx.begin(&in);
    f.setCursor(.text, true);
    f.setCursor(.resize_h, true);
    try testing.expectEqual(Cursor.resize_h, f.end(.{}).platform.cursor);
    f = ctx.begin(&in);
    try testing.expectEqual(Cursor.arrow, f.end(.{}).platform.cursor);
}

test "wake: long press and hover intent wake the host when they fall due, once" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var f = ctx.begin(&in);
    _ = twoButtons(&f);
    _ = f.finish();
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(types.inf, f.finish().wake);

    // Pointer comes to rest on "a" at t = 1: hover intent is due at 1.5.
    in.pointer = .{ 20, 20 };
    in.time = 1;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@as(f32, 0), f.finish().wake); // settle frame
    in.time = 1.2;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectApproxEqAbs(@as(f32, 0.3), f.finish().wake, 1e-4);
    in.time = 1.5;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@backingInt(Id.from("a")), ctx.inter.hover_intent);
    try testing.expectEqual(types.inf, f.finish().wake);

    // Press at t = 2: the long press is due at 2.5, then nothing is pending.
    in.buttons.left = true;
    in.time = 2;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@as(f32, 0), f.finish().wake);
    in.time = 2.1;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectApproxEqAbs(@as(f32, 0.4), f.finish().wake, 1e-4);
    in.time = 2.6;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@backingInt(Id.from("a")), ctx.inter.long_pressed);
    try testing.expectEqual(types.inf, f.finish().wake);
}

test "limits: a frame past every limit at once reports it and never crashes" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 2, .customs = 1, .strings = 16, .depth = 3, .anims = 2, .tweens = 2, .flips = 2, .signals = 2, .timers = 2, .memos = 2 });
    var ctx = try Fx.context();
    // Three frames, so the second and third hit-test, reuse and animate against a full tree.
    for (0..3) |frame| {
        const in: Input = .{ .viewport = .{ 200, 100 }, .pointer = .{ 10, 10 }, .dt = 1.0 / 60.0 };
        var f = ctx.begin(&in);
        for (0..6) |k| {
            const deep = f.open(.hash(std.mem.asBytes(&k)), .{ .size = .{ .pct(0.5), .fill }, .fill = .white });
            _ = f.interact(deep, .button);
            f.animateLayout(deep, .{});
        }
        for (0..12) |k| {
            const tag = 100 + k;
            const id: Id = .hash(std.mem.asBytes(&tag));
            _ = f.text("past the string limit", .{ .px = 10, .wrap = true });
            _ = f.custom(id, .{ .size = .{ .px(4), .px(4) } }, k);
            _ = f.animate(id, @as(f32, @floatFromInt(k)), .{});
            _ = f.tween(id, @as(f32, @floatFromInt(k)), 0.2, .linear);
            _ = scheduler.timer(&f, id, 0.1, .repeat);
            if (!@import("reuse.zig").reuse(&f, id, &.{})) {
                _ = f.open(id, .{});
                _ = f.leaf(.none, .{ .fill = .black });
                f.close();
            }
        }
        for (0..10) |_| f.close();
        const out = f.end(.{});
        try testing.expect(ctx.status.nodes and ctx.status.texts and ctx.status.customs and ctx.status.strings and ctx.status.depth and ctx.status.anims and ctx.status.tweens and ctx.status.flips);
        try testing.expect(out.tree.len <= 8);
        // Every row's parent comes before it (the rewritten last row included), which
        // levels.build, the parent-following passes and paint rely on.
        for (1..out.tree.len) |i| try testing.expect(out.tree.c.parent[i] < i);
        _ = frame;
    }
}

test "animation exhaustion returns settled values without retargeting another control" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 8, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1, .memos = 1 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 100 }, .dt = 1.0 / 60.0 };
    const spring_id: Id = .from("reserved-spring");
    const tween_id: Id = .from("reserved-tween");
    const keys = [_]keyframes.Key{ .{ .at = 0, .value = 3 }, .{ .at = 2, .value = 7 } };
    var f = ctx.begin(&in);
    _ = f.animate(spring_id, 0, .{});
    _ = f.tween(tween_id, 0, 1, .linear);
    try testing.expect(f.end(.{}).status.ok());
    f = ctx.begin(&in);
    try testing.expectEqual(@as(f32, 0), f.animate(spring_id, 10, .{}));
    try testing.expectEqual(@as(f32, 999), f.animate(.from("extra-spring"), 999, .{}));
    try testing.expectEqual(@as(f32, 0), f.tween(tween_id, 10, 1, .linear));
    try testing.expectEqual(@as(f32, 999), f.tween(.from("extra-tween"), 999, 5, .linear));
    try testing.expectEqual(@as(f32, 7), f.sequence(.from("extra-sequence"), &keys));
    const out = f.end(.{});
    try testing.expect(out.status.anims and out.status.tweens and !out.status.flips);
    try testing.expectEqual(@backingInt(spring_id), ctx.anims.c.id[0]);
    try testing.expectEqual(@backingInt(tween_id), ctx.tweens.c.id[0]);
    try testing.expectEqual(@as(f32, 10), ctx.anims.c.target[0]);
    try testing.expectEqual(@as(f32, 10), ctx.tweens.c.to[0]);
    f = ctx.begin(&in);
    _ = f.animate(spring_id, 10, .{});
    _ = f.tween(tween_id, 10, 1, .linear);
    try testing.expect(f.end(.{}).status.ok());
}

test "color transition exhaustion settles all channels without partial reservations" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .depth = 4, .anims = 1, .tweens = 4, .flips = 1, .signals = 1, .timers = 1, .memos = 1 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 100 } };
    var f = ctx.begin(&in);
    _ = f.tween(.from("unrelated"), 5, 1, .linear);
    const target: Color = .rgba(80, 120, 160, 200);
    try testing.expectEqual(target, f.transition(.from("overflow-color"), target, .{}));
    try testing.expectEqual(@as(u32, 1), ctx.tweens.len);
    try testing.expectEqual(@backingInt(Id.from("unrelated")), ctx.tweens.c.id[0]);
    try testing.expectEqual(@as(f32, 5), ctx.tweens.c.to[0]);
    try testing.expect(f.end(.{}).status.tweens);
}

test "FLIP exhaustion preserves prior registrations and reserves its two spring axes atomically" {
    const Ui = struct {
        fn frame(c: *Context, input: *const Input, top: f32, second: bool) Output {
            var f = c.begin(input);
            _ = f.leaf(.none, .{ .size = .{ .fill, .px(top) } });
            const a = f.leaf(.from("first-layout"), .{ .size = .{ .fill, .px(10) } });
            f.animateLayout(a, .{});
            const b = f.leaf(.from("second-layout"), .{ .size = .{ .fill, .px(10) } });
            if (second) f.animateLayout(b, .{});
            return f.end(.{});
        }
    };
    const in: Input = .{ .viewport = .{ 100, 100 } };
    const limits: @import("context.zig").Limits = .{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 8, .anims = 2, .tweens = 1, .flips = 1, .signals = 1, .timers = 1, .memos = 1 };
    var ctx = try Fixture(limits).context();
    _ = Ui.frame(&ctx, &in, 10, true);
    const out = Ui.frame(&ctx, &in, 30, true);
    try testing.expect(out.status.flips and !out.status.anims);
    try testing.expectEqual(@as(f32, 10), out.tree.rect(out.tree.find(.from("first-layout"))).y0);
    try testing.expectEqual(@as(f32, 40), out.tree.rect(out.tree.find(.from("second-layout"))).y0);
    const short_limits = comptime blk: {
        var value = limits;
        value.anims = 1;
        break :blk value;
    };
    var short = try Fixture(short_limits).context();
    _ = Ui.frame(&short, &in, 10, false);
    const settled = Ui.frame(&short, &in, 30, false);
    try testing.expect(settled.status.anims and !settled.status.flips);
    try testing.expectEqual(@as(u32, 0), short.anims.len);
    try testing.expectEqual(@as(f32, 30), settled.tree.rect(settled.tree.find(.from("first-layout"))).y0);
}

test "participation reserves hidden space, collapses layout and cancels descendant input" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 2, .strings = 128, .depth = 8 });
    var ctx = try Fx.context();
    var f = ctx.begin(&.{ .viewport = .{ 200, 200 } });
    const stack = f.open(.from("stack"), .{ .gap = 4 });
    const hidden = f.open(.from("hidden"), .{ .size = .{ .px(40), .px(20) }, .fill = .white, .participation = .hidden });
    const control = f.leaf(.from("hidden-button"), .{ .size = .{ .px(40), .px(20) }, .role = .button, .fill = .white });
    ctx.inter.active = @backingInt(Id.from("hidden-button"));
    ctx.inter.focus = ctx.inter.active;
    ctx.inter.clicked = ctx.inter.active;
    try testing.expectEqual(Response{}, f.interact(control, .button));
    try testing.expectEqual(@as(u32, 0), ctx.inter.active);
    try testing.expectEqual(@as(u32, 0), ctx.inter.focus);
    _ = f.text("hidden", .{});
    _ = f.custom(.none, .{ .float = true, .size = .{ .px(20), .px(20) } }, 1);
    f.close();
    const collapsed = f.open(.from("collapsed"), .{ .size = .{ .px(50), .px(50) }, .pad = @splat(8), .participation = .collapsed });
    _ = f.text("must not restore the collapsed size", .{});
    f.close();
    const shown = f.leaf(.from("shown"), .{ .size = .{ .px(40), .px(10) }, .fill = .white, .role = .button });
    _ = f.interact(shown, .button);
    f.close();
    const result = f.end(.{});
    try testing.expectEqual(@as(f32, 20), result.tree.rect(hidden.ix()).h());
    try testing.expectEqual(@as(f32, 0), result.tree.rect(collapsed.ix()).h());
    try testing.expectEqual(@as(f32, 24), result.tree.rect(shown.ix()).y0 - result.tree.rect(stack.ix()).y0);
    try testing.expectEqual(@as(u32, 1), result.draw.quad_len);
    try testing.expectEqual(@as(u32, 1), result.draw.cmd_len);
    try testing.expectEqual(@as(u8, 0), result.tree.c.role[control.ix()]);
    try testing.expectEqual(types.none, @import("../interact/hit.zig").at(result.tree, 10, 10, .any));
    try testing.expectEqual(shown.ix(), @import("../interact/hit.zig").at(result.tree, 10, 28, .any));
}

test "style cursor inherits through paint extras and explicit arrow overrides it" {
    const Fx = Fixture(.{ .nodes = 12, .texts = 1, .customs = 1, .strings = 16, .depth = 5 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 60 }, .pointer = .{ 10, 10 } };
    for (0..3) |step| {
        var f = ctx.begin(&in);
        _ = f.open(.from("cursor-parent"), .{ .cursor = .crosshair, .size = .{ .fill, .fill } });
        const n = f.leaf(.from("cursor-child"), .{ .cursor = if (step == 2) .arrow else null, .radius = 3, .opacity = 0.8, .size = .{ .px(30), .px(25) }, .fill = .white });
        _ = f.interact(n, .button);
        f.close();
        const out = f.end(.{});
        try testing.expectEqual(@as(?Cursor, if (step == 2) .arrow else .crosshair), out.tree.cursor(n.ix()));
        if (step == 1) try testing.expectEqual(Cursor.crosshair, out.platform.cursor);
        if (step == 2) try testing.expectEqual(Cursor.arrow, out.platform.cursor);
    }
}
