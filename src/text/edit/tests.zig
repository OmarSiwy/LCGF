//! Editing tests across the lane's files: a recorded session replayed from a file, and
//! invariants of the editor over many frames of random replayed input (caret and anchor on
//! grapheme boundaries, the text valid UTF-8 and equal to a copy taken around the gap, undo
//! back to the start and redo forward again). The files' own tests check each step by hand.

const std = @import("std");
const edit = @import("edit.zig");
const moves = @import("moves.zig");
const History = @import("history.zig").History;
const mem = @import("../../core/mem.zig");
const Input = @import("../../core/input.zig").Input;
const keyboard = @import("../../interact/keyboard.zig");
const Interaction = @import("../../interact/interaction.zig").Interaction;
const Focus = @import("../../interact/focus.zig").Focus;
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;
const golden = @import("../layout/golden.zig");
const lines = @import("../layout/lines.zig");

const Editor = edit.Editor;
const testing = std.testing;

test "a recorded session replays from a file" {
    var cols: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cols };
    var raw: [128]u8 = undefined;
    var ed = try Editor.init(&raw, "");
    ed.history = History.init(&carver, 32, 128);
    var clip: keyboard.Clipboard = .{};
    var copied: [32]u8 = undefined;
    const r = try edit.replayWith(&ed, @embedFile("testdata/session.replay"), .{ .width = 80, .clipboard = &clip, .copy_buf = &copied });
    try testing.expect(r.changed);
    // The typo fixed by the click, "second" pasted after the space and its paste undone.
    try testing.expectEqualStrings("Hello world\nsecond line ", ed.text());
    try testing.expectEqual(24, ed.caret);
    // The copy came from the double-clicked word: redo puts the host's paste back.
    _ = try edit.replay(&ed,
        \\frame
        \\press 28 ctrl
    );
    try testing.expectEqualStrings("Hello world\nsecond line second", ed.text());
}

fn isBoundary(text: []const u8, at: u32) bool {
    if (at == 0) return true;
    var it: Graphemes = .{ .text = text };
    while (it.next()) |e| if (e == at) return true;
    return false;
}

/// Whole graphemes that do not join their neighbours, so every insert keeps the boundaries.
const pieces = [_][]const u8{ "a", "b", " ", "\n", "\u{e9}", "e\u{301}", "\u{5D0}", "\u{5D1}", "\u{65e5}", "\t", "1" };
const codes = [_]u8{ 0x2a, 0x4c, 0x28, 0x50, 0x4f, 0x52, 0x51, 0x4a, 0x4d, 0x1d, 0x1c, 0x04, 0x06, 0x1b, 0x19 };

/// Runs `frames` frames of random typing, keys, compositions and (with `width`, ASCII only)
/// clicks into `ed`, checking the invariants after each. At most 8 edits a frame, so 1024
/// history rows keep all of 100 frames.
fn fuzz(seed: u64, ed: *Editor, frames: u32, ascii: bool, width: ?f32, bidi: ?moves.BidiScratch) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var text: [64]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var copied: [256]u8 = undefined;
    var para: golden.Para = .{};
    var shown: [128]u8 = undefined;
    const fo: Focus = .{};
    var it: Interaction = .{ .focus = @backingInt(edit.field) };
    for (0..frames) |_| {
        var n_text: u32 = 0;
        var n_events: usize = 0;
        for (0..rng.uintAtMost(usize, events.len)) |_| {
            if (rng.boolean()) {
                const p = if (ascii) pieces[rng.uintLessThan(usize, 4)] else pieces[rng.uintLessThan(usize, pieces.len)];
                if (n_text + p.len > text.len) continue;
                @memcpy(text[n_text..][0..p.len], p);
                events[n_events] = .{ .kind = .text, .at = n_text, .len = @intCast(p.len) };
                n_text += @intCast(p.len);
            } else {
                const mods: Input.Mods = .{ .shift = rng.boolean(), .ctrl = rng.uintLessThan(u8, 3) == 0 };
                events[n_events] = .{ .kind = if (rng.boolean()) .press else .repeat, .code = codes[rng.uintLessThan(usize, codes.len)], .mods = mods };
            }
            n_events += 1;
        }
        const in: Input = .{ .text = text[0..n_text], .events = events[0..n_events] };
        const k = keyboard.Keyboard.route(&it, &fo, &in);
        var clip: keyboard.Clipboard = .{};
        var cx: edit.Context = .{ .clipboard = &clip, .copy_buf = &copied, .bidi = bidi };
        const comp: keyboard.Composition = .{ .text = "ka", .range = .{ 0, rng.uintAtMost(u32, 2) } };
        if (rng.uintLessThan(u8, 6) == 0) cx.composition = k.composition(edit.field, &comp);
        if (width) |w| {
            const d = ed.display(&shown);
            para.fixed(d, 10);
            try lines.breakLines(&para.g, d, w, &para.l);
            lines.place(&para.l, &para.g, d, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = w });
            cx.view = .{ .l = &para.l, .g = &para.g, .text = d };
            const press = rng.uintLessThan(u8, 4) == 0;
            cx.pointer = .{ .at = .{ rng.float(f32) * w, rng.float(f32) * 60 - 10 }, .press = press, .held = !press and rng.boolean(), .double = rng.uintLessThan(u8, 8) == 0, .shift = rng.boolean() };
        }
        _ = ed.update(&k, edit.field, cx);

        const t = ed.text();
        try testing.expect(std.unicode.utf8ValidateSlice(t));
        try testing.expect(ed.caret <= t.len and ed.anchor <= t.len);
        try testing.expect(isBoundary(t, ed.caret));
        try testing.expect(isBoundary(t, ed.anchor));
        if (clip.set.len > 0) try testing.expect(std.unicode.utf8ValidateSlice(clip.set));
        if (ed.composing()) {
            try testing.expectEqualStrings("ka", t[ed.preedit[0]..ed.preedit[1]]);
            try testing.expect(ed.preedit[0] <= ed.preedit_sel[0] and ed.preedit_sel[1] <= ed.preedit[1]);
        }
        var out: [128]u8 = undefined;
        try testing.expectEqualStrings(t, ed.b.copy(0, ed.b.len(), &out));
    }
}

