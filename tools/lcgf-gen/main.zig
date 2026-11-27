//! lcgf-gen: the generator above the seam, for programs written in C++ or Rust. It reads a UI
//! spec (`.zon`, src/abi/zon.zig) and runs the same `plan` the Zig compiler runs at comptime
//! (src/abi/plan.zig). It writes the tables, the state struct, the widget enum and the inline
//! setters in the program's own language. The prebuilt liblcgf reads the tables at run time
//! through the C seam (src/abi/lcgf.h). Shipped as a native binary; programs that use it need no
//! Zig compiler.
//!
//!   lcgf-gen <spec.zon> --lang cpp   -o <name>.lcgf.hpp
//!   lcgf-gen <spec.zon> --lang rust  -o <name>.rs
//!   lcgf-gen <spec.zon> --lang words -o <name>.tables    (the raw u32 words, for checks)
//!   lcgf-gen <spec.zon> --lang zon                       (the spec as read, echoed; checks)
//!
//! A static UI (`--static`): the comptime pipeline's tables instead (src/abi/ct.zig), from a spec
//! of rows, columns, labels, checkboxes and sliders whose structure never changes. The fold,
//! the constant columns and the paint templates are made here, as Zig makes them at comptime.
//!
//!   lcgf-gen <spec.zon> --static --lang cpp|rust|c|zig|words -o <out>
//!
//! A shader: its bind groups reflected from the WGSL by the same reader `lcgf_render.gpu` uses
//! at comptime (src/render/gpu/reflect.zig, `parseInto`), with the code of each back end it is
//! given embedded: the WGSL itself (wgpu), naga's SPIR-V (Vulkan), naga's GLSL ES of each entry
//! point with LCGF's binding table (GL ES; the bindings are written in as src/render/gpu/naga.zig
//! does at comptime). lcgf-gen runs no other program: the caller runs naga.
//!
//!   lcgf-gen --wgsl <s.wgsl> --name tinted --lang cpp|rust [--spirv <s.spv>] [--glsl <entry>=<file>]... [--msl <s.metal>] [--hlsl <s.hlsl>] -o <out>
//!   lcgf-gen --wgsl <s.wgsl> --entry-points    (one line per entry point: name, naga stage, GLSL profile, file extension)

const std = @import("std");
const lcgf = @import("lcgf");
const plan = lcgf.abi_plan;
const zon = lcgf.abi_zon;
const reflect = lcgf.gpu_reflect;
const seam = lcgf.abi_seam;
const ct = lcgf.abi_ct;
const naga = lcgf.gpu_naga;

const Lang = enum { cpp, rust, c, zig, words, zon };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    var input: ?[]const u8 = null;
    var wgsl: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var spirv: ?[]const u8 = null;
    var msl_path: ?[]const u8 = null;
    var hlsl_path: ?[]const u8 = null;
    var glsl_args: std.ArrayList([]const u8) = .empty;
    var entry_points = false;
    var static = false;
    var lang: Lang = .cpp;
    var out_path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--lang")) {
            lang = std.meta.stringToEnum(Lang, args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, a, "-o")) {
            out_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--wgsl")) {
            wgsl = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--spirv")) {
            spirv = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--hlsl")) {
            hlsl_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--msl")) {
            msl_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--glsl")) {
            try glsl_args.append(arena, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--entry-points")) {
            entry_points = true;
        } else if (std.mem.eql(u8, a, "--static")) {
            static = true;
        } else if (std.mem.eql(u8, a, "--name")) {
            name = args.next() orelse return usage();
        } else if (a.len > 0 and a[0] == '-') {
            return usage();
        } else input = a;
    }
    var out: std.ArrayList(u8) = .empty;
    if (wgsl) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const text = try arena.alloc(u8, src.len);
        const bindings = try arena.alloc(reflect.Binding, std.mem.count(u8, src, "var") + 1);
        const entries = try arena.alloc(reflect.EntryPoint, std.mem.count(u8, src, "fn") + 1);
        var failure: reflect.Failure = .{};
        const m = reflect.parseInto(src, text, bindings, entries, &failure) catch {
            std.log.err("{s}: WGSL reflection: {s} at `{s}`", .{ path, failure.what, failure.at });
            std.process.exit(1);
        };
        if (entry_points) {
            for (m.entry_points) |e| {
                const ext = switch (e.stage) {
                    .vertex => "vert",
                    .fragment => "frag",
                    .compute => "comp",
                };
                try out.print(arena, "{s} {s} {s} {s}\n", .{ e.name, @tagName(e.stage), if (e.stage == .compute) "es310" else "es300", ext });
            }
        } else {
            var words: []const u32 = &.{};
            if (spirv) |sp| {
                const code = try std.Io.Dir.cwd().readFileAlloc(io, sp, arena, .limited(16 << 20));
                if (code.len % 4 != 0) {
                    std.log.err("{s}: not SPIR-V (its length is not a whole number of words)", .{sp});
                    std.process.exit(1);
                }
                const w = try arena.alloc(u32, code.len / 4);
                @memcpy(std.mem.sliceAsBytes(w), code);
                words = w;
            }
            const scratch = try arena.alloc(reflect.Binding, m.bindings.len);
            const table = naga.slotsInto(m, true, true, scratch, try arena.alloc(naga.Slot, m.bindings.len));
            var stages: std.ArrayList(Glsl) = .empty;
            for (glsl_args.items) |arg| {
                const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return usage();
                const raw = try std.Io.Dir.cwd().readFileAlloc(io, arg[eq + 1 ..], arena, .limited(1 << 20));
                const code = naga.glslAlloc(arena, table, raw) catch {
                    std.log.err("{s}: a storage block or image has no binding in {s}", .{ arg[eq + 1 ..], path });
                    std.process.exit(1);
                };
                try stages.append(arena, .{ .entry = arg[0..eq], .code = code });
            }
            // Metal: naga's MSL with every resource at its slot, as the Zig back end has it.
            const mscratch = try arena.alloc(reflect.Binding, m.bindings.len);
            const mtable = naga.slotsInto(m, false, false, mscratch, try arena.alloc(naga.Slot, m.bindings.len));
            var msl: ?[]const u8 = null;
            if (msl_path) |mp| {
                const raw = try std.Io.Dir.cwd().readFileAlloc(io, mp, arena, .limited(1 << 20));
                msl = naga.mslAlloc(arena, m, mtable, raw) catch {
                    std.log.err("{s}: a parameter has no WGSL binding in {s}", .{ mp, path });
                    std.process.exit(1);
                };
            }
            // D3D12: naga's HLSL with its samplers out of naga's heap, as the Zig back end has it.
            var hlsl: ?[]const u8 = null;
            if (hlsl_path) |hp| {
                const raw = try std.Io.Dir.cwd().readFileAlloc(io, hp, arena, .limited(1 << 20));
                hlsl = naga.hlslAlloc(arena, raw) catch {
                    std.log.err("{s}: a sampler of naga's heap was not recognised", .{hp});
                    std.process.exit(1);
                };
            }
            const sh: Shader = .{ .arena = arena, .out = &out, .name = name orelse return usage(), .m = m, .wgsl = src, .spirv = words, .glsl = stages.items, .slots = table, .msl = msl, .msl_slots = mtable, .hlsl = hlsl, .source = path };
            switch (lang) {
                .cpp => try sh.cpp(),
                .rust => try sh.rust(),
                else => return usage(),
            }
        }
    } else if (static) {
        const path = input orelse return usage();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        try out.appendSlice(arena, staticOf(arena, @tagName(lang), try arena.dupeSentinel(u8, bytes, 0), path) orelse std.process.exit(1));
    } else {
        const path = input orelse return usage();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        if (lang == .c or lang == .zig) return usage();
        try out.appendSlice(arena, tablesOf(arena, @tagName(lang), try arena.dupeSentinel(u8, bytes, 0), path) orelse std.process.exit(1));
    }
    if (out_path) |p| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = out.items });
    } else {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(out.items);
        try w.interface.flush();
    }
}

