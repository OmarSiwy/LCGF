//! ct-csrc: rewrites the static-UI engine's C (Zig's C backend, src/abi/ct_c.zig) for a C
//! compiler that is to specialize it to a UI's constant words (lcgf-gen --static --lang c).
//! The backend writes pointer arithmetic through integers, `(T *)(((uintptr_t)p) + (i*sizeof(T)))`,
//! and a compiler cannot fold a load through an integer-made pointer, so no load from the
//! words would fold. This writes each as `(T *)((char *)(p) + (i*sizeof(T)))`, the same
//! address. Anything else is copied as it is.
//!
//!   ct-csrc <in.c> <out.c>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const in_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .limited(64 << 20));
    const out = try rewrite(arena, src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out });
}

const open = "(((uintptr_t)";

/// `src` with every `(((uintptr_t)p) + (e))` or `- (e)` written as `((char *)(p) + (e))`.
pub fn rewrite(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, open)) |p| {
        try out.appendSlice(arena, src[i..p]);
        if (parse(src, p)) |m| {
            try out.print(arena, "((char *)({s}) {c} {s})", .{ m.name, m.op, m.rest });
            i = m.end;
        } else {
            try out.appendSlice(arena, open);
            i = p + open.len;
        }
    }
    try out.appendSlice(arena, src[i..]);
    return out.items;
}

const Match = struct { name: []const u8, op: u8, rest: []const u8, end: usize };

/// `(((uintptr_t)name) op (rest))` at `p`: `rest` with its own parentheses, `end` past it.
fn parse(src: []const u8, p: usize) ?Match {
    var j = p + open.len;
    const name_start = j;
    while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
    if (j == name_start or !std.mem.startsWith(u8, src[j..], ") ")) return null;
    const name = src[name_start..j];
    j += 2;
    if (j + 2 >= src.len or (src[j] != '+' and src[j] != '-') or src[j + 1] != ' ' or src[j + 2] != '(') return null;
    const op = src[j];
    j += 2;
    // `rest` is one balanced parenthesized expression, then the closing parenthesis.
    const rest_start = j;
    var depth: usize = 0;
    while (j < src.len) : (j += 1) {
        switch (src[j]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    if (j + 1 >= src.len or src[j + 1] != ')') return null;
    return .{ .name = name, .op = op, .rest = src[rest_start .. j + 1], .end = j + 2 };
}

test "ct-csrc: integer pointer arithmetic becomes char pointer arithmetic, nothing else changes" {
    const arena_state = std.testing.allocator;
    var a = std.heap.ArenaAllocator.init(arena_state);
    defer a.deinit();
    const got = try rewrite(a.allocator(), "t3 = (uint32_t const *)(((uintptr_t)t3) + (t4*sizeof(uint32_t))); x = (((uintptr_t)a1) - ((uintptr_t)0ul*sizeof(float))); y = (((uintptr_t)t9));");
    try std.testing.expectEqualStrings("t3 = (uint32_t const *)((char *)(t3) + (t4*sizeof(uint32_t))); x = ((char *)(a1) - ((uintptr_t)0ul*sizeof(float))); y = (((uintptr_t)t9));", got);
}
