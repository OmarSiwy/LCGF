//! abi-gen: the bindings' code that is a function of Zig's types and of src/abi/api.zig's export
//! list, generated so no language keeps a hand copy. Each output is committed; `zig build
//! abi-gen` writes them and `zig build test` fails when one is stale.
//!
//!   abi-gen <root>           write the outputs under the repository root
//!   abi-gen --check <root>   exit 1 if an output differs from what would be written, or if
//!                            the tripwire trips
//!
//! Outputs:
//! - src/abi/lcgf_api.h: the C header of api.zig's exports: the types that cross (words structs
//!   for Zig structs of no C layout, the extern structs as they are, handles), the layout hash,
//!   and one prototype per export with its Zig doc comment and parameter names, read from the
//!   source with `std.zig.Ast`.
//!
//! - bindings/cpp/include/lcgf/rows.hpp and bindings/rust/lcgf/src/rows.rs: `Tree.pushRow`'s
//!   stores of a row (`lcgf_row`, tree.zig's `FlatRow`) into the frame's columns (`lcgf_view`):
//!   one per field of `Template.node_fields`, and the extras row's fields copied as they are.
//!   The bindings' inline push (runtime.hpp's `Push`, runtime.rs's `View::push`) calls them and
//!   keeps only what is not a store: the overflow clamp, the participation collapse, the child
//!   count, the extras row's place and the computed fields.
//!
//! The tripwire: every `pub fn` of a container api.zig lists (and every `pub const f = x.f`
//! alias of one) is exported or skipped with a reason, and every skip names one that exists. Without it the bindings fall silently
//! behind the Zig API.

const std = @import("std");
const Ast = std.zig.Ast;
const lcgf = @import("lcgf");
const api = lcgf.abi_api;
const abi = lcgf.abi;
const words = lcgf.abi_words;
const tree = lcgf.tree;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    var check = false;
    var root: []const u8 = args.next() orelse return error.Usage;
    if (std.mem.eql(u8, root, "--check")) {
        check = true;
        root = args.next() orelse return error.Usage;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    var src: Sources = .{ .io = io, .dir = dir, .arena = arena };

    var bad = !try tripwire(&src);
    const outputs = [_]struct { path: []const u8, text: []const u8 }{
        .{ .path = "src/abi/lcgf_api.h", .text = try header(&src) },
        .{ .path = "bindings/cpp/include/lcgf/rows.hpp", .text = try rowsCpp(arena) },
        .{ .path = "bindings/rust/lcgf/src/rows.rs", .text = try rowsRust(arena) },
    };
    for (outputs) |o| {
        if (check) {
            const have = dir.readFileAlloc(io, o.path, arena, .limited(1 << 22)) catch "";
            if (!std.mem.eql(u8, have, o.text)) {
                std.log.err("{s} is stale: run `zig build abi-gen`", .{o.path});
                bad = true;
            }
        } else try dir.writeFile(io, .{ .sub_path = o.path, .data = o.text });
    }
    if (bad) std.process.exit(1);
}

// ---- the Zig sources -------------------------------------------------------------------------

