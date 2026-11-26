//! The Zig side of the static UIs' gate (bindings/check/run.sh): the comptime examples
//! (src/comptime/examples.zig) through Zig's comptime pipeline, `ct_layout.Layout` and
//! `ct_paint.Paint`, over a sequence of viewports and label texts. C++ (`lcgf::StaticUi`) and
//! Rust (`lcgf::StaticUi`) run the same frames over the tables lcgf-gen --static made from the
//! examples' `.zon` (src/abi/testdata/static/); the dumps must be byte-identical.
//!
//!   lcgf-ct-dump <mixer|card|settings|badge|dash|todo|feed|controls|palette|meter> <frames> <out.bin|--bench>
//!   lcgf-ct-dump <mixer|dash|todo|palette|meter> <frames> <out.bin> partial
//!
//! `partial` replays ct_layout's `relayout` and ct_paint's `Patches`: frame f is a full frame
//! (`runLiveText`, `rebuildLiveText`) when f mod 4 is 0; when it is 1 or 2, one string field a
//! label shows changes (the `(f / 4 + f mod 4)`-th of them) and only it is laid out again
//! (`relayout`, then `rebuildLiveText`); when it is 3, only the colour fields change
//! (`colorFor`) and are patched in (`apply`) after the dirty set is cleared. Per frame: the draw
//! list, then one byte per quad of the dirty set.
//!
//! Frame f: a viewport of (40 + 37f mod 761 + f mod 4 / 4) x (30 + 23f mod 571) px, and the
//! state `ct.stateFor` makes for frame f over `texts` (labels, list counts, conditions, choices
//! and scroll offsets all change). Per frame the dump holds the quads, the text runs, the
//! strings and the commands, each after its count (u32). `<out.bin>.events` holds, per frame,
//! the frame's input through ct_events (`pointerOf`, `leftDown`, Tab): the event's widget row
//! (or 0xffffffff) and value bits, and the focused widget's row (or 0xffffffff).

const std = @import("std");
const lcgf = @import("lcgf");
const ct = lcgf.abi_ct;

pub const texts = [_][]const u8{ "", "Mixer", "Battery 82%", "x", "a much longer label than its box", "Settings", "0123456789" };

pub fn viewport(f: u32) [2]f32 {
    const w: f32 = @floatFromInt(40 + (f * 37) % 761);
    const q: f32 = @floatFromInt(f % 4);
    const h: f32 = @floatFromInt(30 + (f * 23) % 571);
    return .{ w + q / 4, h };
}

/// Frame f's input: the pointer stepping over the top-left 155 x 56 px (where the examples'
/// widgets are) once every 6 frames and moving 1 px a frame in between, the left button held
/// the first 3 frames of each 6 (so a press and its release land on the same widget), and a Tab
/// press every 5th frame, with Shift on every third of them.
pub fn pointerOf(f: u32) [2]f32 {
    const step = f / 6;
    return .{ @as(f32, @floatFromInt((step * 11) % 150 + f % 6)) + 0.25, @as(f32, @floatFromInt((step * 5) % 56)) + 0.25 };
}
pub fn leftDown(f: u32) bool {
    return f % 6 < 3;
}

fn put(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(arena, std.mem.asBytes(&v));
}

pub fn dumpDraw(arena: std.mem.Allocator, out: *std.ArrayList(u8), d: *const lcgf.draw_list.DrawList) !void {
    try put(arena, out, d.quad_len);
    try out.appendSlice(arena, std.mem.sliceAsBytes(d.quads[0..d.quad_len]));
    try put(arena, out, d.run_len);
    try out.appendSlice(arena, std.mem.sliceAsBytes(d.runs[0..d.run_len]));
    try put(arena, out, @intCast(d.strings.len));
    try out.appendSlice(arena, d.strings);
    try put(arena, out, d.cmd_len);
    try out.appendSlice(arena, d.cmd.kind[0..d.cmd_len]);
    try out.appendSlice(arena, std.mem.sliceAsBytes(d.cmd.first[0..d.cmd_len]));
    try out.appendSlice(arena, std.mem.sliceAsBytes(d.cmd.count[0..d.cmd_len]));
    try out.appendSlice(arena, std.mem.sliceAsBytes(d.cmd.key[0..d.cmd_len]));
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const name = args.next() orelse return error.Usage;
    const frames = try std.fmt.parseInt(u32, args.next() orelse return error.Usage, 10);
    const out_path = args.next() orelse return error.Usage;
    const partial = if (args.next()) |a| std.mem.eql(u8, a, "partial") else false;
    inline for (ct.static_examples) |e| if (std.mem.eql(u8, e.name, name)) {
        if (partial) return runPartial(e, init.io, arena, frames, out_path);
        return run(e, init.io, arena, frames, out_path);
    };
    return error.UnknownUi;
}

