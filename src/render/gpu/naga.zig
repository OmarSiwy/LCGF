//! naga's translations, finished for each back end at compile time. naga-cli has no option for
//! a binding map, so each language comes out with bindings the native API cannot use as they
//! are; these functions assign them from the WGSL reflection (reflect.zig), as text, before the
//! driver sees the shader:
//!
//!   GLSL ES  storage blocks and images get `binding = k` (GL ES cannot assign them at run time).
//!   HLSL     naga's 2048-entry sampler heap becomes one `register(sB, spaceG)` per sampler.
//!   MSL      every `[[user(fake0)]]` becomes `[[buffer(k)]]`, `[[texture(k)]]` or `[[sampler(k)]]`.
//!
//! Slots are flat per kind, in (group, binding) order: the k-th buffer the shader declares is
//! buffer slot k, and so on. Each function is a compile error on a declaration it does not
//! recognise, so a naga upgrade that changes its text fails the build, not the driver.

const std = @import("std");
const reflect = @import("reflect.zig");

pub const SlotKind = enum { buffer, texture, sampler, image, uniform, storage };

pub const Slot = struct { group: u32, binding: u32, slot: u32 };

/// The flat slot of every binding of `m`, numbered per class. `split_buffers` numbers uniform
/// and storage buffers separately (GL) instead of together (Metal), and `split_images` numbers
/// storage textures apart from textures (GL) instead of with them (Metal).
pub fn slots(comptime m: reflect.Module, comptime split_buffers: bool, comptime split_images: bool) []const Slot {
    comptime {
        var out: []const Slot = &.{};
        var next: [5]u32 = .{ 0, 0, 0, 0, 0 }; // uniform-or-buffer, storage, texture, image, sampler
        for (0..m.groupCount()) |g| for (m.group(g)) |b| {
            const k: usize = switch (b.kind) {
                .uniform => 0,
                .storage_read, .storage_read_write => if (split_buffers) 1 else 0,
                .texture => 2,
                .storage_texture => if (split_images) 3 else 2,
                .sampler, .comparison_sampler => 4,
            };
            out = out ++ [_]Slot{.{ .group = b.group, .binding = b.binding, .slot = next[k] }};
            next[k] += 1;
        };
        return out;
    }
}

pub fn slotOf(comptime table: []const Slot, comptime group: u32, comptime binding: u32) u32 {
    for (table) |s| if (s.group == group and s.binding == binding) return s.slot;
    @compileError(std.fmt.comptimePrint("no slot for @group({d}) @binding({d})", .{ group, binding }));
}

// ---------------------------------------------------------------------------------------------
// GLSL ES

/// GL ES's slots: uniform buffers, storage buffers, textures and images each numbered apart.
pub fn glslSlots(comptime m: reflect.Module) []const Slot {
    return slots(m, true, true);
}

/// naga's GLSL ES with `binding = k` written into each storage block's and image's layout
/// qualifier.
pub fn glsl(comptime m: reflect.Module, comptime src: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100 * src.len + 10_000);
    const table = glslSlots(m);
    var out: []const u8 = "";
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        var l: []const u8 = line;
        const declares = std.mem.indexOf(u8, l, " buffer ") != null or std.mem.indexOf(u8, l, "image") != null;
        if (declares and std.mem.startsWith(u8, l, "layout(")) {
            if (glslName(l)) |gb| {
                const close = std.mem.indexOfScalar(u8, l, ')').?;
                l = l[0..close] ++ std.fmt.comptimePrint(", binding = {d}", .{slotOf(table, gb[0], gb[1])}) ++ l[close..];
            }
        }
        out = out ++ (if (first) "" else "\n") ++ l;
        first = false;
    }
    const final = out[0..out.len].* ++ [_]u8{0};
    return final[0..out.len :0];
}

