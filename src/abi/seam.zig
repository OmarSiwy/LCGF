//! The prebuilt frame behind the C seam: `ComptimeUi.frame` (src/widgets/base.zig) driven by
//! tables (src/abi/plan.zig) instead of by a comptime spec. A C++ or Rust program links it from
//! liblcgf and calls it once per frame. The tables come from `lcgf-gen` or, in Zig, from
//! `plan.tablesOf`. Its draw lists equal `ComptimeUi`'s for the same UI and input (the test
//! below replays the reference widgets' input through both).
//!
//! The caller owns all memory. `bytes` says how much one UI needs. `init` checks the tables
//! once and places the UI at the start of the caller's buffer, and `frame` works only in that
//! buffer. The state is the caller's struct, laid out as the tables say (`plan.Field`).
//!
//! The C names (src/abi/lcgf.h) carry what the build specialised: the index width, the
//! coordinate type and the lane count, as in `lcgf_frame_u32_f32_l8`.

const std = @import("std");
const fmt = @import("../core/fmt.zig");
const plan = @import("plan.zig");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const base = @import("../widgets/base.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const Input = @import("../core/input.zig").Input;
const draw_list = @import("../draw/draw_list.zig");
const DrawList = draw_list.DrawList;
const paint = @import("../draw/paint.zig");
const layout = @import("../layout/layout.zig");
const Mono = @import("../text/protocol.zig").Mono;
const context = @import("../runtime/context.zig");
const anims = @import("../anim/anims.zig");
const focus_mod = @import("../interact/focus.zig");
const Style = types.Style;
const none = plan.none;
/// The `widget` of a frame without an event.
pub const none_widget = plan.none;

const string_bytes = 1024;

/// The working columns one frame carves from the UI's buffer, as `ComptimeUi.Tables`.
const Columns = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    strings: Strings,
    d: DrawList,

    fn carve(carver: *mem.Carver, rows: u32, runs: u32, customs: u32) Columns {
        return .{
            .t = Tree.init(carver, rows),
            .tx = Texts.init(carver, runs),
            .cu = Customs.init(carver, customs),
            .strings = .{ .buf = carver.slice(u8, string_bytes) },
            .d = DrawList.init(carver, rows, runs, customs),
        };
    }

    fn bytes(rows: u32, runs: u32, customs: u32) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = carve(&counter, rows, runs, customs);
        return counter.off;
    }
};

/// What a frame returns: the draw list, the tree it was painted from, and the event the
/// pointer made (`widget` is a slot in widget order, `none` for no event).
pub const Output = struct { draw: *const DrawList, tree: *const Tree, widget: u32 = none, value: f32 = 0, focus: u32 = none, wake: f32 = types.inf };