/// A static `.zon` spec (`src`, read from `path`) as `lang`'s static-UI code (`StaticGen`), or
/// null after logging what is wrong.
fn staticOf(arena: std.mem.Allocator, lang_name: []const u8, src: [:0]const u8, path: []const u8) ?[]const u8 {
    return staticOrError(arena, lang_name, src, path) catch |e| {
        std.log.err("{s}: {s}", .{ path, @errorName(e) });
        return null;
    };
}

fn staticOrError(arena: std.mem.Allocator, lang_name: []const u8, src: [:0]const u8, path: []const u8) !?[]const u8 {
    const x = zon.readStatic(arena, arena, src, path) catch |e| switch (e) {
        error.ParseZon, error.UnknownField, error.FieldWithoutType, error.NotStatic, error.BadField => return null,
        else => return e,
    };
    const words = zon.staticTables(arena, &x) catch |e| {
        std.log.err("{s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    var out: std.ArrayList(u8) = .empty;
    const g: StaticGen = .{ .arena = arena, .out = &out, .x = &x, .words = words, .bytes = ct.Ui.bytes(words) catch unreachable, .source = path };
    switch (std.meta.stringToEnum(Lang, lang_name).?) {
        .cpp => try g.cpp(),
        .rust => try g.rust(),
        .c => try g.cSource(),
        .zig => try g.zigSource(),
        .words => try out.appendSlice(arena, std.mem.sliceAsBytes(words)),
        .zon => try out.appendSlice(arena, src),
    }
    return out.items;
}

/// A `.zon` spec (`src`, read from `path`) as `lang`'s widget tables: `cpp`, `rust`, `words`, or
/// `zon` (echoed). Null after logging what is wrong.
fn tablesOf(arena: std.mem.Allocator, lang_name: []const u8, src: [:0]const u8, path: []const u8) ?[]const u8 {
    return tablesOrError(arena, lang_name, src, path) catch |e| {
        std.log.err("{s}: {s}", .{ path, @errorName(e) });
        return null;
    };
}

fn tablesOrError(arena: std.mem.Allocator, lang_name: []const u8, src: [:0]const u8, path: []const u8) !?[]const u8 {
    const x = zon.read(arena, arena, src, path) catch |e| switch (e) {
        error.ParseZon, error.UnknownField, error.FieldWithoutType => return null,
        else => return e,
    };
    const words = try zon.tables(arena, &x);
    var out: std.ArrayList(u8) = .empty;
    const g: Gen = .{ .arena = arena, .out = &out, .x = &x, .words = words, .bytes = seam.Ui.bytes(words) catch unreachable, .source = path };
    switch (std.meta.stringToEnum(Lang, lang_name).?) {
        .cpp => try g.cpp(),
        .rust => try g.rust(),
        .words => try out.appendSlice(arena, std.mem.sliceAsBytes(words)),
        .zon => try out.appendSlice(arena, src),
        .c, .zig => unreachable,
    }
    return out.items;
}

fn usage() void {
    std.log.err("usage: lcgf-gen <spec.zon> [--static] --lang cpp|rust|c|words [-o out]  |  lcgf-gen --wgsl <file> --name <n> --lang cpp|rust [--spirv f] [--glsl entry=f]... [--msl f] [--hlsl f] [-o out]  |  lcgf-gen --wgsl <file> --entry-points", .{});
    std.process.exit(2);
}

const Gen = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    x: *const zon.Expanded,
    words: []const u32,
    bytes: usize,
    source: []const u8,

    fn print(g: *const Gen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.arena, fmt, args);
    }

    fn widgets(g: *const Gen) []const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (g.x.nodes) |n| if (n.id) |id| list.append(g.arena, id) catch @panic("OOM");
        return list.items;
    }

    fn words_(g: *const Gen, per_line: usize, sep: []const u8) !void {
        for (g.words, 0..) |w, i| {
            if (i % per_line == 0) try g.print("\n   ", .{});
            try g.print(" 0x{x:0>8}{s}", .{ w, sep });
        }
    }

    fn cpp(g: *const Gen) !void {
        const name = g.x.spec.name;
        try g.print(
            \\// Generated by lcgf-gen from {s}. Do not edit: change the spec and run lcgf-gen again.
            \\// The tables are what `plan` (src/abi/plan.zig) made of the spec, the same words Zig makes
            \\// at compile time; liblcgf reads them through lcgf.h. Everything else here is inline.
            \\#pragma once
            \\#include <cstddef>
            \\#include <cstdint>
            \\#include <lcgf/lcgf.hpp>
            \\
            \\namespace {s} {{
            \\
            \\/// The UI's state: yours to read and write between frames. Laid out as the tables say.
            \\struct State {{
            \\
        , .{ g.source, name });
        for (g.x.spec.state, g.x.fields) |z, f| switch (f.type) {
            .str => try g.print("    lcgf::Str {s}{{\"{f}\"}};\n", .{ f.name, std.zig.fmtString(z.str.?) }),
            .bool => try g.print("    bool {s} = {};\n", .{ f.name, z.bool.? }),
            .f32 => try g.print("    float {s} = {s}f;\n", .{ f.name, floatLit(g.arena, z.f32.?) }),
            .u32 => try g.print("    std::uint32_t {s} = {d};\n", .{ f.name, z.u32.? }),
            .u8 => try g.print("    std::uint8_t {s} = {d};\n", .{ f.name, z.u8.? }),
            .color => try g.print("    std::uint32_t {s} = 0x{x};\n", .{ f.name, zon.fieldColor(z) }),
            .other => unreachable, // only Zig state has those, never a .zon spec
        };
        const h = (plan.Tables.decode(g.words) catch unreachable).header;
        try g.print("}};\nstatic_assert(sizeof(State) == {d} && alignof(State) == {d}, \"State does not match the tables\");\n", .{ h.state_size, h.state_align });
        for (g.x.fields) |f| try g.print("static_assert(offsetof(State, {s}) == {d});\n", .{ f.name, f.offset });
        try g.print("\n/// The widgets, in row order: what `events()` reports.\nenum class Widget : std::uint32_t {{", .{});
        for (g.widgets(), 0..) |w, k| try g.print(" {s} = {d},", .{ w, k });
        try g.print(" }};\n\n/// The tables ({d} words).\nalignas(4) inline constexpr std::uint32_t tables[{d}] = {{", .{ g.words.len, g.words.len });
        try g.words_(8, ",");
        try g.print(
            \\
            \\}};
            \\/// Bytes the UI needs in your buffer, aligned to lcgf::column_align, for any lane count.
            \\inline constexpr std::size_t bytes = {d};
            \\
            \\/// The UI: the state, and the frame behind the seam. Setters are one store each.
            \\class Ui : public lcgf::Ui<State, Widget> {{
            \\public:
            \\    explicit Ui(std::span<std::byte> buffer, State s = {{}}) : lcgf::Ui<State, Widget>(tables, buffer, s) {{}}
            \\
        , .{g.bytes});
        for (g.x.fields) |f| {
            const ty = switch (f.type) {
                .str => "lcgf::Str",
                .bool => "bool",
                .f32 => "float",
                .u32 => "std::uint32_t",
                .u8 => "std::uint8_t",
                .color => "std::uint32_t",
                .other => unreachable,
            };
            try g.print("    void set_{s}({s} v) {{ state.{s} = v; }}\n    {s} {s}() const {{ return state.{s}; }}\n", .{ f.name, ty, f.name, ty, f.name, f.name });
        }
        try g.print("}};\n\n}} // namespace {s}\n", .{name});
    }

    fn rust(g: *const Gen) !void {
        const h = (plan.Tables.decode(g.words) catch unreachable).header;
        try g.print(
            \\// Generated by lcgf-gen from {s}. Do not edit: change the spec and run lcgf-gen again.
            \\// The tables are what `plan` (src/abi/plan.zig) made of the spec, the same words Zig makes
            \\// at compile time; liblcgf reads them through lcgf.h. Everything else here is inline.
            \\
            \\/// The UI's state: yours to read and write between frames. Laid out as the tables say.
            \\#[repr(C)]
            \\#[derive(Clone, Copy, Debug)]
            \\pub struct State {{
            \\
        , .{g.source});
        for (g.x.fields) |f| try g.print("    pub {s}: {s},\n", .{ f.name, rustType(f.type) });
        try g.print("}}\n\nimpl Default for State {{\n    fn default() -> Self {{\n        Self {{\n", .{});
        for (g.x.spec.state, g.x.fields) |z, f| switch (f.type) {
            .str => try g.print("            {s}: ::lcgf::Str::new(\"{f}\"),\n", .{ f.name, std.zig.fmtString(z.str.?) }),
            .bool => try g.print("            {s}: {},\n", .{ f.name, z.bool.? }),
            .f32 => try g.print("            {s}: {s}f32,\n", .{ f.name, floatLit(g.arena, z.f32.?) }),
            .u32 => try g.print("            {s}: {d},\n", .{ f.name, z.u32.? }),
            .u8 => try g.print("            {s}: {d},\n", .{ f.name, z.u8.? }),
            .color => try g.print("            {s}: 0x{x},\n", .{ f.name, zon.fieldColor(z) }),
            .other => unreachable,
        };
        try g.print("        }}\n    }}\n}}\n\nconst _: () = assert!(::core::mem::size_of::<State>() == {d} && ::core::mem::align_of::<State>() == {d});\n", .{ h.state_size, h.state_align });
        for (g.x.fields) |f| try g.print("const _: () = assert!(::core::mem::offset_of!(State, {s}) == {d});\n", .{ f.name, f.offset });
        try g.print("\n/// The widgets, in row order: what `events()` reports.\n#[repr(u32)]\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub enum Widget {{\n", .{});
        for (g.widgets(), 0..) |w, k| try g.print("    {s} = {d},\n", .{ camel(g.arena, w), k });
        try g.print("}}\n\nimpl ::lcgf::WidgetEnum for Widget {{\n    fn slot(self) -> u32 {{ self as u32 }}\n}}\n\n/// The tables ({d} words).\npub static TABLES: ::lcgf::Tables<{d}> = ::lcgf::Tables([", .{ g.words.len, g.words.len });
        try g.words_(8, ",");
        try g.print(
            \\
            \\]);
            \\/// Bytes the UI needs in your buffer, for any lane count.
            \\pub const BYTES: usize = {d};
            \\
            \\/// The UI: the state, and the frame behind the seam. Setters are one store each.
            \\pub struct Ui<'a> {{
            \\    pub inner: ::lcgf::Ui<'a, State, Widget>,
            \\}}
            \\
            \\impl<'a> Ui<'a> {{
            \\    pub fn new(buffer: &'a mut ::lcgf::Buffer<BYTES>) -> Result<Self, ::lcgf::Status> {{
            \\        Ok(Self {{ inner: ::lcgf::Ui::new(&TABLES.0, buffer.bytes(), State::default())? }})
            \\    }}
            \\    pub fn frame(&mut self, input: &::lcgf::Input) -> ::lcgf::Frame<'_, Widget> {{
            \\        self.inner.frame(input)
            \\    }}
            \\    pub fn state(&self) -> &State {{
            \\        &self.inner.state
            \\    }}
            \\
        , .{g.bytes});
        for (g.x.fields) |f| try g.print("    pub fn set_{s}(&mut self, v: {s}) {{\n        self.inner.state.{s} = v;\n    }}\n", .{ f.name, rustType(f.type), f.name });
        try g.print("}}\n", .{});
    }
};

