//! Public Frame.reuse benchmark and full-rebuild control. This source also builds
//! against the preceding implementation: it uses only the named lcgf module's
//! existing public API. A mixed-input case reports semantic mismatches instead of
//! silently treating skipped keyboard/timer work as a performance improvement.
//!
//! Each row is a button, an accent leaf and a text node. The fixed-size panel is a
//! relayout boundary; ancestors are rebuilt every frame. All storage is explicit,
//! and the timed interval includes begin, the public scene build and end. There
//! is no pixel rendering, presentation, allocation or hash calculation in it.
//! Every frame contributes a step-tagged output digest and exact update counters,
//! checked between full and retained runs outside timing. Pass --retained-first to
//! reverse each case's measured run order, plus an optional JSON destination.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;
const Output = lcgf.context.Output;
const Frame = lcgf.frame.Frame;
const Input = lcgf.input.Input;
const Id = lcgf.types.Id;
const Signal = lcgf.runtime_signals.Signal;

const warmups = 100;
const sample_count = 1001;
const frame_count = warmups + sample_count;
const viewport: [2]f32 = .{ 1280, 32768 };
const font: lcgf.protocol.Mono = .{};
const theme: lcgf.widgets_base.Theme = .default;
const limits: lcgf.context.Limits = .{
    .nodes = 4096,
    .texts = 2048,
    .strings = 128 * 1024,
    .customs = 1,
    .signals = 4,
    .memos = 4,
    .anims = 4,
    .tweens = 4,
    .flips = 4,
    .timers = 4,
    .depth = 8,
};

var storage: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);
var samples: [sample_count]u64 = undefined;
var observations: [2][frame_count]FrameObservation = undefined;

const Scenario = enum { unchanged, ancestor_clip, ancestor_layout, mixed_updates };

const State = struct {
    signal: Signal,
    revision: u32 = 0,
    builds: u32 = 0,
    copies: u32 = 0,
    timer_fires: u32 = 0,
    activations: u32 = 0,
};

