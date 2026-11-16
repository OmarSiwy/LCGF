//! The inspector's event log: what reached the UI each frame, as text lines in a fixed ring.
//! Input changes (viewport, buttons, keys, typed text, wheel, scroll, touches) come from the
//! frame's `Input`; what they did (hover and click targets) from the interaction step, which
//! `Context.begin` has already run against last frame's tree. Nothing is allocated: the ring
//! is part of the value.

const std = @import("std");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Interaction = @import("../interact/interaction.zig").Interaction;
const Tree = @import("../core/tree.zig").Tree;

pub const EventLog = struct {
    /// Lines kept; older ones are overwritten.
    pub const cap = 64;
    /// Bytes per line; longer lines are cut.
    pub const width = 56;

    text: [cap][width]u8 = undefined,
    len: [cap]u8 = @splat(0),
    /// Lines ever added; the newest is at `(count - 1) % cap`.
    count: u32 = 0,
    // What the last frame had, to log changes only.
    viewport: [2]f32 = .{ 0, 0 },
    buttons: Input.Buttons = .{},
    hot: u32 = 0,

    /// Appends one line, cut to `width`.
    pub fn add(log: *EventLog, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
        const k = log.count % cap;
        const n = @min(s.len, width);
        @memcpy(log.text[k][0..n], s[0..n]);
        log.len[k] = @intCast(n);
        log.count += 1;
    }

    /// The `k`-th newest line (0 is the newest); `k` < `kept()`.
    pub fn newest(log: *const EventLog, k: u32) []const u8 {
        const i = (log.count - 1 - k) % cap;
        return log.text[i][0..log.len[i]];
    }

    pub fn kept(log: *const EventLog) u32 {
        return @min(log.count, cap);
    }

    /// Logs what changed in frame `frame`. `prev` is the tree `inter` was stepped against,
    /// to name targets by row.
    pub fn record(log: *EventLog, frame: u32, in: *const Input, inter: *const Interaction, prev: *const Tree) void {
        if (!std.meta.eql(in.viewport, log.viewport)) log.add("{d} viewport {d:.0}x{d:.0}", .{ frame, in.viewport[0], in.viewport[1] });
        inline for (.{ "left", "right", "middle" }) |b| {
            const was = @field(log.buttons, b);
            const is = @field(in.buttons, b);
            if (is and !was) log.add("{d} press {s} at {d:.0},{d:.0}", .{ frame, b, in.pointer[0], in.pointer[1] });
            if (was and !is) log.add("{d} release {s} at {d:.0},{d:.0}", .{ frame, b, in.pointer[0], in.pointer[1] });
        }
        for (in.events) |e| switch (e.kind) {
            .text => log.add("{d} text \"{s}\"", .{ frame, in.typed(e) }),
            else => log.add("{d} key {s} {d}{s}{s}{s}{s}", .{
                frame,                              @tagName(e.kind),                 e.code,
                if (e.mods.shift) " shift" else "", if (e.mods.ctrl) " ctrl" else "", if (e.mods.alt) " alt" else "",
                if (e.mods.cmd) " cmd" else "",
            }),
        };
        if (in.wheel[0] != 0 or in.wheel[1] != 0) log.add("{d} wheel {d},{d}", .{ frame, in.wheel[0], in.wheel[1] });
        if (in.scroll[0] != 0 or in.scroll[1] != 0) log.add("{d} scroll {d},{d}", .{ frame, in.scroll[0], in.scroll[1] });
        for (in.contacts) |c| log.add("{d} {s} {d} at {d:.0},{d:.0}", .{ frame, @tagName(c.kind), c.id, c.pos[0], c.pos[1] });
        if (inter.hot != log.hot) log.target(frame, "hover", prev, inter.hot);
        if (inter.clicked != 0) log.target(frame, "click", prev, inter.clicked);
        log.viewport = in.viewport;
        log.buttons = in.buttons;
        log.hot = inter.hot;
    }

    /// "<frame> <verb> #row role" for the node with id `id` in `t`.
    fn target(log: *EventLog, frame: u32, verb: []const u8, t: *const Tree, id: u32) void {
        if (id == 0) return log.add("{d} {s} nothing", .{ frame, verb });
        const i = t.find(@fromBackingInt(@intCast(id)));
        if (i == types.none) return log.add("{d} {s} a node gone since", .{ frame, verb });
        log.add("{d} {s} #{d} {s}", .{ frame, verb, i, @tagName(@as(types.Role, @fromBackingInt(@intCast(t.c.role[i])))) });
    }
};

test "EventLog: a ring of the newest lines, cut to width" {
    var log: EventLog = .{};
    for (0..EventLog.cap + 3) |i| log.add("line {d}", .{i});
    try std.testing.expectEqual(@as(u32, EventLog.cap), log.kept());
    try std.testing.expectEqualStrings("line 66", log.newest(0));
    try std.testing.expectEqualStrings("line 3", log.newest(EventLog.cap - 1));
    const long: [100]u8 = @splat('x');
    log.add("{s}", .{&long});
    try std.testing.expectEqual(@as(usize, EventLog.width), log.newest(0).len);
}
