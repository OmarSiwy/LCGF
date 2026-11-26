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
//!   lcgf-gen <spec.zon> --static --lang cpp|rust|c|words -o <out>
//!
//! A shader: its bind groups reflected from the WGSL by the same reader `lcgf_render.gpu` uses
//! at comptime (src/render/gpu/reflect.zig, `parseInto`), with the code of each back end it is
//! given embedded: the WGSL itself (wgpu), naga's SPIR-V (Vulkan), naga's GLSL ES of each entry
//! point with LCGF's binding table (GL ES; the bindings are written in as src/render/gpu/naga.zig
//! does at comptime). lcgf-gen runs no other program: the caller runs naga.
//!
//!   lcgf-gen --wgsl <s.wgsl> --name tinted --lang cpp|rust [--spirv <s.spv>] [--glsl <entry>=<file>]... [--msl <s.metal>] [--hlsl <s.hlsl>] -o <out>
//!   lcgf-gen --wgsl <s.wgsl> --entry-points    (one line per entry point: name, naga stage, GLSL profile, file extension)
//!
//! An HTML page and its CSS: a generated UI module (markup/main.zig, docs/guide/markup.md).
//!
//!   lcgf-gen <page.html> [--css <extra.css>]... --lang zig -o <page_ui.zig> [--depfile <d>]
//!   lcgf-gen --mappings    (the HTML/CSS mapping manifest as TSV)
//!

const std = @import("std");
const lcgf = @import("lcgf");
const plan = lcgf.abi_plan;
const zon = lcgf.abi_zon;
const reflect = lcgf.gpu_reflect;
const seam = lcgf.abi_seam;
const ct = lcgf.abi_ct;
const naga = lcgf.gpu_naga;
const markup = @import("markup/main.zig");

