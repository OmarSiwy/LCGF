//! LCGR: Lightweight Comptime Graphics Renderer. The package root.
//!
//! Each file under src/ is exported here as `pub const name = @import("dir/name.zig");`.
//! A file that is not exported is not compiled and its tests do not run.

const std = @import("std");

pub const simd = @import("core/simd.zig");
pub const input = @import("core/input.zig");
pub const types = @import("core/types.zig");
pub const mem = @import("core/mem.zig");
pub const tree = @import("core/tree.zig");
pub const strings = @import("core/strings.zig");
pub const texts = @import("core/texts.zig");
pub const customs = @import("core/customs.zig");
pub const layout = @import("layout/layout.zig");
pub const hit = @import("interact/hit.zig");
pub const overlay = @import("layout/overlay.zig");
pub const flex = @import("layout/flex.zig");
pub const layout_check = @import("layout/check.zig");
pub const coefs = @import("layout/coefs.zig");
pub const incremental = @import("layout/incremental.zig");
pub const interaction = @import("interact/interaction.zig");
pub const spec = @import("comptime/spec.zig");
pub const protocol = @import("text/protocol.zig");
pub const flatten = @import("comptime/flatten.zig");
pub const signals = @import("comptime/signals.zig");
pub const draw_list = @import("draw/draw_list.zig");
pub const opentype = @import("text/font/opentype.zig");
pub const unicode_property = @import("text/unicode/property.zig");
pub const unicode_utf8 = @import("text/unicode/utf8.zig");
pub const unicode_grapheme = @import("text/unicode/grapheme.zig");
pub const unicode_word = @import("text/unicode/word.zig");
pub const paint = @import("draw/paint.zig");
pub const damage = @import("draw/damage.zig");
pub const features = @import("draw/features.zig");
pub const unicode_line = @import("text/unicode/line.zig");
pub const unicode_bidi = @import("text/unicode/bidi.zig");
pub const unicode_script = @import("text/unicode/script.zig");

test {
    std.testing.refAllDecls(@This());
}