pub const Ui = struct {
    tables: plan.Tables,
    rows: u32,
    runs: u32,
    customs: u32,
    pressed: u32 = none,
    down: bool = false,
    /// The focused widget (a slot), as `ComptimeUi.focus`.
    focus: u32 = none,
    /// Last frame's widget rects, x0, y0, x1, y1 columns of `widgets` rows each.
    rects: []f32,
    /// The tree row of each spec row this frame, 0 for a row a region left out.
    row_of: []u32,
    /// Springs: position, velocity and previous target, `springs` rows each.
    spring_x: []f32,
    spring_v: []f32,
    spring_t: []f32,
    work: []align(mem.column_align) u8,
    /// The theme's parts `plan.emit` adds to a row's style, decoded once.
    looks: plan.Looks,
    cols: Columns = undefined,
    font: Mono = .{},
    built: bool = false,

    pub const Error = plan.Tables.DecodeError || error{ BufferTooSmall, Unaligned };

    /// Bytes one UI of `tables` needs in the caller's buffer.
    pub fn bytes(tables: []const u32) Error!usize {
        const t = try plan.Tables.decode(tables);
        return layoutOf(&t).total;
    }

    const Layout = struct { rects: usize, row_of: usize, springs: usize, work: usize, total: usize };
    fn layoutOf(t: *const plan.Tables) Layout {
        const rects = std.mem.alignForward(usize, @sizeOf(Ui), @alignOf(f32));
        const row_of = rects + 4 * @as(usize, t.header.widgets) * @sizeOf(f32);
        const springs = row_of + @as(usize, t.header.rows) * @sizeOf(u32);
        const work = std.mem.alignForward(usize, springs + 3 * @as(usize, t.header.springs) * @sizeOf(f32), mem.column_align);
        const total = work + Columns.bytes(t.header.rows + 1, @max(t.header.runs, 1), customCap(t));
        return .{ .rects = rects, .row_of = row_of, .springs = springs, .work = work, .total = total };
    }

    /// One custom command per custom draw row, and one more, as `ComptimeUi`.
    fn customCap(t: *const plan.Tables) u32 {
        var n: u32 = 1;
        for (0..t.header.rows) |r| n += @intFromBool(t.row(@intCast(r)).op == .custom);
        return n;
    }

    /// Checks `tables` and places a UI at the start of `buf`.
    pub fn init(tables: []const u32, buf: []u8) Error!*Ui {
        const t = try plan.Tables.decode(tables);
        const l = layoutOf(&t);
        if (buf.len < l.total) return error.BufferTooSmall;
        if (@intFromPtr(buf.ptr) % mem.column_align != 0) return error.Unaligned;
        const ui: *Ui = @ptrCast(@alignCast(buf.ptr));
        const rects: [*]f32 = @ptrCast(@alignCast(buf.ptr + l.rects));
        const row_of: [*]u32 = @ptrCast(@alignCast(buf.ptr + l.row_of));
        const sp: [*]f32 = @ptrCast(@alignCast(buf.ptr + l.springs));
        const ns = t.header.springs;
        ui.* = .{
            .tables = t,
            .rows = t.header.rows + 1,
            .runs = @max(t.header.runs, 1),
            .customs = customCap(&t),
            .rects = rects[0 .. 4 * t.header.widgets],
            .row_of = row_of[0..t.header.rows],
            .spring_x = sp[0..ns],
            .spring_v = sp[ns .. 2 * ns],
            .spring_t = sp[2 * ns .. 3 * ns],
            .work = @alignCast(buf[l.work..l.total]),
            .looks = .{ .label = t.label, .fills = t.fills, .box = .{ t.style(t.box[0]), t.style(t.box[1]) } },
        };
        @memset(ui.rects, 0);
        @memset(sp[0 .. 3 * ns], 0);
        return ui;
    }

    fn rect(ui: *const Ui, side: usize, k: u32) f32 {
        return ui.rects[side * ui.tables.header.widgets + k];
    }

    /// Topmost widget under (x, y), as `Events.at`: half-open edges, the latest row wins.
    fn at(ui: *const Ui, x: f32, y: f32) u32 {
        var found: u32 = none;
        for (0..ui.tables.header.widgets) |k| {
            const kk: u32 = @intCast(k);
            const inside = x >= ui.rect(0, kk) and x < ui.rect(2, kk) and y >= ui.rect(1, kk) and y < ui.rect(3, kk);
            found = if (inside) kk else found;
        }
        return found;
    }

    /// The pointer's event, as `Events.pointer`.
    fn pointer(ui: *Ui, in: *const Input) ?struct { widget: u32, value: f32 } {
        const down = in.buttons.left;
        defer ui.down = down;
        const x = in.pointer[0];
        const y = in.pointer[1];
        if (down and !ui.down) ui.pressed = ui.at(x, y);
        const k = ui.pressed;
        if (k == none) return null;
        if (!down) ui.pressed = none;
        if (ui.tables.widget(k).kind == .slider) {
            if (!down) return null;
            const x0 = ui.rect(0, k);
            const span = ui.rect(2, k) - x0;
            return .{ .widget = k, .value = std.math.clamp((x - x0) / @max(span, std.math.floatMin(f32)), 0, 1) };
        }
        if (down or ui.at(x, y) != k) return null;
        return .{ .widget = k, .value = 0 };
    }

    fn response(ui: *const Ui, k: u32, in: *const Input) types.Response {
        const held = ui.pressed == k;
        const owned = ui.pressed == none or held;
        const under = ui.at(in.pointer[0], in.pointer[1]) == k;
        return .{ .hovered = under and owned, .held = held };
    }

    fn fieldPtr(ui: *const Ui, comptime T: type, state: [*]u8, k: u32) *T {
        return @ptrCast(@alignCast(state + ui.tables.field(k).offset));
    }

    /// A field's value as `BoundSprings.goal` reads it: f32, or a bool as 0 or 1.
    fn goal(ui: *const Ui, state: [*]u8, k: u32) f32 {
        return if (ui.tables.field(k).type == .bool) simd.b2f(ui.fieldPtr(bool, state, k).*) else ui.fieldPtr(f32, state, k).*;
    }

    /// A slider's displayed value: the spring's position when its field has one.
    fn animated(ui: *const Ui, state: [*]u8, k: u32) f32 {
        for (0..ui.tables.header.springs) |i| if (ui.tables.spring(@intCast(i)).field == k) return ui.spring_x[i];
        return ui.goal(state, k);
    }

    /// `BoundSprings.frame`: steps the previous targets, then takes this frame's.
    fn stepSprings(ui: *Ui, state: [*]u8, dt: f32, first: bool) void {
        const h = @min(dt, 1.0 / 30.0);
        for (0..ui.tables.header.springs) |i| {
            const sp = ui.tables.spring(@intCast(i));
            const next = ui.goal(state, sp.field);
            if (first) {
                ui.spring_x[i] = next;
                ui.spring_v[i] = 0;
            } else {
                const k = [1]f32{sp.stiffness};
                const d = [1]f32{sp.damping};
                const c = .{ .x = ui.spring_x[i..][0..1], .v = ui.spring_v[i..][0..1], .target = ui.spring_t[i..][0..1], .stiffness = &k, .damping = &d };
                _ = anims.stepVector(1, c, 0, h);
            }
            ui.spring_t[i] = next;
        }
    }

    fn pending(ui: *const Ui, state: [*]u8) bool {
        var active = false;
        for (0..ui.tables.header.springs) |i| {
            const g = ui.goal(state, ui.tables.spring(@intCast(i)).field);
            active = active or ui.spring_x[i] != g or ui.spring_v[i] != 0;
        }
        return active;
    }

    /// `Events.focusKeys`: Tab and Shift+Tab move focus through the focusable widgets in row
    /// order, wrapping.
    fn focusKeys(ui: *Ui, in: *const Input, tab: u8) void {
        const n = ui.tables.header.widgets;
        for (in.events) |e| {
            if (e.code != tab or (e.kind != .press and e.kind != .repeat)) continue;
            var count: u32 = 0;
            var pos: u32 = none;
            for (0..n) |k| if (ui.tables.widget(@intCast(k)).focusable) {
                if (k == ui.focus) pos = count;
                count += 1;
            };
            if (count == 0) {
                ui.focus = none;
                continue;
            }
            const back = e.mods.shift;
            const want = if (pos == none) (if (back) count - 1 else 0) else if (back) (pos + count - 1) % count else (pos + 1) % count;
            var seen: u32 = 0;
            for (0..n) |k| if (ui.tables.widget(@intCast(k)).focusable) {
                if (seen == want) ui.focus = @intCast(k);
                seen += 1;
            };
        }
    }

    /// Whether spec row `row` is live this frame: its own `when`, and its place in a `list`
    /// or `choice` parent.
    fn live(ui: *const Ui, state: [*]u8, row: plan.Row) bool {
        if (row.when != none and !ui.fieldPtr(bool, state, row.when).*) return false;
        if (row.gate == .none) return true;
        const v: u32 = if (ui.tables.field(row.gate_field).type == .u8) ui.fieldPtr(u8, state, row.gate_field).* else ui.fieldPtr(u32, state, row.gate_field).*;
        return if (row.gate == .list) row.gate_index < v else row.gate_index == v;
    }

    /// What `plan.emit` reads: the state through the tables' field offsets, and the pointer.
    const Host = struct {
        ui: *const Ui,
        state: [*]u8,
        in: *const Input,
        pub inline fn response(h: Host, _: u32, widget: u32) types.Response {
            return h.ui.response(widget, h.in);
        }
        pub inline fn flag(h: Host, k: u32) bool {
            return h.ui.fieldPtr(bool, h.state, k).*;
        }
        pub inline fn animated(h: Host, k: u32) f32 {
            return h.ui.animated(h.state, k);
        }
        pub inline fn text(h: Host, k: u32) []const u8 {
            return h.ui.str(h.state, k);
        }
        pub fn formatted(h: Host, k: u32, sink: *fmt.Sink) void {
            const tb = &h.ui.tables;
            const f = tb.format(k);
            // The text column's words hold their bytes in order on a little-endian machine.
            comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
            const chars = std.mem.sliceAsBytes(tb.words[tb.text.at..][0..tb.text.len])[f.at..][0..f.len];
            for (f.first..f.first + f.count) |i| {
                const g = tb.seg(@intCast(i));
                switch (g.kind) {
                    .literal => sink.put(chars[g.start..][0..g.len]),
                    .str => sink.put(h.ui.str(h.state, g.field)),
                    .bool => sink.putBool(h.ui.fieldPtr(bool, h.state, g.field).*),
                    .u32 => sink.putUint(h.ui.fieldPtr(u32, h.state, g.field).*),
                    .u8 => sink.putUint(h.ui.fieldPtr(u8, h.state, g.field).*),
                    .f32 => sink.putF32(h.ui.fieldPtr(f32, h.state, g.field).*, g.prec),
                }
            }
        }
    };

    fn str(ui: *const Ui, state: [*]u8, k: u32) []const u8 {
        const s = ui.fieldPtr(extern struct { ptr: ?[*]const u8, len: usize }, state, k);
        return if (s.ptr) |p| p[0..s.len] else "";
    }

    /// One frame: the pointer's event applied to the state, then every row pushed, laid out and
    /// painted, as `ComptimeUi.frame` does for the reference widgets.
    pub fn frame(ui: *Ui, state: [*]u8, in: *const Input) Output {
        var out: Output = undefined;
        out.widget = none;
        out.value = 0;
        const press = in.buttons.left and !ui.down;
        const event = ui.pointer(in);
        if (press) ui.focus = ui.pressed;
        ui.focusKeys(in, (focus_mod.Keymap{}).tab);
        if (event) |e| {
            out.widget = e.widget;
            out.value = e.value;
            const w = ui.tables.widget(e.widget);
            const field = ui.tables.row(w.row).field;
            switch (w.kind) {
                .checkbox => {
                    const v = ui.fieldPtr(bool, state, field);
                    v.* = base.toggle(v.*, true);
                },
                .slider => ui.fieldPtr(f32, state, field).* = base.slide(0, true, e.value, 0, 1),
                else => {},
            }
        }
        ui.stepSprings(state, in.dt, !ui.built);

        var carver: mem.Carver = .{ .buf = ui.work };
        ui.cols = Columns.carve(&carver, ui.rows, ui.runs, ui.customs);
        const c = &ui.cols;
        c.t.reset();
        c.tx.reset();
        c.cu.reset();
        c.strings.reset();
        _ = c.t.push(0, context.root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });

        // Rows still open, innermost last; a row is sealed when the next row is past its end.
        var open: [64]u32 = undefined;
        var depth: usize = 0;
        const tb = &ui.tables;
        @memset(ui.row_of, 0);
        var r: u32 = 0;
        while (r < tb.header.rows) {
            const row = tb.row(r);
            // A row a region leaves out is passed over with its subtree.
            const next = if (ui.live(state, row)) blk: {
                const parent = if (row.parent == 0) 0 else ui.row_of[row.parent - 1];
                const host: Host = .{ .ui = ui, .state = state, .in = in };
                const i = plan.emit(host, c, &ui.looks, r, row, tb.style(row.style), parent);
                ui.row_of[r] = i;
                if (row.sealed) {
                    open[depth] = r;
                    depth += 1;
                }
                break :blk r + 1;
            } else row.end - 1;
            while (depth > 0 and tb.row(open[depth - 1]).end <= next + 1) {
                depth -= 1;
                c.t.seal(ui.row_of[open[depth]]);
            }
            r = next;
        }
        c.t.seal(0);

        // `Frame.end`'s pass sequence.
        const t = &c.t;
        const tx = &c.tx;
        ui.font.measure(tx);
        layout.prepare(t);
        layout.applyText(t, tx, .x);
        layout.fit(t, .x);
        layout.resolve(t, .x, in.viewport[0]);
        layout.textAvail(t, tx);
        ui.font.wrap(tx);
        layout.applyText(t, tx, .y);
        layout.fit(t, .y);
        layout.resolve(t, .y, in.viewport[1]);
        layout.place(t);
        layout.finalize(t);
        paint.emit(t, tx, &c.cu, c.strings.buf[0..c.strings.len], &c.d);

        const n = tb.header.widgets;
        for (0..4) |side| {
            for (0..n) |k| {
                // A widget a region left out has no rect, so nothing hits it.
                const tr = ui.row_of[tb.widget(@intCast(k)).row];
                ui.rects[side * n + k] = if (tr != 0) t.c.vis[side][tr] else 0;
            }
        }
        ui.built = true;
        out.draw = &c.d;
        out.tree = t;
        out.focus = ui.focus;
        out.wake = simd.selF(ui.pending(state), 0, types.inf);
        return out;
    }
};

