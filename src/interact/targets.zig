//! Optional visual-independent hit targets. Entries are caller-owned, sorted by tree row;
//! retain them with the completed tree until the next input step. This adds no storage to
//! ordinary nodes. Feed `at` to Context.beginWithHit; normal widget behavior and capture then
//! consume that exact target. For simultaneous contacts, query each position and pass the
//! resulting rows to Touches.stepWithHits. Pure comptime callers use
//! Paint.hitTarget/Events.atPaintTargets.
const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const geometry = @import("../draw/geometry.zig");
const paths = @import("../draw/paths.zig");
const hit = @import("hit.zig");

pub const Shape = union(enum) {
    rectangle,
    rounded,
    ellipse,
    /// Coordinates relative to the node's border-box origin. Fill rules close open contours
    /// as the native path rasterizer does. Borrowed points must outlive the input step.
    path: struct { polyline: *const paths.Polyline, rule: paths.Rule = .nonzero },
};
pub const Policy = struct {
    /// Left/top/right/bottom growth in local logical pixels, before the node's transform.
    padding: [4]f32 = @splat(0),
    /// Symmetric growth after padding. This does not reserve layout space or change paint.
    minimum: [2]f32 = .{ 0, 0 },
    shape: Shape = .rectangle,
};
pub const Entry = struct { node: u32, policy: Policy };
pub const Error = error{ InvalidNode, InvalidPolicy, InvalidPath, InvalidLayers };

pub fn validate(entries: []const Entry, nodes: usize) Error!void {
    for (entries, 0..) |entry, i| {
        if (entry.node >= nodes or (i != 0 and entry.node <= entries[i - 1].node)) return error.InvalidNode;
        try validatePolicy(entry.policy);
    }
}
pub fn validatePolicy(policy: Policy) Error!void {
    for (policy.padding ++ policy.minimum) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPolicy;
    if (policy.shape == .path) {
        for (policy.padding ++ policy.minimum) |value| if (value != 0) return error.InvalidPolicy;
        const p = policy.shape.path.polyline;
        if (p.points > p.x.len or p.points > p.y.len or p.contours > p.end.len) return error.InvalidPath;
        var first: u32 = 0;
        for (p.end[0..p.contours]) |end| {
            if (end <= first or end > p.points) return error.InvalidPath;
            first = end;
        }
        if (first != p.points) return error.InvalidPath;
        for (p.x[0..p.points], p.y[0..p.points]) |x, y| if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidPath;
    }
}

/// Find a policy in a validated sorted list. Missing entries use the normal rectangle.
pub fn policyAt(entries: []const Entry, node: u32) Policy {
    var lo: usize = 0;
    var hi = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].node < node) lo = mid + 1 else hi = mid;
    }
    return if (lo < entries.len and entries[lo].node == node) entries[lo].policy else .{};
}

pub fn rect(border: [4]f32, policy: Policy) [4]f32 {
    var result = geometry.expand(border, policy.padding);
    inline for (0..2) |axis| {
        const growth = @max(0, policy.minimum[axis] - (result[axis + 2] - result[axis])) * 0.5;
        result[axis] -= growth;
        result[axis + 2] += growth;
    }
    return result;
}

/// The same local target calculation is shared by runtime and pure comptime hit testing.
/// Ancestor clips are checked separately in screen space; own clipping does not shrink a
/// control's border or its deliberately larger input target.
pub fn contains(border: [4]f32, radii: [4]f32, point: [2]f32, policy: Policy) bool {
    // Collapsed or absent rows never become active through minimum target sizes.
    if (!geometry.hasArea(border)) return false;
    if (policy.shape == .path) return pathContains(policy.shape.path.polyline, policy.shape.path.rule, .{ point[0] - border[0], point[1] - border[1] });
    const target = rect(border, policy);
    if (!geometry.contains(target, point)) return false;
    return switch (policy.shape) {
        .rectangle => true,
        .rounded => blk: {
            const grow = [4]f32{ border[0] - target[0], border[1] - target[1], target[2] - border[2], target[3] - border[3] };
            break :blk geometry.roundedContains(target, .{ radii[0] + @min(grow[0], grow[1]), radii[1] + @min(grow[2], grow[1]), radii[2] + @min(grow[2], grow[3]), radii[3] + @min(grow[0], grow[3]) }, point);
        },
        .ellipse => blk: {
            const x = (2 * point[0] - target[0] - target[2]) / (target[2] - target[0]);
            const y = (2 * point[1] - target[1] - target[3]) / (target[3] - target[1]);
            break :blk x * x + y * y <= 1;
        },
        .path => unreachable,
    };
}

