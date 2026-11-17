//! Microcontroller demo in the simulator: a thermostat panel for a 320 x 240 touch screen, run
//! by the bare-metal shell (src/shell/baremetal/) on the simulator board, as LVGL runs its demos
//! in a desktop simulator. All memory is static and small: the context for 64 nodes, a 20-row
//! line buffer instead of a framebuffer, and the panel's own memory (`panel`, in the simulator).
//! The board is driven by the recording below: taps on the touch panel.
//!
//! The same file is linked for a Cortex-M7 with no OS (`zig build examples` installs
//! zig-out/mcu/example-mcu-cortex-m7): `_start` runs the recording on the simulator board, which
//! uses no OS either. On a real board, replace `Sim` with the board's touch, panel and timer
//! (src/shell/baremetal/firmware.zig says how).

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const context = lcgf.context;
const sw = lcgf.render_sw;
const Frame = lcgf.frame.Frame;
const Input = lcgf.input.Input;
const Quad = lcgf.draw_list.Quad;
const types = lcgf.types;
const Id = types.Id;
const Events = lcgf.shell_iface.Events;
const Sim = lcgf.shell_baremetal_sim.Sim;
const Shell = lcgf.shell_baremetal_shell.Baremetal(Sim);

pub const width = 320;
pub const height = 240;
pub const rows = 20;
pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 512, .anims = 4, .tweens = 4, .flips = 4, .signals = 4, .depth = 16, .timers = 2, .memos = 2 };

pub const id_down = Id.from("cooler");
pub const id_up = Id.from("warmer");
pub const id_heat = Id.from("heat");

pub const App = struct {
    theme: w.Theme = .default,
    /// Target temperature in tenths of a degree.
    target: i32 = 205,
    heating: bool = false,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        _ = f.open(.from("panel"), .{ .size = .{ .fill, .fill }, .pad = @splat(8), .gap = 8, .fill = th.panel });
        _ = f.open(.from("buttons"), .{ .dir = .x, .gap = 8, .cross = .center });
        if (w.button(f, th, id_down, "-").clicked) app.target -= 5;
        if (w.button(f, th, id_up, "+").clicked) app.target += 5;
        var buf: [24]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Target {d}.{d} C", .{ @divTrunc(app.target, 10), @mod(app.target, 10) }) catch "?");
        f.close();
        _ = w.checkbox(f, th, id_heat, &app.heating, "Heating");
        f.close();
    }
};

/// Two taps on +, one on -, one on the Heating box (positions: the layout at 320 x 240).
pub const recording =
    \\frame
    \\frame
    \\frame
    \\pointer 52 25
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 20 25
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 18 58
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\
;

// Static RAM, all of it.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var lines: [lcgf.shell_baremetal_flush.Display.len(width, rows)]u32 = undefined;
var panel: [sw.Framebuffer.len(width, height)]u32 = undefined;
var glyphs: [128]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [16]u8 = undefined;
var events: [8]Input.Event = undefined;
var contacts: [2]Input.Contact = undefined;

pub var sim: Sim = undefined;
pub var state: App = .{};

/// Runs the recording to its end on the simulator board. False when the context does not fit
/// its buffer or the recording is bad.
pub fn run() bool {
    var ctx = context.Context.init(&ctx_buffer, limits) catch return false;
    state = .{};
    sim = .init(recording, .{ .text = &text, .events = &events, .contacts = &contacts }, .init(&panel, width, height, .rgba8));
    var shell: Shell = .init(&sim, &sim.clock, width, height, rows, .rgba8, 1, .{ .pixels = &lines, .glyphs = &glyphs, .first = &first, .count = &count });
    lcgf.shell_iface.run(&shell, &ctx, &state);
    return sim.err == null;
}

fn start() callconv(.c) noreturn {
    _ = run();
    while (true) {}
}

comptime {
    if (builtin.os.tag == .freestanding) @export(&start, .{ .name = "_start" });
}

test "mcu: the thermostat runs its recording on the simulator board" {
    try std.testing.expect(run());
    try std.testing.expectEqual(@as(i32, 210), state.target);
    try std.testing.expect(state.heating);
    // The panel received the picture: the background panel, and the checked box's accent.
    try std.testing.expectEqual(state.theme.panel, sim.panel.at(300, 230));
    try std.testing.expect(sim.sent >= width * height);
    // RAM the UI itself takes, besides the panel the display owns: the context and the line
    // buffer (104,256 bytes at 8 lanes), within a Cortex-M7's 512 KB of SRAM with room to spare.
    try std.testing.expect(@sizeOf(@TypeOf(ctx_buffer)) + @sizeOf(@TypeOf(lines)) < 128 * 1024);
}
