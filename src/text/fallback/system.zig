//! System font discovery: which installed font file has a character. Feeds the fallback
//! chain (fallback.zig): the caller loads each file found, parses the face, and lists it.
//!
//! Outside the tiers: it calls the platform's font API (DirectWrite, Core Text, fontconfig;
//! docs/DEPENDENCIES.md), so it is its own module over `lcgr` (`zig build fallback-system`),
//! never imported by the core and not exported from src/lcgr.zig, like the HarfBuzz adapter.
//! Every back end has the same three calls: `init`, `deinit`, and
//! `find(cp, path_buffer) !?Found`.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");

/// A face found for a character: its file, in the caller's buffer, and its index in the file
/// (non-zero only in collections).
pub const Found = struct { path: []const u8, index: u32 };

pub const Discovery = switch (builtin.os.tag) {
    .windows => @import("directwrite.zig").Discovery,
    else => @compileError("no system font discovery for this OS"),
};

// ---------------------------------------------------------------------------------------------
// Done when: the mixed-script sample of fallback.zig renders from the system's fonts. One font
// is discovered per script of the sample (by its first letter), the chain lists them per
// script, and every character must come out as a real glyph (not .notdef) of a face whose
// cmap, read by src/text/font/, has it, with ink in every run.

const Face = lcgr.opentype.Face;
const Script = lcgr.unicode_property.Script;

test "a mixed-script sample renders with system fonts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const sample = lcgr.fallback.test_sample;
    const letters = [_]u21{ 'H', 0x532, 0x10D2, 0x3B1 };
    const scripts = [_]Script{ .Latin, .Armenian, .Georgian, .Greek };
    var d = try Discovery.init();
    defer d.deinit();
    var files: [letters.len][]u8 = undefined;
    var faces: [letters.len]Face = undefined;
    var loaded: usize = 0;
    defer for (files[0..loaded]) |f| gpa.free(f);
    for (letters, 0..) |cp, k| {
        var buf: [4096]u8 = undefined;
        const found = (try d.find(cp, &buf)) orelse return error.NoSystemFont;
        std.debug.print("U+{X:0>4}: {s} #{}\n", .{ cp, found.path, found.index });
        files[k] = try std.Io.Dir.cwd().readFileAlloc(io, found.path, gpa, .limited(64 << 20));
        loaded += 1;
        faces[k] = try .parse(files[k], try lcgr.opentype.faceOffset(files[k], found.index));
        try std.testing.expect(faces[k].cmap.glyph(cp) != 0);
    }
    const chain: lcgr.fallback.Chain = .{ .faces = &faces, .script = &scripts, .face = &.{ 0, 1, 2, 3 }, .default = &.{ 0, 1, 2, 3 } };
    var rcols: lcgr.fallback.TestRuns = .{};
    var runs = rcols.runs();
    try lcgr.fallback.resolve(&chain, sample, &runs);

    const raster = lcgr.raster;
    var xs: [4096]f32 = undefined;
    var ys: [4096]f32 = undefined;
    var on: [4096]bool = undefined;
    var ends: [256]u32 = undefined;
    var acc: [96 * 96]f32 = undefined;
    var cov: [96 * 96]u8 = undefined;
    var start: u32 = 0;
    for (runs.end[0..runs.len], runs.face[0..runs.len]) |end, fi| {
        defer start = end;
        const face = faces[fi];
        var scols: lcgr.shape.TestRun = .{};
        var run = scols.run();
        try lcgr.shape.Shaper.init(face).shape(sample[start..end], &run, .{});
        const scale = 24 / @as(f32, @floatFromInt(face.units_per_em));
        var ink: u64 = 0;
        for (run.glyph[0..run.len]) |g| {
            try std.testing.expect(g != 0);
            var o: lcgr.opentype.Outline = .{ .x = &xs, .y = &ys, .on = &on, .ends = &ends };
            try face.outline(g, &o);
            const b = raster.box(&o, scale, 0);
            if (b.w == 0) continue;
            try std.testing.expect(raster.accLen(b) <= acc.len);
            raster.fill(&o, scale, 0, b, &acc);
            raster.coverage(&acc, &cov, @as(usize, b.w) * b.h);
            for (cov[0 .. @as(usize, b.w) * b.h]) |c| ink += c;
        }
        try std.testing.expect(ink > 0);
    }
}