// ---- the C seam (src/abi/lcgf.h) ------------------------------------------------------------

/// The input a host passes: the fields the reference widgets read.
pub const CInput = extern struct {
    viewport: [2]f32 = .{ 800, 600 },
    pointer: [2]f32 = Input.outside,
    dt: f32 = 1.0 / 60.0,
    scale: f32 = 1,
    /// Bit 0 left, 1 right, 2 middle.
    buttons: u32 = 0,
    /// Bit 0 shift, 1 ctrl, 2 alt, 3 cmd.
    mods: u32 = 0,
    /// Key presses this frame, in order (`Input.Event`, 12 bytes each); Tab moves focus.
    events: ?[*]const Input.Event = null,
    events_len: u32 = 0,

    pub fn input(c: *const CInput) Input {
        return .{
            .viewport = c.viewport,
            .pointer = c.pointer,
            .dt = c.dt,
            .scale = c.scale,
            .buttons = @bitCast(@as(u8, @truncate(c.buttons))),
            .mods = @bitCast(@as(u8, @truncate(c.mods))),
            .events = if (c.events) |e| e[0..c.events_len] else &.{},
        };
    }
};

/// A frame's draw list as columns, for C, C++ and Rust to read in place.
pub const CDraw = extern struct {
    quads: [*]const draw_list.Quad,
    quad_len: u32,
    run_len: u32,
    runs: [*]const draw_list.TextRun,
    strings: [*]const u8,
    strings_len: usize,
    cmd_kind: [*]const u8,
    cmd_first: [*]const u32,
    cmd_count: [*]const u32,
    cmd_key: [*]const u32,
    cmd_len: u32,
    custom_len: u32,
    customs: [*]const draw_list.CustomDraw,
};

