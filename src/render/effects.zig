//! Explicit optional filter graphs and backdrop snapshots. A node reads external images or
//! earlier nodes and writes one caller-owned surface. There is no retained graph, allocator,
//! surface cache, callback, or automatic scene capture. The host sequences drawRange, run,
//! composite, and later scene draws. Every output is inspectable and reusable as an image.

const std = @import("std");
const surface = @import("../draw/surface.zig");
const compositor = @import("../draw/compositor.zig");
const primitives = @import("../draw/filter_primitives.zig");
const brushes = @import("../draw/brushes.zig");
const geometry = @import("../draw/geometry.zig");
const color = @import("../draw/color_math.zig");
const prepared = @import("prepared.zig");

pub const Error = prepared.Error || primitives.Error || error{ InvalidGraph, InvalidReference };
pub const Ref = union(enum) { external: u32, node: u32 };
pub const Operation = union(enum) {
    copy: struct { origin: [2]i32 = .{ 0, 0 }, edge: [2]brushes.Address = .{ .transparent, .transparent } },
    composite: compositor.Options,
    mask: compositor.MaskOptions,
    combine_mask: struct { mode: compositor.MaskMode = .alpha, operator: compositor.MaskOperator = .intersect },
    matrix: compositor.ColorMatrix,
    components: struct { channels: [4]primitives.Component, space: compositor.FilterSpace = .linear_srgb },
    blur: struct { sigma: f32, edge: [2]brushes.Address = .{ .transparent, .transparent } },
    morphology: struct { radius: [2]u32, mode: compositor.Morphology, edge: [2]brushes.Address = .{ .transparent, .transparent } },
    shadow: struct { sigma: f32, offset: [2]i32 = .{ 0, 0 }, tint: color.Rgba },
    displacement: compositor.Displacement,
    convolution: primitives.Kernel,
    arithmetic: [4]f32,
    turbulence: primitives.Noise,
    lighting: primitives.Lighting,
};
pub const Node = struct { a: Ref = .{ .external = 0 }, b: Ref = .{ .external = 0 }, operation: Operation };
pub const Limits = struct {
    surfaces: prepared.Limits = .{},
    convolution_taps: usize = 4096,
    morphology_radius: u32 = 512,
    noise_octaves: u8 = 12,
};
pub const Storage = struct { outputs: []const surface.Surface, work: [2]surface.Surface, kernel: []f32 };
pub const Report = struct { image: surface.Image, passes: u32, peak_bytes: usize };

fn arity(operation: Operation) u2 {
    return switch (operation) {
        .turbulence => 0,
        .composite, .mask, .combine_mask, .displacement, .arithmetic => 2,
        else => 1,
    };
}

fn reference(ref: Ref, before: usize, external: []const surface.Image, outputs: []const surface.Surface) Error!surface.Image {
    return switch (ref) {
        .external => |i| if (i < external.len) external[i] else error.InvalidReference,
        .node => |i| if (i < before) outputs[i].view() else error.InvalidReference,
    };
}

