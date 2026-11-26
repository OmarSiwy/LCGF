//! The reference for the bindings' gate (bindings/check/run.sh): a UI run frame by frame in Zig,
//! its draw lists written in the dump format the C++ and Rust checks write too. Equal files
//! mean the three languages drew the same frames.
//!
//!   lcgf-dump <toolbar|mixer|panel|counter> <comptime|seam> <inputs.txt> <out.bin>
//!   lcgf-dump <toolbar|mixer|panel|counter> <comptime|seam> <inputs.txt> --bench   (ns per frame)
//!   lcgf-dump sizes
//!
//! `comptime` runs `ComptimeUi` (the spec unrolled by the Zig compiler, no seam). `seam` runs
//! the same tables through the prebuilt frame. `counter` is examples/markup's HTML page:
//! `comptime` its Zig spec-frontend module, `seam` the `.zon` lcgf-gen lowers it to, expanded
//! and planned here at run time as lcgf-gen does for C++ and Rust. Inputs are one frame per line on an 800 x 600
//! viewport: `x y buttons [tabs]` (pointer in logical pixels, buttons as bits, Tab presses),
//! or `set <field> <value>` to write a u32 or enum field of the panel before the next frame.

const std = @import("std");
const lcgf = @import("lcgf");
const base = lcgf.widgets_base;
const seam = lcgf.abi_seam;
const zon = lcgf.abi_zon;
const Input = lcgf.input.Input;
const DrawList = lcgf.draw_list.DrawList;

const Toolbar = base.Reference(.default);
const MixerUi = base.ComptimeUi(zon.MixerState, zon.mixer_spec, .default);
const PanelUi = base.ComptimeUi(zon.PanelState, zon.panel_spec, .default);
const counter_ui = @import("counter_ui");
const counter_zon: zon.ZSpec = @import("counter_zon");

/// Each UI twice: through the Zig compiler and through the seam.
const Uis = struct {
    var toolbar_ct: Toolbar.Ui = .{};
    var mixer_ct: MixerUi = .{};
    var panel_ct: PanelUi = .{};
    var toolbar_seam: seam.SeamUi(Toolbar.State, Toolbar.spec, .default) = .{};
    var mixer_seam: seam.SeamUi(zon.MixerState, zon.mixer_spec, .default) = .{};
    var panel_seam: seam.SeamUi(zon.PanelState, zon.panel_spec, .default) = .{};
    var counter_ct: counter_ui.Ui = .{};
    var counter_seam: *seam.Ui = undefined;
    var counter_state: []u8 = undefined;
    var counter_fields: []const lcgf.abi_plan.Field = &.{};
};

/// `set <field> <value>` on the counter page, both ways: an f32 or u32 field.
fn setCounter(field: []const u8, value: u32) !void {
    const f = for (Uis.counter_fields) |f| {
        if (std.mem.eql(u8, f.name, field)) break f;
    } else return error.UnknownField;
    const at = Uis.counter_state[f.offset..][0..4];
    if (std.mem.eql(u8, field, "count")) {
        const v: f32 = @floatFromInt(value);
        Uis.counter_ct.signals.set(.count, v);
        at.* = std.mem.toBytes(v);
        return;
    }
    if (std.mem.eql(u8, field, "clicks")) {
        Uis.counter_ct.signals.set(.clicks, value);
        at.* = std.mem.toBytes(value);
        return;
    }
    return error.UnknownField;
}

const Which = enum { toolbar, mixer, panel, counter };

/// The counter page's tables and state struct, from its `.zon` (strings point into it).
fn counterInit(arena: std.mem.Allocator) !void {
    const x = try zon.expand(arena, counter_zon);
    const words = try zon.tables(arena, &x);
    const buf = try arena.alignedAlloc(u8, .fromByteUnits(lcgf.mem.column_align), try seam.Ui.bytes(words));
    Uis.counter_seam = try seam.Ui.init(words, buf);
    const st = lcgf.abi_plan.layoutState(x.fields);
    Uis.counter_fields = x.fields;
    Uis.counter_state = try arena.alignedAlloc(u8, .@"16", st.size);
    for (counter_zon.state, x.fields) |z, f| {
        const at = Uis.counter_state[f.offset..];
        if (z.str) |v| {
            @memcpy(at[0..@sizeOf(usize)], std.mem.asBytes(&@intFromPtr(v.ptr)));
            @memcpy(at[@sizeOf(usize)..][0..@sizeOf(usize)], std.mem.asBytes(&v.len));
        } else if (z.bool) |v| {
            at[0] = @intFromBool(v);
        } else if (z.f32) |v| {
            @memcpy(at[0..4], std.mem.asBytes(&v));
        } else if (z.u32) |v| @memcpy(at[0..4], std.mem.asBytes(&v)) else return error.UnknownField;
    }
}

