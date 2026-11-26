//! The inline-push view (docs/plans/bindings-rust.md §6.3): where `Tree.pushRow` and
//! `Frame.enter` store, so C++ and Rust push a row with the stores Zig's inlined `leaf` makes
//! (bindings/cpp/include/lcgf/rows.hpp, bindings/rust/lcgf/src/rows.rs, from tools/abi-gen)
//! and no call. It has no Zig counterpart: Zig inlines `open`.

const context = @import("../runtime/context.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Look = @import("../core/tree.zig").Look;
const Extra = @import("../core/tree.zig").Extra;

/// The frame's tree as `open` and `leaf` write it (`lcgf_view`). Valid from
/// `lcgf_context_begin` to `lcgf_frame_end`; the counters are pointers because the library's
/// own calls (text, widgets) move them too.
pub const CView = extern struct {
    len: *u32,
    xlen: *u32,
    overflow: *bool,
    depth: *u32,
    /// The context's `Status` byte; `depth_bit` is its overflow flag for `depth`.
    status: *u8,
    cap: u32,
    depth_cap: u32,
    stack: [*]u32,
    id: [*]u32,
    parent: [*]u32,
    end: [*]u32,
    min: [2][*]f32,
    max: [2][*]f32,
    grow: [2][*]f32,
    pct: [2][*]f32,
    pad_lo: [2][*]f32,
    pad_hi: [2][*]f32,
    offset: [2][*]f32,
    scroll: [2][*]f32,
    main: [2][*]f32,
    gap: [*]f32,
    nkids: [*]f32,
    flow: [*]f32,
    shrink: [*]f32,
    align_main: [*]f32,
    align_cross: [*]f32,
    clips: [*]u8,
    sense: [*]u8,
    look: [*]Look,
    role: [*]u8,
    value: [*]f32,
    text: [*]u32,
    custom: [*]u32,
    extra: [*]u32,
    scope: [*]u32,
    x_node: [*]u32,
    x_row: [*]Extra,
};

/// Bit of `CView.status` that `enter` sets when the stack overflows (`Status.depth`).
pub const depth_bit: u5 = @bitOffsetOf(context.Status, "depth");

/// The view of frame `f`'s tree.
pub fn of(f: *const Frame) CView {
    const ctx = f.ctx;
    const t = f.tree();
    const c = &t.c;
    var v: CView = undefined;
    v.len = &t.len;
    v.xlen = &t.xlen;
    v.overflow = &t.overflow;
    v.depth = &ctx.depth;
    v.status = @ptrCast(&ctx.status);
    v.cap = t.cap;
    v.depth_cap = ctx.limits.depth;
    v.stack = ctx.stack.ptr;
    inline for (@typeInfo(CView).@"struct".field_names) |name| {
        if (comptime @hasField(@TypeOf(c.*), name)) {
            const col = @field(c, name);
            if (@TypeOf(col) == [2][]f32) {
                @field(v, name) = .{ col[0].ptr, col[1].ptr };
            } else @field(v, name) = col.ptr;
        }
    }
    v.x_node = t.x.node.ptr;
    v.x_row = t.x.row.ptr;
    return v;
}
