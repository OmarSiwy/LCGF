//! The quad shader in MSL: naga's translation of quad.wgsl, committed in
//! src/render/shaders/gen/<variant>.metal, with its resource slots assigned. naga-cli has no
//! option for a binding map, so it marks every WGSL binding `[[user(fake0)]]`, which Metal does
//! not compile; `bind` replaces those with the slots below, at compile time.
//!
//!   vertex buffer 0     Globals (`@group(0) @binding(0)`), set with setVertexBytes
//!   vertex buffer 1     the instance array (stage_in, `instance_buffer`)
//!   fragment buffer 0   Globals
//!   texture 0, sampler 0   `@group(1)` binding 0 and 1

const std = @import("std");

pub const globals_buffer = 0;
pub const instance_buffer = 1;

const slots = [_][2][]const u8{
    .{ "constant Globals& globals [[user(fake0)]]", "constant Globals& globals [[buffer(0)]]" },
    .{ "metal::texture2d<float, metal::access::sample> tex [[user(fake0)]]", "metal::texture2d<float, metal::access::sample> tex [[texture(0)]]" },
    .{ "metal::sampler samp [[user(fake0)]]", "metal::sampler samp [[sampler(0)]]" },
};

/// `src` (naga MSL of a quad.wgsl variant) with every binding at its slot. A binding left
/// unassigned is a compile error: quad.wgsl gained a resource this table does not know.
pub fn bind(comptime src: []const u8) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100 * src.len);
        var s: []const u8 = src;
        for (slots) |pair| {
            var out: [std.mem.replacementSize(u8, s, pair[0], pair[1])]u8 = undefined;
            _ = std.mem.replace(u8, s, pair[0], pair[1], &out);
            s = &out;
        }
        if (std.mem.indexOf(u8, s, "[[user(fake") != null) @compileError("msl.bind: a binding without a slot; update src/render/metal/msl.zig");
        const final = s[0..s.len].* ++ [_]u8{0};
        return final[0..s.len :0];
    }
}

/// The stock material (`Material.solid`) and the example one, as shipped.
pub const stock = bind(@embedFile("stock_metal"));
pub const example = bind(@embedFile("example_metal"));

const testing = std.testing;

test "msl: every binding of the shipped shaders gets its slot" {
    try testing.expectEqual(2, std.mem.count(u8, stock, "constant Globals& globals [[buffer(0)]]"));
    try testing.expectEqual(1, std.mem.count(u8, stock, "tex [[texture(0)]]"));
    try testing.expectEqual(1, std.mem.count(u8, stock, "samp [[sampler(0)]]"));
    try testing.expectEqual(0, std.mem.count(u8, example, "fake"));
    try testing.expect(std.mem.indexOf(u8, stock, "vertex vsOutput vs(") != null);
    try testing.expect(std.mem.indexOf(u8, stock, "fragment fsOutput fs(") != null);
}