/// Validate shape, references, resource budgets and aliasing before modifying any pixels.
/// Primitive-specific numeric authoring errors are returned by the corresponding operation.
pub fn validate(nodes: []const Node, external: []const surface.Image, storage: Storage, limits: Limits) Error!usize {
    if (nodes.len == 0) return error.InvalidGraph;
    if (nodes.len > limits.surfaces.layers) return error.BudgetExceeded;
    if (storage.outputs.len < nodes.len) return error.NoSpace;
    const size = storage.outputs[0];
    if (size.width == 0 or size.height == 0) return error.InvalidSize;
    _ = try limits.surfaces.pixels(size.width, size.height);
    var bytes: usize = 0;
    // Every output stays alive for inspection. Applications may instead call the primitives
    // directly to reuse dead intermediates; this diagonal makes no hidden lifetime decisions.
    for (0..nodes.len + 2) |i| {
        const item = if (i < nodes.len) storage.outputs[i] else storage.work[i - nodes.len];
        try item.validate();
        if (item.width != size.width or item.height != size.height) return error.SizeMismatch;
        const count = std.math.mul(usize, item.stride, item.height) catch return error.BudgetExceeded;
        bytes = std.math.add(usize, bytes, std.math.mul(usize, count, 4) catch return error.BudgetExceeded) catch return error.BudgetExceeded;
        for (0..i) |j| {
            const previous = if (j < nodes.len) storage.outputs[j] else storage.work[j - nodes.len];
            if (surface.overlaps(item.pixels, previous.pixels)) return error.AliasedStorage;
        }
        for (external) |image| {
            try image.validate();
            if (surface.overlaps(item.pixels, image.pixels)) return error.AliasedStorage;
        }
        if (surface.overlapsBytes(std.mem.sliceAsBytes(item.pixels), std.mem.sliceAsBytes(storage.kernel))) return error.AliasedStorage;
    }
    bytes = std.math.add(usize, bytes, std.math.mul(usize, storage.kernel.len, @sizeOf(f32)) catch return error.BudgetExceeded) catch return error.BudgetExceeded;
    if (bytes > limits.surfaces.bytes) return error.BudgetExceeded;
    for (nodes, 0..) |node, i| {
        if (arity(node.operation) > 0) _ = try reference(node.a, i, external, storage.outputs);
        if (arity(node.operation) > 1) _ = try reference(node.b, i, external, storage.outputs);
        switch (node.operation) {
            .blur => |v| try validateSigma(v.sigma, storage.kernel.len, limits),
            .shadow => |v| try validateSigma(v.sigma, storage.kernel.len, limits),
            .morphology => |v| if (@max(v.radius[0], v.radius[1]) > limits.morphology_radius) return error.BudgetExceeded,
            .convolution => |v| if (v.values.len > limits.convolution_taps) return error.BudgetExceeded,
            .turbulence => |v| if (v.octaves > limits.noise_octaves) return error.BudgetExceeded,
            else => {},
        }
    }
    return bytes;
}

fn validateSigma(sigma: f32, capacity: usize, limits: Limits) Error!void {
    if (sigma > limits.surfaces.blur_sigma) return error.BudgetExceeded;
    if (try compositor.gaussianKernelLength(sigma) > capacity) return error.NoSpace;
}

fn copy(dst: surface.Surface, src: surface.Image) Error!void {
    try compositor.capture(dst, src, .{ 0, 0 }, .{ .transparent, .transparent });
}

/// Execute in the supplied order; backward-only references make cycles impossible.
/// `passes` counts actual full-surface primitive sweeps (a blur has two convolution passes).
pub fn run(nodes: []const Node, external: []const surface.Image, storage: Storage, limits: Limits) Error!Report {
    const bytes = try validate(nodes, external, storage, limits);
    var passes: u32 = 0;
    for (nodes, 0..) |node, i| {
        const out = storage.outputs[i];
        const a: surface.Image = if (arity(node.operation) > 0) try reference(node.a, i, external, storage.outputs) else undefined;
        const b: surface.Image = if (arity(node.operation) > 1) try reference(node.b, i, external, storage.outputs) else undefined;
        switch (node.operation) {
            .copy => |v| {
                try compositor.capture(out, a, v.origin, v.edge);
                passes += 1;
            },
            .composite => |v| {
                try copy(out, a);
                try compositor.composite(out, b, v);
                passes += 2;
            },
            .mask => |v| {
                try copy(out, a);
                try compositor.applyMask(out, b, v);
                passes += 2;
            },
            .combine_mask => |v| {
                try copy(out, a);
                try compositor.combineMask(out, b, v.mode, v.operator);
                passes += 2;
            },
            .matrix => |v| {
                try copy(out, a);
                try compositor.colorMatrix(out, v);
                passes += 2;
            },
            .components => |v| {
                try copy(out, a);
                try primitives.componentTransfer(out, v.channels, v.space);
                passes += 2;
            },
            .blur => |v| {
                const kernel = try compositor.gaussianKernel(v.sigma, storage.kernel);
                try copy(storage.work[0], a);
                try compositor.blur(storage.work[0], out, storage.work[1], kernel, v.edge);
                passes += 3;
            },
            .morphology => |v| {
                try copy(storage.work[0], a);
                try compositor.morphology(storage.work[0], out, storage.work[1], v.radius, v.mode, v.edge);
                passes += 3;
            },
            .shadow => |v| {
                const kernel = try compositor.gaussianKernel(v.sigma, storage.kernel);
                try copy(storage.work[0], a);
                try compositor.dropShadow(storage.work[0], out, storage.work[1], kernel, v.offset, v.tint);
                passes += 8;
            },
            .displacement => |v| {
                try compositor.displace(out, a, b, v);
                passes += 1;
            },
            .convolution => |v| {
                try primitives.convolve(out, a, v);
                passes += 1;
            },
            .arithmetic => |v| {
                try primitives.arithmetic(out, a, b, v);
                passes += 1;
            },
            .turbulence => |v| {
                try primitives.turbulence(out, v);
                passes += 1;
            },
            .lighting => |v| {
                try primitives.lighting(out, a, v);
                passes += 1;
            },
        }
    }
    return .{ .image = storage.outputs[nodes.len - 1].view(), .passes = passes, .peak_bytes = bytes };
}