const Frame = struct { draw: *const DrawList, widget: u32, focus: u32, wake: f32 };

/// One frame of `which`, either way.
fn frame(which: Which, via_seam: bool, in: *const Input) Frame {
    if (via_seam) {
        const o = switch (which) {
            .toolbar => Uis.toolbar_seam.frame(in),
            .mixer => Uis.mixer_seam.frame(in),
            .panel => Uis.panel_seam.frame(in),
            .counter => Uis.counter_seam.frame(Uis.counter_state.ptr, in),
        };
        return .{ .draw = o.draw, .widget = o.widget, .focus = o.focus, .wake = o.wake };
    }
    return switch (which) {
        inline else => |w| blk: {
            const ui = switch (w) {
                .toolbar => &Uis.toolbar_ct,
                .mixer => &Uis.mixer_ct,
                .panel => &Uis.panel_ct,
                .counter => &Uis.counter_ct,
            };
            const E = @TypeOf(ui.*).Events;
            const o = ui.frame(in);
            break :blk .{ .draw = o.draw, .widget = slotOf(E, o.event), .focus = focusSlot(E, ui.focus), .wake = o.wake };
        },
    };
}

/// `set <field> <value>` on the panel's state, both ways.
fn set(field: []const u8, value: u32) !void {
    if (std.mem.eql(u8, field, "len")) {
        Uis.panel_ct.signals.state.len = value;
        Uis.panel_seam.state.len = value;
    } else if (std.mem.eql(u8, field, "mode")) {
        Uis.panel_ct.signals.state.mode = @fromBackingInt(@as(u8, @intCast(value)));
        Uis.panel_seam.state.mode = @fromBackingInt(@as(u8, @intCast(value)));
    } else return error.UnknownField;
}

const Line = union(enum) { frame: Input, set: struct { field: []const u8, value: u32 } };