pub const CFrame = extern struct {
    draw: CDraw,
    /// Widget slot of the event, or 0xffffffff.
    widget: u32,
    value: f32,
    /// The focused widget's slot, or 0xffffffff.
    focus: u32,
    /// Seconds until the UI needs a frame though nothing happened: 0 while a spring moves,
    /// infinity at rest.
    wake: f32,
};

pub fn cDraw(d: *const DrawList) CDraw {
    return .{
        .quads = d.quads.ptr,
        .quad_len = d.quad_len,
        .run_len = d.run_len,
        .runs = d.runs.ptr,
        .strings = d.strings.ptr,
        .strings_len = d.strings.len,
        .cmd_kind = d.cmd.kind.ptr,
        .cmd_first = d.cmd.first.ptr,
        .cmd_count = d.cmd.count.ptr,
        .cmd_key = d.cmd.key.ptr,
        .cmd_len = d.cmd_len,
        .custom_len = d.custom_len,
        .customs = d.customs.ptr,
    };
}

/// Result codes of the C functions: 0 is success.
pub const Status = enum(c_int) { ok = 0, not_tables = 1, version = 2, layout_hash = 3, truncated = 4, buffer_too_small = 5, unaligned = 6 };

fn status(e: Ui.Error) Status {
    return switch (e) {
        error.NotTables => .not_tables,
        error.Version => .version,
        error.LayoutHash => .layout_hash,
        error.Truncated => .truncated,
        error.BufferTooSmall => .buffer_too_small,
        error.Unaligned => .unaligned,
    };
}