const Sources = struct {
    io: std.Io,
    dir: std.Io.Dir,
    arena: std.mem.Allocator,
    trees: std.StringHashMapUnmanaged(Ast) = .empty,

    fn get(s: *Sources, path: []const u8) !*const Ast {
        const e = try s.trees.getOrPut(s.arena, path);
        if (!e.found_existing) {
            const text = try s.dir.readFileAllocOptions(s.io, path, s.arena, .limited(1 << 24), .of(u8), 0);
            e.value_ptr.* = try Ast.parse(s.arena, text, .{});
        }
        return e.value_ptr;
    }

    /// The members of container `decl` of `t` (`null`: the file's top level).
    fn members(s: *Sources, t: *const Ast, decl: ?[]const u8) ![]const Ast.Node.Index {
        const name = decl orelse return t.rootDecls();
        for (t.rootDecls()) |n| {
            const v = t.fullVarDecl(n) orelse continue;
            if (!std.mem.eql(u8, t.tokenSlice(v.ast.mut_token + 1), name)) continue;
            var buf: [2]Ast.Node.Index = undefined;
            const c = t.fullContainerDecl(&buf, v.ast.init_node.unwrap().?) orelse break;
            return try s.arena.dupe(Ast.Node.Index, c.ast.members);
        }
        std.log.err("abi-gen: no container {s}", .{name});
        return error.NoContainer;
    }

    /// Function `loc`: its parameter names and its doc comment.
    fn find(s: *Sources, loc: api.Loc) !struct { params: []const []const u8, doc: []const u8 } {
        const t = try s.get(loc.file);
        for (try s.members(t, loc.decl)) |n| {
            var buf: [1]Ast.Node.Index = undefined;
            const p = t.fullFnProto(&buf, n) orelse continue;
            const name = p.name_token orelse continue;
            if (!std.mem.eql(u8, t.tokenSlice(name), loc.name)) continue;
            // `p` points into `buf`: read it here.
            return .{ .params = try paramNames(s.arena, t, p), .doc = try docOf(s.arena, t, t.firstToken(n)) };
        }
        for (try s.members(t, loc.decl)) |n| if (aliasName(t, n)) |name| {
            if (std.mem.eql(u8, name, loc.name)) return .{ .params = &.{}, .doc = try docOf(s.arena, t, t.firstToken(n)) };
        };
        std.log.err("abi-gen: no fn {s} in {s}", .{ loc.name, loc.file });
        return error.NoFn;
    }
};

/// The `///` lines before token `first`, without the slashes.
fn docOf(arena: std.mem.Allocator, t: *const Ast, first: Ast.TokenIndex) ![]const u8 {
    var start = first;
    while (start > 0 and t.tokenTag(start - 1) == .doc_comment) start -= 1;
    var out: std.ArrayList(u8) = .empty;
    for (start..first) |k| {
        const line = t.tokenSlice(@intCast(k))[3..];
        try out.appendSlice(arena, std.mem.trimEnd(u8, line, " "));
        try out.append(arena, '\n');
    }
    return out.items;
}

/// `pub const needsFrame = scheduler.needsFrame;`: a method defined elsewhere, its name.
fn aliasName(t: *const Ast, n: Ast.Node.Index) ?[]const u8 {
    const v = t.fullVarDecl(n) orelse return null;
    if (v.visib_token == null) return null;
    const name = t.tokenSlice(v.ast.mut_token + 1);
    const init_node = v.ast.init_node.unwrap() orelse return null;
    if (!std.ascii.isLower(name[0]) or t.nodeTag(init_node) != .field_access) return null;
    return name;
}

fn paramNames(arena: std.mem.Allocator, t: *const Ast, proto: Ast.full.FnProto) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = proto.iterate(t);
    while (it.next()) |p| try out.append(arena, if (p.name_token) |n| t.tokenSlice(n) else "_");
    return out.items;
}

// ---- the tripwire ----------------------------------------------------------------------------

fn tripwire(src: *Sources) !bool {
    var ok = true;
    inline for (api.containers) |k| {
        const t = try src.get(k.file);
        var have: std.StringHashMapUnmanaged(void) = .empty;
        for (try src.members(t, k.decl)) |n| {
            var buf: [1]Ast.Node.Index = undefined;
            const name = if (aliasName(t, n)) |a| a else blk: {
                const p = t.fullFnProto(&buf, n) orelse continue;
                if (p.visib_token == null) continue;
                break :blk t.tokenSlice(p.name_token orelse continue);
            };
            try have.put(src.arena, name, {});
            if (!covered(k, name)) {
                std.log.err("{s}: pub fn {s}{s}{s} is neither exported nor skipped in src/abi/api.zig", .{ k.file, k.decl orelse "", if (k.decl != null) "." else "", name });
                ok = false;
            }
        }
        for (k.skip) |s| if (!have.contains(s[0])) {
            std.log.err("src/abi/api.zig: skip {s} names no pub fn of {s}", .{ s[0], k.file });
            ok = false;
        };
    }
    return ok;
}