/// Undoes until nothing is left to undo, then redoes everything, comparing with `start` and
/// `end`. The keys go through `update`, so a preedit left over is first taken out.
fn undoRedo(ed: *Editor, start: []const u8, end: []const u8) !void {
    var guard: u32 = 0;
    while ((try edit.replay(ed,
        \\frame
        \\press 29 ctrl
    )).changed) guard += 1;
    try testing.expect(guard < 1000);
    try testing.expectEqualStrings(start, ed.text());
    while ((try edit.replay(ed,
        \\frame
        \\press 28 ctrl
    )).changed) {}
    try testing.expectEqualStrings(end, ed.text());
}

test "random replayed input keeps the caret on graphemes, the text whole, and undo exact" {
    var cols: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cols };
    const bidi = carver.columns(moves.BidiScratch, 129);
    const hist_mark = carver.off;
    for (0..20) |seed| {
        carver.off = hist_mark;
        var raw: [128]u8 = undefined;
        const start = "start \u{5D0}\u{5D1} e\u{301}\nline";
        var ed = try Editor.init(&raw, start);
        // Enough history that nothing is dropped: undo then goes all the way back.
        ed.history = History.init(&carver, 1024, 16 * 1024);
        try fuzz(seed, &ed, 100, false, null, if (seed % 2 == 0) bidi else null);
        // Take out a preedit the last frame left before comparing.
        _ = try edit.replay(&ed, "frame");
        var end_buf: [128]u8 = undefined;
        const end = end_buf[0..ed.text().len];
        @memcpy(end, ed.text());
        try undoRedo(&ed, start, end);
    }
}

test "random replayed input with layout, clicks, and single-line and password modes" {
    var cols: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cols };
    const modes = [_]edit.Mode{ .{}, .{ .single_line = true }, .{ .password = true, .bullet = "*" } };
    for (modes, 0..) |mode, m| {
        for (0..10) |seed| {
            carver.off = 0;
            var raw: [128]u8 = undefined;
            var ed = try Editor.init(&raw, "ab cd");
            ed.mode = mode;
            ed.history = History.init(&carver, 1024, 16 * 1024);
            try fuzz(seed * 3 + m, &ed, 100, true, 50, null);
            if (mode.single_line or mode.password) {
                // Only the initial text's newlines could be there, and it has none.
                try testing.expect(std.mem.indexOfScalar(u8, ed.text(), '\n') == null);
            }
            _ = try edit.replay(&ed, "frame");
            var end_buf: [128]u8 = undefined;
            const end = end_buf[0..ed.text().len];
            @memcpy(end, ed.text());
            try undoRedo(&ed, "ab cd", end);
        }
    }
}