/// The (group, binding) of a GLSL line declaring naga's `_group_G_binding_B_<stage>`, if any.
pub fn glslName(line: []const u8) ?[2]u32 {
    const tag = "_group_";
    const at = std.mem.indexOf(u8, line, tag) orelse return null;
    var rest: []const u8 = line[at + tag.len ..];
    const g_end = std.mem.indexOfScalar(u8, rest, '_') orelse return null;
    const g = std.fmt.parseInt(u32, rest[0..g_end], 10) catch return null;
    rest = rest[g_end..];
    if (!std.mem.startsWith(u8, rest, "_binding_")) return null;
    rest = rest["_binding_".len..];
    const b_end = std.mem.indexOfScalar(u8, rest, '_') orelse return null;
    const b = std.fmt.parseInt(u32, rest[0..b_end], 10) catch return null;
    return .{ g, b };
}

/// The uniform block names naga gave `name` (`_group_G_binding_B_<stage>`) in `text`: the
/// `uniform <Block> {` on the line that declares it.
pub fn glslBlocks(comptime text: []const u8, comptime name: []const u8) []const [:0]const u8 {
    comptime {
        var out: []const [:0]const u8 = &.{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, name) == null) continue;
            if (std.mem.indexOfScalar(u8, line, '{') == null) continue;
            const u = std.mem.indexOf(u8, line, "uniform ") orelse continue;
            const rest = line[u + "uniform ".len ..];
            const end = std.mem.indexOfAny(u8, rest, " {") orelse continue;
            const z = rest[0..end].* ++ [_]u8{0};
            out = out ++ [_][:0]const u8{z[0..end :0]};
        }
        return out;
    }
}

// ---------------------------------------------------------------------------------------------
// HLSL

/// naga's HLSL with its sampler heap removed: each `static const SamplerState x =
/// nagaSamplerHeap[nagaGroupGSamplerIndexArray[B]];` becomes `SamplerState x : register(sB,
/// spaceG);`, and the heap and index arrays go. Line endings are kept.
pub fn hlsl(comptime src: []const u8) [:0]const u8 {
    @setEvalBranchQuota(200 * src.len + 10_000);
    var out: []const u8 = "";
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        const end = line[l.len..];
        var kept: ?[]const u8 = l;
        if (std.mem.startsWith(u8, l, "SamplerState nagaSamplerHeap") or
            std.mem.startsWith(u8, l, "SamplerComparisonState nagaComparisonSamplerHeap") or
            (std.mem.startsWith(u8, l, "StructuredBuffer<uint> nagaGroup") and std.mem.indexOf(u8, l, "SamplerIndexArray") != null))
        {
            kept = null;
        } else for ([_][2][]const u8{ .{ "static const SamplerState ", "SamplerState " }, .{ "static const SamplerComparisonState ", "SamplerComparisonState " } }) |pair| {
            if (!std.mem.startsWith(u8, l, pair[0])) continue;
            const rest = l[pair[0].len..];
            const name = rest[0..std.mem.indexOfScalar(u8, rest, ' ').?];
            const g_at = std.mem.indexOf(u8, rest, "nagaGroup").? + "nagaGroup".len;
            const g_end = g_at + std.mem.indexOfNone(u8, rest[g_at..], "0123456789").?;
            const b_at = std.mem.indexOf(u8, rest, "IndexArray[").? + "IndexArray[".len;
            const b_end = b_at + std.mem.indexOfScalar(u8, rest[b_at..], ']').?;
            kept = pair[1] ++ name ++ " : register(s" ++ rest[b_at..b_end] ++ ", space" ++ rest[g_at..g_end] ++ ");";
        }
        if (kept) |k| {
            out = out ++ (if (first) "" else "\n") ++ k ++ end;
            first = false;
        }
    }
    if (std.mem.indexOf(u8, out, "nagaSamplerHeap") != null) @compileError("naga.hlsl: a sampler still reads naga's heap; update src/render/gpu/naga.zig");
    const final = out[0..out.len].* ++ [_]u8{0};
    return final[0..out.len :0];
}

// ---------------------------------------------------------------------------------------------
// MSL

/// Metal's slots: buffers (uniform and storage) together, textures with storage textures.
pub fn mslSlots(comptime m: reflect.Module) []const Slot {
    return slots(m, false, false);
}

/// Buffer slot of the runtime-sized arrays' lengths (`_buffer_sizes`): after every buffer.
pub fn mslSizesSlot(comptime m: reflect.Module) u32 {
    var n: u32 = 0;
    for (m.bindings) |b| n += @intFromBool(b.kind.isBuffer());
    return n;
}