/// The exported names, specialised as this build is: 32-bit rows, f32 coordinates, and the
/// lane count of `simd`.
pub const frame_symbol = std.fmt.comptimePrint("lcgf_frame_u32_f32_l{d}", .{simd.lanes});

/// The C functions, by the names lcgf.h declares. `exportAll` exports them; liblcgf_auto's
/// dispatcher (src/abi/auto.zig) routes the same names to one lane width's copy.
pub const exports = .{
    .{ "lcgf_tables_check", &cTablesCheck },
    .{ "lcgf_ui_bytes", &cUiBytes },
    .{ "lcgf_ui_init", &cUiInit },
    .{ frame_symbol, &cFrame },
    .{ "lcgf_layout_hash", &cLayoutHash },
};

/// Exports the seam's functions. A library's root calls it once, so a program that only imports
/// lcgf does not export them.
pub fn exportAll() void {
    inline for (0..exports.len) |k| @export(exports[k][1], .{ .name = exports[k][0] ++ plan.symbol_suffix });
}

fn cTablesCheck(words: [*]const u32, len: usize) callconv(.c) c_int {
    _ = plan.Tables.decode(words[0..len]) catch |e| return @backingInt(status(e));
    return 0;
}

fn cUiBytes(words: [*]const u32, len: usize) callconv(.c) usize {
    return Ui.bytes(words[0..len]) catch 0;
}

