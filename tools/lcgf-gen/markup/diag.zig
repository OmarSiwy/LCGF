//! Source files and diagnostics. A location is a file index and a byte offset; lines and columns
//! are computed only when a message is printed. Messages print in GNU format
//! (`file:line:col: error: msg`, then the source line and a caret), which is what Zig, gcc and
//! clang print, so editors' problem matchers jump to the HTML.

const std = @import("std");

pub const none: u32 = 0xffff_ffff;

pub const File = struct { path: []const u8, bytes: []const u8 };

pub const Loc = struct {
    file: u16 = 0,
    off: u32 = none,

    pub const unknown: Loc = .{};
};

pub const Severity = enum { @"error", warning, note };

pub const Item = struct { loc: Loc, severity: Severity, msg: []const u8 };

/// How many errors are printed before the rest are counted only.
pub const max_errors = 20;

pub const Diags = struct {
    arena: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,
    items: std.ArrayList(Item) = .empty,
    errors: u32 = 0,
    /// Lexbor's recovery notes (foster parenting, a missing end tag) are warnings; tests that
    /// compare output exactly may turn them off.
    warnings: bool = true,

    pub fn addFile(d: *Diags, path: []const u8, bytes: []const u8) u16 {
        d.files.append(d.arena, .{ .path = path, .bytes = bytes }) catch @panic("out of memory");
        return @intCast(d.files.items.len - 1);
    }

    pub fn add(d: *Diags, loc: Loc, severity: Severity, comptime format: []const u8, args: anytype) void {
        if (severity == .warning and !d.warnings) return;
        if (severity == .@"error") d.errors += 1;
        const msg = std.fmt.allocPrint(d.arena, format, args) catch @panic("out of memory");
        d.items.append(d.arena, .{ .loc = loc, .severity = severity, .msg = msg }) catch @panic("out of memory");
    }

    pub fn err(d: *Diags, loc: Loc, comptime format: []const u8, args: anytype) void {
        d.add(loc, .@"error", format, args);
    }

    pub fn warn(d: *Diags, loc: Loc, comptime format: []const u8, args: anytype) void {
        d.add(loc, .warning, format, args);
    }

    pub fn note(d: *Diags, loc: Loc, comptime format: []const u8, args: anytype) void {
        d.add(loc, .note, format, args);
    }

    /// `file:line:col` of `loc` ("file" alone when the offset is unknown).
    pub fn where(d: *const Diags, loc: Loc) Where {
        const f = d.files.items[loc.file];
        if (loc.off == none or loc.off > f.bytes.len) return .{ .path = f.path, .line = 0, .col = 0, .text = "" };
        var line: u32 = 1;
        var start: usize = 0;
        for (f.bytes[0..loc.off], 0..) |c, i| if (c == '\n') {
            line += 1;
            start = i + 1;
        };
        const end = std.mem.indexOfScalarPos(u8, f.bytes, loc.off, '\n') orelse f.bytes.len;
        return .{ .path = f.path, .line = line, .col = @intCast(loc.off - start + 1), .text = f.bytes[start..end] };
    }

    /// Writes every message in order, at most `max_errors` errors, each with its source line.
    pub fn render(d: *const Diags, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var printed: u32 = 0;
        for (d.items.items) |it| {
            if (it.severity == .@"error") {
                if (printed == max_errors) continue;
                printed += 1;
            }
            const at = d.where(it.loc);
            if (at.line == 0) {
                try w.print("{s}: {s}: {s}\n", .{ at.path, @tagName(it.severity), it.msg });
                continue;
            }
            try w.print("{s}:{d}:{d}: {s}: {s}\n{s}\n", .{ at.path, at.line, at.col, @tagName(it.severity), it.msg, at.text });
            // The caret under the column; tabs are kept so it lines up in a terminal.
            for (at.text[0 .. at.col - 1]) |c| try w.writeByte(if (c == '\t') '\t' else ' ');
            try w.writeAll("^\n");
        }
        if (d.errors > max_errors) try w.print("{d} more errors not shown\n", .{d.errors - max_errors});
    }
};

pub const Where = struct { path: []const u8, line: u32, col: u32, text: []const u8 };

test "Diags: GNU format with the source line and a caret" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diags = .{ .arena = arena.allocator() };
    const f = d.addFile("page.html", "<p>\n  <script>x</script>\n");
    d.err(.{ .file = f, .off = 6 }, "no JavaScript", .{});
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.render(&w);
    try std.testing.expectEqualStrings("page.html:2:3: error: no JavaScript\n  <script>x</script>\n  ^\n", w.buffered());
    try std.testing.expectEqual(1, d.errors);
}
