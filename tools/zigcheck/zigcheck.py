#!/usr/bin/env python3
"""Checks docs/ZIG_0_17_1.md against the compiler you actually have.

    python3 tools/zigcheck/zigcheck.py            run every case
    python3 tools/zigcheck/zigcheck.py vector     only cases whose name contains "vector"
    ZIG="python3 -m ziglang" python3 tools/zigcheck/zigcheck.py   use another compiler command

Each case is a few lines of Zig and whether it is expected to compile (and pass,
if it is a test). A mismatch means the notes are wrong for your compiler: fix
the notes before trusting them. To settle a question about the language or std,
add a case here and run it; that is cheaper than guessing.
Results below were recorded on Zig 0.17.1 (x86-64 Linux).
"""
import os
import shlex
import subprocess
import sys
import tempfile

ZIG = shlex.split(os.environ.get("ZIG", "zig"))
STD = 'const std = @import("std");\n'

# name: (expected to work, source)
CASES = {
    # ---- builtins and syntax that changed
    "intFromEnum_still_works": (True, 'const E = enum(u8) { a, b };\ntest { const x: u8 = @intFromEnum(E.b); try @import("std").testing.expect(x == 1); }'),
    "backingInt_and_fromBackingInt": (True, 'const E = enum(u8) { a, b };\ntest { const x: u8 = @backingInt(E.b); const e: E = @fromBackingInt(x); try @import("std").testing.expect(e == .b); }'),
    "Type_builtin_removed": (False, "test { const T = @Type(.{ .int = .{ .signedness = .unsigned, .bits = 5 } }); _ = T; }"),
    "Int_builtin": (True, "test { const T = @Int(.unsigned, 5); const x: T = 3; _ = x; }"),
    "Enum_builtin": (True, 'test { const names = [_][]const u8{ "a", "b" }; const vals = [_]u8{ 0, 1 }; const E = @Enum(u8, .exhaustive, &names, &vals); const e: E = .b; _ = e; }'),
    "Struct_builtin": (True, 'test { const T = @Struct(.auto, null, &.{"a"}, &.{u8}, &.{.{}}); _ = T; }'),
    "std_meta_Int_removed": (False, STD + "test { const T = std.meta.Int(.unsigned, 5); _ = T; }"),
    "array_repeat_operator_removed": (False, "test { const a = [_]u8{0} ** 4; _ = a; }"),
    "array_concat_still_works": (True, "test { const a = [_]u8{ 1, 2 } ++ [_]u8{3}; _ = a; }"),
    "splat_fills_arrays": (True, "test { const a: [4]u8 = @splat(0); _ = a; const b: [2][3]f32 = @splat(@splat(1)); _ = b; }"),
    "cImport_removed": (False, 'const c = @cImport(@cInclude("stdint.h"));\ntest { _ = c; }'),
    "usingnamespace_removed": (False, "const A = struct { pub const x = 1; };\nusingnamespace A;\ntest {}"),
    "async_removed": (False, "fn f() void {}\ntest { _ = async f(); }"),
    "callconv_lowercase_c": (True, "export fn f() callconv(.c) void {}"),
    "callconv_uppercase_C_removed": (False, "export fn f() callconv(.C) void {}"),
    "index_array_literal_directly": (False, "test { var i: usize = 1; _ = &i; const x = [2]u8{ 5, 6 }[i]; _ = x; }"),
    "alias_with_same_name_as_nested_decl": (False, "const ns = struct { pub const lanes = 4; pub fn f() u32 { return lanes; } };\nconst lanes = ns.lanes;\ntest { _ = ns.f(); _ = lanes; }"),
    "parameter_shadows_top_level_decl": (False, "const State = struct {};\nfn f(comptime State: type) type { return State; }\ntest { _ = f(u8); }"),
    "local_shadows_top_level_decl": (False, "const x = 1;\ntest { const x = 2; _ = x; }"),
    "branchHint": (True, "fn f(x: u32) u32 { if (x == 0) { @branchHint(.unlikely); return 1; } return x; }\ntest { _ = f(1); }"),
    "labeled_switch_continue": (True, "test { var s: u8 = 0; _ = &s; sw: switch (s) { 0 => continue :sw 1, 1 => {}, else => {} } }"),
    "decl_literal": (True, "const S = struct { x: u8, pub const zero: S = .{ .x = 0 }; };\ntest { const s: S = .zero; _ = s; }"),
    "setEvalBranchQuota": (True, "test { comptime { @setEvalBranchQuota(5000); var i: u32 = 0; while (i < 2000) : (i += 1) {} } }"),
    # ---- reflection
    "typeinfo_struct_fields_removed": (False, 'const S = struct { a: u8, b: u16 };\ntest { comptime { if (@typeInfo(S).@"struct".fields.len != 2) unreachable; } }'),
    "typeinfo_struct_field_names_types_attrs": (True, 'const S = struct { a: u8, b: u16 };\ntest { comptime { const ti = @typeInfo(S).@"struct"; if (ti.field_names.len != 2) unreachable; if (ti.field_types[1] != u16) unreachable; _ = ti.field_attrs; } }'),
    "typeinfo_enum_fields_removed": (False, 'const E = enum { a, b };\ntest { comptime { if (@typeInfo(E).@"enum".fields.len != 2) unreachable; } }'),
    "typeinfo_enum_field_names_values": (True, 'const E = enum(u8) { a = 3, b = 5 };\ntest { comptime { const ti = @typeInfo(E).@"enum"; if (ti.field_names.len != 2) unreachable; if (ti.field_values[1] != 5) unreachable; } }'),
    "typeinfo_union_field_names_types": (True, 'const U = union(enum) { a: u8, b: f32 };\ntest { comptime { const ti = @typeInfo(U).@"union"; if (ti.field_types[1] != f32) unreachable; } }'),
    "inline_for_over_field_names": (True, 'const S = struct { a: u8 = 1, b: u16 = 2 };\ntest { const s: S = .{}; inline for (@typeInfo(S).@"struct".field_names) |n| { _ = @field(s, n); } }'),
    "std_meta_fields_is_a_compile_error": (False, STD + "const S = struct { a: u8 };\ntest { comptime { _ = std.meta.fields(S); } }"),
    "std_meta_fieldNames": (True, STD + "const S = struct { a: u8, b: u16 };\ntest { comptime { if (std.meta.fieldNames(S).len != 2) unreachable; } }"),
    "std_meta_FieldEnum": (True, STD + "const S = struct { a: u8, b: u16 };\ntest { const F = std.meta.FieldEnum(S); const f: F = .b; _ = f; }"),
    "FieldType_builtin": (True, 'const S = struct { a: u8, b: u16 };\ntest { comptime { if (@FieldType(S, "b") != u16) unreachable; } }'),
    "IntFittingRange": (True, STD + "test { comptime { if (std.math.IntFittingRange(0, 8) != u4) unreachable; } }"),
    "SourceLocation_in_std_builtin": (True, STD + "fn f(s: std.builtin.SourceLocation) u32 { return s.line; }\ntest { _ = f(@src()); }"),
    "refAllDeclsRecursive_removed": (False, STD + "test { std.testing.refAllDeclsRecursive(@This()); }"),
    "refAllDecls": (True, STD + "test { std.testing.refAllDecls(@This()); }"),
    # ---- vectors
    "vector_in_extern_struct_rejected": (False, "const S = extern struct { v: @Vector(4, f32) };\ntest { var s: S = undefined; _ = &s; }"),
    "vector_in_plain_struct": (True, "const S = struct { v: @Vector(4, f32) };\ntest { var s: S = undefined; _ = &s; }"),
    "bool_vector_bitwise_and_or_not": (True, "test { const a: @Vector(4, bool) = @splat(true); const b: @Vector(4, bool) = @splat(false); _ = a & b; _ = a | b; _ = !a; }"),
    "bool_vector_and_keyword_rejected": (False, "test { const a: @Vector(4, bool) = @splat(true); const b: @Vector(4, bool) = @splat(false); const c = a and b; _ = c; }"),
    "vector_select": (True, "test { const m: @Vector(4, bool) = .{ true, false, true, false }; const a: @Vector(4, f32) = @splat(1); const b: @Vector(4, f32) = @splat(2); _ = @select(f32, m, a, b); }"),
    "vector_reduce": (True, 'test { const a: @Vector(4, u32) = .{ 1, 2, 3, 4 }; try @import("std").testing.expect(@reduce(.Add, a) == 10); }'),
    "bool_vector_bitcast_to_mask": (True, 'test { const m: @Vector(8, bool) = @splat(true); const bits: u8 = @bitCast(m); try @import("std").testing.expect(bits == 0xff); }'),
    "intFromBool_on_bool_vector": (True, "test { const m: @Vector(4, bool) = @splat(true); const u: @Vector(4, u1) = @intFromBool(m); _ = u; }"),
    "vector_load_store_through_slice": (True, "test { var a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 }; const v: @Vector(4, f32) = a[2..][0..4].*; a[0..4].* = v; }"),
    "vector_math_builtins": (True, "test { const a: @Vector(4, f32) = @splat(1); const b: @Vector(4, f32) = @splat(2); _ = @max(a, b); _ = @min(a, b); _ = @abs(a); _ = @floor(a); _ = @round(a); _ = @mulAdd(@Vector(4, f32), a, a, a); _ = a < b; }"),
    "vector_shuffle_and_shift": (True, "test { const a: @Vector(4, u32) = .{ 1, 2, 3, 4 }; _ = @shuffle(u32, a, undefined, [4]i32{ 3, 2, 1, 0 }); const s: @Vector(4, u5) = @splat(1); _ = a >> s; }"),
    "simd_suggestVectorLength_and_iota": (True, STD + "test { const n = std.simd.suggestVectorLength(f32) orelse 4; _ = n; _ = std.simd.iota(u32, 4); }"),
    # ---- std: containers and allocators
    "ArrayList_managed_init_removed": (False, STD + "test { var l = std.ArrayList(u8).init(std.testing.allocator); defer l.deinit(); try l.append(1); }"),
    "ArrayList_takes_allocator_per_call": (True, STD + "test { var l: std.ArrayList(u8) = .empty; defer l.deinit(std.testing.allocator); try l.append(std.testing.allocator, 1); }"),
    "MultiArrayList": (True, STD + "const E = struct { a: u32, b: f32 };\ntest { var l: std.MultiArrayList(E) = .empty; defer l.deinit(std.testing.allocator); try l.append(std.testing.allocator, .{ .a = 1, .b = 2 }); _ = l.items(.a); }"),
    "GeneralPurposeAllocator_removed": (False, STD + "test { var g = std.heap.GeneralPurposeAllocator(.{}){}; _ = g.allocator(); }"),
    "DebugAllocator": (True, STD + "test { var g: std.heap.DebugAllocator(.{}) = .init; _ = g.allocator(); _ = g.deinit(); }"),
    "FixedBufferAllocator": (True, STD + "test { var buf: [64]u8 = undefined; var f = std.heap.FixedBufferAllocator.init(&buf); _ = try f.allocator().alloc(u8, 8); }"),
    "alignedAlloc_with_Alignment_enum": (True, STD + 'test { const p = try std.testing.allocator.alignedAlloc(u8, .@"64", 128); defer std.testing.allocator.free(p); }'),
    # ---- std: I/O and time
    "std_io_lowercase_removed": (False, STD + 'pub fn main() !void { const o = std.io.getStdOut().writer(); try o.print("x\\n", .{}); }'),
    "std_fs_File_removed": (False, STD + "pub fn main() !void { _ = std.fs.File.stdout(); }"),
    "std_fs_cwd_removed": (False, STD + "test { _ = std.fs.cwd(); }"),
    "std_posix_write_removed": (False, STD + 'test { _ = try std.posix.write(2, ""); }'),
    "main_takes_process_Init": (True, STD + "pub fn main(init: std.process.Init) !void { _ = init; }"),
    "io_example_stdout_files_args_clock": (True, STD + '''pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = "zigcheck_tmp.txt", .data = "hello" });
    const text = try cwd.readFileAlloc(io, "zigcheck_tmp.txt", gpa, .limited(1 << 20));
    defer gpa.free(text);
    const t0 = std.Io.Timestamp.now(io, .awake);
    const ns = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    try w.print("{d} bytes, {d} ns\\n", .{ text.len, ns });
    try w.flush();
}'''),
    "fixed_buffer_writer": (True, STD + 'test { var buf: [32]u8 = undefined; var w = std.Io.Writer.fixed(&buf); try w.print("{d}", .{5}); try std.testing.expectEqualStrings("5", w.buffered()); }'),
    "testing_io_and_allocator": (True, STD + "test { const t = std.Io.Timestamp.now(std.testing.io, .awake); _ = t; _ = std.testing.allocator; }"),
    "std_time_Timer_removed": (False, STD + "test { var t = try std.time.Timer.start(); _ = t.read(); }"),
    "std_time_nanoTimestamp_removed": (False, STD + "test { _ = std.time.nanoTimestamp(); }"),
    "linux_clock_gettime": (True, STD + "test { var ts: std.os.linux.timespec = undefined; _ = std.os.linux.clock_gettime(.MONOTONIC, &ts); }"),
    "debug_print_and_bufPrint": (True, STD + 'test { std.debug.print("", .{}); var b: [32]u8 = undefined; _ = try std.fmt.bufPrint(&b, "{d} {s} {d:.2}", .{ 1, "x", @as(f32, 1.5) }); }'),
    # ---- layout guarantees the renderer relies on
    "extern_struct_layout": (True, 'const Q = extern struct { r: [4]f32, c: u32 };\ntest { comptime { if (@sizeOf(Q) != 20) unreachable; if (@offsetOf(Q, "c") != 16) unreachable; } }'),
    "packed_struct_bitcast": (True, "const P = packed struct(u8) { a: bool, b: u7 };\ntest { const p: P = @bitCast(@as(u8, 3)); _ = p; }"),
}