fn cUiInit(words: [*]const u32, len: usize, buf: *anyopaque, buf_len: usize) callconv(.c) c_int {
    _ = Ui.init(words[0..len], @as([*]u8, @ptrCast(buf))[0..buf_len]) catch |e| return @backingInt(status(e));
    return 0;
}

fn cFrame(buf: *anyopaque, state: *anyopaque, in: *const CInput, out: *CFrame) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(buf));
    const input = in.input();
    const o = ui.frame(@ptrCast(state), &input);
    out.* = .{ .draw = cDraw(o.draw), .widget = o.widget, .value = o.value, .focus = o.focus, .wake = o.wake };
}

fn cLayoutHash() callconv(.c) u32 {
    return plan.layout_hash;
}

// ---- tests: the seam against ComptimeUi -----------------------------------------------------

const testing = std.testing;
const spec_zig = @import("../comptime/spec.zig");

/// The state struct a C++ or Rust program would pass for `State`: strings as pointer and
/// length, in declaration order.
pub fn ExternState(comptime State: type) type {
    const info = @typeInfo(State).@"struct";
    var field_types: [info.field_names.len]type = undefined;
    for (info.field_types, &field_types) |T, *out| out.* = if (T == []const u8) extern struct { ptr: ?[*]const u8, len: usize } else T;
    return @Struct(.@"extern", null, info.field_names, &field_types, &@splat(.{}));
}

/// `State`'s defaults, as the extern struct.
pub fn externDefaults(comptime State: type) ExternState(State) {
    const s: State = .{};
    var out: ExternState(State) = undefined;
    inline for (@typeInfo(State).@"struct".field_names) |name| {
        const v = @field(s, name);
        @field(out, name) = if (@TypeOf(v) == []const u8) .{ .ptr = v.ptr, .len = v.len } else v;
    }
    return out;
}

