//! counted, written by hand: list markers counted from the copy index inside run-time regions,
//! from the list's start in upper-roman, and down from the item count in a reversed list.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.col(.{ .role = .list }, .{lcgf.ct_interop.region(.each_items, .{ .size = .{ .px(300), .px(80) } })}),
    s.col(.{ .role = .list }, .{lcgf.ct_interop.region(.each_steps, .{ .size = .{ .px(300), .px(80) } })}),
});

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

const Item = struct { name: []const u8 };

/// The items parity.zig gives both frontends' regions.
pub const Sample = struct {
    items: [2]Item = .{ .{ .name = "a" }, .{ .name = "b" } },
    steps: [3]Item = .{ .{ .name = "x" }, .{ .name = "y" }, .{ .name = "z" } },

    pub fn data(x: *Sample) struct { items: []const Item, steps: []const Item } {
        return .{ .items = &x.items, .steps = &x.steps };
    }
};

fn has(d: *const lcgf.draw_list.DrawList, text: []const u8) bool {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return true;
    return false;
}

/// The markers each copy draws: III. and IV. from start 3; 3. 2. 1. down from three items.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var sample: Sample = .{};
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, sample.data());
    for ([_][]const u8{ "III. ", "IV. ", "3. ", "2. ", "1. " }) |m| try std.testing.expect(has(out.draw, m));
    try std.testing.expect(!has(out.draw, "V. ") and !has(out.draw, "4. "));
}