/// The state struct in C++, with its layout asserted against the tables'.
fn stateCpp(arena: std.mem.Allocator, out: *std.ArrayList(u8), state: []const zon.ZField, fields: []const plan.Field, size: u32, alignment: u32) !void {
    try out.print(arena, "/// The UI's state: yours to read and write between frames. Laid out as the tables say.\nstruct State {{\n", .{});
    for (state, fields) |z, f| switch (f.type) {
        .str => try out.print(arena, "    lcgf::Str {s}{{\"{f}\"}};\n", .{ f.name, std.zig.fmtString(z.str.?) }),
        .bool => try out.print(arena, "    bool {s} = {};\n", .{ f.name, z.bool.? }),
        .f32 => try out.print(arena, "    float {s} = {s}f;\n", .{ f.name, floatLit(arena, z.f32.?) }),
        .u32 => try out.print(arena, "    std::uint32_t {s} = {d};\n", .{ f.name, z.u32.? }),
        .u8 => try out.print(arena, "    std::uint8_t {s} = {d};\n", .{ f.name, z.u8.? }),
        .color => try out.print(arena, "    std::uint32_t {s} = 0x{x};\n", .{ f.name, zon.fieldColor(z) }),
        .other => unreachable,
    };
    try out.print(arena, "}};\nstatic_assert(sizeof(State) == {d} && alignof(State) == {d}, \"State does not match the tables\");\n", .{ size, alignment });
    for (fields) |f| try out.print(arena, "static_assert(offsetof(State, {s}) == {d});\n", .{ f.name, f.offset });
}

/// The state struct in Rust, with `Default` from the spec and its layout asserted.
fn stateRust(arena: std.mem.Allocator, out: *std.ArrayList(u8), state: []const zon.ZField, fields: []const plan.Field, size: u32, alignment: u32) !void {
    try out.print(arena, "/// The UI's state: yours to read and write between frames. Laid out as the tables say.\n#[repr(C)]\n#[derive(Clone, Copy, Debug)]\npub struct State {{\n", .{});
    for (fields) |f| try out.print(arena, "    pub {s}: {s},\n", .{ f.name, rustType(f.type) });
    try out.print(arena, "}}\n\nimpl Default for State {{\n    fn default() -> Self {{\n        Self {{\n", .{});
    for (state, fields) |z, f| switch (f.type) {
        .str => try out.print(arena, "            {s}: ::lcgf::Str::new(\"{f}\"),\n", .{ f.name, std.zig.fmtString(z.str.?) }),
        .bool => try out.print(arena, "            {s}: {},\n", .{ f.name, z.bool.? }),
        .f32 => try out.print(arena, "            {s}: {s}f32,\n", .{ f.name, floatLit(arena, z.f32.?) }),
        .u32 => try out.print(arena, "            {s}: {d},\n", .{ f.name, z.u32.? }),
        .u8 => try out.print(arena, "            {s}: {d},\n", .{ f.name, z.u8.? }),
        .color => try out.print(arena, "            {s}: 0x{x},\n", .{ f.name, zon.fieldColor(z) }),
        .other => unreachable,
    };
    try out.print(arena, "        }}\n    }}\n}}\n\nconst _: () = assert!(::core::mem::size_of::<State>() == {d} && ::core::mem::align_of::<State>() == {d});\n", .{ size, alignment });
    for (fields) |f| try out.print(arena, "const _: () = assert!(::core::mem::offset_of!(State, {s}) == {d});\n", .{ f.name, f.offset });
}