/// Point-in-path for the same flattened geometry and winding rules used by paths.fill.
/// Half-open crossings keep shared edges deterministic. Input has been validated once.
pub fn pathContains(path: *const paths.Polyline, rule: paths.Rule, point: [2]f32) bool {
    var winding: i32 = 0;
    var first: usize = 0;
    for (path.end[0..path.contours]) |end| {
        for (first..end) |i| {
            const j = if (i + 1 == end) first else i + 1;
            const y0 = path.y[i];
            const y1 = path.y[j];
            const rising = y0 <= point[1] and y1 > point[1];
            const falling = y1 <= point[1] and y0 > point[1];
            if (!rising and !falling) continue;
            const x = path.x[i] + (point[1] - y0) * (path.x[j] - path.x[i]) / (y1 - y0);
            if (point[0] < x) winding += if (rising) @as(i32, 1) else -1;
        }
        first = end;
    }
    return if (rule == .even_odd) @mod(winding, 2) != 0 else winding != 0;
}

pub fn nodeContains(tree: *const Tree, node: u32, screen: [2]f32, policy: Policy) bool {
    if (node >= tree.len or !tree.participation(node).hit) return false;
    const inverse = geometry.inverse(geometry.worldAt(tree, node)) orelse return false;
    const c = &tree.c;
    const extra = tree.x.row[c.extra[node]];
    const radii = @import("../core/tree.zig").radiiOf(extra.radii, c.look[node].radius);
    return contains(.{ c.rect[0][node], c.rect[1][node], c.rect[2][node], c.rect[3][node] }, radii, geometry.point(inverse, screen), policy) and geometry.clipsContain(tree, node, screen);
}

/// Highest (layer,row) wins overlapping targets; an empty layers slice uses row order.
/// No entries preserves the existing SIMD route. Opting in refines geometry and ancestor
/// clips, so a target can grow into empty space without crossing a clipping ancestor.
pub fn at(tree: *const Tree, entries: []const Entry, screen: [2]f32, want: types.Sense, layers: []const u8) Error!u32 {
    try validate(entries, tree.len);
    if (layers.len != 0 and layers.len < @import("../core/simd.zig").padded(tree.len)) return error.InvalidLayers;
    if (entries.len == 0) return if (layers.len == 0) hit.at(tree, screen[0], screen[1], want) else hit.atLayered(tree, layers, screen[0], screen[1], want);
    var found: u32 = types.none;
    var level: u8 = 0;
    for (0..tree.len) |i| {
        if ((tree.c.sense[i] & @as(u8, @bitCast(want))) == 0) continue;
        const next_level = if (layers.len == 0) 0 else layers[i];
        if (next_level < level) continue;
        if (nodeContains(tree, @intCast(i), screen, policyAt(entries, @intCast(i)))) {
            found = @intCast(i);
            level = next_level;
        }
    }
    return found;
}

test "expanded transformed targets preserve clipping, ordering, real activation and unchanged paint" {
    const Context = @import("../runtime/context.zig").Context;
    const Input = @import("../core/input.zig").Input;
    const limits: @import("../runtime/context.zig").Limits = .{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 5 };
    var memory: [Context.requiredBytes(limits)]u8 align(@import("../core/mem.zig").column_align) = undefined;
    var ctx = try Context.init(&memory, limits);
    var input: Input = .{ .viewport = .{ 100, 100 }, .pointer = .{ 36, 16 } };
    const Build = struct {
        fn run(f: *@import("../runtime/frame.zig").Frame) types.Response {
            _ = f.open(.from("clip"), .{ .size = .{ .px(50), .px(50) }, .clip = true, .radius = 8, .transform = .{ 1, 0, 0, 1, 20, 0 } });
            const n = f.leaf(.from("small"), .{ .float = true, .offset = .{ 20, 10 }, .size = .{ .px(10), .px(10) }, .fill = .white });
            const r = f.interact(n, .button);
            f.close();
            return r;
        }
    };
    var f = ctx.begin(&input);
    _ = Build.run(&f);
    const original = f.end(.{});
    const n = original.tree.find(.from("small"));
    const entry = [_]Entry{.{ .node = n, .policy = .{ .minimum = .{ 24, 24 }, .shape = .rounded } }};
    try std.testing.expectEqual(types.none, hit.at(original.tree, 36, 16, .any));
    try std.testing.expectEqual(n, try at(original.tree, &entry, input.pointer, .any, &.{}));
    try std.testing.expectEqual(types.none, try at(original.tree, &entry, .{ 19, 16 }, .any, &.{}));
    input.buttons.left = true;
    f = ctx.beginWithHit(&input, try at(&ctx.trees[ctx.cur], &entry, input.pointer, .any, &.{}));
    try std.testing.expect(Build.run(&f).pressed);
    const pressed = f.end(.{});
    try std.testing.expectEqual(@as(f32, 10), pressed.tree.rect(n).w());
    input.buttons.left = false;
    f = ctx.beginWithHit(&input, try at(&ctx.trees[ctx.cur], &entry, input.pointer, .any, &.{}));
    try std.testing.expect(Build.run(&f).clicked);
    _ = f.end(.{});
}

