//! The bare-metal example: the shells' example application (src/shell/example.zig) on a
//! 320 x 240 panel through a 20-row line buffer, driven by the simulator board (sim.zig) from
//! the recording testdata/firmware.replay. The same code is
//!
//! - run natively by `zig build baremetal`, whose test checks what the recording did, and
//! - built by the same step as a freestanding executable for two microcontrollers (Cortex-M7
//!   and RV32IMAC): no OS, no libc, no allocator; `_start` runs the recording and then idles.
//!
//! On a real board, replace `Sim` with a board whose `read` polls the touch controller and the
//! encoder, whose `flush` writes the area to the panel, and whose `idle` executes `wfi`; and call
//! `clock.inc` from a timer interrupt. This file is the root of its own module over `lcgr`
//! (docs/ARCHITECTURE.md, adapters), so it is not exported from src/lcgr.zig.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const context = lcgr.context;
const sw = lcgr.render_sw;
const Input = lcgr.input.Input;
const Quad = lcgr.draw_list.Quad;
const Sim = lcgr.shell_baremetal_sim.Sim;
const Shell = lcgr.shell_baremetal_shell.Baremetal(Sim);
const App = lcgr.shell_example.App;

pub const width = 320;
pub const height = 240;
pub const rows = 20;
const limits: context.Limits = .{ .nodes = 128, .texts = 32 };

// Static RAM, all of it. `panel` stands for the display's own memory.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var lines: [lcgr.shell_baremetal_flush.Display.len(width, rows)]u32 = undefined;
var panel: [sw.Framebuffer.len(width, height)]u32 = undefined;
var glyphs: [256]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [16]u8 = undefined;
var events: [8]Input.Event = undefined;
var contacts: [2]Input.Contact = undefined;

var sim: Sim = undefined;
var app: App = .{};

/// Runs the recording to its end. Returns false when the context does not fit its buffer or the
/// recording is bad.
pub fn run() bool {
    var ctx = context.Context.init(&ctx_buffer, limits) catch return false;
    app = .{};
    sim = .init(@embedFile("testdata/firmware.replay"), .{ .text = &text, .events = &events, .contacts = &contacts }, .init(&panel, width, height, .rgba8));
    var shell: Shell = .init(&sim, &sim.clock, width, height, rows, .rgba8, 1, .{ .pixels = &lines, .glyphs = &glyphs, .first = &first, .count = &count });
    lcgr.shell_iface.run(&shell, &ctx, &app);
    return sim.err == null;
}

fn start() callconv(.c) noreturn {
    _ = run();
    while (true) {}
}

comptime {
    if (builtin.os.tag == .freestanding) @export(&start, .{ .name = "_start" });
}

test "firmware: the bare-metal example runs its recording" {
    try std.testing.expect(run());
    // Tapped Reset, then Add layer twice; the encoder's keys reach no button of the example.
    try std.testing.expectEqual(@as(u32, 1), app.resets);
    try std.testing.expectEqual(@as(u32, 5), app.layers);
    try std.testing.expectEqual(app.theme.panel, sim.panel.at(80, 230));
    try std.testing.expectEqual(app.theme.control, sim.panel.at(12, 74));
}