def run(name, expected, source, work):
    path = os.path.join(work, name + ".zig")
    with open(path, "w") as f:
        f.write(source + "\n")
    if "pub fn main" in source:
        cmd = ZIG + ["build-exe", path, "-fno-emit-bin"]
    elif "test" in source:
        cmd = ZIG + ["test", path]
    else:
        cmd = ZIG + ["build-obj", path, "-fno-emit-bin"]
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=work)
    ok = p.returncode == 0
    first_error = next((l.split("error:", 1)[1].strip() for l in p.stderr.splitlines() if "error:" in l), "")
    return ok, first_error


def autovectorization(work):
    """Reports whether a plain scalar loop is turned into vector code (x86-64 only)."""
    src = "export fn add(a: [*]f32, b: [*]const f32, n: usize) void {\n    for (0..n) |i| a[i] += b[i];\n}\n"
    path = os.path.join(work, "autovec.zig")
    open(path, "w").write(src)
    p = subprocess.run(ZIG + ["build-obj", path, "-O", "ReleaseFast", "-target", "x86_64-linux", "-mcpu", "x86_64_v3",
                              "-femit-bin=" + os.path.join(work, "autovec.o")], capture_output=True, text=True, cwd=work)
    if p.returncode:
        return "could not build the auto-vectorization probe"
    try:
        asm = subprocess.run(["objdump", "-d", os.path.join(work, "autovec.o")], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return "objdump not found: auto-vectorization not checked"
    packed = sum(1 for l in asm.splitlines() if "ymm" in l)
    return ("plain loops ARE auto-vectorized by this compiler ({} ymm instructions): the notes say they are not".format(packed)
            if packed else "plain loops are not auto-vectorized (as the notes say): write @Vector code by hand")


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        version = subprocess.run(ZIG + ["version"], capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        sys.exit("compiler not found: set ZIG to the command that runs it")
    print("zig", version)
    bad = 0
    with tempfile.TemporaryDirectory() as work:
        for name, (expected, source) in CASES.items():
            if want not in name:
                continue
            ok, err = run(name, expected, source, work)
            agrees = ok == expected
            bad += not agrees
            print("{} {:44s} {}{}".format("ok      " if agrees else "MISMATCH", name,
                                         "works" if ok else "rejected", "" if ok else ": " + err[:90]))
        if not want or want in "autovectorization":
            print("note     " + autovectorization(work))
    if bad:
        sys.exit("{} case(s) disagree with docs/ZIG_0_17_1.md on this compiler".format(bad))


if __name__ == "__main__":
    main()
