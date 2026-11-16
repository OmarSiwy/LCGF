//! Fallback chain tests beyond the mixed-script sample of fallback.zig: each rule of
//! `resolve` on its own, over the lane's test fonts. Tier 0.
//!
//! Coverage of the fonts used (fontTools getBestCmap):
//!   latin.ttf     " !,Hi" and αβγ
//!   armenian.ttf  " " and Բաերւ
//!   shape.ttf     " ATVacefilopuvy" and U+0300, U+0301, U+0323

const std = @import("std");
const fallback = @import("fallback.zig");
const opentype = @import("../font/opentype.zig");
const Script = @import("../unicode/property.zig").Script;

const Face = opentype.Face;
const Chain = fallback.Chain;
const shape_font = @embedFile("../shape/testdata/shape.ttf");

const Want = struct { end: u32, face: u16, script: Script };

fn expectRuns(chain: *const Chain, text: []const u8, want: []const Want) !void {
    var cols: fallback.TestRuns = .{};
    var runs = cols.runs();
    try fallback.resolve(chain, text, &runs);
    var got: [16]Want = undefined;
    for (0..runs.len) |k| got[k] = .{ .end = runs.end[k], .face = runs.face[k], .script = runs.script[k] };
    try std.testing.expectEqualSlices(Want, want, got[0..runs.len]);
}

fn faces3() ![3]Face {
    return .{ try .parse(fallback.test_latin, 0), try .parse(fallback.test_armenian, 0), try .parse(shape_font, 0) };
}

test "a script's rows come before the default faces" {
    const faces = try faces3();
    // Latin prefers shape.ttf (2); Greek has no rows, so it takes the defaults in order.
    const chain: Chain = .{ .faces = &faces, .script = &.{.Latin}, .face = &.{2}, .default = &.{ 0, 1, 2 } };
    // shape.ttf has "i" but not "H": H falls through to the defaults, i takes its row.
    try expectRuns(&chain, "Hi αβγ", &.{
        .{ .end = 1, .face = 0, .script = .Latin },
        .{ .end = 3, .face = 2, .script = .Latin },
        .{ .end = 9, .face = 0, .script = .Greek },
    });
    // Rows are tried in order: the first row of a script that has the character wins.
    const two: Chain = .{ .faces = &faces, .script = &.{ .Latin, .Latin }, .face = &.{ 2, 0 }, .default = &.{1} };
    try expectRuns(&two, "iH", &.{
        .{ .end = 1, .face = 2, .script = .Latin },
        .{ .end = 2, .face = 0, .script = .Latin },
    });
}

test "common characters stay in the face before them while it has them" {
    const faces = try faces3();
    const chain: Chain = .{ .faces = &faces, .script = &.{.Armenian}, .face = &.{1}, .default = &.{ 0, 1, 2 } };
    // The space is in latin.ttf, first of the defaults, but armenian.ttf has it too: one run.
    try expectRuns(&chain, "Բ ա", &.{.{ .end = 5, .face = 1, .script = .Armenian }});
    // "!" is not in armenian.ttf: it falls back to latin.ttf, and the space after it stays there.
    try expectRuns(&chain, "Բ! ա", &.{
        .{ .end = 2, .face = 1, .script = .Armenian },
        .{ .end = 4, .face = 0, .script = .Armenian },
        .{ .end = 6, .face = 1, .script = .Armenian },
    });
    // A combining mark stays with its base while the base's face has it.
    const marks: Chain = .{ .faces = &faces, .default = &.{ 2, 0 } };
    try expectRuns(&marks, "a\u{301}i", &.{.{ .end = 4, .face = 2, .script = .Latin }});
}

test "a script change splits a run even in the same face" {
    const faces = try faces3();
    const chain: Chain = .{ .faces = &faces, .default = &.{0} };
    try expectRuns(&chain, "Hi αβ", &.{
        .{ .end = 3, .face = 0, .script = .Latin },
        .{ .end = 7, .face = 0, .script = .Greek },
    });
}

test "a character no face has stays in the current face" {
    const faces = try faces3();
    const chain: Chain = .{ .faces = &faces, .default = &.{ 1, 0 } };
    // "é" is in none of the faces: it draws as .notdef of latin.ttf, in the same run.
    try expectRuns(&chain, "Hé", &.{.{ .end = 3, .face = 0, .script = .Latin }});
    // At the start of the text there is no current face: the first default.
    try expectRuns(&chain, "éH", &.{
        .{ .end = 2, .face = 1, .script = .Latin },
        .{ .end = 3, .face = 0, .script = .Latin },
    });
}

test "text of only common characters is one common run" {
    const faces = try faces3();
    const chain: Chain = .{ .faces = &faces, .default = &.{ 1, 0 } };
    // armenian.ttf (first default) has no "!": the first character takes latin.ttf, the
    // space after it stays there.
    try expectRuns(&chain, "! ", &.{.{ .end = 2, .face = 0, .script = .Common }});
    try expectRuns(&chain, "", &.{});
}

test "short run columns fail with NoSpace" {
    var faces: [3]Face = undefined;
    const chain = try fallback.testChain(&faces);
    var end: [4]u32 = undefined;
    var face: [4]u16 = undefined;
    var script: [4]Script = undefined;
    var runs: fallback.Runs = .{ .end = &end, .face = &face, .script = &script };
    // The sample needs 5 runs.
    try std.testing.expectError(error.NoSpace, fallback.resolve(&chain, fallback.test_sample, &runs));
}

test "invalid UTF-8 resolves like U+FFFD and keeps every byte in a run" {
    const faces = try faces3();
    const chain: Chain = .{ .faces = &faces, .default = &.{0} };
    // U+FFFD is in no face: it stays in latin.ttf, one byte per bad byte (src/text/unicode/utf8.zig).
    try expectRuns(&chain, "H\xffi\xc3", &.{.{ .end = 4, .face = 0, .script = .Latin }});
}