/// A UI over the seam in Zig: the tables made while compiling, the frame behind the seam.
pub fn SeamUi(comptime State: type, comptime spec: spec_zig.Spec, comptime th: base.Theme) type {
    const words = plan.tablesOf(State, spec, th);
    return struct {
        const Self = @This();
        pub const tables = words;
        buf: [size]u8 align(mem.column_align) = undefined,
        state: ExternState(State) = externDefaults(State),
        ui: *Ui = undefined,

        const size = blk: {
            @setEvalBranchQuota(100_000);
            const t = plan.Tables.decode(&words) catch unreachable;
            break :blk Ui.layoutOf(&t).total;
        };

        pub fn init(s: *Self) !void {
            s.ui = try Ui.init(&tables, &s.buf);
        }

        pub fn frame(s: *Self, in: *const Input) Output {
            return s.ui.frame(@ptrCast(&s.state), in);
        }
    };
}

test "seam: the reference widgets' replay draws what ComptimeUi draws, frame by frame" {
    const Ref = base.Reference(.default);
    const Replay = @import("../core/input.zig").Replay;
    const Comp = struct {
        var ui: Ref.Ui = .{};
        var seam: SeamUi(Ref.State, Ref.spec, .default) = .{};
    };
    Comp.ui = .{};
    Comp.seam = .{};
    try Comp.seam.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buffers: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = base.reference_replay };
    var frames: u32 = 0;
    var events: u32 = 0;
    while (try replay.next(buffers)) |in| {
        const a = Comp.ui.frame(in);
        const b = Comp.seam.frame(in);
        try testing.expect(base.sameDraw(a.draw, b.draw));
        try testing.expectEqual(a.event != null, b.widget != none);
        events += @intFromBool(b.widget != none);
        frames += 1;
    }
    try testing.expect(frames >= 6);
    try testing.expect(events >= 2);
    // The state the seam changed is the state ComptimeUi changed.
    try testing.expectEqual(Comp.ui.signals.state.wireframe, Comp.seam.state.wireframe);
    try testing.expectEqual(Comp.ui.signals.state.exposure, Comp.seam.state.exposure);
}

test "seam: regions, a custom draw node, springs and focus draw what ComptimeUi draws" {
    const zon = @import("zon.zig");
    const Comp = struct {
        var ui: base.ComptimeUi(zon.PanelState, zon.panel_spec, .default) = .{};
        var seam: SeamUi(zon.PanelState, zon.panel_spec, .default) = .{};
    };
    Comp.ui = .{};
    Comp.seam = .{};
    try Comp.seam.init();
    const tab: Input.Event = .{ .kind = .press, .code = (focus_mod.Keymap{}).tab };
    const Step = struct { x: f32, y: f32, left: bool, tab: bool = false, set: ?enum { hide, show, len0, len4, detailed } = null };
    const steps = [_]Step{
        .{ .x = 5, .y = 5, .left = false },
        .{ .x = 5, .y = 5, .left = false, .tab = true },
        .{ .x = 5, .y = 5, .left = false, .tab = true, .set = .detailed },
        .{ .x = 5, .y = 5, .left = false, .set = .len4 },
        .{ .x = 100, .y = 17, .left = true }, // on the slider: a drag, then a spring
        .{ .x = 130, .y = 17, .left = true },
        .{ .x = 130, .y = 17, .left = false },
        .{ .x = 20, .y = 17, .left = true }, // the checkbox: a click hides the `when`
        .{ .x = 20, .y = 17, .left = false },
        .{ .x = 5, .y = 5, .left = false, .set = .hide },
        .{ .x = 5, .y = 5, .left = false, .set = .len0 },
        .{ .x = 5, .y = 5, .left = false, .set = .show },
        .{ .x = 5, .y = 5, .left = false },
        .{ .x = 5, .y = 5, .left = false },
    };
    var customs: usize = 0;
    var moving: usize = 0;
    for (steps) |st| {
        if (st.set) |what| switch (what) {
            .hide => {
                Comp.ui.signals.state.show = false;
                Comp.seam.state.show = false;
            },
            .show => {
                Comp.ui.signals.state.show = true;
                Comp.seam.state.show = true;
            },
            .len0 => {
                Comp.ui.signals.state.len = 0;
                Comp.seam.state.len = 0;
            },
            .len4 => {
                Comp.ui.signals.state.len = 4;
                Comp.seam.state.len = 4;
            },
            .detailed => {
                Comp.ui.signals.state.mode = .detailed;
                Comp.seam.state.mode = .detailed;
            },
        };
        const evs = [_]Input.Event{tab};
        const in: Input = .{ .pointer = .{ st.x, st.y }, .buttons = .{ .left = st.left }, .events = if (st.tab) &evs else &.{} };
        const a = Comp.ui.frame(&in);
        const b = Comp.seam.frame(&in);
        try testing.expect(base.sameDraw(a.draw, b.draw));
        try testing.expectEqual(a.wake, b.wake);
        const fa: u32 = if (Comp.ui.focus) |f| for (@TypeOf(Comp.ui).Events.widget_nodes, 0..) |nd, k| {
            if (nd == @backingInt(f)) break @intCast(k);
        } else unreachable else none;
        try testing.expectEqual(fa, b.focus);
        customs += b.draw.custom_len;
        moving += @intFromBool(b.wake == 0);
    }
    try testing.expect(customs > 0);
    try testing.expect(moving > 0);
}