/// A static UI's generated code: the state, the widgets and fields, the words (`ct.make`) for
/// liblcgf's frame, and the UI's own frame specialized to them (as Zig or C).
const StaticGen = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    x: *const zon.Static,
    words: []const u32,
    bytes: usize,
    source: []const u8,

    fn print(g: *const StaticGen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.arena, fmt, args);
    }

    fn words_(g: *const StaticGen) !void {
        for (g.words, 0..) |w, i| {
            if (i % 8 == 0) try g.print("\n   ", .{});
            try g.print(" 0x{x:0>8},", .{w});
        }
    }

    fn header(g: *const StaticGen) *const ct.Header {
        return @ptrCast(g.words.ptr);
    }

    fn fieldType(t: plan.FieldType) []const u8 {
        return switch (t) {
            .str => "lcgf::Str",
            .bool => "bool",
            .f32 => "float",
            .u32 => "std::uint32_t",
            .u8 => "std::uint8_t",
            .color => "std::uint32_t",
            .other => unreachable,
        };
    }

    fn widgetsRust(g: *const StaticGen) !void {
        const ws = g.x.widgets;
        try g.print("/// The widgets, valued by their rows: what `at`, `pointer` and `focus` report.\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\n", .{});
        if (ws.len > 0) try g.print("#[repr(u32)]\n", .{});
        try g.print("pub enum Widget {{\n", .{});
        for (ws) |w| try g.print("    {s} = {d},\n", .{ camel(g.arena, w.name), w.row });
        try g.print("}}\n\n/// An event on a widget: a click on a checkbox, a slider's value while it is dragged.\n#[derive(Clone, Copy, Debug, PartialEq)]\npub enum Event {{\n", .{});
        for (ws) |w| try g.print("    {s}{s},\n", .{ camel(g.arena, w.name), if (w.slider) "(f32)" else "" });
        try g.print("}}\n\nimpl Widget {{\n    /// The widget's row.\n    pub fn row(self) -> u32 {{\n        match self {{\n", .{});
        for (ws) |w| try g.print("            Widget::{s} => {d},\n", .{ camel(g.arena, w.name), w.row });
        try g.print("        }}\n    }}\n}}\n\nimpl Event {{\n    /// The widget the event is on.\n    pub fn widget(self) -> Widget {{\n        match self {{\n", .{});
        for (ws) |w| try g.print("            Event::{s}{s} => Widget::{s},\n", .{ camel(g.arena, w.name), if (w.slider) "(_)" else "", camel(g.arena, w.name) });
        try g.print("        }}\n    }}\n    /// A slider's value.\n    pub fn value(self) -> Option<f32> {{\n        match self {{\n", .{});
        var any_slider = false;
        for (ws) |w| if (w.slider) {
            any_slider = true;
            try g.print("            Event::{s}(v) => Some(v),\n", .{camel(g.arena, w.name)});
        };
        if (ws.len > 0 and (!any_slider or blk: {
            var all = true;
            for (ws) |w| all = all and w.slider;
            break :blk !all;
        })) try g.print("            _ => None,\n", .{});
        try g.print("        }}\n    }}\n}}\n\n", .{});
    }

    /// How a constant column's rows are written: as its own number type, so a compiler sees a
    /// column of one value as a splat, or as whole words for anything else.
    const ColumnType = struct { c: []const u8, zig: []const u8, elem: usize };

    fn columnType(comptime field: []const u8) ColumnType {
        const FT = @FieldType(lcgf.tree.Tree.Columns, field);
        const T = switch (@typeInfo(FT)) {
            .pointer => |p| p.child,
            .array => |a| @typeInfo(a.child).pointer.child,
            else => unreachable,
        };
        return switch (T) {
            f32 => .{ .c = "float", .zig = "f32", .elem = 4 },
            u32 => .{ .c = "uint32_t", .zig = "u32", .elem = 4 },
            u16 => .{ .c = "uint16_t", .zig = "u16", .elem = 2 },
            u8 => .{ .c = "uint8_t", .zig = "u8", .elem = 1 },
            i16 => .{ .c = "int16_t", .zig = "i16", .elem = 2 },
            else => .{ .c = "uint32_t", .zig = "u32", .elem = 4 },
        };
    }

    /// Each constant column of each tree as its own array named `col<tree>_<k>`, in C or Zig;
    /// returns, per `frameWith` column, the array's name or null for a written column.
    fn columnArrays(g: *const StaticGen, comptime zig: bool) ![ct.cols_len]?[]const u8 {
        const h = g.header();
        var refs: [ct.cols_len]?[]const u8 = @splat(null);
        for ([_]*const ct.Block{ &h.full, &h.skel }, 0..) |b, bi| {
            if (bi == 1 and h.folded == 0) continue;
            const offs = g.words[b.cols..][0..ct.column_arrays.len];
            inline for (ct.column_arrays, 0..) |col, k| if (offs[k] != ct.none) {
                const ty = comptime columnType(col.field);
                const bytes = std.mem.sliceAsBytes(g.words[offs[k]..])[0 .. ct.rowsMax(b.n) * col.size];
                const id = try std.fmt.allocPrint(g.arena, "col{d}_{d}", .{ bi, k });
                const count = bytes.len / ty.elem;
                if (zig)
                    try g.print("const {s}: [{d}]{s} align(64) = .{{", .{ id, count, ty.zig })
                else
                    try g.print("static const {s} {s}[{d}] __attribute__((aligned(64))) = {{", .{ ty.c, id, count });
                for (0..count) |i| {
                    if (i % 16 == 0) try g.print("\n   ", .{});
                    const v: u32 = switch (ty.elem) {
                        1 => bytes[i],
                        2 => std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little),
                        else => std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little),
                    };
                    if (comptime std.mem.eql(u8, ty.zig, "f32")) {
                        if (zig) try g.print(" @bitCast(@as(u32, 0x{x})),", .{v}) else try g.print(" {s},", .{try cFloat(g.arena, @bitCast(v))});
                    } else if (comptime std.mem.eql(u8, ty.zig, "i16"))
                        try g.print(" {d},", .{@as(i16, @bitCast(@as(u16, @intCast(v))))})
                    else
                        try g.print(" 0x{x},", .{v});
                }
                try g.print("\n}};\n", .{});
                refs[bi * ct.column_arrays.len + k] = id;
            };
        }
        return refs;
    }

    /// The UI's frame as a Zig root (`--lang zig`), for `zig build-obj` against the lcgf sources
    /// `zig build abi` installs (share/lcgf/zig): liblcgf's static-UI frame (`ct.Ui.frameWith`)
    /// with this UI's words and each constant column as constants, so Zig specializes it as it
    /// does a comptime UI. Exports `lcgf_ui_<name>_frame` and `lcgf_ui_<name>_words`.
    fn zigSource(g: *const StaticGen) !void {
        const name = g.x.spec.name;
        try g.print(
            \\//! Generated by lcgf-gen --static --lang zig from {s}. Do not edit: change the spec and
            \\//! run lcgf-gen again. The frame of the static UI `{s}`, specialized to its tables.
            \\const ct = @import("lcgf").abi_ct;
            \\
            \\const words: [{d}]u32 align(64) = .{{
        , .{ g.source, name, g.words.len });
        try g.words_();
        try g.print("\n}};\n", .{});
        const refs = try g.columnArrays(true);
        try g.print("const written: [1]u8 align(64) = .{{0}};\nconst cols: [{d}][*]const u8 = .{{", .{ct.cols_len});
        for (refs, 0..) |r, i| {
            if (i % 4 == 0) try g.print("\n   ", .{});
            if (r) |id| try g.print(" @ptrCast(&{s}),", .{id}) else try g.print(" &written,", .{});
        }
        try g.print(
            \\
            \\}};
            \\
            \\export fn lcgf_ui_{0s}_frame(buf: [*]align(64) u8, bytes: usize, state: [*]const u8, width: f32, height: f32, out: *anyopaque) callconv(.c) void {{
            \\    ct.frameInto(&words, &cols, buf[0..bytes], state, .{{ width, height }}, out);
            \\}}
            \\
            \\export fn lcgf_ui_{0s}_words(len: *usize) callconv(.c) [*]const u32 {{
            \\    len.* = words.len;
            \\    return &words;
            \\}}
            \\
        , .{name});
    }

    /// The UI's frame as C (`--lang c`): liblcgf's static-UI engine (share/lcgf/lcgf_ct_l*.c,
    /// Zig's C backend) included into this file with the words and each constant column as
    /// constants, so clang specializes the frame to this UI as Zig does at comptime. Other
    /// compilers call liblcgf's frame over the same words.
    fn cSource(g: *const StaticGen) !void {
        const name = g.x.spec.name;
        try g.print(
            \\// Generated by lcgf-gen --static --lang c from {s}. Do not edit: change the spec and run
            \\// lcgf-gen again. The frame of the static UI `{s}`: with clang, liblcgf's static-UI engine
            \\// (share/lcgf/lcgf_ct_l<LANES>.c, made by Zig's C backend) compiled here over this UI's
            \\// words as constants, so the compiler specializes it; with any other compiler, liblcgf's
            \\// frame over the same words. Compile with -DLCGF_LANES=<4|8|16> as liblcgf is linked.
            \\#include <stddef.h>
            \\#include <stdint.h>
            \\
            \\
        , .{ g.source, name });
        try g.print("static const uint32_t words[{d}] __attribute__((aligned(64))) = {{", .{g.words.len});
        try g.words_();
        try g.print("\n}};\n\n", .{});
        const refs = try g.columnArrays(false);
        try g.print("static const uint8_t *const cols[{d}] = {{", .{ct.cols_len});
        for (refs, 0..) |r, i| {
            try g.print("{s}", .{if (i % 4 == 0) "\n    " else " "});
            if (r) |id| try g.print("(const uint8_t *){s},", .{id}) else try g.print("0,", .{});
        }
        try g.print(
            \\
            \\}};
            \\
            \\#if defined(__clang__) && defined(LCGF_LANES) && LCGF_LANES != 0
            \\// Every engine function inlined into the frame below, so the words fold into it; its C
            \\// functions under names of this file's own (below), so every UI may include it.
            \\#pragma clang attribute push(__attribute__((always_inline)), apply_to = function)
            \\
        , .{});
        inline for (ct.exports) |e| if (comptime !std.mem.eql(u8, e[0], ct.frame_symbol)) {
            try g.print("#define {0s} lcgf_ui_{1s}_{0s}\n", .{ e[0], name });
        };
        for ([_][]const u8{ "lcgf_ct_frame_u32_f32_l", "lcgf_ct_frame_words_u32_f32_l" }) |prefix| for ([_]u32{ 4, 8, 16 }) |l| {
            try g.print("#define {0s}{2d} lcgf_ui_{1s}_{0s}{2d}\n", .{ prefix, name, l });
        };
        try g.print(
            \\#if LCGF_LANES == 4
            \\#include "lcgf_ct_l4.c"
            \\#elif LCGF_LANES == 8
            \\#include "lcgf_ct_l8.c"
            \\#else
            \\#include "lcgf_ct_l16.c"
            \\#endif
            \\#pragma clang attribute pop
            \\#define LCGF_UI_CAT_(a, b) a##b
            \\#define LCGF_UI_CAT(a, b) LCGF_UI_CAT_(a, b)
            \\#define LCGF_UI_FRAME(buf, bytes, state, width, height, out) \
            \\    LCGF_UI_CAT(lcgf_ui_{0s}_lcgf_ct_frame_words_u32_f32_l, LCGF_LANES)(words, sizeof words / 4, cols, buf, bytes, state, width, height, out)
            \\#else
            \\// Not clang: liblcgf's frame, over the words lcgf_ct_init was given.
            \\#include <lcgf.h>
            \\#define LCGF_UI_FRAME(buf, bytes, state, width, height, out) ((void)(bytes), LCGF_CT_FRAME(buf, state, width, height, out))
            \\#endif
            \\
            \\/// One frame of the UI in `buf` (lcgf_ct_init'd with these words, `bytes` long).
            \\void lcgf_ui_{0s}_frame(void *buf, size_t bytes, const void *state, float width, float height, void *out) {{
            \\    LCGF_UI_FRAME(buf, bytes, state, width, height, out);
            \\}}
            \\
            \\/// These words, for lcgf_ct_init.
            \\const uint32_t *lcgf_ui_{0s}_words(size_t *len) {{
            \\    *len = sizeof words / 4;
            \\    return words;
            \\}}
            \\
        , .{name});
    }

    fn cpp(g: *const StaticGen) !void {
        const name = g.x.spec.name;
        try g.print(
            \\// Generated by lcgf-gen --static from {s}. Do not edit: change the spec and run lcgf-gen again.
            \\// A static UI: liblcgf's static-UI frame (src/abi/ct.zig, the comptime pipeline's frame over the
            \\// tables lcgf-gen made of the spec), specialized to this UI by its own frame, which lcgf_add_ui
            \\// builds from lcgf-gen --static --lang zig (or --lang c without Zig).
            \\#pragma once
            \\#include <cstddef>
            \\#include <cstdint>
            \\#include <lcgf/lcgf.hpp>
            \\
            \\extern "C" void lcgf_ui_{s}_frame(void *buf, std::size_t bytes, const void *state, float width, float height, lcgf_draw *out);
            \\extern "C" const std::uint32_t *lcgf_ui_{s}_words(std::size_t *len);
            \\
            \\namespace {s} {{
            \\
            \\
        , .{ g.source, name, name, name });
        try stateCpp(g.arena, g.out, g.x.spec.state, g.x.fields, g.x.state_size, g.x.state_align);
        try g.print("\n/// The widgets, valued by their rows: what `at`, `pointer` and `focus` report.\nenum class Widget : std::uint32_t {{", .{});
        for (g.x.widgets, 0..) |w, k| try g.print("{s} {s} = {d}", .{ if (k == 0) "" else ",", w.name, w.row });
        try g.print(" }};\n/// The state's fields, for `relayout` and `patch`.\nenum class Field : std::uint32_t {{", .{});
        for (g.x.fields, 0..) |f, k| try g.print("{s} {s} = {d}", .{ if (k == 0) "" else ",", f.name, k });
        try g.print(
            \\ }};
            \\/// Bytes the UI keeps, for any lane count.
            \\inline constexpr std::size_t bytes = {d};
            \\
            \\/// The UI: its state and its frame's memory, a value of its own.
            \\class Ui : public lcgf::StaticUi<State, Widget, Field, bytes, lcgf_ui_{s}_frame, lcgf_ui_{s}_words> {{
            \\public:
            \\    explicit Ui(State s = {{}}) : StaticUi(s) {{}}
            \\
        , .{ g.bytes, name, name });
        for (g.x.fields) |f| {
            const ty = fieldType(f.type);
            try g.print("    void set_{s}({s} v) {{ state.{s} = v; }}\n    {s} {s}() const {{ return state.{s}; }}\n", .{ f.name, ty, f.name, ty, f.name, f.name });
        }
        try g.print("}};\n\n}} // namespace {s}\n", .{name});
    }

    fn rust(g: *const StaticGen) !void {
        const name = g.x.spec.name;
        try g.print(
            \\// Generated by lcgf-gen --static from {s}. Do not edit: change the spec and run lcgf-gen again.
            \\// A static UI: liblcgf's static-UI frame (src/abi/ct.zig, the comptime pipeline's frame over the
            \\// tables lcgf-gen made of the spec), specialized to this UI by its own frame, which the crate's
            \\// build script builds with `lcgf_build::static_ui` (lcgf-gen --static --lang zig, or c).
            \\
            \\
        , .{g.source});
        try stateRust(g.arena, g.out, g.x.spec.state, g.x.fields, g.x.state_size, g.x.state_align);
        try g.print("\n", .{});
        try g.widgetsRust();
        try g.print("/// The state's fields, for `relayout` and `patch`.\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\n#[repr(u32)]\npub enum Field {{\n", .{});
        for (g.x.fields, 0..) |f, k| try g.print("    {s} = {d},\n", .{ camel(g.arena, f.name), k });
        try g.print("}}\n\n/// The tables (`ct.make`), for liblcgf's frame.\npub static WORDS: ::lcgf::StaticTables<{d}> = ::lcgf::StaticTables([", .{g.words.len});
        try g.words_();
        try g.print(
            \\
            \\]);
            \\/// Bytes the UI needs in your buffer, for any lane count.
            \\pub const BYTES: usize = {0d};
            \\
            \\unsafe extern "C" {{
            \\    fn lcgf_ui_{1s}_frame(buf: *mut u8, bytes: usize, state: *const u8, width: f32, height: f32, out: *mut ::core::ffi::c_void);
            \\}}
            \\
            \\/// This UI's types and tables, for `lcgf::StaticUi`.
            \\pub struct Spec;
            \\
            \\impl ::lcgf::StaticSpec for Spec {{
            \\    type State = State;
            \\    type Widget = Widget;
            \\    type Event = Event;
            \\    type Field = Field;
            \\    const WORDS: &'static [u32] = &WORDS.0;
            \\    const FRAME: ::lcgf::StaticFrame = lcgf_ui_{1s}_frame;
            \\    fn field(f: Field) -> u32 {{
            \\        f as u32
            \\    }}
            \\    #[allow(unreachable_code)]
            \\    fn widget_row(w: Widget) -> u32 {{
            \\        w.row()
            \\    }}
            \\    fn widget(row: u32) -> Widget {{
            \\        match row {{
            \\
        , .{ g.bytes, name });
        for (g.x.widgets) |w| try g.print("            {d} => Widget::{s},\n", .{ w.row, camel(g.arena, w.name) });
        try g.print("            _ => unreachable!(),\n        }}\n    }}\n    fn event(row: u32, _value: f32) -> Event {{\n        match row {{\n", .{});
        for (g.x.widgets) |w| try g.print("            {d} => Event::{s}{s},\n", .{ w.row, camel(g.arena, w.name), if (w.slider) "(_value)" else "" });
        try g.print(
            \\            _ => unreachable!(),
            \\        }}
            \\    }}
            \\}}
            \\
            \\/// The UI, in your buffer: `Ui::new(buffer.bytes(), State::default())` with a `Buffer<BYTES>`.
            \\pub type Ui<'a> = ::lcgf::StaticUi<'a, Spec>;
            \\
        , .{});
    }
};