fn run(comptime e: anytype, io: std.Io, arena: std.mem.Allocator, frames: u32, out_path: []const u8) !void {
    const L = lcgf.ct_layout.Layout(e.spec, e.options);
    const P = lcgf.ct_paint.Paint(e.spec, e.options);
    const Pt = ct.Patched(e);
    var dirty: P.Dirty = .empty;
    const nodes = comptime ct.nodesOf(e.State, e.spec);
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;
    const dbuf = try arena.alignedAlloc(u8, .fromByteUnits(lcgf.mem.column_align), 1 << 16);
    var carver: lcgf.mem.Carver = .{ .buf = dbuf };
    var d = lcgf.draw_list.DrawList.init(&carver, P.quad_count, P.label_count, 0);
    var spans_buf: [@max(L.label_count, 1)]lcgf.strings.Span = undefined;
    const spans = spans_buf[0..L.label_count];
    var strings: [ct.default_string_cap]u8 = undefined;
    const E = lcgf.events.Events(e.spec);
    var ptr: E.Pointer = .{};
    var focus: ?E.Widget = null;
    const bench = std.mem.eql(u8, out_path, "--bench");
    var out: std.ArrayList(u8) = .empty;
    var events: std.ArrayList(u8) = .empty;
    const reps: u32 = if (bench) 50 else 1;
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..frames) |fi| {
            const f: u32 = @intCast(fi);
            const state = ct.stateFor(e.State, f, &texts);
            // The labels' text, gathered in label order as the static UI's frame does.
            const at = ct.gatherText(e.State, &nodes, &state, &strings, spans);
            const sel = L.Regions.select(e.State, &state);
            L.runLiveText(&scratch, &ram, viewport(f), sel, spans, lcgf.protocol.Mono{});
            Pt.rebuildLiveText(&state, &ram, sel, spans, strings[0..at], &d, &dirty);
            if (!bench) {
                try dumpDraw(arena, &out, &d);
                var row: u32 = lcgf.types.none;
                var value: f32 = 0;
                var focused: u32 = lcgf.types.none;
                if (comptime E.widget_count > 0) {
                    // The widgets' visible rects in the UI's coordinate type, as ct_events reads them.
                    var r: E.Rects = .{};
                    for (0..4) |side| for (E.widget_nodes, 0..) |node, w| {
                        r.c[side][w] = f32Of(ram.vis[side][L.Cols.slot(node)]);
                    };
                    const keys = [_]lcgf.input.Input.Event{.{ .kind = .press, .code = 0x2b, .mods = .{ .shift = f % 15 == 5 } }};
                    const in: lcgf.input.Input = .{ .pointer = pointerOf(f), .buttons = .{ .left = leftDown(f) }, .events = if (f % 5 == 0) &keys else &.{} };
                    if (E.pointer(&ptr, &r, &in)) |ev| switch (ev) {
                        inline else => |payload, tag| {
                            row = @backingInt(tag);
                            if (@TypeOf(payload) == f32) value = payload;
                        },
                    };
                    E.focusKeys(&focus, &in, 0x2b);
                    if (focus) |w| focused = @backingInt(w);
                }
                try put(arena, &events, row);
                try put(arena, &events, @bitCast(value));
                try put(arena, &events, focused);
            }
        }
        const ns: u64 = @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
        best = @min(best, ns);
    }
    if (bench) {
        std.debug.print("ct {s:<9} zig     {d:>7} ns/frame\n", .{ e.name, best / frames });
        return benchEngine(e, io, arena, frames);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}.events", .{out_path}), .data = events.items });
}

