//! Host-authored locale presentation. Translation rows, numeral symbols, font preferences
//! and direction are ordinary borrowed data. No locale database, formatter callback or
//! global current locale is required. These helpers lower to existing styles/layout passes.

const std = @import("std");
const types = @import("../core/types.zig");
const environment = @import("environment.zig");
const properties = @import("properties.zig");
const resolution = @import("resolve.zig");
const match = @import("../text/font/match.zig");
const rtl = @import("../layout/rtl.zig");
const rounding = @import("../layout/rounding.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Mono = @import("../text/protocol.zig").Mono;
const TextStack = @import("../text/layout/stack.zig").Stack;
const Output = @import("../runtime/context.zig").Output;

pub const Label = struct { id: types.Id, text: []const u8 };
pub const Locale = struct {
    direction: enum { ltr, rtl } = .ltr,
    labels: []const Label = &.{},
    font_families: []const []const u8 = &.{},
    numbers: Numbers = .{},

    /// Last matching translation wins. Fallback is explicit source content, never an ID
    /// rendered as a label. Strings are borrowed until Frame/Texts copies them.
    pub fn label(locale: Locale, id: types.Id, fallback: []const u8) []const u8 {
        var value = fallback;
        for (locale.labels) |row| if (row.id == id) {
            value = row.text;
        };
        return value;
    }
    pub fn inputs(locale: Locale, previous: environment.Environment) environment.Environment {
        var out = previous;
        out.rtl = locale.direction == .rtl;
        return out;
    }
    /// Explicit font miss, so a host can load a face or choose its fallback. The returned
    /// declaration is suitable for a recipe's root local declarations and inherits normally.
    pub fn font(locale: Locale, catalog: []const match.Entry, request: match.Request) error{FontUnavailable}!resolution.Declaration {
        const index = match.find(catalog, locale.font_families, request) orelse return error.FontUnavailable;
        return resolution.set(.text_font, @fromBackingInt(catalog[index].font));
    }
    pub fn directText(locale: Locale, current: types.TextStyle, catalog: []const match.Entry, request: match.Request) error{FontUnavailable}!types.TextStyle {
        if (locale.font_families.len == 0) return current;
        const index = match.find(catalog, locale.font_families, request) orelse return error.FontUnavailable;
        var out = current;
        out.font = @fromBackingInt(catalog[index].font);
        return out;
    }
    pub fn setDirection(locale: Locale, directions: *rtl.Rtl, node: types.Node) void {
        directions.set(node.ix(), if (locale.direction == .rtl) .rtl else .ltr);
    }
    /// Icon mirroring is explicit metadata. This leaves photos/logos and unmarked icons
    /// unchanged and does not mirror glyph shapes or reorder semantic tree rows.
    pub fn iconUv(locale: Locale, uv: [4]f32, directional: bool) [4]f32 {
        return if (directional and locale.direction == .rtl) .{ uv[2], uv[1], uv[0], uv[3] } else uv;
    }
};

pub const NumberError = error{ NoSpace, InvalidNumber, InvalidFormat };
pub const Numbers = struct {
    digits: [10][]const u8 = @import("../text/layout/counters.zig").decimal_digits,
    decimal: []const u8 = ".",
    group: []const u8 = ",",
    /// Groups counted from the right; the final size repeats. {3,2} gives 12,34,567.
    groups: []const u8 = &.{3},
    minimum_grouping_digits: u8 = 4,
    minus: []const u8 = "-",
    plus: []const u8 = "+",
    negative_suffix: []const u8 = "",

    /// Map an exact host-formatted ASCII decimal into this locale. Sign, leading zeroes and
    /// fractional digits are preserved; exponents/currency/percent notation must be supplied
    /// by the host as full label content, rather than silently interpreted here.
    pub fn format(numbers: Numbers, ascii: []const u8, out: []u8) NumberError![]const u8 {
        try numbers.validate();
        if (ascii.len == 0) return error.InvalidNumber;
        const signed = ascii[0] == '-' or ascii[0] == '+';
        const first: usize = @intFromBool(signed);
        var dot = ascii.len;
        for (ascii[first..], first..) |ch, i| {
            if (ch == '.' and dot == ascii.len) dot = i else if (ch < '0' or ch > '9') return error.InvalidNumber;
        }
        if (dot == first or (dot < ascii.len and dot + 1 == ascii.len)) return error.InvalidNumber;
        var size: usize = 0;
        try numbers.emit(ascii, first, dot, null, &size);
        if (out.len < size) return error.NoSpace;
        var written: usize = 0;
        try numbers.emit(ascii, first, dot, out, &written);
        return out[0..written];
    }
    pub fn integer(numbers: Numbers, value: i64, out: []u8) NumberError![]const u8 {
        var ascii: [24]u8 = undefined;
        const bytes = std.fmt.bufPrint(&ascii, "{d}", .{value}) catch unreachable;
        return numbers.format(bytes, out);
    }
    fn validate(numbers: Numbers) NumberError!void {
        for (numbers.digits) |s| if (s.len == 0 or !std.unicode.utf8ValidateSlice(s)) return error.InvalidFormat;
        for ([_][]const u8{ numbers.decimal, numbers.group, numbers.minus, numbers.plus, numbers.negative_suffix }) |s| if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidFormat;
        if (numbers.decimal.len == 0) return error.InvalidFormat;
        for (numbers.groups) |g| if (g == 0) return error.InvalidFormat;
    }
    fn boundary(numbers: Numbers, remaining: usize) bool {
        if (numbers.groups.len == 0) return false;
        var total: usize = 0;
        for (numbers.groups) |group| {
            total += group;
            if (remaining <= total) return remaining == total;
        }
        return (remaining - total) % numbers.groups[numbers.groups.len - 1] == 0;
    }
    fn emit(numbers: Numbers, ascii: []const u8, first: usize, dot: usize, out: ?[]u8, count: *usize) NumberError!void {
        if (first > 0) try append(out, count, if (ascii[0] == '-') numbers.minus else numbers.plus);
        for (ascii[first..dot], first..) |ch, i| {
            if (i > first and dot - first >= numbers.minimum_grouping_digits and numbers.boundary(dot - i)) try append(out, count, numbers.group);
            try append(out, count, numbers.digits[ch - '0']);
        }
        if (dot < ascii.len) {
            try append(out, count, numbers.decimal);
            for (ascii[dot + 1 ..]) |ch| try append(out, count, numbers.digits[ch - '0']);
        }
        if (first > 0 and ascii[0] == '-') try append(out, count, numbers.negative_suffix);
    }
};
fn append(out: ?[]u8, count: *usize, value: []const u8) NumberError!void {
    const limit = std.math.add(usize, count.*, value.len) catch return error.NoSpace;
    if (out) |bytes| {
        if (limit > bytes.len) return error.NoSpace;
        @memcpy(bytes[count.*..limit], value);
    }
    count.* = limit;
}

pub const Presentation = struct { directions: ?*rtl.Rtl = null, rounding: rounding.Options = .{} };
pub const LayoutError = error{ NoSpace, InvalidScale };
pub fn validateDirections(directions: *const rtl.Rtl, nodes: usize) error{NoSpace}!void {
    inline for (@typeInfo(rtl.Rtl.Columns).@"struct".field_names) |field| if (@field(directions.c, field).len < nodes) return error.NoSpace;
}
pub fn beforeLayout(tree: *const @import("../core/tree.zig").Tree, directions: *rtl.Rtl) error{NoSpace}!void {
    try validateDirections(directions, tree.len);
    rtl.direction(tree, directions);
    // startEnd writes physical padding; the tree is mutable in the caller's layout stage.
}

/// Optional diagonal over the ordinary Frame passes. Populate directions while building;
/// the source/semantic/keyboard row order stays stable while physical boxes mirror.
pub fn layoutWith(frame: *Frame, font: Mono, presentation: Presentation) LayoutError!void {
    try presentation.rounding.validate();
    if (presentation.directions) |directions| {
        try beforeLayout(frame.tree(), directions);
        rtl.startEnd(frame.tree(), directions);
    }
    frame.arrangeWith(font);
    if (presentation.directions) |directions| rtl.mirror(frame.tree(), directions);
    try frame.finalizeLayout(presentation.rounding);
}
pub fn end(frame: *Frame, font: Mono, presentation: Presentation) LayoutError!Output {
    try layoutWith(frame, font, presentation);
    return frame.finish();
}
pub fn layoutText(frame: *Frame, stack: *TextStack, ascent: []f32, presentation: Presentation) LayoutError!void {
    try presentation.rounding.validate();
    if (presentation.directions) |directions| {
        try beforeLayout(frame.tree(), directions);
        rtl.startEnd(frame.tree(), directions);
    }
    frame.arrangeText(stack, ascent);
    if (presentation.directions) |directions| rtl.mirror(frame.tree(), directions);
    try frame.finalizeLayout(presentation.rounding);
}
pub fn endText(frame: *Frame, stack: *TextStack, ascent: []f32, presentation: Presentation) LayoutError!Output {
    try layoutText(frame, stack, ascent, presentation);
    return frame.finish();
}

test "locale numeric data maps exact integers groups digits and decimal punctuation" {
    const arabic: Numbers = .{ .digits = .{ "٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩" }, .decimal = "٫", .group = "٬", .minus = "−" };
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("−١٬٢٣٤٬٥٦٧٫٨٠", try arabic.format("-1234567.80", &out));
    const indian: Numbers = .{ .groups = &.{ 3, 2 } };
    try std.testing.expectEqualStrings("1,23,45,678", try indian.integer(12345678, &out));
    try std.testing.expectEqualStrings("-9,223,372,036,854,775,808", try (Numbers{}).integer(std.math.minInt(i64), &out));
    try std.testing.expectError(error.NoSpace, arabic.integer(123, out[0..2]));
    try std.testing.expectError(error.InvalidNumber, arabic.format("1.2.3", &out));
    try std.testing.expectError(error.InvalidNumber, arabic.format("1e3", &out));
}

test "locale font preferences and labels lower to real Frame text rows" {
    @setEvalBranchQuota(100_000);
    const model = @import("../theme/recipe.zig");
    const controls = @import("../theme/recipe_controls.zig");
    const context = @import("../runtime/context.zig");
    const limits: context.Limits = .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 256, .depth = 8, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
    var memory: [context.Context.requiredBytes(limits)]u8 align(64) = undefined;
    var ctx = try context.Context.init(&memory, limits);
    const input: @import("../core/input.zig").Input = .{ .viewport = .{ 600, 100 } };
    const localized: Locale = .{ .direction = .rtl, .labels = &.{.{ .id = .from("save"), .text = "Save all changes to the document" }}, .font_families = &.{ "Local UI", "Fallback" } };
    const fonts = [_]match.Entry{ .{ .family = "Fallback", .font = 0 }, .{ .family = "Local UI", .font = 7 } };
    const font = try localized.font(&fonts, .{});
    var f = ctx.begin(&input);
    _ = try controls.button(&f, .from("save"), "Save", .{});
    var output = f.end(.{});
    const before = output.tree.rect(output.tree.find(.from("save"))).w();
    f = ctx.begin(&input);
    const button = try controls.beginButton(&f, .from("save"), .{ .local = &.{font}, .environment = localized.inputs(.{}) });
    _ = try controls.directionalIcon(&f, &button, .white, .{ 0, 0, 1, 1 }, true);
    _ = controls.label(&f, &button, localized.label(.from("save"), "Save"));
    controls.end(&f, &button);
    output = f.end(.{});
    try std.testing.expect(output.tree.rect(output.tree.find(.from("save"))).w() > before);
    try std.testing.expectEqual(@as(u16, 7), output.texts.c.font[0]);
    const icon_row = output.tree.find(.from("save")) + 1;
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, output.tree.x.row[output.tree.c.extra[icon_row]].uv);
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, localized.iconUv(.{ 0, 0, 1, 1 }, false));
    try std.testing.expect((try model.button.resolve(.from("root"), .{ .environment = localized.inputs(.{}) }, null)).text.px > 0);
}