fn covered(comptime k: api.Container, name: []const u8) bool {
    for (k.skip) |s| if (std.mem.eql(u8, s[0], name)) return true;
    inline for (api.exports) |E| if (E.api) |a| {
        if (comptime std.mem.eql(u8, a.file, k.file) and eqlOpt(a.decl, k.decl))
            if (std.mem.eql(u8, a.name, name)) return true;
    };
    return false;
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---- C spellings -----------------------------------------------------------------------------

fn named(comptime T: type) bool {
    inline for (api.names) |n| if (n[0] == T) return true;
    return false;
}

/// `lcgf_<name>` of a type api.zig names.
fn nameOf(comptime T: type) []const u8 {
    inline for (api.names) |n| if (n[0] == T) return "lcgf_" ++ n[1];
    @compileError("abi-gen: src/abi/api.zig names no C type for " ++ @typeName(T));
}

fn fieldName(comptime name: []const u8) []const u8 {
    inline for (api.renames) |r| if (comptime std.mem.eql(u8, r[0], name)) return r[1];
    return name;
}

/// The C spelling of `T` as a parameter, result or extern field (arrays aside).
fn spell(comptime T: type) []const u8 {
    return switch (T) {
        void => "void",
        bool => "bool",
        f32 => "float",
        f64 => "double",
        u8 => "uint8_t",
        u16 => "uint16_t",
        u32 => "uint32_t",
        u64 => "uint64_t",
        i32 => "int32_t",
        i64 => "int64_t",
        usize => "size_t",
        c_int => "int",
        anyopaque => "void",
        else => switch (@typeInfo(T)) {
            .pointer => |p| (if (p.attrs.@"const") "const " else "") ++ spell(p.child) ++ " *",
            .optional => |o| spell(o.child),
            .@"enum" => |e| spell(e.tag_type),
            .@"struct" => |s| if (s.backing_integer) |B| (if (named(T)) nameOf(T) else spell(B)) else nameOf(zigOf(T)),
            .@"opaque" => nameOf(zigOf(T)),
            else => @compileError("abi-gen: no C spelling for " ++ @typeName(T)),
        },
    };
}

/// The Zig type a C form stands for (`Words(Style)` is `Style`).
fn zigOf(comptime T: type) type {
    return if (@hasDecl(T, "Zig")) T.Zig else T;
}

/// `T name`, with C's array suffixes: `float *min[2]`.
fn declare(comptime T: type, comptime name: []const u8, comptime words_form: bool) []const u8 {
    comptime var E = T;
    comptime var dims: []const u8 = "";
    inline while (@typeInfo(E) == .array) {
        dims = dims ++ std.fmt.comptimePrint("[{d}]", .{@typeInfo(E).array.len});
        E = @typeInfo(E).array.child;
    }
    const s = if (words_form) wordSpell(E) else spell(E);
    return s ++ (if (s[s.len - 1] == '*') "" else " ") ++ fieldName(name) ++ dims;
}

/// A leaf of a words struct: an f32 is a float, everything else one uint32_t, a struct of no
/// C layout its own words struct.
fn wordSpell(comptime T: type) []const u8 {
    if (T == f32) return "float";
    return switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.backing_integer != null) "uint32_t" else nameOf(T),
        .optional => |o| wordSpell(o.child),
        else => "uint32_t",
    };
}

// ---- the header ------------------------------------------------------------------------------

const Emitted = std.StringHashMapUnmanaged(void);

