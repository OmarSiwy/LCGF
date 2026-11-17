//! Input-to-photon latency of the example (src/shell/example.zig) in the headless shell: the
//! time from the shell receiving an input event to the frame showing it in the framebuffer
//! (poll, needsFrame, begin, build, end, present with the software back end), and how many
//! presented frames it takes. The pointer moves on and off the Reset button every poll; the
//! button's face must change colour in the first frame presented after the move, every time.
//! No window, no display: the platform's own input and scan-out delay are not included.
//!
//!   zig build gates-latency            prints `latency late=0 polls=N median_us=M p99_us=P`
//!
//! bench/gates/gates.py latency checks that line against bench/gates/recorded.json.
const std = @import("std");
const lcgf = @import("lcgf");
const Headless = lcgf.shell_headless.Headless;
const Events = lcgf.shell_iface.Events;
const Context = lcgf.context.Context;
const App = lcgf.shell_example.App;
const Input = lcgf.input.Input;
const Quad = lcgf.draw_list.Quad;
const Framebuffer = lcgf.render_sw.Framebuffer;

const toggles = 2000;
const head = "frame\nviewport 800 600\nframe\nframe\n";
const pair = "frame\npointer 37 25\nframe\npointer 400 400\n";
const limits: lcgf.context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 800;
const fb_h = 600;
/// Inside Reset's face (8,8 .. 66,42), left of its label.
const probe_x = 10;
const probe_y = 25;

var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var pixels: [Framebuffer.len(fb_w, fb_h)]u32 = undefined;
var glyphs: [512]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [64]u8 = undefined;
var events: [16]Input.Event = undefined;
var contacts: [4]Input.Contact = undefined;
var samples: [2 * toggles]u64 = undefined;
var recording: [head.len + pair.len * toggles]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    @memcpy(recording[0..head.len], head);
    for (0..toggles) |i| @memcpy(recording[head.len + i * pair.len ..][0..pair.len], pair);
    var ctx = try Context.init(&ctx_buffer, limits);
    var app: App = .{};
    var shell: Headless = .init(io, &recording, fb_w, fb_h, .{
        .replay = .{ .text = &text, .events = &events, .contacts = &contacts },
        .pixels = &pixels,
        .glyphs = &glyphs,
        .first = &first,
        .count = &count,
    });
    const fills = app.theme.controlFills();
    var ev: Events = .{};
    var n: usize = 0;
    var late: u32 = 0;
    while (true) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        if (!shell.poll(&ev)) break;
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            shell.apply(&out.platform);
            shell.present(&out);
        }
        const t1 = std.Io.Timestamp.now(io, .awake);
        if (shell.polls <= 3) continue; // the first frame, the settle frame and an idle poll
        const over = ev.in.pointer[0] < 100;
        const want = fills[@intFromBool(over)];
        late += @intFromBool(!std.meta.eql(shell.fb.at(probe_x, probe_y), want));
        samples[n] = @intCast(t0.durationTo(t1).toNanoseconds());
        n += 1;
    }
    if (shell.err) |e| return e;
    std.mem.sort(u64, samples[0..n], {}, std.sort.asc(u64));
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    // late: moves not shown in the first frame presented after them.
    try w.print("latency late={d} polls={d} median_us={d:.1} p99_us={d:.1}\n", .{
        late,
        n,
        @as(f64, @floatFromInt(samples[n / 2])) / 1000,
        @as(f64, @floatFromInt(samples[n * 99 / 100])) / 1000,
    });
    try w.flush();
    if (late != 0) return error.LateFrame;
}