const FmtState = struct { name: []const u8 = "Gain", level: f32 = 0.5, count: u32 = 3, on: bool = true, mode: enum(u8) { a, b } = .b };
const fmt_spec = spec_zig.col(.{ .pad = @splat(4), .gap = 2 }, .{
    spec_zig.text("{}: {.2} x{} {} {} {{}}", .{ .name, .level, .count, .on, .mode }),
    base.ct.slider(.default, .level, .level),
});

test "seam: formatted labels write what ComptimeUi writes, as each field changes" {
    const Comp = struct {
        var ui: base.ComptimeUi(FmtState, fmt_spec, .default) = .{};
        var seam: SeamUi(FmtState, fmt_spec, .default) = .{};
    };
    Comp.ui = .{};
    Comp.seam = .{};
    try Comp.seam.init();
    const in: Input = .{ .viewport = .{ 300, 100 } };
    for (0..6) |k| {
        switch (k) {
            1 => {
                Comp.ui.signals.state.level = 0.125;
                Comp.seam.state.level = 0.125;
            },
            2 => {
                Comp.ui.signals.state.count = 4_000_000_000;
                Comp.seam.state.count = 4_000_000_000;
            },
            3 => {
                Comp.ui.signals.state.on = false;
                Comp.seam.state.on = false;
            },
            4 => {
                Comp.ui.signals.state.name = "Pan";
                Comp.seam.state.name = .{ .ptr = "Pan", .len = 3 };
            },
            5 => {
                Comp.ui.signals.state.mode = .a;
                Comp.seam.state.mode = .a;
            },
            else => {},
        }
        const a = Comp.ui.frame(&in);
        const b = Comp.seam.frame(&in);
        try testing.expect(base.sameDraw(a.draw, b.draw));
        try testing.expectEqualStrings(a.draw.strings, b.draw.strings);
        if (k == 0) try testing.expectEqualStrings("Gain: 0.50 x3 true 1 {}", b.draw.strings);
        if (k == 5) try testing.expectEqualStrings("Pan: 0.13 x4000000000 false 0 {}", b.draw.strings);
    }
}

test "seam: init refuses a buffer that is too small or tables from another layout" {
    const Ref = base.Reference(.default);
    const words = comptime plan.tablesOf(Ref.State, Ref.spec, .default);
    var small: [64]u8 align(mem.column_align) = undefined;
    try testing.expectError(error.BufferTooSmall, Ui.init(&words, &small));
    var bad = words;
    bad[2] ^= 1;
    try testing.expectError(error.LayoutHash, Ui.init(&bad, &small));
}
