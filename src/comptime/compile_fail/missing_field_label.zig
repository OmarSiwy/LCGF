//! expect: col > label[0]: state missing_field_label.State has no field 'tilte'
const s = @import("lcgr").spec;

/// A declaration is not a field: binding to it is still an error.
const State = struct {
    title: []const u8 = "",
    pub const tilte = "decl";
};

comptime {
    @import("lcgr").validate.check(State, s.col(.{}, .{s.label(.tilte)}));
}
