//! The root of liblcgf_auto.a (`zig build abi`, x86-64 ELF): one archive for a program shipped
//! to machines it does not know. It holds three copies of liblcgf, each built for a CPU level
//! with the lane count that level suits (4 lanes for x86-64, 8 for x86-64-v3, 16 for
//! x86-64-v4) and its C names suffixed (`lcgf_rt_begin__l8`), and this dispatcher, which
//! exports lcgf.h's names.
//!
//! Each name is one `jmp` through a table. The table starts at stubs: the first call of any
//! name reads CPUID (8 lanes with AVX2, else 4; `LCGF_FORCE_LANES` = 4, 8 or 16 forces a
//! width the CPU can run), points every entry at one copy and
//! continues into it. From then on a call costs one indirect jump; nothing else changes, and a
//! program never mixes copies, since the first call decides for all of them. The rows that
//! C++ and Rust push inline go through `lcgf_rt_view`, which the chosen copy answers, so they
//! need no dispatch.
const std = @import("std");
const lcgf = @import("lcgf");

const Entry = struct { public: []const u8, copy: []const u8 };

/// Names that carry the lane count: `lcgf_frame_u32_f32_auto` here (and the static UIs'
/// `lcgf_ct_frame_u32_f32_auto`), the copy's own lane-named frame (`lcgf_frame_u32_f32_l8`) in
/// each copy.
const laned = [_][]const u8{ "lcgf_frame_u32_f32_l", "lcgf_ct_frame_u32_f32_l" };

fn lanedPrefix(comptime name: []const u8) ?[]const u8 {
    for (laned) |p| if (std.mem.startsWith(u8, name, p)) return p;
    return null;
}

/// lcgf.h's names.
const entries = blk: {
    @setEvalBranchQuota(20_000);
    const lists = .{ lcgf.abi_seam.exports, lcgf.abi_runtime.exports, lcgf.abi_api.c_names, lcgf.abi_ct.exports };
    var count = 0;
    for (lists) |list| count += list.len;
    var e: [count]Entry = undefined;
    var n = 0;
    for (lists) |list| for (0..list.len) |k| {
        const name: []const u8 = list[k][0];
        e[n] = if (lanedPrefix(name)) |p|
            .{ .public = p[0 .. p.len - 1] ++ "auto", .copy = p }
        else
            .{ .public = name, .copy = name };
        n += 1;
    };
    break :blk e;
};

pub const widths = [_]u32{ 4, 8, 16 };

fn copyName(comptime e: Entry, comptime w: u32) []const u8 {
    const suffix = std.fmt.comptimePrint("__l{d}", .{w});
    return if (lanedPrefix(e.copy) != null)
        std.fmt.comptimePrint("{s}{d}{s}", .{ e.copy, w, suffix })
    else
        e.copy ++ suffix;
}

/// Each copy's functions, in `entries` order.
const copies = blk: {
    @setEvalBranchQuota(200_000);
    var t: [widths.len][entries.len]*const anyopaque = undefined;
    for (widths, 0..) |w, i| for (entries, 0..) |e, k| {
        t[i][k] = @extern(*const anyopaque, .{ .name = copyName(e, w) });
    };
    break :blk t;
};

extern var lcgf_auto_table: [entries.len]usize;
extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;

fn cpuid(leaf: u32, sub: u32) [4]u32 {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ a, b, c, d };
}