fn header(src: *Sources) ![]const u8 {
    @setEvalBranchQuota(100_000);
    const a = src.arena;
    var o: std.ArrayList(u8) = .empty;
    var done: Emitted = .empty;
    try o.appendSlice(a,
        \\/* lcgf_api.h: liblcgf's C API, the Zig API in C form (docs/plans/bindings-rust.md §6).
        \\ * Generated by tools/abi-gen (zig build abi-gen) from src/abi/api.zig and the Zig sources
        \\ * it names. Do not edit: change the Zig and run it again.
        \\ *
        \\ * Structs of no C layout in Zig cross as their words, one 32-bit word per field in
        \\ * declaration order (src/abi/words.zig): floats, and uint32_t for everything else. Colours
        \\ * are 0xAABBGGRR. lcgf_style_default and lcgf_theme_default write the defaults. */
        \\#ifndef LCGF_API_H
        \\#define LCGF_API_H
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\#define LCGF_STATIC_ASSERT static_assert
        \\extern "C" {
        \\#else
        \\#define LCGF_STATIC_ASSERT _Static_assert
        \\#endif
        \\
        \\
    );
    try o.print(a, "/* The layout of every type below the library reads: compare with lcgf_layout(). */\n#define LCGF_LAYOUT 0x{x:0>8}u\n", .{api.layout});
    try o.print(a, "#define LCGF_CONTEXT_ALIGN {d}\n#define LCGF_NO_WIDGET 0xffffffffu\n", .{api.column_align});
    try o.print(a, "/* The bit of lcgf_view.status set when the stack overflowed. */\n#define LCGF_DEPTH_BIT {d}\n\n", .{lcgf.abi_runtime.depth_bit});
    try o.appendSlice(a, "/* What lcgf_context_init and the tables' calls return. */\nenum lcgf_status {\n");
    inline for (@typeInfo(lcgf.abi_seam.Status).@"enum".field_names, @typeInfo(lcgf.abi_seam.Status).@"enum".field_values) |n, v|
        try o.print(a, "    LCGF_{s} = {d},\n", .{ try upper(a, n), v });
    try o.appendSlice(a, "};\n\n");

    inline for (api.handles) |H| {
        if (comptime isValue(H)) {
            try o.print(a, "/* Held by value; only the library reads it. */\ntypedef struct {s} {{\n    void *p_[{d}];\n}} {s};\n\n", .{ comptime nameOf(H), @sizeOf(H) / @sizeOf(usize), comptime nameOf(H) });
        } else try o.print(a, "typedef struct {s} {s};\n", .{ comptime nameOf(H), comptime nameOf(H) });
    }
    try o.append(a, '\n');

    inline for (api.exports) |E| {
        const F = @TypeOf(E.func);
        const C = comptime abi.cParamsOf(F, api.handles);
        inline for (C) |P| try typesOf(a, &o, &done, P);
        try typesOf(a, &o, &done, comptime abi.CResult(@typeInfo(F).@"fn".return_type.?));
        try typesOf(a, &o, &done, @typeInfo(F).@"fn".return_type.?);
    }

    inline for (api.exports) |E| {
        const F = @TypeOf(E.func);
        const impl = try src.find(E.impl);
        const doc = if (impl.doc.len != 0) impl.doc else if (E.api) |l| (try src.find(l)).doc else "";
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, doc, "\n"), '\n');
        if (doc.len != 0) while (lines.next()) |l| try o.print(a, "///{s}\n", .{l});
        const names = impl.params;
        const R = @typeInfo(F).@"fn".return_type.?;
        const r = comptime if (isBytes(R)) "char *" else if (isNamedBits(R)) nameOf(R) else spell(abi.CResult(R));
        try o.print(a, "{s}{s}{s}(", .{ r, if (r[r.len - 1] == '*') "" else " ", E.c });
        try params(a, &o, F, names);
        try o.appendSlice(a, ");\n");
    }
    try o.appendSlice(a,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\#endif
        \\
    );
    return o.items;
}

/// A bitpack struct api.zig names (`Response`): spelled by its name, not its backing integer.
fn isNamedBits(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".backing_integer != null and named(T);
}

fn isBytes(comptime T: type) bool {
    return T == []const u8 or T == []u8;
}

fn isValue(comptime H: type) bool {
    inline for (api.value_handles) |V| if (V == H) return true;
    return false;
}

