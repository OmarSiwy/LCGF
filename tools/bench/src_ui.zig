//! The names bench/scenes/ build with, taken from lcgf's runtime front end (src/runtime/) and
//! reference widgets (src/widgets/base.zig), so the same scene source builds against either core.
const lcgf = @import("lcgf");

pub const Frame = lcgf.frame.Frame;
pub const Input = lcgf.input.Input;
pub const Theme = lcgf.widgets_base.Theme;
pub const Id = lcgf.types.Id;
pub const Color = lcgf.types.Color;
pub const widgets = lcgf.widgets_base;