test "path targets share evenodd/nonzero holes and validate ambiguous expansion" {
    var x = [_]f32{ 0, 10, 10, 0, 3, 7, 7, 3 };
    var y = [_]f32{ 0, 0, 10, 10, 3, 3, 7, 7 };
    var ends = [_]u32{ 4, 8 };
    var closed = [_]bool{ true, true };
    const path: paths.Polyline = .{ .x = &x, .y = &y, .end = &ends, .closed = &closed, .points = 8, .contours = 2 };
    const policy: Policy = .{ .shape = .{ .path = .{ .polyline = &path, .rule = .even_odd } } };
    try validatePolicy(policy);
    try std.testing.expect(contains(.{ 20, 20, 30, 30 }, @splat(0), .{ 21, 21 }, policy));
    try std.testing.expect(!contains(.{ 20, 20, 30, 30 }, @splat(0), .{ 25, 25 }, policy));
    try std.testing.expect(pathContains(&path, .nonzero, .{ 5, 5 }));
    var invalid = policy;
    invalid.padding[0] = 1;
    try std.testing.expectError(error.InvalidPolicy, validatePolicy(invalid));
}

test "expanded targets agree across pure comptime and layered runtime input" {
    const Spec = @import("../comptime/spec.zig").Spec;
    const sp = @import("../comptime/spec.zig");
    const spec = sp.col(.{ .size = .{ .px(80), .px(40) }, .clip = true }, .{
        Spec{ .kind = .checkbox, .id = "a", .style = .{ .float = true, .offset = .{ 10, 10 }, .size = .{ .px(10), .px(10) }, .fill = .white } },
        Spec{ .kind = .checkbox, .id = "b", .style = .{ .float = true, .offset = .{ 25, 10 }, .size = .{ .px(10), .px(10) }, .fill = .white } },
    });
    const L = @import("../comptime/layout.zig").Layout(spec, .{ .require_names = false });
    const P = @import("../comptime/paint.zig").Paint(spec, .{ .require_names = false });
    const E = @import("../comptime/events.zig").Events(spec);
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;
    L.run(&scratch, &ram, .{ 80, 40 });
    const entries = [_]Entry{ .{ .node = 1, .policy = .{ .minimum = .{ 24, 24 } } }, .{ .node = 2, .policy = .{ .minimum = .{ 24, 24 } } } };
    try std.testing.expectEqual(E.Widget.b, (try E.atPaintTargets(P, &ram, &entries, 23, 15)).?);
    try std.testing.expectEqual(@as(?E.Widget, null), E.atPaint(P, &ram, 23, 15));
    try std.testing.expectEqual(@as(?E.Widget, null), try E.atPaintTargets(P, &ram, &entries, -1, 15));
    var buffer: [32768]u8 align(64) = undefined;
    var carve: @import("../core/mem.zig").Carver = .{ .buf = &buffer };
    var tree = Tree.init(&carve, 8);
    _ = tree.push(0, .none, &spec.style);
    inline for (spec.children) |child| {
        const n = tree.push(0, .none, &child.style);
        tree.c.sense[n] = @bitCast(types.Sense.button);
        tree.seal(n);
    }
    tree.seal(0);
    var tx = @import("../core/texts.zig").Texts.init(&carve, 1);
    @import("../layout/layout.zig").run(&tree, &tx, .{ 80, 40 });
    try std.testing.expectEqual(@as(u32, 2), try at(&tree, &entries, .{ 23, 15 }, .any, &.{}));
    var layers: [@import("../core/simd.zig").rows(8)]u8 = @splat(0);
    layers[1] = 1;
    try std.testing.expectEqual(@as(u32, 1), try at(&tree, &entries, .{ 23, 15 }, .any, &layers));
    try std.testing.expect(!contains(.{ 0, 0, 0, 0 }, @splat(0), .{ 0, 0 }, .{ .minimum = .{ 24, 24 } }));
}