/// Propagate changed external resources through the graph into caller-owned flags. The host
/// can reuse unchanged outputs with its own cache; no generations or dirty state are hidden.
pub fn changes(nodes: []const Node, external: []const bool, node_changes: []const bool, out: []bool) Error!void {
    if (node_changes.len != 0 and node_changes.len != nodes.len) return error.InvalidGraph;
    if (out.len < nodes.len) return error.NoSpace;
    for (nodes, 0..) |node, i| {
        var changed = node_changes.len != 0 and node_changes[i];
        const refs = [_]Ref{ node.a, node.b };
        for (refs[0..arity(node.operation)]) |ref| {
            const input_changed = switch (ref) {
                .external => |k| if (k < external.len) external[k] else return error.InvalidReference,
                .node => |k| if (k < i) out[k] else return error.InvalidReference,
            };
            changed = changed or input_changed;
        }
        out[i] = changed;
    }
}

/// A backdrop samples the already-painted scene over this world-space region. The host owns
/// its revision. Moving background damage inside the sampling halo invalidates the snapshot,
/// even when the panel's geometry and foreground are unchanged.
pub const Backdrop = struct {
    origin: [2]i32,
    size: [2]u32,
    sigma: f32,
    edge: [2]brushes.Address = .{ .clamp, .clamp },

    pub fn dependency(value: Backdrop) Error![4]f32 {
        _ = try compositor.gaussianKernelLength(value.sigma);
        const x: f32 = @floatFromInt(value.origin[0]);
        const y: f32 = @floatFromInt(value.origin[1]);
        return geometry.expand(.{ x, y, x + @as(f32, @floatFromInt(value.size[0])), y + @as(f32, @floatFromInt(value.size[1])) }, @splat(@ceil(value.sigma * 3)));
    }

    pub fn affected(value: Backdrop, damaged: []const [4]f32) Error!bool {
        const needed = try value.dependency();
        for (damaged) |rect| if (geometry.hasArea(geometry.intersect(needed, rect))) return true;
        return false;
    }

    /// Halo-inclusive dimensions required by captureFiltered. All three buffers use these
    /// dimensions; the returned origin identifies them in the scene for subsequent clipping.
    pub fn dimensions(value: Backdrop, limits: prepared.Limits) Error!struct { origin: [2]i32, size: [2]u32 } {
        const rect = try value.dependency();
        if (value.sigma > limits.blur_sigma) return error.BudgetExceeded;
        if (rect[0] < -2147483648 or rect[1] < -2147483648 or rect[2] >= 2147483648 or rect[3] >= 2147483648) return error.BudgetExceeded;
        const size: [2]u32 = .{ @intFromFloat(rect[2] - rect[0]), @intFromFloat(rect[3] - rect[1]) };
        if (size[0] == 0 or size[1] == 0) return error.InvalidSize;
        _ = try limits.pixels(size[0], size[1]);
        return .{ .origin = .{ @intFromFloat(rect[0]), @intFromFloat(rect[1]) }, .size = size };
    }

    /// Capture before drawing this panel, blur including its halo, then let the caller mask
    /// to the intended panel shape and composite exactly once at the returned world origin.
    pub fn captureFiltered(value: Backdrop, scene: surface.Image, out: surface.Surface, captured: surface.Surface, scratch: surface.Surface, kernel_storage: []f32, limits: prepared.Limits) Error![2]i32 {
        const dims = try value.dimensions(limits);
        for ([_]surface.Surface{ out, captured, scratch }) |s| {
            try s.validate();
            if (s.width != dims.size[0] or s.height != dims.size[1]) return error.SizeMismatch;
        }
        var bytes: usize = 0;
        for ([_]surface.Surface{ out, captured, scratch }) |s| {
            bytes = std.math.add(usize, bytes, std.math.mul(usize, s.pixels.len, 4) catch return error.BudgetExceeded) catch return error.BudgetExceeded;
            if (surface.overlapsBytes(std.mem.sliceAsBytes(s.pixels), std.mem.sliceAsBytes(kernel_storage))) return error.AliasedStorage;
        }
        bytes = std.math.add(usize, bytes, std.math.mul(usize, kernel_storage.len, 4) catch return error.BudgetExceeded) catch return error.BudgetExceeded;
        if (surface.overlapsBytes(std.mem.sliceAsBytes(scene.pixels), std.mem.sliceAsBytes(kernel_storage))) return error.AliasedStorage;
        if (bytes > limits.bytes) return error.BudgetExceeded;
        if (surface.overlaps(out.pixels, captured.pixels) or surface.overlaps(out.pixels, scratch.pixels) or surface.overlaps(captured.pixels, scratch.pixels) or
            surface.overlaps(scene.pixels, out.pixels) or surface.overlaps(scene.pixels, captured.pixels) or surface.overlaps(scene.pixels, scratch.pixels)) return error.AliasedStorage;
        const kernel = try compositor.gaussianKernel(value.sigma, kernel_storage);
        try compositor.capture(captured, scene, dims.origin, value.edge);
        try compositor.blur(captured, out, scratch, kernel, value.edge);
        return dims.origin;
    }
};