fn upper(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

/// `F`'s C parameters, named after the Zig ones: a slice `s` is `s, s_len`; a slice result
/// writes `len`, a words result `out`.
fn params(a: std.mem.Allocator, o: *std.ArrayList(u8), comptime F: type, names: []const []const u8) !void {
    const info = @typeInfo(F).@"fn";
    if (info.param_types.len == 0 and !hasOut(F)) return o.appendSlice(a, "void");
    var first = true;
    inline for (info.param_types, 0..) |P, k| {
        const C = comptime abi.CParams(P.?, api.handles);
        inline for (C, 0..) |T, j| {
            if (!first) try o.appendSlice(a, ", ");
            first = false;
            // A byte slice is text: `const char *`.
            const s = comptime if (j == 0 and isBytes(P.?)) "const char *" else if (isNamedBits(P.?)) nameOf(P.?) else spell(T);
            try o.print(a, "{s}{s}{s}{s}", .{ s, if (s[s.len - 1] == '*') "" else " ", names[k], if (j == 1) "_len" else "" });
        }
    }
    const R = info.return_type.?;
    if (comptime hasOut(F)) {
        const C = comptime abi.cParamsOf(F, api.handles);
        const s = comptime spell(C[C.len - 1]);
        try o.print(a, "{s}{s}{s}", .{ if (first) "" else ", ", s, if (@typeInfo(R) == .pointer) "len" else "out" });
    }
}

fn hasOut(comptime F: type) bool {
    return comptime blk: {
        var n: usize = 0;
        for (@typeInfo(F).@"fn".param_types) |P| n += abi.CParams(P.?, api.handles).len;
        break :blk abi.cParamsOf(F, api.handles).len > n;
    };
}

/// The typedefs `T` needs, each once, children first.
fn typesOf(a: std.mem.Allocator, o: *std.ArrayList(u8), done: *Emitted, comptime T: type) !void {
    switch (@typeInfo(T)) {
        .pointer => |p| return typesOf(a, o, done, p.child),
        .optional => |p| return typesOf(a, o, done, p.child),
        .array => |p| return typesOf(a, o, done, p.child),
        .@"struct" => |s| {
            if (s.backing_integer) |B| {
                if (comptime !named(T)) return;
                if (done.contains(comptime nameOf(T))) return;
                try done.put(a, comptime nameOf(T), {});
                try o.print(a, "/* Bits, from bit 0:", .{});
                inline for (s.field_names) |n| if (n[0] != '_') try o.print(a, " {s}", .{n});
                return o.print(a, ". */\ntypedef {s} {s};\n\n", .{ comptime spell(B), comptime nameOf(T) });
            }
            if (@hasDecl(T, "Zig")) return wordsStruct(a, o, done, T.Zig);
            if (s.layout != .@"extern") return;
            if (done.contains(comptime nameOf(T))) return;
            inline for (s.field_types) |F| try typesOf(a, o, done, F);
            try done.put(a, comptime nameOf(T), {});
            try o.print(a, "typedef struct {{\n", .{});
            inline for (s.field_names, s.field_types) |n, F| try o.print(a, "    {s};\n", .{comptime declare(F, n, false)});
            try o.print(a, "}} {s};\nLCGF_STATIC_ASSERT(sizeof({s}) == {d}, \"{s}\");\n\n", .{ comptime nameOf(T), comptime nameOf(T), @sizeOf(T), comptime nameOf(T) });
        },
        else => {},
    }
}

/// `T`'s words as a C struct: a nested struct of no C layout is its own words struct.
fn wordsStruct(a: std.mem.Allocator, o: *std.ArrayList(u8), done: *Emitted, comptime T: type) !void {
    if (done.contains(comptime nameOf(T))) return;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_types) |F| {
        comptime var E = F;
        inline while (@typeInfo(E) == .array) E = @typeInfo(E).array.child;
        if (@typeInfo(E) == .@"struct" and @typeInfo(E).@"struct".backing_integer == null) try wordsStruct(a, o, done, E);
    }
    try done.put(a, comptime nameOf(T), {});
    try o.print(a, "typedef struct {{\n", .{});
    inline for (s.field_names, s.field_types) |n, F| try o.print(a, "    {s};\n", .{comptime declare(F, n, true)});
    try o.print(a, "}} {s};\nLCGF_STATIC_ASSERT(sizeof({s}) == {d} * 4, \"{s}: words\");\n\n", .{ comptime nameOf(T), comptime nameOf(T), words.wordsOf(T), comptime nameOf(T) });
}

// ---- the row stores -------------------------------------------------------------------------

const rows_note = "Generated by tools/abi-gen (zig build abi-gen) from src/core/tree.zig: `Tree.pushRow`'s stores of\n{s} a row (`Template.node_fields`, `Extra`). Do not edit; change the Zig types and run it again.\n";