/// Vertex buffer slot `slot` of a pipeline: counted down from the top of Metal's 31 buffer
/// slots, so it never meets a resource buffer.
pub fn mslVertexBuffer(slot: u32) u32 {
    return 30 - slot;
}

/// The runtime-sized storage buffers, in the order naga's `_mslBufferSizes` lists them: the
/// order the WGSL declares them.
pub fn mslSized(comptime m: reflect.Module) []const reflect.Binding {
    comptime {
        var out: []const reflect.Binding = &.{};
        for (m.bindings) |b| if (b.runtime_sized) {
            out = out ++ [_]reflect.Binding{b};
        };
        return out;
    }
}

/// naga's MSL with every resource at its slot. naga names a parameter after its WGSL variable,
/// with `_` or `_N` appended when the name is taken or reserved.
pub fn msl(comptime m: reflect.Module, comptime src: []const u8) [:0]const u8 {
    @setEvalBranchQuota(400 * src.len + 10_000);
    const table = mslSlots(m);
    const fake = " [[user(fake0)]]";
    var out: []const u8 = "";
    var rest: []const u8 = src;
    while (std.mem.indexOf(u8, rest, fake)) |at| {
        const before = rest[0..at];
        var start = at;
        while (start > 0 and (std.ascii.isAlphanumeric(before[start - 1]) or before[start - 1] == '_')) start -= 1;
        const ident = before[start..];
        const slot: []const u8 = if (std.mem.eql(u8, ident, "_buffer_sizes"))
            std.fmt.comptimePrint("buffer({d})", .{mslSizesSlot(m)})
        else blk: {
            for (m.bindings) |b| if (mslNameMatches(ident, b.name)) {
                const k = slotOf(table, b.group, b.binding);
                break :blk switch (b.kind) {
                    .uniform, .storage_read, .storage_read_write => std.fmt.comptimePrint("buffer({d})", .{k}),
                    .texture, .storage_texture => std.fmt.comptimePrint("texture({d})", .{k}),
                    .sampler, .comparison_sampler => std.fmt.comptimePrint("sampler({d})", .{k}),
                };
            };
            @compileError("naga.msl: no WGSL binding for the parameter `" ++ ident ++ "`; update src/render/gpu/naga.zig");
        };
        out = out ++ before ++ " [[" ++ slot ++ "]]";
        rest = rest[at + fake.len ..];
    }
    out = out ++ rest;
    const final = out[0..out.len].* ++ [_]u8{0};
    return final[0..out.len :0];
}

