//! Features required by a spec. Includes every possible child of a dynamic region.
const std = @import("std");
const spec_zig = @import("spec.zig");
const features = @import("../draw/features.zig");

pub fn usage(comptime spec: spec_zig.Spec) features.Usage {
    comptime {
        @setEvalBranchQuota(1000 + 40 * @import("flatten.zig").count(spec));
        var out: features.Usage = .{};
        collect(spec, &out);
        return out;
    }
}

fn collect(comptime spec: spec_zig.Spec, out: *features.Usage) void {
    const style = spec.style;
    // A user widget can push arbitrary styles and text, a user shader can read every input.
    if (spec.widget != null or style.material != .solid) {
        out.* = .all;
        return;
    }
    out.text = out.text or spec.kind == .label;
    out.image = out.image or style.texture != .white;
    // The widget front end emits a rounded, bordered checkbox indicator and a rounded slider thumb.
    out.border = out.border or spec.kind == .checkbox or style.border >= 0.001;
    out.radius = out.radius or spec.kind == .checkbox or spec.kind == .slider or style.radius > 0 or
        @reduce(.Or, @as(@Vector(4, f32), style.radii) > @as(@Vector(4, f32), @splat(0)));
    out.kinds.insert(std.enums.fromInt(features.Kind, @as(u32, @bitCast(style.params[0]))) orelse .solid);
    for (spec.children) |child| collect(child, out);
}

test "usage collects nested sources, labels, clip radii and stock material selectors" {
    const minimal = comptime usage(spec_zig.col(.{ .fill = .white }, .{}));
    try std.testing.expectEqual(features.Usage{}, minimal);
    const mixed = comptime usage(spec_zig.col(.{ .clip = true, .radii = .{ -1, -1, 3, -1 } }, .{
        spec_zig.label(.caption),
        spec_zig.col(.{ .texture = @fromBackingInt(1), .border = 1, .params = features.dotted(2) }, .{}),
    }));
    try std.testing.expect(mixed.text and mixed.radius and mixed.border and mixed.image);
    try std.testing.expectEqualSlices(features.Kind, &.{ .solid, .dotted }, mixed.kindList());
    try std.testing.expectEqual(features.Usage.all, comptime usage(.{ .kind = .col, .widget = struct {} }));
}