test "runtime and comptime locale layout mirror boxes while Tab keeps source reading order" {
    @setEvalBranchQuota(200_000);
    const controls = @import("../theme/recipe_controls.zig");
    const ct = @import("../theme/recipe_comptime.zig");
    const base = @import("../widgets/base.zig");
    const spec = @import("../comptime/spec.zig");
    const context = @import("../runtime/context.zig");
    const mem = @import("../core/mem.zig");
    const Input = @import("../core/input.zig").Input;
    const panel: types.Style = .{ .dir = .x, .gap = 8, .size = .{ .fill, .fit } };
    const App = struct { first: []const u8 = "First", second: []const u8 = "Second" };
    const page = spec.row(panel, .{ ct.button(.first, .first, .{}), ct.button(.second, .second, .{}) });
    const Ui = base.ComptimeUi(App, page, .default);
    const limits: context.Limits = .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 128, .depth = 8, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
    const Saved = struct {
        var storage: [context.Context.requiredBytes(limits)]u8 align(64) = undefined;
        var ui: Ui = .{};
        var directions_rt: [8192]u8 align(64) = undefined;
        var directions_ct: [8192]u8 align(64) = undefined;
    };
    Saved.ui = .{};
    var ctx = try context.Context.init(&Saved.storage, limits);
    var rt_carver: mem.Carver = .{ .buf = &Saved.directions_rt };
    var ct_carver: mem.Carver = .{ .buf = &Saved.directions_ct };
    var rt_directions = rtl.Rtl.init(&rt_carver, 32);
    var ct_directions = rtl.Rtl.init(&ct_carver, 32);
    rt_directions.reset();
    ct_directions.reset();
    rt_directions.set(0, .rtl);
    ct_directions.set(0, .rtl);
    var input: Input = .{ .viewport = .{ 400, 100 } };
    for (0..3) |frame_index| {
        input.events = if (frame_index == 0) &.{} else &.{.{ .kind = .press, .code = 43 }};
        var f = ctx.begin(&input);
        _ = f.open(.none, panel);
        _ = try controls.button(&f, .from("first"), "First", .{});
        _ = try controls.button(&f, .from("second"), "Second", .{});
        f.close();
        const runtime = try end(&f, .{}, .{ .directions = &rt_directions, .rounding = .{ .scale = 1.25 } });
        const comptime_output = try Saved.ui.frameWithPresentation(&input, &.{}, .{ .directions = &ct_directions, .rounding = .{ .scale = 1.25 } });
        try std.testing.expect(base.sameDraw(runtime.draw, comptime_output.draw));
        const first = runtime.tree.find(.from("first"));
        const second = runtime.tree.find(.from("second"));
        try std.testing.expect(first < second);
        try std.testing.expect(runtime.tree.rect(first).x0 > runtime.tree.rect(second).x0);
        if (frame_index > 0) {
            try std.testing.expectEqual(if (frame_index == 1) @backingInt(types.Id.from("first")) else @backingInt(types.Id.from("second")), ctx.inter.focus);
            try std.testing.expectEqual(if (frame_index == 1) Ui.Events.Widget.first else .second, Saved.ui.focus.?);
        }
    }
}