fn mslNameMatches(ident: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, ident, name)) return false;
    const tail = ident[name.len..];
    if (tail.len == 0) return true;
    if (tail[0] != '_') return false;
    for (tail[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const testing = std.testing;

const sample = reflect.parse(
    \\@group(0) @binding(0) var<uniform> params: vec4f;
    \\@group(0) @binding(1) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var smp: sampler;
    \\@group(1) @binding(0) var<storage, read> data: array<vec4f>;
    \\@group(1) @binding(1) var img: texture_storage_2d<rgba8unorm, write>;
);

// ---- The same at run time ----

/// `slots` at run time: one per binding, into `out` (at least `m.bindings.len` long).
pub fn slotsInto(m: reflect.Module, split_buffers: bool, split_images: bool, scratch: []reflect.Binding, out: []Slot) []Slot {
    var n: usize = 0;
    var next: [5]u32 = .{ 0, 0, 0, 0, 0 };
    var groups: u32 = 0;
    for (m.bindings) |b| groups = @max(groups, b.group + 1);
    for (0..groups) |g| for (reflect.groupInto(m, @intCast(g), scratch)) |b| {
        const k: usize = switch (b.kind) {
            .uniform => 0,
            .storage_read, .storage_read_write => if (split_buffers) 1 else 0,
            .texture => 2,
            .storage_texture => if (split_images) 3 else 2,
            .sampler, .comparison_sampler => 4,
        };
        out[n] = .{ .group = b.group, .binding = b.binding, .slot = next[k] };
        next[k] += 1;
        n += 1;
    };
    return out[0..n];
}

/// `slotOf` at run time.
pub fn slotIn(table: []const Slot, group: u32, binding: u32) ?u32 {
    for (table) |s| if (s.group == group and s.binding == binding) return s.slot;
    return null;
}

/// `glsl` at run time: naga's GLSL ES with storage blocks and images given their bindings.
pub fn glslAlloc(gpa: std.mem.Allocator, table: []const Slot, src: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const declares = std.mem.indexOf(u8, l, " buffer ") != null or std.mem.indexOf(u8, l, "image") != null;
        if (declares and std.mem.startsWith(u8, l, "layout(")) {
            if (glslName(l)) |gb| {
                const close = std.mem.indexOfScalar(u8, l, ')').?;
                const slot = slotIn(table, gb[0], gb[1]) orelse return error.NoSlot;
                try out.print(gpa, "{s}, binding = {d}{s}", .{ l[0..close], slot, l[close..] });
                continue;
            }
        }
        try out.appendSlice(gpa, l);
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// `glslBlocks` at run time: the uniform blocks of `text` that hold `name`, appended to `out`.
pub fn glslBlocksInto(gpa: std.mem.Allocator, text: []const u8, name: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, name) == null) continue;
        if (std.mem.indexOfScalar(u8, line, '{') == null) continue;
        const u = std.mem.indexOf(u8, line, "uniform ") orelse continue;
        const rest = line[u + "uniform ".len ..];
        const end = std.mem.indexOfAny(u8, rest, " {") orelse continue;
        try out.append(gpa, rest[0..end]);
    }
}

/// `hlsl` at run time: naga's samplers taken out of its heap, one
/// `register(sB, spaceG)` each, line endings kept.
pub fn hlslAlloc(gpa: std.mem.Allocator, src: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        const end = line[l.len..];
        if (std.mem.startsWith(u8, l, "SamplerState nagaSamplerHeap") or
            std.mem.startsWith(u8, l, "SamplerComparisonState nagaComparisonSamplerHeap") or
            (std.mem.startsWith(u8, l, "StructuredBuffer<uint> nagaGroup") and std.mem.indexOf(u8, l, "SamplerIndexArray") != null)) continue;
        if (!first) try out.append(gpa, '\n');
        first = false;
        for ([_][2][]const u8{ .{ "static const SamplerState ", "SamplerState " }, .{ "static const SamplerComparisonState ", "SamplerComparisonState " } }) |pair| {
            if (!std.mem.startsWith(u8, l, pair[0])) continue;
            const rest = l[pair[0].len..];
            const name = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse return error.NoSampler];
            const g_at = (std.mem.indexOf(u8, rest, "nagaGroup") orelse return error.NoSampler) + "nagaGroup".len;
            const g_end = g_at + (std.mem.indexOfNone(u8, rest[g_at..], "0123456789") orelse return error.NoSampler);
            const b_at = (std.mem.indexOf(u8, rest, "IndexArray[") orelse return error.NoSampler) + "IndexArray[".len;
            const b_end = b_at + (std.mem.indexOfScalar(u8, rest[b_at..], ']') orelse return error.NoSampler);
            try out.print(gpa, "{s}{s} : register(s{s}, space{s});{s}", .{ pair[1], name, rest[b_at..b_end], rest[g_at..g_end], end });
            break;
        } else try out.print(gpa, "{s}{s}", .{ l, end });
    }
    if (std.mem.indexOf(u8, out.items, "nagaSamplerHeap") != null) return error.NoSampler;
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// `mslSizesSlot` at run time.
pub fn mslSizesSlotIn(m: reflect.Module) u32 {
    var n: u32 = 0;
    for (m.bindings) |b| n += @intFromBool(b.kind.isBuffer());
    return n;
}

/// The index of `@group(g) @binding(b)` among the runtime-sized arrays (`mslSized`), if it is one.
pub fn mslSizedIndex(m: reflect.Module, group: u32, binding: u32) ?u32 {
    var k: u32 = 0;
    for (m.bindings) |b| if (b.runtime_sized) {
        if (b.group == group and b.binding == binding) return k;
        k += 1;
    };
    return null;
}

