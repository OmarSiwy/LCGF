//! controls, written by hand: a number field with its range, and a radio group made of three
//! `<input type=radio name=size>`, captioned by their labels, the checked one the default.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const number = lcgf.widgets_number;
const radio = lcgf.widgets_radio;

pub const theme: w.Theme = .{};

pub const State = struct { qty: number.Number = .{}, size: u32 = 1 };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    number.ct.number(theme, .qty, .qty, .{ .lo = 1, .hi = 10, .step = 1 }),
    s.col(.{}, .{
        radio.ct.radio(theme, .size, .size, .{ "Small", "Medium", "Large" }),
    }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        last: u32 = 99,

        pub fn size_changed(h: *@This(), _: *Ui, value: u32) void {
            h.last = value;
        }
    };
}
