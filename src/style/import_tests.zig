//! End-to-end native consumers of the checked-in DTCG fixture. Regenerate with stylegen;
//! host tests validate error paths and this suite verifies generated Zig reaches real passes.

const std = @import("std");
const api = struct {
    pub const types = @import("../core/types.zig");
    pub const style = @import("resolve.zig");
    pub const color_math = @import("../draw/color_math.zig");
    pub const decoration = @import("../draw/decoration.zig");
    pub const brushes = @import("../draw/brushes.zig");
    pub const surface = @import("../draw/surface.zig");
    pub const vector = @import("../draw/vector.zig");
    pub const paths = @import("../draw/paths.zig");
    pub const font_match = @import("../text/font/match.zig");
    pub const text_stack = @import("../text/layout/stack.zig");
    pub const motion = @import("../anim/motion.zig");
};
const generated = @import("testdata/dtcg_generated.zig").Tokens(api);

test "DTCG generated semantic aliases and typography feed actual text layout" {
    const scopes = [_]api.style.tokens.Scope{.{ .entries = &generated.entries }};
    const computed = try api.style.resolve(.{ .tokens = .{ .scopes = &scopes }, .scope = 0, .local = &.{ api.style.token(.fill, .from("color.accent")), api.style.token(.padding_left, .from("space.alias")) } }, null);
    try std.testing.expectEqual(api.types.Color.rgba(26, 51, 77, 255), computed.box.fill);
    try std.testing.expectEqual(@as(f32, 8), computed.box.pad[0]);
    const families = [_]api.font_match.Entry{ .{ .family = "UI", .font = 3, .weight = 400 }, .{ .family = "UI", .font = 9, .weight = 700 } };
    const text = try generated.values.body.textStyle(&families);
    try std.testing.expectEqual(@as(u16, 9), @backingInt(text.font));
    try std.testing.expectError(error.FontNotFound, generated.values.body.textStyle(&.{}));
    const context = @import("../runtime/context.zig");
    const caps: context.Limits = .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 128, .depth = 4, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
    const bytes = comptime blk: {
        @setEvalBranchQuota(30_000);
        break :blk context.Context.requiredBytes(caps);
    };
    var memory: [bytes]u8 align(64) = undefined;
    var ctx = try context.Context.init(&memory, caps);
    var frame = ctx.begin(&.{ .viewport = .{ 180, 80 } });
    _ = frame.textStyled("Imported", text, computed.box);
    const output = frame.end(.{});
    try std.testing.expectEqual(@as(u16, 9), output.texts.c.font[0]);
    try std.testing.expectEqual(@as(f32, 16), output.texts.c.px[0]);
    try std.testing.expect(output.draw.run_len > 0);
    try std.testing.expect(output.status.ok());
    // Paragraph data reaches the same configurable shaping path as hand-authored values.
    const paragraph = generated.values.body.paragraph();
    const golden = @import("../text/layout/golden.zig");
    const shape = @import("../text/shape/shape.zig");
    const mem = @import("../core/mem.zig");
    const shapers = [_]shape.Shaper{.init(try @import("../text/font/opentype.zig").Face.parse(golden.font, 0))};
    var text_memory: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &text_memory };
    var texts = @import("../core/texts.zig").Texts.init(&carver, 1);
    var string_memory: [64]u8 = undefined;
    var strings: @import("../core/strings.zig").Strings = .{ .buf = &string_memory };
    const actual_font = try generated.values.body.textStyle(&.{.{ .family = "UI", .font = 0, .weight = 700 }});
    _ = texts.push(0, strings.add("typed tokens"), &actual_font);
    var para: golden.Para = .{};
    para.bind();
    var run: golden.RunCols = .{};
    var stack: api.text_stack.Stack = .{ .shapers = &shapers, .run = run.run(), .g = para.g, .l = para.l, .default_paragraph = paragraph };
    var ascent: [1]f32 = undefined;
    stack.measure(&texts, &strings, &ascent);
    texts.c.avail[0] = 200;
    stack.wrap(&texts, &strings, &ascent);
    try std.testing.expectEqual(@as(f32, 24), texts.c.h[0]);
    try std.testing.expect(!stack.overflow);
}

test "DTCG generated gradients, shadows and borders paint caller-owned pixels" {
    var segments: [2]api.brushes.Segment = undefined;
    const ramp = try api.brushes.prepareStops(generated.values.@"gradient.brand", &segments, .{}, .pad);
    const layers = [_]api.decoration.Layer{.{ .brush = .{ .linear = .{ .ramp = ramp, .from = .{ 0, 0 }, .to = .{ 16, 0 } } } }};
    var pixels: [api.surface.requiredPixels(24, 24) catch unreachable]u32 = undefined;
    const surface = try api.surface.init(&pixels, 24, 24);
    try api.decoration.rasterize(surface, .{ .rect = .{ .x0 = 2, .y0 = 2, .x1 = 22, .y1 = 22 } }, .{ .backgrounds = &layers, .border = generated.values.border, .shadows = generated.values.@"elevation.soft" }, .{});
    const left = api.color_math.unpack(surface.pixels[12 * surface.stride + 5]);
    const right = api.color_math.unpack(surface.pixels[12 * surface.stride + 17]);
    try std.testing.expect(left[3] > 0.9 and right[3] > 0.9);
    try std.testing.expect(right[0] > left[0]);
    try std.testing.expectEqual(@as(f32, 2), generated.values.@"elevation.soft"[0].sigma);
}

test "DTCG generated transition timing and custom stroke use native playback and stroking" {
    const transition = generated.values.@"motion.enter";
    var playback = try api.motion.Playback.init(transition.timing);
    const sample = try playback.advance(0.07, true, .continue_playing, false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sample.progress.?, 1e-5);
    try transition.curve.validate();
    try std.testing.expect(transition.curve.at(sample.progress.?) > 0.5);
    var source_buffer: api.paths.TestBuffers(4, 64) = .{};
    var path = source_buffer.path();
    path.moveTo(0, 0);
    path.lineTo(20, 0);
    var source = source_buffer.polyline();
    api.paths.flatten(&path, 0.25, &source);
    var dash_buffer: api.paths.TestBuffers(32, 128) = .{};
    var stroke_buffer: api.paths.TestBuffers(128, 512) = .{};
    var dashes = dash_buffer.polyline();
    var stroked = stroke_buffer.polyline();
    try api.vector.strokeDashed(&source, .{ .width = 2 }, generated.values.stroke.pattern, 0.25, &dashes, &stroked);
    try std.testing.expect(stroked.points > 0);
    try std.testing.expect(dashes.contours > 1);
}