test "filter graph blends group pixels and propagates external changes" {
    var raw: [5][1024]u32 = undefined;
    var buffers: [5]surface.Surface = undefined;
    for (&buffers, &raw) |*dst, *pixels| dst.* = try surface.init(pixels, 4, 4);
    var kernel: [33]f32 = undefined;
    const red: surface.Image = .{ .pixels = &.{0xff0000ff}, .width = 1, .height = 1, .stride = 1 };
    const blue: surface.Image = .{ .pixels = &.{0xffff0000}, .width = 1, .height = 1, .stride = 1 };
    const nodes = [_]Node{
        .{ .operation = .{ .copy = .{ .edge = .{ .clamp, .clamp } } } },
        .{ .a = .{ .external = 1 }, .operation = .{ .copy = .{ .edge = .{ .clamp, .clamp } } } },
        .{ .a = .{ .node = 0 }, .b = .{ .node = 1 }, .operation = .{ .composite = .{ .opacity = 0.5 } } },
    };
    const result = try run(&nodes, &.{ red, blue }, .{ .outputs = buffers[0..3], .work = buffers[3..5].*, .kernel = &kernel }, .{});
    try std.testing.expectEqual(@as(u32, 0xff800080), result.image.pixels[0]);
    try std.testing.expectEqual(@as(u32, 4), result.passes);
    var dirty: [3]bool = undefined;
    try changes(&nodes, &.{ false, true }, &.{}, &dirty);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, &dirty);
    const before = result.image.pixels[0];
    try std.testing.expectError(error.BudgetExceeded, run(&nodes, &.{ red, blue }, .{ .outputs = buffers[0..3], .work = buffers[3..5].*, .kernel = &kernel }, .{ .surfaces = .{ .bytes = 1 } }));
    try std.testing.expectEqual(before, result.image.pixels[0]);
    var bad = nodes;
    bad[0].a = .{ .node = 0 };
    try std.testing.expectError(error.InvalidReference, run(&bad, &.{ red, blue }, .{ .outputs = buffers[0..3], .work = buffers[3..5].*, .kernel = &kernel }, .{}));
}

test "backdrop refresh follows changed background inside the blur halo" {
    const panel: Backdrop = .{ .origin = .{ 10, 10 }, .size = .{ 4, 4 }, .sigma = 1 };
    try std.testing.expect(try panel.affected(&.{.{ 8, 10, 9, 11 }}));
    try std.testing.expect(!try panel.affected(&.{.{ 0, 0, 2, 2 }}));
    const dims = try panel.dimensions(.{});
    try std.testing.expectEqual([2]u32{ 10, 10 }, dims.size);
    var scene_raw: [4096]u32 = undefined;
    const scene = try surface.init(&scene_raw, 24, 24);
    scene.pixels[10 * scene.stride + 9] = 0xffffffff;
    var raw: [3][1024]u32 = undefined;
    var buffers: [3]surface.Surface = undefined;
    for (&buffers, &raw) |*dst, *pixels| dst.* = try surface.init(pixels, dims.size[0], dims.size[1]);
    var kernel: [9]f32 = undefined;
    const origin = try panel.captureFiltered(scene.view(), buffers[0], buffers[1], buffers[2], &kernel, .{});
    try std.testing.expectEqual([2]i32{ 7, 7 }, origin);
    // The white source lies outside the panel itself, but contributes through the halo.
    try std.testing.expect(buffers[0].pixels[3 * buffers[0].stride + 3] >> 24 > 0);
}