/// The same frames through the static UI's engine (src/abi/ct.zig) in this process: the words
/// made here, the state laid out as C lays it out. Not a gate: it shows the engine's cost apart
/// from the seam.
fn benchEngine(comptime e: anytype, io: std.Io, arena: std.mem.Allocator, frames: u32) !void {
    const words = try ct.wordsOf(arena, e);
    const fields = try arena.dupe(lcgf.abi_plan.Field, &comptime lcgf.abi_plan.fieldsOf(e.State));
    const st = lcgf.abi_plan.layoutState(fields);
    const buf = try arena.alignedAlloc(u8, .fromByteUnits(lcgf.mem.column_align), try ct.Ui.bytes(words));
    const ui = try ct.Ui.init(words, buf);
    const cstate = try arena.alignedAlloc(u8, .@"8", @max(st.size, 1));
    var best: u64 = std.math.maxInt(u64);
    for (0..50) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..frames) |fi| {
            const f: u32 = @intCast(fi);
            const state = ct.stateFor(e.State, f, &texts);
            ct.cStateOf(e.State, &state, fields, cstate);
            std.mem.doNotOptimizeAway(ui.frame(cstate.ptr, viewport(f)));
        }
        const ns: u64 = @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
        best = @min(best, ns);
    }
    std.debug.print("ct {s:<9} engine  {d:>7} ns/frame\n", .{ e.name, best / frames });
}

fn f32Of(x: anytype) f32 {
    return if (@TypeOf(x) == f32) x else @floatFromInt(x);
}

/// The string fields the labels of `e` show, in field order.
fn labelFields(comptime e: anytype) []const u32 {
    comptime {
        const nodes = ct.nodesOf(e.State, e.spec);
        var out: []const u32 = &.{};
        for (0..@typeInfo(e.State).@"struct".field_names.len) |k| {
            for (nodes) |nd| if (nd.labelShows(k)) {
                out = out ++ [_]u32{k};
                break;
            };
        }
        return out;
    }
}

fn runPartial(comptime e: anytype, io: std.Io, arena: std.mem.Allocator, frames: u32, out_path: []const u8) !void {
    const L = lcgf.ct_layout.Layout(e.spec, e.options);
    const P = lcgf.ct_paint.Paint(e.spec, e.options);
    const Field = std.meta.FieldEnum(e.State);
    const names = @typeInfo(e.State).@"struct".field_names;
    const Pt = ct.Patched(e);
    const nodes = comptime ct.nodesOf(e.State, e.spec);
    const labels = comptime labelFields(e);
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;
    const dbuf = try arena.alignedAlloc(u8, .fromByteUnits(lcgf.mem.column_align), 1 << 16);
    var carver: lcgf.mem.Carver = .{ .buf = dbuf };
    var d = lcgf.draw_list.DrawList.init(&carver, P.quad_count, P.label_count, 0);
    var spans_buf: [@max(L.label_count, 1)]lcgf.strings.Span = undefined;
    const spans = spans_buf[0..L.label_count];
    var strings: [ct.default_string_cap]u8 = undefined;
    var dirty: P.Dirty = .empty;
    var state: e.State = .{};
    var sel: L.Regions.Selection = undefined;
    var out: std.ArrayList(u8) = .empty;
    for (0..frames) |fi| {
        const f: u32 = @intCast(fi);
        if (f % 4 == 3) {
            dirty = .empty;
            inline for (names, 0..) |name, k| if (@FieldType(e.State, name) == lcgf.types.Color) {
                @field(state, name) = @bitCast(ct.colorFor(f, k));
                Pt.apply(@field(Field, name), &state, &ram, &d, &dirty);
            };
        } else {
            if (f % 4 == 0) state = ct.stateFor(e.State, f, &texts) else if (labels.len > 0) {
                const j = labels[(f / 4 + f % 4) % labels.len];
                // The field as `stateFor` makes it this frame (a string `texts[(f + 3k) mod 7]`).
                inline for (names, 0..) |name, k| if (k == j) {
                    @field(state, name) = @field(ct.stateFor(e.State, f, &texts), name);
                };
            }
            const at = ct.gatherText(e.State, &nodes, &state, &strings, spans);
            if (f % 4 == 0) {
                sel = L.Regions.select(e.State, &state);
                L.runLiveText(&scratch, &ram, viewport(f), sel, spans, lcgf.protocol.Mono{});
            } else if (labels.len > 0) {
                const j = labels[(f / 4 + f % 4) % labels.len];
                inline for (names, 0..) |name, k| if (k == j) {
                    L.relayout(name, &scratch, &ram, spans, lcgf.protocol.Mono{});
                };
            }
            Pt.rebuildLiveText(&state, &ram, sel, spans, strings[0..at], &d, &dirty);
        }
        try dumpDraw(arena, &out, &d);
        for (0..P.quad_count) |k| try out.append(arena, @intFromBool(dirty.isSet(k)));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
}