const Timing = struct {
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

const Result = struct {
    nodes: u32,
    texts: u32,
    quads: u32,
    text_runs: u32,
    draw_commands: u32,
    subtree_builds: u32,
    subtree_copies: u32,
    timer_fires: u32,
    keyboard_activations: u32,
    frame: Timing,
    output_hash: [16]u8,
    sequence_hash: [16]u8,
    observed_frames: u32,
    changed_output_frames: u32,
};

const Case = struct {
    scenario: Scenario,
    rows: u32,
    full_rebuild: Result,
    retained: Result,
    run_order: []const u8,
    compared_frames: u32,
    mismatched_frames: u32,
    first_mismatch_step: ?u32,
    /// False means the retained timing did different work and is not comparable.
    same_output_and_updates: bool,
};

/// Numeric observations own their values: no pointer into reused Context storage.
/// Counters and dimensions compare exactly. Output bytes are checked by a hash;
/// a hash match is regression evidence, not a mathematical equivalence proof.
const FrameObservation = struct {
    output_hash: u64,
    nodes: u32,
    texts: u32,
    quads: u32,
    text_runs: u32,
    draw_commands: u32,
    string_bytes: u32,
    revision: u32,
    timer_fires: u32,
    keyboard_activations: u32,
};

fn rowId(index: usize) Id {
    return Id.from("reuse-bench.row").with(@intCast(index));
}

fn prepare(context: *Context, state: *State, comptime scenario: Scenario, step: usize) Input {
    var input: Input = .{ .viewport = viewport, .time = @as(f64, @floatFromInt(step)) / 60.0 };
    if (scenario == .mixed_updates) {
        if (step > 0 and step % 83 == 0) {
            state.revision += 1;
            context.signals.touch(state.signal);
        }
        // Focus and activation arrive while the pointer stays outside the panel.
        if (step == 2 or step % 97 == 0) context.inter.focus = @backingInt(rowId(0));
        if (step % 64 == 32) input.events = &.{.{ .kind = .press, .code = 40 }};
        input.scale = if ((step / 29) & 1 == 0) 1 else 1.25;
    }
    return input;
}

fn build(context: *Context, input: *const Input, state: *State, comptime rows: u32, comptime scenario: Scenario, comptime retained: bool, step: usize) Output {
    var frame = context.begin(input);
    const panel_height: f32 = @as(f32, @floatFromInt(rows)) * 18;
    const clip_changes = scenario == .ancestor_clip or scenario == .mixed_updates;
    const position_changes = scenario == .ancestor_layout or scenario == .mixed_updates;
    const height = if (clip_changes and (step / 4) & 1 != 0) panel_height * 0.5 else panel_height;
    _ = frame.open(.from("reuse-bench.body"), .{
        .size = .{ .px(1060), .px(height) },
        .clip = true,
        .offset = .{ if (position_changes and step & 1 != 0) @as(f32, 0.375) else 0, 0 },
        .scroll = .{ 0, if (position_changes and (step / 2) & 1 != 0) @as(f32, 7.5) else 0 },
        .opacity = if (scenario == .mixed_updates and (step / 13) & 1 != 0) 0.75 else 1,
    });
    // Move the memo's source/destination rows independently of its geometry.
    if (scenario == .mixed_updates) {
        for (0..step % 3) |_| _ = frame.leaf(.none, .{ .float = true, .size = .{ .px(1), .px(1) } });
    }

    const id = Id.from("reuse-bench.panel");
    if (retained and frame.reuse(id, &.{state.signal})) {
        state.copies += 1;
    } else {
        state.builds += 1;
        _ = frame.open(id, .{ .size = .{ .px(1050), .px(panel_height) }, .offset = .{ 0.25, 0.25 } });
        if (scenario == .mixed_updates and frame.timer(.from("reuse-bench.caret"), 0.125, .repeat))
            state.timer_fires += 1;
        for (0..rows) |index| {
            const row = frame.open(rowId(index), .{
                .dir = .x,
                .size = .{ .fill, .px(18) },
                .gap = 6,
                .pad = .{ 2, 1, 2, 1 },
                .role = .button,
            });
            const response = frame.interact(row, .button);
            if (scenario == .mixed_updates and response.focused)
                for (input.events) |event| {
                    if (event.kind == .press and event.code == 40) state.activations += 1;
                };
            const changed = (state.revision + state.timer_fires + state.activations) & 1 != 0;
            frame.setFill(row, if (response.focused or changed) theme.accent else theme.control);
            _ = frame.leaf(.none, .{ .size = .{ .px(10), .px(10) }, .fill = theme.accent });
            _ = frame.text("Retained rows keep explicit state and stable identity.", .{ .px = 12, .color = theme.text });
            frame.close();
        }
        frame.close();
    }
    frame.close();
    return frame.end(font);
}

fn observe(output: Output) void {
    std.mem.doNotOptimizeAway(output.tree);
    std.mem.doNotOptimizeAway(output.texts);
    std.mem.doNotOptimizeAway(output.draw);
}

fn validate(output: Output, comptime rows: u32, comptime scenario: Scenario, step: usize) !void {
    if (!output.status.ok()) return error.FrameCapacityExceeded;
    const leading = if (scenario == .mixed_updates) step % 3 else 0;
    if (output.tree.len != 3 + 3 * rows + leading or output.texts.len != rows)
        return error.UnexpectedSceneSize;
    if (output.draw.run_len == 0) return error.AllTextWasCulled;
}

fn outputHash(output: Output) u64 {
    var hash = std.hash.Wyhash.init(0);
    const tree = output.tree;
    const texts = output.texts;
    const draw = output.draw;
    inline for (.{ tree.c.id, tree.c.parent, tree.c.end, tree.c.sense, tree.c.role, tree.c.value, tree.c.visible }) |column|
        hash.update(std.mem.sliceAsBytes(column[0..tree.len]));
    inline for (0..2) |axis| {
        hash.update(std.mem.sliceAsBytes(tree.c.size[axis][0..tree.len]));
        hash.update(std.mem.sliceAsBytes(tree.c.pos[axis][0..tree.len]));
    }
    inline for (0..4) |edge| {
        hash.update(std.mem.sliceAsBytes(tree.c.rect[edge][0..tree.len]));
        hash.update(std.mem.sliceAsBytes(tree.c.vis[edge][0..tree.len]));
    }
    inline for (.{ texts.c.w, texts.c.h, texts.c.avail, texts.c.wrap }) |column|
        hash.update(std.mem.sliceAsBytes(column[0..texts.len]));
    hash.update(draw.strings);
    // These are padding-free extern rows, so hashes contain no addresses or padding.
    hash.update(std.mem.sliceAsBytes(draw.quads[0..draw.quad_len]));
    hash.update(std.mem.sliceAsBytes(draw.runs[0..draw.run_len]));
    inline for (.{ draw.cmd.kind, draw.cmd.first, draw.cmd.count, draw.cmd.key }) |column|
        hash.update(std.mem.sliceAsBytes(column[0..draw.cmd_len]));
    return hash.final();
}

fn record(output: Output, state: *const State, comptime retained: bool, step: usize, sequence: *std.hash.Wyhash) FrameObservation {
    const observation: FrameObservation = .{
        .output_hash = outputHash(output),
        .nodes = output.tree.len,
        .texts = output.texts.len,
        .quads = output.draw.quad_len,
        .text_runs = output.draw.run_len,
        .draw_commands = output.draw.cmd_len,
        .string_bytes = @intCast(output.draw.strings.len),
        .revision = state.revision,
        .timer_fires = state.timer_fires,
        .keyboard_activations = state.activations,
    };
    observations[@intFromBool(retained)][step] = observation;
    const marker: u64 = @intCast(step);
    sequence.update(std.mem.asBytes(&marker));
    // Hash named values individually, never struct padding.
    inline for (.{ "output_hash", "nodes", "texts", "quads", "text_runs", "draw_commands", "string_bytes", "revision", "timer_fires", "keyboard_activations" }) |name| {
        const value = @field(observation, name);
        sequence.update(std.mem.asBytes(&value));
    }
    return observation;
}

fn summarize() Timing {
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{
        .median_ns = samples[(sample_count * 50 + 99) / 100 - 1],
        .p95_ns = samples[(sample_count * 95 + 99) / 100 - 1],
        .p99_ns = samples[(sample_count * 99 + 99) / 100 - 1],
        .min_ns = samples[0],
        .max_ns = samples[sample_count - 1],
    };
}

fn runScene(io: std.Io, comptime rows: u32, comptime scenario: Scenario, comptime retained: bool) !Result {
    var context = try Context.init(&storage, limits);
    var state: State = .{ .signal = context.signals.create() };
    var output: Output = undefined;
    var sequence = std.hash.Wyhash.init(0);
    var previous_hash: u64 = 0;
    var changed_frames: u32 = 0;
    for (0..warmups) |step| {
        const input = prepare(&context, &state, scenario, step);
        output = build(&context, &input, &state, rows, scenario, retained, step);
        observe(output);
        try validate(output, rows, scenario, step);
        previous_hash = record(output, &state, retained, step, &sequence).output_hash;
    }
    for (&samples, warmups..) |*sample, step| {
        const input = prepare(&context, &state, scenario, step);
        const start = std.Io.Timestamp.now(io, .awake);
        output = build(&context, &input, &state, rows, scenario, retained, step);
        observe(output);
        const end = std.Io.Timestamp.now(io, .awake);
        sample.* = @intCast(start.durationTo(end).toNanoseconds());
        try validate(output, rows, scenario, step);
        const observation = record(output, &state, retained, step, &sequence);
        changed_frames += @intFromBool(observation.output_hash != previous_hash);
        previous_hash = observation.output_hash;
    }
    var result: Result = .{
        .nodes = output.tree.len,
        .texts = output.texts.len,
        .quads = output.draw.quad_len,
        .text_runs = output.draw.run_len,
        .draw_commands = output.draw.cmd_len,
        .subtree_builds = state.builds,
        .subtree_copies = state.copies,
        .timer_fires = state.timer_fires,
        .keyboard_activations = state.activations,
        .frame = summarize(),
        .output_hash = undefined,
        .sequence_hash = undefined,
        .observed_frames = frame_count,
        .changed_output_frames = changed_frames,
    };
    _ = try std.fmt.bufPrint(&result.output_hash, "{x:0>16}", .{previous_hash});
    _ = try std.fmt.bufPrint(&result.sequence_hash, "{x:0>16}", .{sequence.final()});
    return result;
}

fn runCase(io: std.Io, comptime rows: u32, comptime scenario: Scenario, retained_first: bool) !Case {
    var full: Result = undefined;
    var retained: Result = undefined;
    if (retained_first) {
        retained = try runScene(io, rows, scenario, true);
        full = try runScene(io, rows, scenario, false);
    } else {
        full = try runScene(io, rows, scenario, false);
        retained = try runScene(io, rows, scenario, true);
    }
    var mismatches: u32 = 0;
    var first_mismatch: ?u32 = null;
    for (observations[0], observations[1], 0..) |reference, actual, step| {
        if (!std.meta.eql(reference, actual)) {
            mismatches += 1;
            if (first_mismatch == null) first_mismatch = @intCast(step);
        }
    }
    if (scenario != .unchanged and full.changed_output_frames == 0)
        return error.ScenarioDidNotChangeOutput;
    return .{
        .scenario = scenario,
        .rows = rows,
        .full_rebuild = full,
        .retained = retained,
        .run_order = if (retained_first) "retained, full" else "full, retained",
        .compared_frames = frame_count,
        .mismatched_frames = mismatches,
        .first_mismatch_step = first_mismatch,
        .same_output_and_updates = mismatches == 0,
    };
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    var path: ?[]const u8 = null;
    var retained_first = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--retained-first")) {
            retained_first = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else if (path == null) {
            path = arg;
        } else return error.TooManyArguments;
    }

    const cases = [_]Case{
        try runCase(init.io, 330, .unchanged, retained_first),
        try runCase(init.io, 330, .ancestor_clip, !retained_first),
        try runCase(init.io, 330, .ancestor_layout, retained_first),
        try runCase(init.io, 330, .mixed_updates, !retained_first),
        try runCase(init.io, 1320, .unchanged, !retained_first),
        try runCase(init.io, 1320, .ancestor_clip, retained_first),
        try runCase(init.io, 1320, .ancestor_layout, !retained_first),
        try runCase(init.io, 1320, .mixed_updates, retained_first),
    };
    const report = .{
        .benchmark = "public_frame_reuse",
        .scope = "CPU Context.begin + public Frame.reuse scene + Frame.end; no rasterization or presentation",
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .arch = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .cpu_target = builtin.cpu.model.name,
        .simd_lanes = lcgf.simd.lanes,
        .viewport = viewport,
        .warmups = warmups,
        .samples = sample_count,
        .percentiles = "nearest rank; individual frame wall-clock samples in nanoseconds",
        .context_bytes = storage.len,
        .mixed_updates = "signal changes, keyboard activation, repeating timer, ancestor clip/position/opacity, scale and moved row indices",
        .run_order = "Cases alternate full/retained order; pass --retained-first on alternating process runs to reverse every case",
        .comparison_rule = "Compare timings only when every frame's output hash, dimensions and cumulative update counters match. Per-frame checks and step-tagged sequence digests are outside timing; hashes are regression evidence, not mathematical equivalence proof.",
        .cases = cases,
    };
    var json_buffer: [32768]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &json);
    try json.writeByte('\n');
    const bytes = json.buffered();
    if (path) |destination|
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = destination, .data = bytes });
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.writeAll(bytes);
    try stdout.interface.flush();
}