fn xcr0() u32 {
    return asm volatile ("xgetbv"
        : [lo] "={eax}" (-> u32),
        : [n] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
}

fn bits(word: u32, comptime list: []const u5) bool {
    inline for (list) |b| if ((word >> b) & 1 == 0) return false;
    return true;
}

/// The widest lane count this CPU can run: 16 with x86-64-v4's AVX-512 (F, BW, CD, DQ, VL), 8
/// with x86-64-v3's AVX2, FMA, BMI1/2, F16C, LZCNT and MOVBE, else 4. The OS must save the
/// vector state too (XCR0), or the wide registers are not usable.
pub fn detect() u32 {
    const max = cpuid(0, 0)[0];
    if (max < 7) return 4;
    const l1 = cpuid(1, 0);
    const l7 = cpuid(7, 0);
    const ext = cpuid(0x8000_0001, 0);
    if (!bits(l1[2], &.{ 12, 22, 27, 28, 29 })) return 4; // FMA MOVBE OSXSAVE AVX F16C
    const x = xcr0();
    if (!bits(x, &.{ 1, 2 })) return 4; // SSE and AVX state
    if (!bits(l7[1], &.{ 3, 5, 8 }) or !bits(ext[2], &.{5})) return 4; // BMI1 AVX2 BMI2; LZCNT
    if (bits(l7[1], &.{ 16, 17, 28, 30, 31 }) and bits(x, &.{ 5, 6, 7 })) return 16;
    return 8;
}

/// The width chosen without `LCGF_FORCE_LANES`: 8 where the CPU has AVX2, AVX-512 included.
/// 16 lanes measured slower than 8 on an AVX-512 machine (docs/guide/bindings.md), so they run
/// only when forced.
pub const default_max = 8;

/// `LCGF_FORCE_LANES` (4, 8 or 16), else the widest the CPU runs up to `default_max`. A forced
/// width the CPU cannot run is ignored.
fn choose() u32 {
    const can = detect();
    const best = @min(can, default_max);
    const forced = getenv("LCGF_FORCE_LANES") orelse return best;
    const w = std.fmt.parseInt(u32, std.mem.span(forced), 10) catch return best;
    return if ((w == 4 or w == 8 or w == 16) and w <= can) w else best;
}

/// Points every entry of the table at the chosen copy. The stubs call it on the first call of
/// any name; calls racing on two threads write the same values.
fn pick() callconv(.c) void {
    const w = choose();
    const i: usize = switch (w) {
        4 => 0,
        8 => 1,
        else => 2,
    };
    for (&lcgf_auto_table, copies[i]) |*slot, f| @atomicStore(usize, slot, @intFromPtr(f), .release);
}

/// The width the first call chose (0 before it), for tests and diagnostics.
fn chosen() callconv(.c) u32 {
    const first = @atomicLoad(usize, &lcgf_auto_table[0], .acquire);
    for (copies, widths) |c, w| if (first == @intFromPtr(c[0])) return w;
    return 0;
}

comptime {
    @export(&pick, .{ .name = "lcgf_auto_pick", .visibility = .hidden });
    @export(&chosen, .{ .name = "lcgf_auto_lanes" });
    asm (source());
}

/// The jumps, the stubs, the resolver and the table, in x86-64 ELF assembly. The resolver
/// keeps every argument register (System V passes up to six integers and eight floats in
/// registers) across `pick`, then jumps on as if the stub were never there.
fn source() []const u8 {
    @setEvalBranchQuota(200_000);
    var s: []const u8 = ".text\n";
    for (entries, 0..) |e, k| s = s ++ std.fmt.comptimePrint(
        \\.globl {0s}
        \\.type {0s},@function
        \\.p2align 4
        \\{0s}:
        \\  jmp *lcgf_auto_table+{1d}(%rip)
        \\.size {0s}, .-{0s}
        \\lcgf_auto_stub_{2d}:
        \\  movl ${2d}, %r11d
        \\  jmp lcgf_auto_resolve
        \\
    , .{ e.public, k * 8, k });
    s = s ++
        \\.p2align 4
        \\lcgf_auto_resolve:
        \\  pushq %rdi
        \\  pushq %rsi
        \\  pushq %rdx
        \\  pushq %rcx
        \\  pushq %r8
        \\  pushq %r9
        \\  pushq %r11
        \\  subq $128, %rsp
        \\  movdqu %xmm0, 0(%rsp)
        \\  movdqu %xmm1, 16(%rsp)
        \\  movdqu %xmm2, 32(%rsp)
        \\  movdqu %xmm3, 48(%rsp)
        \\  movdqu %xmm4, 64(%rsp)
        \\  movdqu %xmm5, 80(%rsp)
        \\  movdqu %xmm6, 96(%rsp)
        \\  movdqu %xmm7, 112(%rsp)
        \\  call lcgf_auto_pick
        \\  movdqu 0(%rsp), %xmm0
        \\  movdqu 16(%rsp), %xmm1
        \\  movdqu 32(%rsp), %xmm2
        \\  movdqu 48(%rsp), %xmm3
        \\  movdqu 64(%rsp), %xmm4
        \\  movdqu 80(%rsp), %xmm5
        \\  movdqu 96(%rsp), %xmm6
        \\  movdqu 112(%rsp), %xmm7
        \\  addq $128, %rsp
        \\  popq %r11
        \\  popq %r9
        \\  popq %r8
        \\  popq %rcx
        \\  popq %rdx
        \\  popq %rsi
        \\  popq %rdi
        \\  leaq lcgf_auto_table(%rip), %rax
        \\  jmp *(%rax,%r11,8)
        \\.data
        \\.p2align 3
        \\.globl lcgf_auto_table
        \\.hidden lcgf_auto_table
        \\lcgf_auto_table:
        \\
    ;
    for (0..entries.len) |k| s = s ++ std.fmt.comptimePrint("  .quad lcgf_auto_stub_{d}\n", .{k});
    return s ++ ".text\n";
}