/// The extras row's fields `Tree.pushRow` copies from the row unchanged: every field of `Extra`
/// the row has, but `paint_reference`, which it clamps to an earlier row.
fn extraCopied(comptime name: []const u8) bool {
    return @hasField(tree.FlatRow, name) and !std.mem.eql(u8, name, "paint_reference");
}

fn ElemOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |a| a.child,
        else => T,
    };
}

fn cType(comptime T: type) []const u8 {
    return switch (T) {
        f32 => "float",
        u32 => "std::uint32_t",
        u16 => "std::uint16_t",
        u8, lcgf.types.Participation => "std::uint8_t",
        else => @compileError("abi-gen: no C type for " ++ @typeName(T)),
    };
}

fn rustType(comptime T: type) []const u8 {
    return switch (T) {
        f32 => "f32",
        u32 => "u32",
        u16 => "u16",
        u8, lcgf.types.Participation => "u8",
        else => @compileError("abi-gen: no Rust type for " ++ @typeName(T)),
    };
}

/// `r.<name>[k]` (or `r.<name>`) as the column's element type `To`; the row's words are f32 or u32.
fn cValue(arena: std.mem.Allocator, comptime name: []const u8, comptime To: type, index: ?usize) ![]const u8 {
    const from = ElemOf(@FieldType(tree.FlatRow, name));
    const v = if (index) |k| try std.fmt.allocPrint(arena, "r.{s}[{d}]", .{ name, k }) else "r." ++ name;
    return if (from == To or (To == f32 and from == f32)) v else try std.fmt.allocPrint(arena, "{s}({s})", .{ cType(To), v });
}

fn rustValue(arena: std.mem.Allocator, comptime name: []const u8, comptime To: type) ![]const u8 {
    const from = ElemOf(@FieldType(tree.FlatRow, name));
    return if (from == ElemOf(To)) "r." ++ name else try std.fmt.allocPrint(arena, "r.{s} as {s}", .{ name, rustType(To) });
}