/// `v` as a float literal C++ and Rust both read exactly: the shortest round-trip digits, with a
/// decimal point.
/// `v` as a C float constant, exactly: a hex float, or the builtins for infinities and NaN.
fn cFloat(arena: std.mem.Allocator, v: f32) ![]const u8 {
    if (std.math.isNan(v)) return std.fmt.allocPrint(arena, "__builtin_nanf(\"0x{x}\")", .{@as(u32, @bitCast(v)) & 0x7fffff});
    if (std.math.isInf(v)) return if (v > 0) "__builtin_inff()" else "-__builtin_inff()";
    return std.fmt.allocPrint(arena, "{x}f", .{v});
}

fn floatLit(arena: std.mem.Allocator, v: f32) []const u8 {
    const s = std.fmt.allocPrint(arena, "{d}", .{v}) catch @panic("OOM");
    if (std.mem.indexOfAny(u8, s, ".e") != null) return s;
    return std.fmt.allocPrint(arena, "{s}.0", .{s}) catch @panic("OOM");
}

fn rustType(t: plan.FieldType) []const u8 {
    return switch (t) {
        .str => "::lcgf::Str",
        .bool => "bool",
        .f32 => "f32",
        .u32 => "u32",
        .u8 => "u8",
        .color => "u32",
        .other => unreachable, // only Zig state has those, never a .zon spec
    };
}