const Lang = enum { cpp, rust, c, words, zon };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    {
        // An HTML page goes to the markup compiler (markup/main.zig).
        var all = try init.minimal.args.iterateAllocator(arena);
        _ = all.next();
        var list: std.ArrayList([]const u8) = .empty;
        while (all.next()) |a| try list.append(arena, a);
        if (markup.wants(list.items)) std.process.exit(try markup.main(io, arena, list.items));
    }
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
        const src = try arena.dupeSentinel(u8, bytes, 0);
        const x = zon.readStatic(init.gpa, arena, src, path) catch |e| switch (e) {
            error.ParseZon, error.UnknownField, error.FieldWithoutType, error.NotStatic, error.BadField => std.process.exit(1),
            else => return e,
        };
        const words = zon.staticTables(arena, &x) catch |e| {
            std.log.err("{s}: {s}", .{ path, @errorName(e) });
            std.process.exit(1);
        };
        const g: StaticGen = .{ .arena = arena, .out = &out, .x = &x, .words = words, .bytes = ct.Ui.bytes(words) catch unreachable, .source = path };
        switch (lang) {
            .cpp => try g.cpp(),
            .rust => try g.rust(),
            .c => try g.cSource(),
            .words => try out.appendSlice(arena, std.mem.sliceAsBytes(words)),
            .zon => try out.appendSlice(arena, bytes),
        }
    } else {
        const path = input orelse return usage();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const src = try arena.dupeSentinel(u8, bytes, 0);
        const x = zon.read(init.gpa, arena, src, path) catch |e| switch (e) {
            error.ParseZon, error.UnknownField, error.FieldWithoutType => std.process.exit(1),
            else => return e,
        };
        const words = zon.tables(arena, &x) catch |e| {
            std.log.err("{s}: {s}", .{ path, @errorName(e) });
            std.process.exit(1);
        };
        const ui_bytes = seam.Ui.bytes(words) catch unreachable;
        const g: Gen = .{ .arena = arena, .out = &out, .x = &x, .words = words, .bytes = ui_bytes, .source = path };
        switch (lang) {
            .cpp => try g.cpp(),
            .rust => try g.rust(),
            .c => return usage(),
            .words => try out.appendSlice(arena, std.mem.sliceAsBytes(words)),
            .zon => try out.appendSlice(arena, bytes),
        }
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

/// One tree of a static UI's words, as the passes compiled in C++ and Rust read it: the
/// columns they use, `n` rows each (floats as bits), `border` resolved from the extras, and
/// the regions with their choice windows in one list.
const NativeBlock = struct {
    n: u32,
    u32s: [names.len][2][]const u32,
    clips: []const u8,
    border: []const u32,
    label_rows: []const u32,
    regions: []const [8]u32,
    alts: []const [2]u32,

    /// The u32 / f32 columns emitted, by their C++ and Rust names; `true`: per axis.
    const names = [_][]const u8{ "parent", "min", "max", "grow", "pct", "pad_lo", "pad_hi", "offset", "scroll", "main", "gap", "gap_total", "flow", "shrink", "align_main", "align_cross" };
    const axes = [_]bool{ false, true, true, true, true, true, true, true, true, true, false, false, false, false, false, false };

    fn column(words: []const u32, b: *const ct.Block, field: []const u8, axis: u32) ?u32 {
        const offs = words[b.cols..][0..ct.column_arrays.len];
        for (ct.column_arrays, 0..) |c, k| if (std.mem.eql(u8, c.field, field) and c.axis == axis) {
            return if (offs[k] == ct.none) null else offs[k];
        };
        unreachable;
    }

    fn decode(arena: std.mem.Allocator, words: []const u32, h: *const ct.Header, b: *const ct.Block) !NativeBlock {
        const n = b.n;
        var out: NativeBlock = .{ .n = n, .u32s = undefined, .clips = &.{}, .border = &.{}, .label_rows = words[b.label_rows..][0..h.labels], .regions = &.{}, .alts = &.{} };
        const zeros = try arena.alloc(u32, n);
        @memset(zeros, 0);
        for (names, axes, 0..) |name, per_axis, k| for (0..2) |a| {
            if (!per_axis and a == 1) {
                out.u32s[k][1] = &.{};
                continue;
            }
            // The masked columns' sources when regions rewrite them; the gap totals are then
            // made each frame from `gap`.
            const src: ?u32 = if (h.regions > 0 and std.mem.eql(u8, name, "max"))
                b.max_src[a]
            else if (h.regions > 0 and std.mem.eql(u8, name, "flow"))
                b.flow_src
            else if (h.has_windows != 0 and std.mem.eql(u8, name, "scroll"))
                b.scroll_src[a]
            else
                column(words, b, name, @intCast(a));
            out.u32s[k][a] = if (src) |o| words[o..][0..n] else zeros;
        };
        out.clips = std.mem.sliceAsBytes(words[column(words, b, "clips", 0).?..])[0..n];
        // `x.row[extra[i]].border`, row by row.
        const extra = words[column(words, b, "extra", 0).?..][0..n];
        const xw = @sizeOf(lcgf.tree.Extra) / 4;
        const bw = @offsetOf(lcgf.tree.Extra, "border") / 4;
        const border = try arena.alloc(u32, n);
        for (border, extra) |*o, e| o.* = words[b.extras + e * xw + bw];
        out.border = border;
        var regions: std.ArrayList([8]u32) = .empty;
        var alts: std.ArrayList([2]u32) = .empty;
        const rs = std.mem.bytesAsSlice(ct.Region, std.mem.sliceAsBytes(words[b.regions..][0 .. h.regions * @sizeOf(ct.Region) / 4]));
        for (rs) |r| {
            const first: u32 = @intCast(alts.items.len);
            if (r.kind == @backingInt(ct.RegionKind.choice)) {
                for (0..r.max + 1) |k| try alts.append(arena, .{ words[r.alts + 2 * k], words[r.alts + 2 * k + 1] });
            }
            try regions.append(arena, .{ r.kind, r.row, r.end, r.stride, r.max, first, @intFromBool(r.scroll_offset != ct.none), @bitCast(r.height) });
        }
        if (alts.items.len == 0) try alts.append(arena, .{ 0, 0 });
        out.regions = regions.items;
        out.alts = alts.items;
        return out;
    }
};

/// A static UI's generated code: the state, the tables as compile-time constants for the
/// passes compiled in the program's language (`lcgf::ct`), and the words (`ct.make`) for
/// liblcgf's frame behind the seam.
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

    /// `n` words as a list: `{ 0x.., .. }` (C++) or `[0x.., ..]` (Rust).
    fn list(g: *const StaticGen, ws: []const u32, in_rust: bool) !void {
        try g.print("{s}", .{if (in_rust) "[" else "{"});
        for (ws, 0..) |w, i| try g.print("{s}0x{x}", .{ if (i == 0) "" else ", ", w });
        if (!in_rust and ws.len == 0) try g.print("0", .{});
        try g.print("{s}", .{if (in_rust) "]" else "}"});
    }

    fn sel(ws: []const u32, k: usize) []const u32 {
        return ws[k..][0..1];
    }

    /// The body of `texts`: each label in label order written to the sink `o` (its string
    /// field, or its format as straight-line calls: the format is read here, not at run
    /// time), then its end in the strings, `end[k]`.
    fn texts(g: *const StaticGen, comptime in_rust: bool) !void {
        const s = if (in_rust) "_s" else "s";
        var k: usize = 0;
        for (g.x.nodes) |nd| {
            if (!nd.isLabel()) continue;
            if (nd.format) |f| {
                for (f.segs) |sg| {
                    if (sg.kind == .literal) {
                        try g.print(if (in_rust) " o.put(b\"" else " o.put(\"", .{});
                        for (f.text[sg.start..][0..sg.len]) |c| {
                            if (c == '"' or c == '\\') try g.print("\\{c}", .{c}) else if (c >= 0x20 and c < 0x7f) try g.print("{c}", .{c}) else if (in_rust) try g.print("\\x{x:0>2}", .{c}) else try g.print("\\{o:0>3}", .{c});
                        }
                        if (in_rust) try g.print("\");", .{}) else try g.print("\", {d});", .{sg.len});
                        continue;
                    }
                    const name = g.x.fields[f.args[sg.arg]].name;
                    switch (sg.kind) {
                        .str => try g.print(if (in_rust) " o.put_str({s}.{s});" else " o.put({s}.{s});", .{ s, name }),
                        .bool => try g.print(" o.put_bool({s}.{s});", .{ s, name }),
                        .u32, .u8 => try g.print(if (in_rust) " o.put_uint({s}.{s} as u64);" else " o.put_uint({s}.{s});", .{ s, name }),
                        .f32 => try g.print(" o.put_f32({s}.{s}, {d});", .{ s, name, sg.prec }),
                        .literal => unreachable,
                    }
                }
            } else try g.print(if (in_rust) " o.put_str({s}.{s});" else " o.put({s}.{s});", .{ s, g.x.fields[nd.label_field].name });
            try g.print(if (in_rust) " end[{d}] = o.len as u32;" else " end[{d}] = o.len;", .{k});
            k += 1;
        }
    }

    const Selector = struct { field: plan.Field, scroll: ?[]const u8 };
    fn selectors(g: *const StaticGen) []const Selector {
        var out: std.ArrayList(Selector) = .empty;
        for (g.x.nodes) |nd| if (nd.region != .none) out.append(g.arena, .{
            .field = g.x.fields[nd.region_field],
            .scroll = if (nd.scroll_field != ct.none) g.x.fields[nd.scroll_field].name else null,
        }) catch @panic("OOM");
        return out.items;
    }

    fn blockCpp(g: *const StaticGen, name: []const u8, b: *const NativeBlock) !void {
        try g.print("    struct {s} {{\n        static constexpr std::uint32_t n = {d};\n", .{ name, b.n });
        for (NativeBlock.names, NativeBlock.axes, 0..) |col, per_axis, k| {
            if (per_axis) {
                try g.print("        static constexpr std::uint32_t {s}[2][{d}] = {{", .{ col, b.n });
                try g.list(b.u32s[k][0], false);
                try g.print(", ", .{});
                try g.list(b.u32s[k][1], false);
                try g.print("}};\n", .{});
            } else {
                try g.print("        static constexpr std::uint32_t {s}[{d}] = ", .{ col, b.n });
                try g.list(b.u32s[k][0], false);
                try g.print(";\n", .{});
            }
        }
        try g.print("        static constexpr std::uint8_t clips[{d}] = {{", .{b.n});
        for (b.clips, 0..) |c, i| try g.print("{s}{d}", .{ if (i == 0) "" else ", ", c });
        try g.print("}};\n        static constexpr std::uint32_t border[{d}] = ", .{b.n});
        try g.list(b.border, false);
        try g.print(";\n        static constexpr std::uint32_t label_rows[{d}] = ", .{@max(b.label_rows.len, 1)});
        try g.list(b.label_rows, false);
        try g.print(";\n        static constexpr lcgf::ct::Region regions[{d}] = {{", .{@max(b.regions.len, 1)});
        for (b.regions, 0..) |r, i| {
            try g.print("{s}", .{if (i == 0) "" else ", "});
            try g.list(&r, false);
        }
        if (b.regions.len == 0) try g.print("{{}}", .{});
        try g.print("}};\n        static constexpr std::array<std::uint32_t, 2> alts[{d}] = {{", .{b.alts.len});
        for (b.alts, 0..) |w, i| try g.print("{s}{{{{{d}, {d}}}}}", .{ if (i == 0) "" else ", ", w[0], w[1] });
        try g.print("}};\n    }};\n", .{});
    }

    /// `T::<name>[count]` from header word offset `off` (`per` words each, as std::array when > 1).
    fn arrayCpp(g: *const StaticGen, name: []const u8, off: u32, count: u32, per: u32) !void {
        const ws = g.words[off..][0 .. count * per];
        if (per == 1) {
            try g.print("    static constexpr std::uint32_t {s}[{d}] = ", .{ name, @max(count, 1) });
            try g.list(ws, false);
            try g.print(";\n", .{});
            return;
        }
        try g.print("    static constexpr std::array<std::uint32_t, {d}> {s}[{d}] = {{", .{ per, name, @max(count, 1) });
        for (0..count) |k| {
            try g.print("{s}{{", .{if (k == 0) "" else ", "});
            try g.list(ws[k * per ..][0..per], false);
            try g.print("}}", .{});
        }
        if (count == 0) try g.print("{{}}", .{});
        try g.print("}};\n", .{});
    }

    /// The widget tables of ct_events: rows, which are sliders, and the focus order (every
    /// checkbox and slider, in row order).
    fn widgetsCpp(g: *const StaticGen) !void {
        const ws = g.x.widgets;
        try g.print("    static constexpr std::uint32_t widgets = {d}, focusables = {d};\n    static constexpr std::uint32_t widget_rows[{d}] = {{", .{ ws.len, ws.len, @max(ws.len, 1) });
        for (ws, 0..) |w, k| try g.print("{s}{d}", .{ if (k == 0) "" else ", ", w.row });
        if (ws.len == 0) try g.print("0", .{});
        try g.print("}};\n    static constexpr bool widget_slider[{d}] = {{", .{@max(ws.len, 1)});
        for (ws, 0..) |w, k| try g.print("{s}{}", .{ if (k == 0) "" else ", ", w.slider });
        if (ws.len == 0) try g.print("false", .{});
        try g.print("}};\n    static constexpr std::uint32_t focus_order[{d}] = {{", .{@max(ws.len, 1)});
        for (ws, 0..) |_, k| try g.print("{s}{d}", .{ if (k == 0) "" else ", ", k });
        if (ws.len == 0) try g.print("0", .{});
        try g.print("}};\n", .{});
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

    /// The C type a constant column's rows are written as: its own for numbers, so a compiler
    /// sees a column of one value as a splat; whole words otherwise.
    fn cColumnType(comptime field: []const u8) []const u8 {
        const FT = @FieldType(lcgf.tree.Tree.Columns, field);
        const T = switch (@typeInfo(FT)) {
            .pointer => |p| p.child,
            .array => |a| @typeInfo(a.child).pointer.child,
            else => unreachable,
        };
        return switch (T) {
            f32 => "float",
            u32 => "uint32_t",
            u16 => "uint16_t",
            u8 => "uint8_t",
            i16 => "int16_t",
            else => "uint32_t",
        };
    }

    /// The UI's frame as C (`--lang c`): liblcgf's static-UI engine (share/lcgf/lcgf_ct_l*.c,
    /// Zig's C backend) included into this file with the words and each constant column as
    /// constants, so clang specializes the frame to this UI as Zig does at comptime. Other
    /// compilers call liblcgf's frame over the same words.
    fn cSource(g: *const StaticGen) !void {
        const name = g.x.spec.name;
        const h = g.header();
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
        // Each constant column of each tree, as its own array.
        var refs: [ct.cols_len][]const u8 = @splat("0");
        for ([_]*const ct.Block{ &h.full, &h.skel }, 0..) |b, bi| {
            if (bi == 1 and h.folded == 0) continue;
            const offs = g.words[b.cols..][0..ct.column_arrays.len];
            inline for (ct.column_arrays, 0..) |col, k| if (offs[k] != ct.none) {
                const ty = comptime cColumnType(col.field);
                const elem: usize = if (comptime std.mem.eql(u8, ty, "uint8_t")) 1 else if (comptime std.mem.eql(u8, ty, "uint16_t") or std.mem.eql(u8, ty, "int16_t")) 2 else 4;
                const bytes = std.mem.sliceAsBytes(g.words[offs[k]..])[0 .. ct.rowsMax(b.n) * col.size];
                const id = try std.fmt.allocPrint(g.arena, "col{d}_{d}", .{ bi, k });
                try g.print("static const {s} {s}[{d}] __attribute__((aligned(64))) = {{", .{ ty, id, bytes.len / elem });
                for (0..bytes.len / elem) |i| {
                    if (i % 16 == 0) try g.print("\n   ", .{});
                    const v: u32 = switch (elem) {
                        1 => bytes[i],
                        2 => std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little),
                        else => std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little),
                    };
                    if (comptime std.mem.eql(u8, ty, "float"))
                        try g.print(" {s},", .{try cFloat(g.arena, @bitCast(v))})
                    else if (comptime std.mem.eql(u8, ty, "int16_t"))
                        try g.print(" {d},", .{@as(i16, @bitCast(@as(u16, @intCast(v))))})
                    else
                        try g.print(" 0x{x},", .{v});
                }
                try g.print("\n}};\n", .{});
                refs[bi * ct.column_arrays.len + k] = try std.fmt.allocPrint(g.arena, "(const uint8_t *){s}", .{id});
            };
        }
        try g.print("static const uint8_t *const cols[{d}] = {{", .{ct.cols_len});
        for (refs, 0..) |r, i| try g.print("{s}{s},", .{ if (i % 4 == 0) "\n    " else " ", r });
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
        const h = g.header();
        const full = try NativeBlock.decode(g.arena, g.words, h, &h.full);
        try g.print(
            \\// Generated by lcgf-gen --static from {s}. Do not edit: change the spec and run lcgf-gen again.
            \\// A static UI: the comptime pipeline's tables (src/abi/ct.zig: the fold, the constant columns
            \\// and the paint templates), the values Zig makes at compile time, as constants the passes of
            \\// lcgf/ct.hpp are compiled against. `SeamUi` runs the same UI through liblcgf instead.
            \\#pragma once
            \\#include <array>
            \\#include <cstddef>
            \\#include <cstdint>
            \\#include <lcgf/ct.hpp>
            \\#include <lcgf/lcgf.hpp>
            \\
            \\namespace {s} {{
            \\
            \\
        , .{ g.source, name });
        try stateCpp(g.arena, g.out, g.x.spec.state, g.x.fields, g.x.state_size, g.x.state_align);
        const n = h.full.n;
        try g.print("\n/// The widgets, valued by their rows: what `at`, `pointer` and `focus` report.\nenum class Widget : std::uint32_t {{", .{});
        for (g.x.widgets, 0..) |w, k| try g.print("{s} {s} = {d}", .{ if (k == 0) "" else ",", w.name, w.row });
        try g.print(" }};\n/// The state's fields, for `relayout` and `patch`.\nenum class Field : std::uint32_t {{", .{});
        for (g.x.fields, 0..) |f, k| try g.print("{s} {s} = {d}", .{ if (k == 0) "" else ",", f.name, k });
        try g.print(" }};\n", .{});
        try g.print(
            \\
            \\/// The tables, as compile-time constants (floats as their bits).
            \\struct Tables {{
            \\    using Widget = {s}::Widget;
            \\    static constexpr std::uint32_t n = {d}, labels = {d}, quads = {d}, batches = {d}, regions = {d};
            \\    static constexpr std::uint32_t slot_count = {d}, coord = {d}, string_cap = {d};
            \\    static constexpr bool folded = {}, live = {}, windows = {}, has_child_clip = {}, root_when = {}, slots_shared = {};
            \\    static constexpr std::uint32_t text_px = 0x{x}, text_font = {d}, advance = 0x{x}, line = 0x{x};
            \\
        , .{
            name,
            n,
            h.labels,
            h.quads,
            h.batches,
            h.regions,
            h.slot_count,
            h.coord,
            h.string_cap,
            h.folded > 0,
            h.regions > 0,
            h.has_windows != 0,
            h.has_child_clip != 0,
            h.root_when != 0,
            h.slot_count != n,
            @as(u32, @bitCast((lcgf.types.TextStyle{}).px)),
            @backingInt((lcgf.types.TextStyle{}).font),
            @as(u32, @bitCast((lcgf.protocol.Mono{}).advance)),
            @as(u32, @bitCast((lcgf.protocol.Mono{}).line)),
        });
        try g.blockCpp("full", &full);
        if (h.folded > 0) {
            const skel = try NativeBlock.decode(g.arena, g.words, h, &h.skel);
            try g.blockCpp("skel", &skel);
            try g.arrayCpp("expand_base", h.expand[0], n, 1);
            try g.print("    static constexpr std::uint32_t expand_rel[2][{d}] = {{", .{n});
            try g.list(g.words[h.expand[1]..][0..n], false);
            try g.print(", ", .{});
            try g.list(g.words[h.expand[2]..][0..n], false);
            try g.print("}};\n    static constexpr std::uint32_t expand_size[2][{d}] = {{", .{n});
            try g.list(g.words[h.expand[3]..][0..n], false);
            try g.print(", ", .{});
            try g.list(g.words[h.expand[4]..][0..n], false);
            try g.print("}};\n", .{});
            try g.arrayCpp("expand_keep", h.expand[5], n, 1);
        } else try g.print("    using skel = full;\n", .{});
        try g.arrayCpp("paint_node", h.paint_node, h.quads, 1);
        try g.arrayCpp("clip_node", h.clip_node, h.quads, 1);
        try g.arrayCpp("keys", h.keys, h.quads, 1);
        try g.arrayCpp("templates", h.templates, h.quads, @sizeOf(lcgf.draw_list.Quad) / 4);
        try g.arrayCpp("batch_first", h.batch_first, h.batches, 1);
        try g.arrayCpp("batch_count", h.batch_count, h.batches, 1);
        try g.arrayCpp("batch_key", h.batch_key, h.batches, 1);
        try g.arrayCpp("label_plans", h.label_plans, h.labels, @sizeOf(lcgf.ct_tables.Label) / 4);
        try g.widgetsCpp();
        try g.print("    using Field = {s}::Field;\n    static constexpr std::uint32_t fields = {d}, patch_count = {d};\n", .{ name, h.fields, h.patch_count });
        try g.arrayCpp("spans", h.spans, h.fields, 2);
        try g.arrayCpp("patches", h.patches, h.patch_count, 4);
        try g.print("    static std::uint32_t color([[maybe_unused]] const State& s, std::uint32_t field) {{\n        switch (field) {{\n", .{});
        for (g.x.fields, 0..) |f, k| if (f.type == .color) try g.print("        case {d}: return s.{s};\n", .{ k, f.name });
        try g.print("        default: return 0;\n        }}\n    }}\n", .{});
        try g.arrayCpp("slot_of", h.slots, n, 1);
        try g.arrayCpp("slot_defaults", h.slot_defaults, h.slot_count, 1);
        try g.print("    static void texts([[maybe_unused]] const State& s, [[maybe_unused]] lcgf::ct::Sink& o, [[maybe_unused]] std::uint32_t* end) {{", .{});
        try g.texts(false);
        try g.print(" }}\n    static void select([[maybe_unused]] const State& s, [[maybe_unused]] std::uint32_t* n, [[maybe_unused]] float* scroll) {{", .{});
        for (g.selectors(), 0..) |sl, k| {
            try g.print(" n[{d}] = std::uint32_t(s.{s});", .{ k, sl.field.name });
            if (sl.scroll) |sc| try g.print(" scroll[{d}] = s.{s};", .{ k, sc }) else try g.print(" scroll[{d}] = 0;", .{k});
        }
        try g.print(" }}\n}};\n\n/// The UI: a value holding its state and its frame's columns, compiled against `Tables`.\nclass Ui : public lcgf::ct::Ui<Tables, State> {{\npublic:\n    explicit Ui(State s = {{}}) : lcgf::ct::Ui<Tables, State>(s) {{}}\n", .{});
        for (g.x.fields) |f| {
            const ty = fieldType(f.type);
            try g.print("    void set_{s}({s} v) {{ state.{s} = v; }}\n    {s} {s}() const {{ return state.{s}; }}\n", .{ f.name, ty, f.name, ty, f.name, f.name });
        }
        try g.print("}};\n\n/// The same UI through liblcgf's frame (lcgf.h), over these words.\nalignas(64) inline constexpr std::uint32_t words[{d}] = {{", .{g.words.len});
        try g.words_();
        try g.print(
            \\
            \\}};
            \\/// Bytes `SeamUi` needs in your buffer, aligned to lcgf::column_align, for any lane count.
            \\inline constexpr std::size_t bytes = {d};
            \\class SeamUi : public lcgf::StaticUi<State> {{
            \\public:
            \\    explicit SeamUi(std::span<std::byte> buffer, State s = {{}}) : lcgf::StaticUi<State>(words, buffer, s) {{}}
            \\}};
            \\
            \\}} // namespace {s}
            \\
        , .{ g.bytes, name });
    }

    fn rust(g: *const StaticGen) !void {
        const h = g.header();
        const n = h.full.n;
        const full = try NativeBlock.decode(g.arena, g.words, h, &h.full);
        try g.print(
            \\// Generated by lcgf-gen --static from {s}. Do not edit: change the spec and run lcgf-gen again.
            \\// A static UI: the comptime pipeline's tables (src/abi/ct.zig: the fold, the constant columns
            \\// and the paint templates), the values Zig makes at compile time, as constants the passes of
            \\// `lcgf::ct` are compiled against. `SeamUi` runs the same UI through liblcgf instead.
            \\
            \\
        , .{g.source});
        try stateRust(g.arena, g.out, g.x.spec.state, g.x.fields, g.x.state_size, g.x.state_align);
        try g.print("\n", .{});
        try g.widgetsRust();
        try g.print("/// The state's fields, for `relayout` and `patch`.\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\n#[repr(u32)]\npub enum Field {{\n", .{});
        for (g.x.fields, 0..) |f, k| try g.print("    {s} = {d},\n", .{ camel(g.arena, f.name), k });
        try g.print("}}\n\n", .{});
        try g.print("/// The tables, as compile-time constants (floats as their bits).\npub struct Tables;\n\n", .{});
        try g.blockRust("FULL", &full);
        if (h.folded > 0) {
            const skel = try NativeBlock.decode(g.arena, g.words, h, &h.skel);
            try g.blockRust("SKEL", &skel);
        }
        try g.print(
            \\impl ::lcgf::ct::Tables for Tables {{
            \\    type State = State;
            \\    type Widget = Widget;
            \\    type Event = Event;
            \\    type Field = Field;
            \\    const N: usize = {d};
            \\    const LABELS: usize = {d};
            \\    const QUADS: usize = {d};
            \\    const BATCHES: usize = {d};
            \\    const REGIONS: usize = {d};
            \\    const SLOT_COUNT: usize = {d};
            \\    const COORD: u32 = {d};
            \\    const STRING_CAP: usize = {d};
            \\    const FOLDED: bool = {};
            \\    const LIVE: bool = {};
            \\    const WINDOWS: bool = {};
            \\    const HAS_CHILD_CLIP: bool = {};
            \\    const ROOT_WHEN: bool = {};
            \\    const SLOTS_SHARED: bool = {};
            \\    const TEXT_PX: u32 = 0x{x};
            \\    const TEXT_FONT: u32 = {d};
            \\    const ADVANCE: u32 = 0x{x};
            \\    const LINE: u32 = 0x{x};
            \\    const FULL: ::lcgf::ct::Block = FULL;
            \\    const SKEL: ::lcgf::ct::Block = {s};
            \\
        , .{
            n,                                          h.labels,                                           h.quads,                                         h.batches,                            h.regions,
            h.slot_count,                               h.coord,                                            h.string_cap,                                    h.folded > 0,                         h.regions > 0,
            h.has_windows != 0,                         h.has_child_clip != 0,                              h.root_when != 0,                                h.slot_count != n,                    @as(u32, @bitCast((lcgf.types.TextStyle{}).px)),
            @backingInt((lcgf.types.TextStyle{}).font), @as(u32, @bitCast((lcgf.protocol.Mono{}).advance)), @as(u32, @bitCast((lcgf.protocol.Mono{}).line)), if (h.folded > 0) "SKEL" else "FULL",
        });
        const empty: []const u32 = &.{};
        const folded = h.folded > 0;
        try g.sliceRust("EXPAND_BASE", if (folded) g.words[h.expand[0]..][0..n] else empty);
        try g.print("    const EXPAND_REL: [&'static [u32]; 2] = [&", .{});
        try g.list(if (folded) g.words[h.expand[1]..][0..n] else empty, true);
        try g.print(", &", .{});
        try g.list(if (folded) g.words[h.expand[2]..][0..n] else empty, true);
        try g.print("];\n    const EXPAND_SIZE: [&'static [u32]; 2] = [&", .{});
        try g.list(if (folded) g.words[h.expand[3]..][0..n] else empty, true);
        try g.print(", &", .{});
        try g.list(if (folded) g.words[h.expand[4]..][0..n] else empty, true);
        try g.print("];\n", .{});
        try g.sliceRust("EXPAND_KEEP", if (folded) g.words[h.expand[5]..][0..n] else empty);
        try g.sliceRust("PAINT_NODE", g.words[h.paint_node..][0..h.quads]);
        try g.sliceRust("CLIP_NODE", g.words[h.clip_node..][0..h.quads]);
        try g.sliceRust("KEYS", g.words[h.keys..][0..h.quads]);
        try g.rowsRust("TEMPLATES", g.words[h.templates..][0 .. h.quads * 34], 34);
        try g.sliceRust("BATCH_FIRST", g.words[h.batch_first..][0..h.batches]);
        try g.sliceRust("BATCH_COUNT", g.words[h.batch_count..][0..h.batches]);
        try g.sliceRust("BATCH_KEY", g.words[h.batch_key..][0..h.batches]);
        try g.rowsRust("LABEL_PLANS", g.words[h.label_plans..][0 .. h.labels * 8], 8);
        {
            const ws = g.x.widgets;
            const rows = try g.arena.alloc(u32, ws.len);
            const order = try g.arena.alloc(u32, ws.len);
            for (ws, rows, order, 0..) |w, *r, *o, k| {
                r.* = w.row;
                o.* = @intCast(k);
            }
            try g.sliceRust("WIDGET_ROWS", rows);
            try g.print("    const WIDGET_SLIDER: &'static [bool] = &[", .{});
            for (ws, 0..) |w, k| try g.print("{s}{}", .{ if (k == 0) "" else ", ", w.slider });
            try g.print("];\n", .{});
            try g.sliceRust("FOCUS_ORDER", order);
            try g.print("    fn widget(slot: usize) -> Widget {{\n        match slot {{\n", .{});
            for (ws, 0..) |w, k| try g.print("            {d} => Widget::{s},\n", .{ k, camel(g.arena, w.name) });
            try g.print("            _ => unreachable!(),\n        }}\n    }}\n    fn event(slot: usize, _value: f32) -> Event {{\n        match slot {{\n", .{});
            for (ws, 0..) |w, k| try g.print("            {d} => Event::{s}{s},\n", .{ k, camel(g.arena, w.name), if (w.slider) "(_value)" else "" });
            try g.print("            _ => unreachable!(),\n        }}\n    }}\n", .{});
        }
        try g.rowsRust("SPANS", g.words[h.spans..][0 .. h.fields * 2], 2);
        try g.rowsRust("PATCHES", g.words[h.patches..][0 .. h.patch_count * 4], 4);
        try g.print("    #[inline(always)]\n    fn field_index(f: Field) -> usize {{\n        f as usize\n    }}\n    #[inline(always)]\n    fn color(_s: &State, field: usize) -> u32 {{\n        match field {{\n", .{});
        for (g.x.fields, 0..) |f, k| if (f.type == .color) try g.print("            {d} => _s.{s},\n", .{ k, f.name });
        try g.print("            _ => 0,\n        }}\n    }}\n", .{});
        try g.sliceRust("SLOT_OF", g.words[h.slots..][0..n]);
        try g.sliceRust("SLOT_DEFAULTS", g.words[h.slot_defaults..][0..h.slot_count]);
        try g.print("    #[inline(always)]\n    fn texts(_s: &State, o: &mut ::lcgf::ct::Sink<'_>, end: &mut [u32]) {{", .{});
        try g.texts(true);
        try g.print(" }}\n    #[inline(always)]\n    fn select(_s: &State, _n: &mut [u32], _scroll: &mut [f32]) {{", .{});
        for (g.selectors(), 0..) |sl, k| {
            try g.print(" _n[{d}] = _s.{s} as u32;", .{ k, sl.field.name });
            if (sl.scroll) |sc| try g.print(" _scroll[{d}] = _s.{s};", .{ k, sc }) else try g.print(" _scroll[{d}] = 0.0;", .{k});
        }
        const skel_n = if (h.folded > 0) h.skel.n else n;
        try g.print(
            \\ }}
            \\}}
            \\
            \\/// The UI: a value holding its state and its frame's columns, compiled against `Tables`.
            \\pub type Ui = ::lcgf::ct::Ui<Tables, {d}, {d}, {d}, {d}, {d}, {d}>;
            \\
            \\/// The same UI through liblcgf's frame (lcgf.h), over these words.
            \\pub static WORDS: ::lcgf::StaticTables<{d}> = ::lcgf::StaticTables([
        , .{ n, skel_n, @max(h.labels, 1), h.quads + 1, h.labels + 1, h.quads + h.labels + 4, g.words.len });
        try g.words_();
        try g.print(
            \\
            \\]);
            \\/// Bytes `SeamUi` needs in your buffer, for any lane count.
            \\pub const BYTES: usize = {d};
            \\
            \\/// The UI through liblcgf.
            \\pub struct SeamUi<'a> {{
            \\    pub inner: ::lcgf::StaticUi<'a, State>,
            \\}}
            \\
            \\impl<'a> SeamUi<'a> {{
            \\    pub fn new(buffer: &'a mut ::lcgf::Buffer<BYTES>) -> Result<Self, ::lcgf::Status> {{
            \\        Ok(Self {{ inner: ::lcgf::StaticUi::new(&WORDS.0, buffer.bytes(), State::default())? }})
            \\    }}
            \\    pub fn frame(&mut self, width: f32, height: f32) -> ::lcgf::DrawList<'_> {{
            \\        self.inner.frame(width, height)
            \\    }}
            \\}}
            \\
        , .{g.bytes});
    }

    fn sliceRust(g: *const StaticGen, name: []const u8, ws: []const u32) !void {
        try g.print("    const {s}: &'static [u32] = &", .{name});
        try g.list(ws, true);
        try g.print(";\n", .{});
    }

    fn rowsRust(g: *const StaticGen, name: []const u8, ws: []const u32, comptime per: usize) !void {
        try g.print("    const {s}: &'static [[u32; {d}]] = &[", .{ name, per });
        var k: usize = 0;
        while (k < ws.len) : (k += per) {
            try g.print("{s}", .{if (k == 0) "" else ", "});
            try g.list(ws[k..][0..per], true);
        }
        try g.print("];\n", .{});
    }

    fn blockRust(g: *const StaticGen, name: []const u8, b: *const NativeBlock) !void {
        try g.print("const {s}: ::lcgf::ct::Block = ::lcgf::ct::Block {{\n    n: {d},\n", .{ name, b.n });
        for (NativeBlock.names, NativeBlock.axes, 0..) |col, per_axis, k| {
            if (per_axis) {
                try g.print("    {s}: [&", .{col});
                try g.list(b.u32s[k][0], true);
                try g.print(", &", .{});
                try g.list(b.u32s[k][1], true);
                try g.print("],\n", .{});
            } else {
                try g.print("    {s}: &", .{col});
                try g.list(b.u32s[k][0], true);
                try g.print(",\n", .{});
            }
        }
        try g.print("    clips: &[", .{});
        for (b.clips, 0..) |c, i| try g.print("{s}{d}", .{ if (i == 0) "" else ", ", c });
        try g.print("],\n    border: &", .{});
        try g.list(b.border, true);
        try g.print(",\n    label_rows: &", .{});
        try g.list(b.label_rows, true);
        try g.print(",\n    regions: &[", .{});
        for (b.regions, 0..) |r, i| try g.print("{s}::lcgf::ct::Region {{ kind: {d}, row: {d}, end: {d}, stride: {d}, max: {d}, alts: {d}, scroll: {d}, height: 0x{x} }}", .{ if (i == 0) "" else ", ", r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7] });
        try g.print("],\n    alts: &[", .{});
        for (b.alts, 0..) |w, i| try g.print("{s}[{d}, {d}]", .{ if (i == 0) "" else ", ", w[0], w[1] });
        try g.print("],\n}};\n\n", .{});
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