fn rowsCpp(arena: std.mem.Allocator) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(arena, "// " ++ rows_note, .{"//"});
    try o.appendSlice(arena,
        \\#pragma once
        \\#include <cstdint>
        \\
        \\#include <lcgf.h>
        \\
        \\namespace lcgf::gen {
        \\
        \\/// Row `r`'s node fields into row `i` of `v`'s columns, as `Tree.pushRow` stores them.
        \\LCGF_INLINE void StoreNode(const lcgf_view& v, std::uint32_t i, const lcgf_row& r) {
        \\
    );
    inline for (tree.Template.node_fields) |name| {
        const T = @FieldType(tree.Template, name);
        if (T == tree.Look) {
            try o.appendSlice(arena, "    lcgf_look& look = v.look[i];\n");
            inline for (@typeInfo(tree.Look).@"struct".field_names) |f| {
                const F = @FieldType(tree.Look, f);
                switch (@typeInfo(F)) {
                    .array => |a| for (0..a.len) |k| try o.print(arena, "    look.{s}[{d}] = {s};\n", .{ f, k, try cValue(arena, f, a.child, k) }),
                    else => try o.print(arena, "    look.{s} = {s};\n", .{ f, try cValue(arena, f, F, null) }),
                }
            }
        } else switch (@typeInfo(T)) {
            .array => |a| for (0..a.len) |k| try o.print(arena, "    v.{s}[{d}][i] = {s};\n", .{ name, k, try cValue(arena, name, a.child, k) }),
            else => try o.print(arena, "    v.{s}[i] = {s};\n", .{ name, try cValue(arena, name, T, null) }),
        }
    }
    try o.appendSlice(arena,
        \\}
        \\
        \\/// The extras row's fields `Tree.pushRow` copies from row `r` as they are.
        \\LCGF_INLINE void StoreExtra(lcgf_extra& e, const lcgf_row& r) {
        \\
    );
    inline for (@typeInfo(tree.Extra).@"struct".field_names) |name| if (comptime extraCopied(name)) {
        const T = @FieldType(tree.Extra, name);
        switch (@typeInfo(T)) {
            .array => |a| for (0..a.len) |k| try o.print(arena, "    e.{s}[{d}] = {s};\n", .{ name, k, try cValue(arena, name, a.child, k) }),
            else => try o.print(arena, "    e.{s} = {s};\n", .{ name, try cValue(arena, name, T, null) }),
        }
    };
    try o.appendSlice(arena,
        \\}
        \\
        \\/// Row `i`'s layout inputs as a collapsed node has them (`Template.collapsed`).
        \\LCGF_INLINE void CollapseNode(const lcgf_view& v, std::uint32_t i) {
        \\
    );
    inline for (tree.Template.collapsed) |name| {
        const off = if (comptime std.mem.eql(u8, name, "pct")) "-1" else "0";
        switch (@typeInfo(@FieldType(tree.Template, name))) {
            .array => |x| for (0..x.len) |k| try o.print(arena, "    v.{s}[{d}][i] = {s};\n", .{ name, k, off }),
            else => try o.print(arena, "    v.{s}[i] = {s};\n", .{ name, off }),
        }
    }
    try o.appendSlice(arena, "}\n\n} // namespace lcgf::gen\n");
    return o.items;
}

fn rowsRust(arena: std.mem.Allocator) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(arena, "// " ++ rows_note, .{"//"});
    try o.appendSlice(arena,
        \\// Included into runtime.rs (`include!`), whose `View`, `Row`, `Look` and `Extra` it reads.
        \\
        \\/// Row `r`'s node fields into row `i` of `v`'s columns, as `Tree.pushRow` stores them.
        \\///
        \\/// # Safety
        \\/// `i` is below `v`'s capacity and `v` is the frame's live view.
        \\#[inline(always)]
        \\unsafe fn store_node(v: &View, i: usize, r: &Row) {
        \\    unsafe {
        \\
    );
    inline for (tree.Template.node_fields) |name| {
        const T = @FieldType(tree.Template, name);
        if (T == tree.Look) {
            try o.appendSlice(arena, "        *v.look.add(i) = Look {\n");
            inline for (@typeInfo(tree.Look).@"struct".field_names) |f|
                try o.print(arena, "            {s}: {s},\n", .{ f, try rustValue(arena, f, @FieldType(tree.Look, f)) });
            try o.appendSlice(arena, "        };\n");
        } else switch (@typeInfo(T)) {
            .array => |a| for (0..a.len) |k| try o.print(arena, "        *v.{s}[{d}].add(i) = r.{s}[{d}];\n", .{ name, k, name, k }),
            else => try o.print(arena, "        *v.{s}.add(i) = {s};\n", .{ name, try rustValue(arena, name, T) }),
        }
    }
    try o.appendSlice(arena,
        \\    }
        \\}
        \\
        \\/// The extras row's fields `Tree.pushRow` copies from row `r` as they are.
        \\#[inline(always)]
        \\fn store_extra(e: &mut Extra, r: &Row) {
        \\
    );
    inline for (@typeInfo(tree.Extra).@"struct".field_names) |name| if (comptime extraCopied(name)) {
        try o.print(arena, "    e.{s} = {s};\n", .{ name, try rustValue(arena, name, @FieldType(tree.Extra, name)) });
    };
    try o.appendSlice(arena,
        \\}
        \\
        \\/// Row `i`'s layout inputs as a collapsed node has them (`Template.collapsed`).
        \\///
        \\/// # Safety
        \\/// `i` is below `v`'s capacity and `v` is the frame's live view.
        \\#[inline(always)]
        \\unsafe fn collapse_node(v: &View, i: usize) {
        \\    unsafe {
        \\
    );
    inline for (tree.Template.collapsed) |name| {
        const off = if (comptime std.mem.eql(u8, name, "pct")) "-1.0" else "0.0";
        switch (@typeInfo(@FieldType(tree.Template, name))) {
            .array => |x| for (0..x.len) |k| try o.print(arena, "        *v.{s}[{d}].add(i) = {s};\n", .{ name, k, off }),
            else => try o.print(arena, "        *v.{s}.add(i) = {s};\n", .{ name, off }),
        }
    }
    try o.appendSlice(arena, "    }\n}\n");
    return o.items;
}
