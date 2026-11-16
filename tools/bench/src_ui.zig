//! The names bench/scenes/ build with, taken from lcgr's runtime front end (src/runtime/) and
//! reference widgets (src/widgets/base.zig), so the same scene source builds against either core.
const lcgr = @import("lcgr");

pub const Frame = lcgr.frame.Frame;
pub const Input = lcgr.input.Input;
pub const Theme = lcgr.widgets_base.Theme;
pub const Id = lcgr.types.Id;
pub const Color = lcgr.types.Color;
pub const widgets = lcgr.widgets_base;