fn camel(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var up = true;
    for (s) |ch| {
        if (ch == '_') {
            up = true;
            continue;
        }
        out.append(arena, if (up) std.ascii.toUpper(ch) else ch) catch @panic("OOM");
        up = false;
    }
    return out.items;
}

// ---- WGSL: a shader's code and its bind groups ------------------------------------------------

/// One entry point's GLSL ES, with LCGF's bindings written in.
const Glsl = struct { entry: []const u8, code: [:0]const u8 };

const Shader = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    m: reflect.Module,
    wgsl: []const u8,
    /// Empty when no SPIR-V was given: the Vulkan back end then refuses the shader.
    spirv: []const u32,
    /// Empty when no GLSL was given: the GL ES back end then refuses the shader.
    glsl: []const Glsl,
    slots: []const naga.Slot,
    /// naga's MSL with its slots, or null when none was given: the Metal back end then refuses
    /// the shader.
    msl: ?[]const u8,
    /// Metal's slots: buffers together, textures with storage textures.
    msl_slots: []const naga.Slot,
    /// naga's HLSL with its samplers registered, or null: the D3D12 back end then refuses the
    /// shader. Its root signature comes from the groups.
    hlsl: ?[]const u8,
    source: []const u8,

    fn print(sh: *const Shader, comptime fmt: []const u8, args: anytype) !void {
        try sh.out.print(sh.arena, fmt, args);
    }

    fn groupCount(sh: *const Shader) u32 {
        var n: u32 = 0;
        for (sh.m.bindings) |b| n = @max(n, b.group + 1);
        return n;
    }

    fn group(sh: *const Shader, g: u32) []reflect.Binding {
        const out = sh.arena.alloc(reflect.Binding, sh.m.bindings.len) catch @panic("OOM");
        return reflect.groupInto(sh.m, g, out);
    }

    fn words(sh: *const Shader) !void {
        for (sh.spirv, 0..) |w, i| {
            if (i % 8 == 0) try sh.print("\n       ", .{});
            try sh.print(" 0x{x:0>8},", .{w});
        }
    }

    /// `text` as a string literal both languages read: one escaped line per source line.
    /// Separated by `sep` (C++ joins adjacent literals; Rust's `concat!` takes commas).
    fn literal(sh: *const Shader, text: []const u8, nul: bool, sep: []const u8, indent: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try sh.print("{s}\n{s}", .{ sep, indent });
            first = false;
            try sh.print("\"", .{});
            for (line) |ch| switch (ch) {
                '\\' => try sh.print("\\\\", .{}),
                '"' => try sh.print("\\\"", .{}),
                '\t' => try sh.print("\\t", .{}),
                '\r' => {},
                else => try sh.out.append(sh.arena, ch),
            };
            if (lines.peek() != null) try sh.print("\\n", .{});
            if (nul and lines.peek() == null) try sh.print("\\0", .{});
            try sh.print("\"", .{});
        }
    }

    /// The GL ES binding of `b` in its group: unit, the sampler bound on a texture's unit (the
    /// group's only sampler, else the k-th sampler for the k-th texture), image format and access.
    const GlesBinding = struct { unit: u32, sampler: u32, format: u32, access: u32 };

    fn gles(sh: *const Shader, bs: []const reflect.Binding, i: usize) GlesBinding {
        const b = bs[i];
        var r: GlesBinding = .{ .unit = naga.slotIn(sh.slots, b.group, b.binding).?, .sampler = std.math.maxInt(u32), .format = 0, .access = 0 };
        if (b.kind == .texture) {
            var samplers: u32 = 0;
            for (bs) |x| samplers += @intFromBool(x.kind == .sampler or x.kind == .comparison_sampler);
            var k: u32 = 0;
            for (bs[0..i]) |x| k += @intFromBool(x.kind == .texture);
            var n: u32 = 0;
            for (bs, 0..) |x, j| if (x.kind == .sampler or x.kind == .comparison_sampler) {
                if (samplers == 1 or n == k) r.sampler = @intCast(j);
                n += 1;
            };
        }
        if (b.kind == .storage_texture) {
            const table = [_]struct { []const u8, u32 }{
                .{ "rgba8unorm", 0x8058 }, .{ "rgba16float", 0x881A }, .{ "rgba32float", 0x8814 },
                .{ "r32float", 0x822E },   .{ "r32uint", 0x8236 },     .{ "r32sint", 0x8235 },
                .{ "rgba32uint", 0x8D70 }, .{ "rgba8snorm", 0x8F97 },
            };
            for (table) |row| if (std.mem.eql(u8, row[0], b.storage_format)) {
                r.format = row[1];
            };
            r.access = switch (b.access) {
                .read => 0x88B8,
                .write => 0x88B9,
                .read_write => 0x88BA,
            };
        }
        return r;
    }

    /// A binding's Metal slot and, for a runtime-sized array, its index in `_buffer_sizes`.
    fn metal(sh: *const Shader, b: reflect.Binding) struct { slot: u32, sized: u32 } {
        return .{ .slot = naga.slotIn(sh.msl_slots, b.group, b.binding).?, .sized = naga.mslSizedIndex(sh.m, b.group, b.binding) orelse std.math.maxInt(u32) };
    }

    fn metalSized(sh: *const Shader) u32 {
        var n: u32 = 0;
        for (sh.m.bindings) |b| n += @intFromBool(b.runtime_sized);
        return n;
    }

    fn workgroup(sh: *const Shader) [3]u32 {
        for (sh.m.entry_points) |e| if (e.stage == .compute) return e.workgroup_size;
        return .{ 1, 1, 1 };
    }

    const Name = struct { name: []const u8, slot: u32 };

    /// The names bound after linking: uniform blocks to their binding points, sampler uniforms
    /// to their units (naga names a resource `_group_G_binding_B_<stage>`).
    fn names(sh: *const Shader, blocks: bool) ![]const Name {
        var out: std.ArrayList(Name) = .empty;
        for (sh.slots) |u| {
            const b = for (sh.m.bindings) |x| {
                if (x.group == u.group and x.binding == u.binding) break x;
            } else unreachable;
            if (b.kind != (if (blocks) reflect.Kind.uniform else reflect.Kind.texture)) continue;
            for ([_][]const u8{ "vs", "fs", "cs" }) |stage| {
                const name = try std.fmt.allocPrint(sh.arena, "_group_{d}_binding_{d}_{s}", .{ u.group, u.binding, stage });
                for (sh.glsl) |g| {
                    if (blocks) {
                        var found: std.ArrayList([]const u8) = .empty;
                        try naga.glslBlocksInto(sh.arena, g.code, name, &found);
                        for (found.items) |block| try out.append(sh.arena, .{ .name = block, .slot = u.slot });
                    } else if (std.mem.indexOf(u8, g.code, name) != null) {
                        try out.append(sh.arena, .{ .name = name, .slot = u.slot });
                        break;
                    }
                }
            }
        }
        return out.items;
    }

    fn cpp(sh: *const Shader) !void {
        try sh.print(
            \\// Generated by lcgf-gen from {s}. Do not edit: change the shader and run lcgf-gen again.
            \\// The bind groups are what lcgf_render.gpu reflects from the WGSL; the code is the WGSL
            \\// (wgpu) and what naga made of it for the other back ends.
            \\#pragma once
            \\#include <array>
            \\#include <cstdint>
            \\#include <span>
            \\#include <string_view>
            \\#include <lcgf/gpu.hpp>
            \\
            \\namespace {s} {{
            \\
            \\struct Shader;
            \\
        , .{ sh.source, sh.name });
        const n = sh.groupCount();
        for (0..n) |g_| {
            const g: u32 = @intCast(g_);
            const bs = sh.group(g);
            if (bs.len == 0) continue;
            try sh.print("\n/// @group({d}): one member per binding, named as in the WGSL.\nstruct Group{d} {{\n    using Shader = {s}::Shader;\n    static constexpr std::uint32_t index = {d};\n", .{ g, g, sh.name, g });
            for (bs) |b| try sh.print("    lcgf::gpu::{s} {s}; // @binding({d})\n", .{ cppType(b.kind), b.name, b.binding });
            try sh.print("    std::array<lcgf::gpu::Resource, {d}> Resources() const {{\n        return {{", .{bs.len});
            for (bs, 0..) |b, i| try sh.print("{s}lcgf::gpu::{s}Resource({d}, lcgf::gpu::BindingKind::{s}, {s})", .{ if (i == 0) "" else ", ", resourceFn(b.kind), b.binding, kindName(sh.arena, b.kind), b.name });
            try sh.print("}};\n    }}\n}};\n", .{});
        }
        try sh.print("\n/// The shader: its bind group layouts and its code for each back end it was built for.\nstruct Shader {{\n    static constexpr std::string_view wgsl =\n        ", .{});
        try sh.literal(sh.wgsl, false, "", "        ");
        try sh.print(";\n", .{});
        for (0..n) |g_| {
            const bs = sh.group(@intCast(g_));
            if (bs.len == 0) continue;
            try sh.print("    static constexpr lcgf::gpu::BindingLayout group{d}[] = {{", .{g_});
            for (bs) |b| try sh.print(" {{{d}, lcgf::gpu::BindingKind::{s}}},", .{ b.binding, kindName(sh.arena, b.kind) });
            try sh.print(" }};\n    static constexpr lcgf::gpu::GlesBinding gles_group{d}[] = {{", .{g_});
            for (bs, 0..) |b, i| {
                const r = sh.gles(bs, i);
                try sh.print(" {{lcgf::gpu::BindingKind::{s}, {d}, 0x{x}, 0x{x}, 0x{x}}},", .{ kindName(sh.arena, b.kind), r.unit, r.sampler, r.format, r.access });
            }
            try sh.print(" }};\n", .{});
        }
        try sh.print("    static constexpr std::span<const lcgf::gpu::BindingLayout> groups[] = {{", .{});
        for (0..n) |g_| if (sh.group(@intCast(g_)).len == 0) try sh.print(" {{}},", .{}) else try sh.print(" group{d},", .{g_});
        try sh.print(" }};\n    static constexpr std::span<const lcgf::gpu::GlesBinding> gles_groups[] = {{", .{});
        for (0..n) |g_| if (sh.group(@intCast(g_)).len == 0) try sh.print(" {{}},", .{}) else try sh.print(" gles_group{d},", .{g_});
        try sh.print(" }};\n", .{});
        if (sh.spirv.len > 0) {
            try sh.print("    static constexpr std::uint32_t spirv[] = {{", .{});
            try sh.words();
            try sh.print("\n    }};\n    static constexpr lcgf::gpu::ShaderInfo info{{spirv, groups}};\n", .{});
        }
        if (sh.glsl.len > 0) {
            try sh.print("    static constexpr lcgf::gpu::GlslStage glsl[] = {{\n", .{});
            for (sh.glsl) |g| {
                try sh.print("        {{\"{s}\",\n         ", .{g.entry});
                try sh.literal(g.code, false, "", "         ");
                try sh.print("}},\n", .{});
            }
            try sh.print("    }};\n", .{});
            for ([_]bool{ true, false }) |blocks| {
                const list = try sh.names(blocks);
                const what = if (blocks) "blocks" else "textures";
                if (list.len == 0) {
                    try sh.print("    static constexpr std::span<const lcgf::gpu::GlslName> gles_{s}{{}};\n", .{what});
                    continue;
                }
                try sh.print("    static constexpr lcgf::gpu::GlslName gles_{s}[] = {{", .{what});
                for (list) |x| try sh.print(" {{\"{s}\", {d}}},", .{ x.name, x.slot });
                try sh.print(" }};\n", .{});
            }
            try sh.print("    static constexpr lcgf::gpu::GlesTable gles{{gles_groups, gles_blocks, gles_textures}};\n", .{});
        }
        if (sh.hlsl) |code| {
            try sh.print("    static constexpr std::string_view hlsl =\n        ", .{});
            try sh.literal(code, false, "", "        ");
            try sh.print(";\n", .{});
        }
        if (sh.msl) |code| {
            try sh.print("    static constexpr std::string_view msl =\n        ", .{});
            try sh.literal(code, false, "", "        ");
            try sh.print(";\n", .{});
            for (0..n) |g_| {
                const bs = sh.group(@intCast(g_));
                if (bs.len == 0) continue;
                try sh.print("    static constexpr lcgf::gpu::MetalBinding metal_group{d}[] = {{", .{g_});
                for (bs) |b| {
                    const r = sh.metal(b);
                    try sh.print(" {{lcgf::gpu::BindingKind::{s}, {d}, 0x{x}}},", .{ kindName(sh.arena, b.kind), r.slot, r.sized });
                }
                try sh.print(" }};\n", .{});
            }
            try sh.print("    static constexpr std::span<const lcgf::gpu::MetalBinding> metal_groups[] = {{", .{});
            for (0..n) |g_| if (sh.group(@intCast(g_)).len == 0) try sh.print(" {{}},", .{}) else try sh.print(" metal_group{d},", .{g_});
            const w = sh.workgroup();
            try sh.print(" }};\n    static constexpr lcgf::gpu::MetalTable metal{{metal_groups, {d}, {d}, {{{d}, {d}, {d}}}}};\n", .{ sh.metalSized(), naga.mslSizesSlotIn(sh.m), w[0], w[1], w[2] });
        }
        for (sh.m.entry_points) |e| if (e.stage == .compute) {
            try sh.print("    static constexpr std::uint32_t workgroup_size[3] = {{{d}, {d}, {d}}};\n", .{ e.workgroup_size[0], e.workgroup_size[1], e.workgroup_size[2] });
            break;
        };
        try sh.print("}};\n\n}} // namespace {s}\n", .{sh.name});
    }

    fn rust(sh: *const Shader) !void {
        try sh.print(
            \\// Generated by lcgf-gen from {s}. Do not edit: change the shader and run lcgf-gen again.
            \\// The bind groups are what lcgf_render.gpu reflects from the WGSL; the code is the WGSL
            \\// (wgpu) and what naga made of it for the other back ends.
            \\
            \\/// The shader: its bind group layouts and its code for each back end it was built for.
            \\pub struct Shader;
            \\
            \\impl ::lcgf::gpu::ShaderSource for Shader {{
            \\    const WGSL: &'static str = concat!(
        , .{sh.source});
        try sh.print("\n        ", .{});
        try sh.literal(sh.wgsl, false, ",", "        ");
        try sh.print(",\n    ", .{});
        try sh.print(");\n    const GROUPS: &'static [&'static [::lcgf::gpu::BindingLayout]] = &[", .{});
        const n = sh.groupCount();
        for (0..n) |g_| {
            try sh.print("\n        &[", .{});
            for (sh.group(@intCast(g_))) |b| try sh.print("::lcgf::gpu::BindingLayout {{ binding: {d}, kind: ::lcgf::gpu::BindingKind::{s} }}, ", .{ b.binding, kindName(sh.arena, b.kind) });
            try sh.print("],", .{});
        }
        try sh.print("\n    ];\n", .{});
        if (sh.spirv.len > 0) {
            try sh.print("    const SPIRV: &'static [u32] = &[", .{});
            try sh.words();
            try sh.print("\n    ];\n", .{});
        }
        if (sh.glsl.len > 0) {
            try sh.print("    const GLSL: &'static [::lcgf::gpu::GlslStage] = &[\n", .{});
            for (sh.glsl) |g| {
                try sh.print("        ::lcgf::gpu::GlslStage {{ entry_point: \"{s}\", code: concat!(\n            ", .{g.entry});
                try sh.literal(g.code, true, ",", "            ");
                try sh.print(",\n        ", .{});
                try sh.print(") }},\n", .{});
            }
            try sh.print("    ];\n    const GLES: ::lcgf::gpu::GlesTable = ::lcgf::gpu::GlesTable {{\n        groups: &[", .{});
            for (0..n) |g_| {
                const bs = sh.group(@intCast(g_));
                try sh.print("\n            &[", .{});
                for (bs, 0..) |b, i| {
                    const r = sh.gles(bs, i);
                    try sh.print("::lcgf::gpu::GlesBinding {{ kind: ::lcgf::gpu::BindingKind::{s}, unit: {d}, sampler: 0x{x}, format: 0x{x}, access: 0x{x} }}, ", .{ kindName(sh.arena, b.kind), r.unit, r.sampler, r.format, r.access });
                }
                try sh.print("],", .{});
            }
            try sh.print("\n        ],\n", .{});
            for ([_]bool{ true, false }) |blocks| {
                try sh.print("        {s}: &[", .{if (blocks) "blocks" else "textures"});
                for (try sh.names(blocks)) |x| try sh.print("::lcgf::gpu::GlslName {{ name: \"{s}\\0\", slot: {d} }}, ", .{ x.name, x.slot });
                try sh.print("],\n", .{});
            }
            try sh.print("    }};\n", .{});
        }
        if (sh.hlsl) |code| {
            try sh.print("    const HLSL: &'static str = concat!(\n        ", .{});
            try sh.literal(code, true, ",", "        ");
            try sh.print(",\n    );\n", .{});
        }
        if (sh.msl) |code| {
            try sh.print("    const MSL: &'static str = concat!(\n        ", .{});
            try sh.literal(code, true, ",", "        ");
            try sh.print(",\n    );\n    const METAL: ::lcgf::gpu::MetalTable = ::lcgf::gpu::MetalTable {{\n        groups: &[", .{});
            for (0..n) |g_| {
                try sh.print("\n            &[", .{});
                for (sh.group(@intCast(g_))) |b| {
                    const r = sh.metal(b);
                    try sh.print("::lcgf::gpu::MetalBinding {{ kind: ::lcgf::gpu::BindingKind::{s}, slot: {d}, sized: 0x{x} }}, ", .{ kindName(sh.arena, b.kind), r.slot, r.sized });
                }
                try sh.print("],", .{});
            }
            const w = sh.workgroup();
            try sh.print("\n        ],\n        sized: {d},\n        sizes_slot: {d},\n        workgroup: [{d}, {d}, {d}],\n    }};\n", .{ sh.metalSized(), naga.mslSizesSlotIn(sh.m), w[0], w[1], w[2] });
        }
        try sh.print("}}\n", .{});
        for (sh.m.entry_points) |e| if (e.stage == .compute) {
            try sh.print("\npub const WORKGROUP_SIZE: [u32; 3] = [{d}, {d}, {d}];\n", .{ e.workgroup_size[0], e.workgroup_size[1], e.workgroup_size[2] });
            break;
        };
        for (0..n) |g_| {
            const g: u32 = @intCast(g_);
            const bs = sh.group(g);
            if (bs.len == 0) continue;
            try sh.print("\n/// @group({d}): one field per binding, named as in the WGSL.\npub struct Group{d}<'a> {{\n", .{ g, g });
            for (bs) |b| try sh.print("    pub {s}: &'a ::lcgf::gpu::{s}, // @binding({d})\n", .{ b.name, cppType(b.kind), b.binding });
            try sh.print("}}\n\nimpl ::lcgf::gpu::Group for Group{d}<'_> {{\n    type Shader = Shader;\n    type BindGroup = ::lcgf::gpu::BindGroup<{d}>;\n    const INDEX: u32 = {d};\n    fn resources(&self, out: &mut [::lcgf::gpu::Resource; 16]) -> usize {{\n", .{ g, g, g });
            for (bs, 0..) |b, i| try sh.print("        out[{d}] = ::lcgf::gpu::Resource::{s}({d}, ::lcgf::gpu::BindingKind::{s}, self.{s});\n", .{ i, rustResourceFn(b.kind), b.binding, kindName(sh.arena, b.kind), b.name });
            try sh.print("        {d}\n    }}\n}}\n", .{bs.len});
        }
    }
};

fn cppType(k: reflect.Kind) []const u8 {
    return switch (k) {
        .uniform, .storage_read, .storage_read_write => "Buffer",
        .texture, .storage_texture => "TextureView",
        .sampler, .comparison_sampler => "Sampler",
    };
}

fn resourceFn(k: reflect.Kind) []const u8 {
    return switch (k) {
        .uniform, .storage_read, .storage_read_write => "Buffer",
        .texture, .storage_texture => "View",
        .sampler, .comparison_sampler => "Sampler",
    };
}

fn rustResourceFn(k: reflect.Kind) []const u8 {
    return switch (k) {
        .uniform, .storage_read, .storage_read_write => "buffer",
        .texture, .storage_texture => "view",
        .sampler, .comparison_sampler => "sampler",
    };
}

fn kindName(arena: std.mem.Allocator, k: reflect.Kind) []const u8 {
    return camel(arena, @tagName(k));
}
