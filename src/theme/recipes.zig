//! Optional component recipes with caller-owned data and independent resolution. Existing
//! theme/widget APIs remain the direct lightweight path; recipes lower to the same consumers.

pub const model = @import("recipe.zig");
pub const controls = @import("recipe_controls.zig");
pub const ct = @import("recipe_comptime.zig");
pub const tests = @import("recipe_tests.zig");
pub const parts = @import("recipe_parts.zig");
pub const comptime_parts = @import("recipe_part_comptime.zig");
pub const extra_controls = @import("recipe_extra_controls.zig");
pub const extra_tests = @import("recipe_extra_tests.zig");
pub const overlays = @import("recipe_overlays.zig");
pub const defaults = model;
pub const Recipe = model.Recipe;
pub const Part = model.Part;
pub const Use = model.Use;
pub const Names = model.Names;
pub const tokenRows = model.tokenRows;
pub const Options = controls.Options;
pub const OpenControl = controls.OpenControl;
pub const beginButton = controls.beginButton;
pub const label = controls.label;
pub const icon = controls.icon;
pub const directionalIcon = controls.directionalIcon;
pub const end = controls.end;
pub const beginBox = controls.beginBox;
pub const endBox = controls.endBox;
pub const button = controls.button;
pub const beginLink = controls.beginLink;
pub const link = controls.link;
pub const search = controls.search;
pub const toggle = controls.toggle;
pub const checkbox = controls.checkbox;
pub const switchControl = controls.switchControl;
pub const slider = controls.slider;
pub const progress = controls.progress;
pub const textfield = controls.textfield;
pub const textarea = parts.textarea;
pub const radio = extra_controls.radio;
pub const range = extra_controls.range;
pub const spinner = extra_controls.spinner;

test {
    @import("std").testing.refAllDecls(@This());
}
