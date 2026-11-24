//! Typed styling as independently callable operations. Core Style/TextStyle stay available;
//! this optional authoring layer lowers to them and owns no storage or frame sequencing.

pub const properties = @import("properties.zig");
pub const tokens = @import("tokens.zig");
pub const environment = @import("environment.zig");
pub const resolution = @import("resolve.zig");
pub const storage = @import("storage.zig");
pub const paragraph = @import("paragraph.zig");
pub const Property = properties.Property;
pub const Value = properties.Value;
pub const Computed = properties.Computed;
pub const Invalidation = properties.Invalidation;
pub const Declaration = resolution.Declaration;
pub const Rule = resolution.Rule;
pub const Request = resolution.Request;
pub const Parts = resolution.Parts;
pub const States = resolution.States;
pub const Origin = resolution.Origin;
pub const Error = resolution.Error;
pub const set = resolution.set;
pub const inherit = resolution.inherit;
pub const initial = resolution.initial;
pub const token = resolution.token;
pub const patch = resolution.patch;
pub const resolve = resolution.resolve;
pub const inspect = resolution.inspect;

test {
    @import("std").testing.refAllDecls(@This());
}

pub const compiler = @import("compiler.zig");