/// `msl` at run time: naga's MSL with every resource at its slot (`table` from
/// `slotsInto(m, false, false, ...)`).
pub fn mslAlloc(gpa: std.mem.Allocator, m: reflect.Module, table: []const Slot, src: []const u8) ![:0]u8 {
    const fake = " [[user(fake0)]]";
    var out: std.ArrayList(u8) = .empty;
    var rest: []const u8 = src;
    while (std.mem.indexOf(u8, rest, fake)) |at| {
        const before = rest[0..at];
        var start = at;
        while (start > 0 and (std.ascii.isAlphanumeric(before[start - 1]) or before[start - 1] == '_')) start -= 1;
        const ident = before[start..];
        try out.appendSlice(gpa, before);
        if (std.mem.eql(u8, ident, "_buffer_sizes")) {
            try out.print(gpa, " [[buffer({d})]]", .{mslSizesSlotIn(m)});
        } else {
            const b = for (m.bindings) |b| {
                if (mslNameMatches(ident, b.name)) break b;
            } else return error.NoSlot;
            const k = slotIn(table, b.group, b.binding) orelse return error.NoSlot;
            const what = switch (b.kind) {
                .uniform, .storage_read, .storage_read_write => "buffer",
                .texture, .storage_texture => "texture",
                .sampler, .comparison_sampler => "sampler",
            };
            try out.print(gpa, " [[{s}({d})]]", .{ what, k });
        }
        rest = rest[at + fake.len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSliceSentinel(gpa, 0);
}

test "naga: slots are flat per kind, in group and binding order" {
    const gl = comptime glslSlots(sample);
    try testing.expectEqual(0, comptime slotOf(gl, 0, 0)); // uniform 0
    try testing.expectEqual(0, comptime slotOf(gl, 1, 0)); // storage 0
    try testing.expectEqual(0, comptime slotOf(gl, 1, 1)); // image 0
    const mt = comptime mslSlots(sample);
    try testing.expectEqual(1, comptime slotOf(mt, 1, 0)); // buffer 1, after params
    try testing.expectEqual(1, comptime slotOf(mt, 1, 1)); // texture 1, after tex
    try testing.expectEqual(2, comptime mslSizesSlot(sample));
}

test "naga: GLSL storage blocks get their binding" {
    const out = comptime glsl(sample, "layout(std430) readonly buffer type_block_1Fragment { vec4 _group_1_binding_0_fs[]; };\nuniform highp sampler2D _group_0_binding_1_fs;\n");
    try testing.expectEqualStrings("layout(std430, binding = 0) readonly buffer type_block_1Fragment { vec4 _group_1_binding_0_fs[]; };\nuniform highp sampler2D _group_0_binding_1_fs;\n", out);
    try testing.expectEqualStrings("Params_block_0Fragment", (comptime glslBlocks("layout(std140) uniform Params_block_0Fragment { Params _group_0_binding_0_fs; };", "_group_0_binding_0_fs"))[0]);
}

test "naga: HLSL samplers leave the heap, line endings kept" {
    const out = comptime hlsl("a\r\nSamplerState nagaSamplerHeap[2048]: register(s0, space0);\r\nStructuredBuffer<uint> nagaGroup1SamplerIndexArray : register(t0, space255);\r\nstatic const SamplerState s = nagaSamplerHeap[nagaGroup1SamplerIndexArray[3]];\r\nb\r\n");
    try testing.expectEqualStrings("a\r\nSamplerState s : register(s3, space1);\r\nb\r\n", out);
}

test "naga: MSL parameters get their slots, renamed ones too" {
    const out = comptime msl(sample, ", constant metal::float4& params [[user(fake0)]]\n, metal::texture2d<float> tex [[user(fake0)]]\n, metal::sampler smp [[user(fake0)]]\n, device type_4 const& data_ [[user(fake0)]]\n, constant _mslBufferSizes& _buffer_sizes [[user(fake0)]]\n");
    try testing.expectEqualStrings(", constant metal::float4& params [[buffer(0)]]\n, metal::texture2d<float> tex [[texture(0)]]\n, metal::sampler smp [[sampler(0)]]\n, device type_4 const& data_ [[buffer(1)]]\n, constant _mslBufferSizes& _buffer_sizes [[buffer(2)]]\n", out);
}

test "naga: the committed translations of the repository's shaders all resolve" {
    const textured = comptime reflect.parse(@embedFile("textured.wgsl"));
    _ = comptime msl(textured, @embedFile("../shaders/gen/gpu_textured.metal"));
    _ = comptime hlsl(@embedFile("../shaders/gen/gpu_textured.hlsl"));
    const fill = comptime reflect.parse(@embedFile("fill.wgsl"));
    const m = comptime msl(fill, @embedFile("../shaders/gen/gpu_fill.metal"));
    try testing.expect(std.mem.indexOf(u8, m, "fake") == null);
    try testing.expect(std.mem.indexOf(u8, comptime glsl(fill, @embedFile("../shaders/gen/gpu_fill.main.comp")), "binding = 0) buffer") != null);
}

test "naga: the run-time GLSL patch and block names are the comptime ones" {
    const gpa = testing.allocator;
    inline for (.{
        .{ "textured.wgsl", "../shaders/gen/gpu_textured.vs.vert", "../shaders/gen/gpu_textured.fs.frag" },
        .{ "fill.wgsl", "../shaders/gen/gpu_fill.main.comp", "../shaders/gen/gpu_fill.main.comp" },
    }) |f| {
        const m = comptime reflect.parse(@embedFile(f[0]));
        var scratch: [m.bindings.len]reflect.Binding = undefined;
        var table: [m.bindings.len]Slot = undefined;
        const t = slotsInto(m, true, true, &scratch, &table);
        try testing.expectEqualSlices(Slot, comptime glslSlots(m), t);
        inline for (.{ f[1], f[2] }) |text_path| {
            const src = @embedFile(text_path);
            const got = try glslAlloc(gpa, t, src);
            defer gpa.free(got);
            try testing.expectEqualStrings(comptime glsl(m, src), got);
            inline for (m.bindings) |b| inline for (.{ "vs", "fs", "cs" }) |stage| {
                const name = std.fmt.comptimePrint("_group_{d}_binding_{d}_{s}", .{ b.group, b.binding, stage });
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(gpa);
                try glslBlocksInto(gpa, src, name, &names);
                const want = comptime glslBlocks(src, name);
                try testing.expectEqual(want.len, names.items.len);
                for (want, names.items) |w, g| try testing.expectEqualStrings(w, g);
            };
        }
    }
}

test "naga: the run-time MSL patch is the comptime one" {
    const gpa = testing.allocator;
    inline for (.{ .{ "textured.wgsl", "../shaders/gen/gpu_textured.metal" }, .{ "fill.wgsl", "../shaders/gen/gpu_fill.metal" } }) |f| {
        const m = comptime reflect.parse(@embedFile(f[0]));
        var scratch: [m.bindings.len]reflect.Binding = undefined;
        var table: [m.bindings.len]Slot = undefined;
        const t = slotsInto(m, false, false, &scratch, &table);
        try testing.expectEqualSlices(Slot, comptime mslSlots(m), t);
        const got = try mslAlloc(gpa, m, t, @embedFile(f[1]));
        defer gpa.free(got);
        try testing.expectEqualStrings(comptime msl(m, @embedFile(f[1])), got);
        try testing.expectEqual(comptime mslSizesSlot(m), mslSizesSlotIn(m));
        inline for (comptime mslSized(m), 0..) |b, k| try testing.expectEqual(@as(?u32, k), mslSizedIndex(m, b.group, b.binding));
    }
}

test "naga: the run-time HLSL patch is the comptime one" {
    const gpa = testing.allocator;
    inline for (.{ "../shaders/gen/gpu_textured.hlsl", "../shaders/gen/gpu_fill.hlsl", "../shaders/gen/gpu_gradient.hlsl" }) |f| {
        const got = try hlslAlloc(gpa, @embedFile(f));
        defer gpa.free(got);
        try testing.expectEqualStrings(comptime hlsl(@embedFile(f)), got);
    }
}