const tab: [1]Input.Event = .{.{ .kind = .press, .code = 0x2b }};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const which_name = args.next() orelse return error.Usage;
    if (std.mem.eql(u8, which_name, "sizes")) {
        // RAM per UI: ComptimeUi's value against the seam's buffer plus the state struct.
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "toolbar: ComptimeUi {d} B, seam {d} B; mixer: ComptimeUi {d} B, seam {d} B; panel: ComptimeUi {d} B, seam {d} B\n", .{
            @sizeOf(Toolbar.Ui), @sizeOf(@TypeOf(Uis.toolbar_seam)), @sizeOf(MixerUi), @sizeOf(@TypeOf(Uis.mixer_seam)), @sizeOf(PanelUi), @sizeOf(@TypeOf(Uis.panel_seam)),
        });
        _ = std.os.linux.write(1, line.ptr, line.len);
        return;
    }
    const which = std.meta.stringToEnum(Which, which_name) orelse return error.Usage;
    const via_seam = std.mem.eql(u8, args.next() orelse return error.Usage, "seam");
    const inputs = try std.Io.Dir.cwd().readFileAlloc(io, args.next() orelse return error.Usage, arena, .limited(1 << 20));
    const out_path = args.next() orelse return error.Usage;
    try Uis.toolbar_seam.init();
    try Uis.mixer_seam.init();
    try Uis.panel_seam.init();
    try counterInit(arena);

    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.tokenizeScalar(u8, inputs, '\n');
    while (it.next()) |text| {
        var f = std.mem.tokenizeAny(u8, text, " \t\r");
        const first = f.next() orelse continue;
        if (std.mem.eql(u8, first, "set")) {
            const field = f.next() orelse return error.BadLine;
            try lines.append(arena, .{ .set = .{ .field = field, .value = try std.fmt.parseInt(u32, f.next() orelse return error.BadLine, 10) } });
            continue;
        }
        const x = try std.fmt.parseFloat(f32, first);
        const y = try std.fmt.parseFloat(f32, f.next() orelse return error.BadLine);
        const buttons = try std.fmt.parseInt(u8, f.next() orelse return error.BadLine, 10);
        const tabs = if (f.next()) |t| try std.fmt.parseInt(u8, t, 10) else 0;
        try lines.append(arena, .{ .frame = .{ .viewport = .{ 800, 600 }, .pointer = .{ x, y }, .buttons = @bitCast(buttons), .events = if (tabs > 0) &tab else &.{} } });
    }
    if (std.mem.eql(u8, out_path, "--bench")) {
        // Bench: every pass replays the inputs; the sink keeps the frames from being dropped.
        var sink: u32 = 0;
        var n: usize = 0;
        const passes = 200;
        const t0 = now();
        for (0..passes) |_| for (lines.items) |*l| switch (l.*) {
            .frame => |*in| {
                sink +%= frame(which, via_seam, in).draw.quad_len;
                n += 1;
            },
            .set => {},
        };
        const ns = now() - t0;
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{s} {s}: {d:.0} ns/frame (sink {d})\n", .{ which_name, if (via_seam) "seam" else "comptime", @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n)), sink });
        _ = std.os.linux.write(1, line.ptr, line.len);
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    for (lines.items) |*l| switch (l.*) {
        .set => |s| switch (which) {
            .panel => try set(s.field, s.value),
            .counter => try setCounter(s.field, s.value),
            else => {},
        },
        .frame => |*in| try dump(arena, &out, frame(which, via_seam, in)),
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn slotOf(comptime E: type, event: ?E.Event) u32 {
    const e = event orelse return seam.none_widget;
    return slotOfRow(E, @backingInt(std.meta.activeTag(e)));
}

fn focusSlot(comptime E: type, w: ?E.Widget) u32 {
    return slotOfRow(E, @backingInt(w orelse return seam.none_widget));
}

fn slotOfRow(comptime E: type, row: anytype) u32 {
    for (E.widget_nodes, 0..) |n, k| if (n == row) return @intCast(k);
    unreachable;
}

/// The dump format: per frame, the counts and bytes of quads, runs, strings, commands and
/// custom draws, then the event's widget slot, the focused slot and the wake time (f32 bits).
/// bindings/cpp/check/check.cpp and bindings/rust/lcgf-check write the same.
fn dump(gpa: std.mem.Allocator, out: *std.ArrayList(u8), f: Frame) !void {
    const d = f.draw;
    const u32s = struct {
        fn put(g: std.mem.Allocator, o: *std.ArrayList(u8), v: u32) !void {
            try o.appendSlice(g, std.mem.asBytes(&v));
        }
    };
    try u32s.put(gpa, out, d.quad_len);
    try out.appendSlice(gpa, std.mem.sliceAsBytes(d.quads[0..d.quad_len]));
    try u32s.put(gpa, out, d.run_len);
    try out.appendSlice(gpa, std.mem.sliceAsBytes(d.runs[0..d.run_len]));
    try u32s.put(gpa, out, @intCast(d.strings.len));
    try out.appendSlice(gpa, d.strings);
    try u32s.put(gpa, out, d.cmd_len);
    for (0..d.cmd_len) |i| {
        try u32s.put(gpa, out, d.cmd.kind[i]);
        try u32s.put(gpa, out, d.cmd.first[i]);
        try u32s.put(gpa, out, d.cmd.count[i]);
        try u32s.put(gpa, out, d.cmd.key[i]);
    }
    try u32s.put(gpa, out, d.custom_len);
    try out.appendSlice(gpa, std.mem.sliceAsBytes(d.customs[0..d.custom_len]));
    try u32s.put(gpa, out, f.widget);
    try u32s.put(gpa, out, f.focus);
    try u32s.put(gpa, out, @bitCast(f.wake));
}
