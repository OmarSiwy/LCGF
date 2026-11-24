//! CPU-only benchmark of the public Context.begin -> build -> Frame.end path.
//! Both cases build the same 3,961-node tree: 330 rows of four text cells and three
//! accent leaves. The only scene input that changes is whether all text may wrap.
//! A tall viewport keeps both cases fully visible, avoiding paint culling as an
//! accidental substitute for work. No pixels, window server, or GPU are timed.
//!
//! The first optional argument is a JSON output path. The same JSON is always
//! written to stdout. Compare output hashes across baseline/candidate builds;
//! hashes and invariant checks run outside the timed interval.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;
const Output = lcgf.context.Output;
const Frame = lcgf.frame.Frame;
const Input = lcgf.input.Input;
const Id = lcgf.types.Id;

const row_count = 330;
const expected_nodes = 1 + row_count * 12;
const expected_texts = row_count * 4;
const warmups = 100;
const sample_count = 1001;
const viewport: [2]f32 = .{ 1280, 32768 };
const theme: lcgf.widgets_base.Theme = .default;
const font: lcgf.protocol.Mono = .{};
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

// Stable addresses and explicit capacity. Initialization, sorting and JSON output
// are outside timed frames; the timed path takes no allocator.
var storage: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);
var samples: [sample_count]u64 = undefined;

const Timing = struct {
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

const Result = struct {
    scene: []const u8,
    nodes: u32,
    texts: u32,
    wrapped_runs: u32,
    quads: u32,
    draw_commands: u32,
    frame: Timing,
    /// Inline bytes, not a slice into a returned function's stack buffer.
    output_hash: [16]u8,
};

/// Build only through public Frame operations, including real interactive cells.
/// Fixed input has the pointer outside and no held buttons in both scene variants.
fn build(frame: *Frame, comptime wrapping: bool) void {
    const labels = [_][]const u8{
        "Compile layout and interaction into predictable contiguous work.",
        "Keep feature state explicit while views borrow only what they need.",
        "Render this text in a fixed width cell and preserve stable identity.",
        "Wrapping text exercises the normal measure and layout pipeline.",
    };
    for (0..row_count) |row_index| {
        const row_id = Id.from("core-bench.row").with(@intCast(row_index));
        _ = frame.open(row_id, .{
            .dir = .x,
            .size = .{ .fill, .fit },
            .gap = 6,
            .pad = @splat(2),
            .cross = .center,
        });
        for (labels, 0..) |label, cell_index| {
            const cell_id = Id.from("core-bench.cell").with(@intCast(row_index * labels.len + cell_index));
            const cell = frame.open(cell_id, .{
                .size = .{ .px(240), .fit },
                .pad = @splat(6),
                .radius = theme.radius,
                .clip = true,
                .role = .button,
            });
            const response = frame.interact(cell, .button);
            frame.setFill(cell, lcgf.widgets_base.buttonFill(&theme, response));
            frame.setCursor(.pointer, response.hovered);
            _ = frame.text(label, .{ .px = theme.text_px, .color = theme.text, .wrap = wrapping });
            frame.close();
        }
        for (0..3) |_| _ = frame.leaf(.none, .{
            .size = .{ .px(12), .px(12) },
            .fill = theme.accent,
        });
        frame.close();
    }
}

fn observe(output: Output) void {
    // Pointer escapes include a compiler memory barrier. Reading only lengths
    // would allow unused geometry or metric writes to disappear under optimization.
    std.mem.doNotOptimizeAway(output.tree);
    std.mem.doNotOptimizeAway(output.texts);
    std.mem.doNotOptimizeAway(output.draw);
}

fn validate(output: Output, comptime wrapping: bool) !u32 {
    if (!output.status.ok()) return error.FrameCapacityExceeded;
    if (output.tree.len != expected_nodes or output.texts.len != expected_texts)
        return error.UnexpectedSceneSize;
    var wrapped: u32 = 0;
    for (output.texts.c.h[0..output.texts.len], output.texts.c.px[0..output.texts.len]) |height, px|
        wrapped += @intFromBool(height > px * font.line);
    if (wrapped != (if (wrapping) expected_texts else 0)) return error.UnexpectedWrapping;
    // Every cell is in the viewport; a layout or clipping regression must not
    // silently speed up the benchmark by dropping its text from the draw list.
    if (output.draw.run_len != expected_texts) return error.UnexpectedTextCulling;
    return wrapped;
}

/// Hash meaningful live output bytes, never pointers, unused capacity or arbitrary
/// struct padding. A match is regression evidence, not a mathematical equivalence proof.
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
    // Quad and TextRun are upstream extern rows with verified, padding-free layouts.
    hash.update(std.mem.sliceAsBytes(draw.quads[0..draw.quad_len]));
    hash.update(std.mem.sliceAsBytes(draw.runs[0..draw.run_len]));
    inline for (.{ draw.cmd.kind, draw.cmd.first, draw.cmd.count, draw.cmd.key }) |column|
        hash.update(std.mem.sliceAsBytes(column[0..draw.cmd_len]));
    return hash.final();
}

/// Nearest-rank percentiles, using integer indices after sorting all samples.
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

fn runScene(io: std.Io, comptime wrapping: bool) !Result {
    var context = try Context.init(&storage, limits);
    const input: Input = .{ .viewport = viewport };
    var output: Output = undefined;
    for (0..warmups) |_| {
        var frame = context.begin(&input);
        build(&frame, wrapping);
        output = frame.end(font);
        observe(output);
        if (!output.status.ok()) return error.FrameCapacityExceeded;
    }
    _ = try validate(output, wrapping);
    const reference_hash = outputHash(output);

    for (&samples) |*sample| {
        const start = std.Io.Timestamp.now(io, .awake);
        var frame = context.begin(&input);
        build(&frame, wrapping);
        output = frame.end(font);
        observe(output);
        const end = std.Io.Timestamp.now(io, .awake);
        sample.* = @intCast(start.durationTo(end).toNanoseconds());
        if (!output.status.ok()) return error.FrameCapacityExceeded;
    }
    const wrapped = try validate(output, wrapping);
    const final_hash = outputHash(output);
    if (reference_hash != final_hash) return error.OutputChangedBetweenFrames;
    var result: Result = .{
        .scene = if (wrapping) "all_wrapping" else "no_wrapping",
        .nodes = output.tree.len,
        .texts = output.texts.len,
        .wrapped_runs = wrapped,
        .quads = output.draw.quad_len,
        .draw_commands = output.draw.cmd_len,
        .frame = summarize(),
        .output_hash = undefined,
    };
    _ = try std.fmt.bufPrint(&result.output_hash, "{x:0>16}", .{final_hash});
    return result;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next();
    if (args.next() != null) return error.TooManyArguments;

    const results = [_]Result{
        try runScene(init.io, false),
        try runScene(init.io, true),
    };
    const report = .{
        .benchmark = "public_frame_end",
        .scope = "CPU Context.begin + scene build + Frame.end; no rasterization or presentation",
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
        .cases = results,
    };
    var json_buffer: [4096]u8 = undefined;
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
