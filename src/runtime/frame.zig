//! Frame: one frame under construction in the runtime front end (tier 1). `Context.begin`
//! returns one; the caller builds the tree through it and ends it. Ported from prototype/ui.zig
//! ("Context and Frame").

const Context = @import("context.zig").Context;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;

/// One frame under construction. Cheap to copy: two pointers.
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
};
