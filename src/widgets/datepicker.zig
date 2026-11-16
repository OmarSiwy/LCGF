//! Date picker (tier 2): a button showing the chosen date, which opens a dialog below it with
//! the month's grid of days, the WAI-ARIA APG date picker dialog pattern. Written against the
//! public API of tiers 0 and 1, after the recipe in base.zig. The dialog floats under the root
//! at an offset taken from the button's rect of the last frame (`Style.float`, `Style.offset`,
//! prototype/ui.zig), as popover.zig's panel does. Dates are days since 1970-01-01, months and
//! years from src/i18n/date.zig (`Date.fromDays`, `months`, `format`).
//!
//! The grid always shows six weeks, Sunday first, so the dialog has the same rows every frame:
//! one builder (`buildDialog`) makes them for both front ends, over `Frame` in the runtime one
//! and over the tables in the comptime one. The dialog's rows sense nothing; what the pointer
//! is over is read from last frame's tree (`targetAt`), in both front ends alike.
//!
//! Runtime: `button(...)` in the page's flow, then `dialog(...)` under the root after the page.
//!
//! Comptime: `const D = Datepicker(.due, .due);` gives the spec builders `D.button` (in the
//! flow) and `D.layer` (last in the page's root), custom widgets (`Spec.widget`) of
//! `base.ComptimeUi`.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const date = @import("../i18n/date.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Response = types.Response;

// ---- spec: what the date picker takes and keeps -----------------------------------------------

/// A date picker's state, owned by the application: plain data.
pub const DateState = struct {
    /// The chosen date, days since 1970-01-01: the value.
    value: i32 = 0,
    /// The day the grid's keyboard focus is on; its month is the one shown.
    focus: i32 = 0,
    /// The dialog is shown.
    open: bool = false,
    /// The left button was down last frame, so a press is told from a hold.
    down: bool = false,
    /// What the left button went down on (`Target`), or `no_target`.
    press: u8 = no_target,
    /// What the pointer is over (`Target`), or `no_target`.
    hover: u8 = no_target,

    /// A closed picker on `day`, its grid on it too.
    pub fn on(day: i32) DateState {
        return .{ .value = day, .focus = day };
    }
};

/// What the pointer can be over in the dialog: day cell 0 to 41 (row-major, six weeks), then
/// these.
pub const Target = struct {
    pub const prev: u8 = 42;
    pub const next: u8 = 43;
    /// The dialog, but none of the above.
    pub const dialog: u8 = 44;
};
/// Nothing of the dialog.
pub const no_target: u8 = 0xff;

/// Cells in the grid: six weeks of seven days.
pub const cells = 42;

/// `null` if `State` can hold a date picker bound to `field`, else the compile error.
pub fn checkDatepicker(comptime State: type, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "datepicker: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != DateState) return "datepicker: field '" ++ field ++ "' must be a datepicker.DateState";
    return null;
}

/// Ids of the dialog's parts, from the picker's name: `name_dialog`, `name_prev`, `name_next`,
/// `name_grid` and the cells `name_d0` to `name_d41`.
pub fn partName(comptime name: []const u8, comptime part: []const u8) [:0]const u8 {
    return name ++ "_" ++ part;
}

fn cellId(comptime name: []const u8, comptime k: u32) Id {
    return .from(partName(name, std.fmt.comptimePrint("d{d}", .{k})));
}

// ---- the calendar: days since 1970-01-01 -------------------------------------------------------

/// The day number of `y`-`m`-`d` (Howard Hinnant's `days_from_civil`, the inverse of
/// `date.Date.fromDays`).
pub fn daysFromCivil(y: i32, m: u8, d: u8) i32 {
    const yy = y - @intFromBool(m <= 2);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp: i32 = @mod(@as(i32, m) + 9, 12); // March is 0
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

pub fn civil(day: i32) date.Date {
    return date.Date.fromDays(day);
}

/// 0 for Sunday to 6 for Saturday (1970-01-01 was a Thursday).
pub fn weekday(day: i32) u8 {
    return @intCast(@mod(day + 4, 7));
}

/// Days in month `m` of year `y`.
pub fn monthLength(y: i32, m: u8) u8 {
    const next = if (m == 12) daysFromCivil(y + 1, 1, 1) else daysFromCivil(y, m + 1, 1);
    return @intCast(next - daysFromCivil(y, m, 1));
}

/// `day` moved by `n` months, its day of month clamped to the new month's length.
pub fn addMonths(day: i32, n: i32) i32 {
    const d = civil(day);
    const total = d.year * 12 + (@as(i32, d.month) - 1) + n;
    const y = @divFloor(total, 12);
    const m: u8 = @intCast(@mod(total, 12) + 1);
    return daysFromCivil(y, m, @min(d.day, monthLength(y, m)));
}

/// The day in the grid's first cell for the month of `day`: the Sunday on or before the 1st.
pub fn gridStart(day: i32) i32 {
    const first = day - (civil(day).day - 1);
    return first - weekday(first);
}

/// "1" to "31", the grid's labels.
const day_texts = blk: {
    @setEvalBranchQuota(100_000);
    var out: [32][]const u8 = undefined;
    for (&out, 0..) |*s, k| s.* = std.fmt.comptimePrint("{d}", .{k});
    break :blk out;
};
const weekday_texts = [7][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };

/// "November 2026": the month the grid shows, in `out`.
pub fn title(out: []u8, day: i32) []const u8 {
    const d = civil(day);
    return std.fmt.bufPrint(out, "{s} {d}", .{ date.months(.en)[d.month - 1], @as(u32, @intCast(d.year)) }) catch unreachable;
}

/// "November 16, 2026": the chosen date in the CLDR long pattern, in `out`.
pub fn valueText(out: []u8, day: i32) []const u8 {
    return date.format(out, .en, .long, civil(day)) catch unreachable;
}

// ---- building: one sequence of rows for both front ends ---------------------------------------

/// The comptime front end's side of `buildDialog`: pushes onto the tables directly, as
/// `Frame.open`, `close` and `text` do.
pub const TableBuilder = struct {
    t: *Tree,
    tx: *Texts,
    strings: *Strings,
    stack: [8]u32,
    depth: u32 = 1,

    pub fn init(t: *Tree, tx: *Texts, strings: *Strings, parent: u32) TableBuilder {
        var b: TableBuilder = .{ .t = t, .tx = tx, .strings = strings, .stack = undefined };
        b.stack[0] = parent;
        return b;
    }
    pub fn open(b: *TableBuilder, id: Id, s: Style) u32 {
        const i = b.t.push(b.stack[b.depth - 1], id, &s);
        b.stack[b.depth] = i;
        b.depth += 1;
        return i;
    }
    pub fn close(b: *TableBuilder) void {
        b.depth -= 1;
        b.t.seal(b.stack[b.depth]);
    }
    pub fn text(b: *TableBuilder, str: []const u8, ts: TextStyle) void {
        const i = b.t.push(b.stack[b.depth - 1], .none, &.{ .role = .label });
        b.t.c.text[i] = b.tx.push(i, b.strings.add(str), &ts);
    }
};

/// The runtime front end's side of `buildDialog`.
pub const FrameBuilder = struct {
    f: *Frame,

    pub fn open(b: *FrameBuilder, id: Id, s: Style) u32 {
        return b.f.open(id, s).ix();
    }
    pub fn close(b: *FrameBuilder) void {
        b.f.close();
    }
    pub fn text(b: *FrameBuilder, str: []const u8, ts: TextStyle) void {
        _ = b.f.text(str, ts);
    }
};

/// The button's rows: the button (filled by its response `r`) and its label, the chosen date.
pub fn buildButton(b: anytype, th: *const Theme, comptime name: []const u8, st: DateState, r: Response) u32 {
    var buf: [48]u8 = undefined;
    const i = b.open(.from(name), buttonStyle(th, r));
    b.text(valueText(&buf, st.value), base.labelText(th));
    b.close();
    return i;
}

/// The dialog's rows, below the button's rect `at` (last frame's): a header (previous month,
/// the month's title, next month), the weekdays, and six weeks of days.
pub fn buildDialog(b: anytype, th: *const Theme, comptime name: []const u8, st: DateState, at: Rect) void {
    var buf: [48]u8 = undefined;
    _ = b.open(.from(partName(name, "dialog")), dialogStyle(th, at));
    _ = b.open(.none, headerStyle(th));
    _ = b.open(.from(partName(name, "prev")), navStyle(th, st.hover == Target.prev));
    b.text("<", base.labelText(th));
    b.close();
    _ = b.open(.none, titleStyle());
    b.text(title(&buf, st.focus), base.labelText(th));
    b.close();
    _ = b.open(.from(partName(name, "next")), navStyle(th, st.hover == Target.next));
    b.text(">", base.labelText(th));
    b.close();
    b.close();
    _ = b.open(.from(partName(name, "grid")), gridStyle(th));
    _ = b.open(.none, weekStyle());
    for (weekday_texts) |w| {
        _ = b.open(.none, cellStyle(th, .{}));
        b.text(w, base.labelText(th));
        b.close();
    }
    b.close();
    const start = gridStart(st.focus);
    const month = civil(st.focus).month;
    inline for (0..6) |week| {
        _ = b.open(.none, weekStyle());
        inline for (0..7) |wd| {
            const k: u8 = week * 7 + wd;
            const day: i32 = start + @as(i32, k);
            const d = civil(day);
            _ = b.open(cellId(name, k), cellStyle(th, .{ .hovered = st.hover == k, .focused = day == st.focus, .chosen = day == st.value }));
            b.text(day_texts[d.day], dayText(th, d.month == month));
            b.close();
        }
        b.close();
    }
    b.close();
    b.close();
}

/// Rows `buildDialog` makes, and how many of them are text: the comptime front end's capacity.
pub const dialog_rows = 1 + (1 + 6) + (1 + 1 + 14) + 6 * (1 + 14);
pub const dialog_texts = 3 + 7 + cells;

/// The rect of the row with `id` in `t`, or an empty rect when there is none.
fn rectIn(t: *const Tree, id: Id) Rect {
    const i = t.find(id);
    if (i == types.none) return .{};
    return t.rect(i);
}

/// What the pointer at `p` is over in `t` (last frame's tree): a `Target`, or `no_target`.
pub fn targetAt(t: *const Tree, comptime name: []const u8, p: [2]f32) u8 {
    if (!within(rectIn(t, .from(partName(name, "dialog"))), p)) return no_target;
    var at: u8 = Target.dialog;
    inline for (0..cells) |k| {
        if (within(rectIn(t, cellId(name, k)), p)) at = k;
    }
    if (within(rectIn(t, .from(partName(name, "prev"))), p)) at = Target.prev;
    if (within(rectIn(t, .from(partName(name, "next"))), p)) at = Target.next;
    return at;
}

/// Whether `p` is inside `r` (an empty rect holds nothing).
pub fn within(r: Rect, p: [2]f32) bool {
    return p[0] >= r.x0 and p[0] < r.x1 and p[1] >= r.y0 and p[1] < r.y1;
}

// ---- comptime front end -------------------------------------------------------------------------

/// Date picker `name` bound to the `DateState` field `field`: its spec builders, custom widgets
/// of `base.ComptimeUi` (`Spec.widget`).
pub fn Datepicker(comptime name: @EnumLiteral(), comptime field: @EnumLiteral()) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    return struct {
        /// The button, showing the chosen date. Its click is its event.
        pub fn button() Spec {
            return .{ .kind = .row, .id = id, .bind = field_name, .widget = Button, .children = &.{.{ .kind = .label }} };
        }

        /// The dialog, shown while it is open: one node whose subtree holds as many rows and
        /// texts as `buildDialog` makes. Put it last in the page's root so it is drawn above
        /// the rest (and no widget comes after it).
        pub fn layer() Spec {
            const holes = blk: {
                @setEvalBranchQuota(10_000);
                var out: [dialog_rows - 1]Spec = undefined;
                for (&out, 0..) |*s, k| s.* = .{ .kind = if (k < dialog_texts) .label else .col };
                break :blk out;
            };
            return .{ .kind = .col, .widget = Layer, .children = &holes };
        }

        pub const Button = struct {
            pub fn bindError(comptime State: type, comptime bound: []const u8) ?[]const u8 {
                return checkDatepicker(State, bound);
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const tb = &ui.tables;
                var b: TableBuilder = .init(&tb.t, &tb.tx, &tb.strings, parent);
                _ = buildButton(&b, &th, id, @field(ui.signals.state, field_name), ui.response(next.*, in));
                next.* += comptime @import("../comptime/flatten.zig").count(n);
            }
        };

        pub const Layer = struct {
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = .{ row, event };
                // The button's rect for `push`, from last frame's tree.
                const at: Rect = if (ui.built) rectIn(&ui.tables.t, .from(id)) else .{};
                ui.keep(Layer).* = .{ at.x0, at.y0, at.x1, at.y1 };
                _ = in;
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                _ = in;
                next.* += comptime @import("../comptime/flatten.zig").count(n);
                const st: DateState = @field(ui.signals.state, field_name);
                if (!st.open) return;
                const th = @TypeOf(ui.*).theme;
                const tb = &ui.tables;
                const k = ui.keep(Layer).*;
                var b: TableBuilder = .init(&tb.t, &tb.tx, &tb.strings, parent);
                buildDialog(&b, &th, id, st, .{ .x0 = k[0], .y0 = k[1], .x1 = k[2], .y1 = k[3] });
            }
        };
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The button: a theme button filled by its response, at least 160 wide, its text at the
/// start.
pub fn buttonStyle(th: *const Theme, r: Response) Style {
    var s = base.buttonStyle(th);
    s.fill = base.buttonFill(th, r);
    s.min = .{ 160, 0 };
    s.main = .start;
    return s;
}

/// The dialog: popover.zig's panel, floating `th.gap` below the button's rect `at`, left
/// edges aligned.
pub fn dialogStyle(th: *const Theme, at: Rect) Style {
    return popover.panelStyle(th, at);
}

/// The header: previous month, the title, next month, across the dialog.
pub fn headerStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .cross = .center, .gap = th.gap };
}

/// The previous and next month buttons, filled from `navFills` by hover.
pub fn navStyle(th: *const Theme, hovered: bool) Style {
    return .{ .size = .{ .px(28), .px(28) }, .main = .center, .cross = .center, .radius = th.radius, .fill = navFills(th)[@intFromBool(hovered)] };
}

/// A month button's fill, indexed by hover: none, then the hot control colour.
pub fn navFills(th: *const Theme) base.OnOff {
    return .{ .transparent, th.control_hot };
}

/// The month's title, centred between the buttons.
pub fn titleStyle() Style {
    return .{ .size = .{ .grow(1), .fit }, .main = .center, .cross = .center };
}

/// The grid: the weekdays' row and six weeks, touching.
pub fn gridStyle(th: *const Theme) Style {
    _ = th;
    return .{};
}

/// A week: seven cells, touching.
pub fn weekStyle() Style {
    return .{ .dir = .x };
}

/// What a cell shows besides its day.
pub const CellState = struct { hovered: bool = false, focused: bool = false, chosen: bool = false };

/// A day cell (and a weekday heading, with no state): filled from `cellFills` by choice and
/// hover, outlined in the text colour where the keyboard focus is (`focusBorders`).
pub fn cellStyle(th: *const Theme, cs: CellState) Style {
    return .{
        .size = .{ .px(32), .px(28) },
        .main = .center,
        .cross = .center,
        .radius = th.radius,
        .fill = cellFills(th)[(@as(u2, @intFromBool(cs.chosen)) << 1) | @intFromBool(cs.hovered)],
        .border = 1,
        .border_color = focusBorders(th)[@intFromBool(cs.focused)],
    };
}

/// A cell's fill, indexed by `chosen << 1 | hovered`: none, the hot control colour under the
/// pointer, the accent for the chosen day, hovered or not.
pub fn cellFills(th: *const Theme) base.StateColors {
    return .{ .transparent, th.control_hot, th.accent, th.accent };
}

/// A cell's outline, indexed by focus: none, then the text colour.
pub fn focusBorders(th: *const Theme) base.OnOff {
    return .{ .transparent, th.text };
}

/// A day's number, by whether it is in the month shown (`dayColors`).
pub fn dayText(th: *const Theme, in_month: bool) TextStyle {
    var ts = base.labelText(th);
    ts.color = dayColors(th)[@intFromBool(in_month)];
    return ts;
}

/// A day's colour, indexed by whether it is in the month shown: the hot control colour (dim),
/// then the text colour.
pub fn dayColors(th: *const Theme) base.OnOff {
    return .{ th.control_hot, th.text };
}

// ---- runtime front end ------------------------------------------------------------------------

/// The button of date picker `name`, in the page's flow, showing the chosen date.
pub fn button(f: *Frame, th: *const Theme, comptime name: []const u8, st: *DateState) Response {
    const r = f.ctx.inter.response(.from(name));
    var b: FrameBuilder = .{ .f = f };
    _ = f.interact(@fromBackingInt(buildButton(&b, th, name, st.*, r)), .button);
    return r;
}

/// The dialog of date picker `name`, if it is open. Call it at the root's depth, after the
/// rest of the page, so it is drawn on top.
pub fn dialog(f: *Frame, th: *const Theme, comptime name: []const u8, st: *const DateState) void {
    if (!st.open) return;
    var b: FrameBuilder = .{ .f = f };
    buildDialog(&b, th, name, st.*, f.lastRect(.from(name)));
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// 2026-11-16, a Monday.
const today: i32 = 20773;

/// The test page: a toolbar with a caption and the date picker, and the date picker's dialog.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        const page_style: Style = .{ .size = .{ .fill, .fill } };

        pub const App = struct {
            due: DateState = .on(today),

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, toolbar_style);
                _ = base.label(f, &th, "Due");
                _ = button(f, &th, "due", &app.due);
                f.close();
                dialog(f, &th, "due", &app.due);
                f.close();
            }
        };

        pub const State = struct {
            due: DateState = .on(today),
            caption: []const u8 = "Due",
        };
        pub const D = Datepicker(.due, .due);
        pub const spec = spec_zig.col(page_style, .{
            spec_zig.row(toolbar_style, .{ base.ct.label(th, .caption), D.button() }),
            D.layer(),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const limits: context.Limits = .{ .nodes = 160, .texts = 64, .customs = 1, .strings = 1024, .depth = 10 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the picker's state in both front ends of `h` and builds two frames (the second sees
/// the first's rects); returns the second's tree.
fn setState(h: anytype, st: DateState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 } };
    h.app.due = st;
    h.ui.signals.set(.due, st);
    _ = try h.frame(&in);
    return (try h.frame(&in)).runtime.tree;
}

test "calendar: day numbers, weekdays, month lengths, month moves and the grid's start" {
    try testing.expectEqual(@as(i32, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(today, daysFromCivil(2026, 11, 16));
    try testing.expectEqual(date.Date{ .year = 2026, .month = 11, .day = 16 }, civil(today));
    try testing.expectEqual(@as(u8, 1), weekday(today)); // Monday
    try testing.expectEqual(@as(u8, 29), monthLength(2024, 2));
    try testing.expectEqual(@as(u8, 28), monthLength(2026, 2));
    try testing.expectEqual(daysFromCivil(2026, 2, 28), addMonths(daysFromCivil(2026, 1, 31), 1));
    try testing.expectEqual(daysFromCivil(2025, 12, 16), addMonths(today, -11));
    try testing.expectEqual(daysFromCivil(2027, 11, 16), addMonths(today, 12));
    // November 2026 starts on a Sunday: the grid starts on the 1st.
    try testing.expectEqual(daysFromCivil(2026, 11, 1), gridStart(today));
    try testing.expectEqual(daysFromCivil(2026, 11, 29), gridStart(daysFromCivil(2026, 12, 5)));
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("November 2026", title(&buf, today));
    try testing.expectEqualStrings("November 16, 2026", valueText(&buf, today));
}

test "Datepicker: the page agrees in both front ends, closed and open" {
    const h = &harness;
    h.init();
    var t = try setState(h, .on(today));
    try testing.expectEqual(@as(u32, 6), t.len);
    var st: DateState = .on(today);
    st.open = true;
    t = try setState(h, st);
    try testing.expectEqual(@as(u32, 6 + dialog_rows), t.len);
    try testing.expectEqual(@as(u32, 2 + dialog_texts), h.ctx.texts[h.ctx.cur].len);
    const at = t.rect(t.find(.from("due")));
    try testing.expectEqual(at.x0, t.rect(t.find(.from("due_dialog"))).x0);
    // The first cell is November 1st, the last December 12th.
    try testing.expect(t.rect(t.find(.from("due_d0"))).x0 < t.rect(t.find(.from("due_d6"))).x0);
    try testing.expect(t.rect(t.find(.from("due_d0"))).y0 < t.rect(t.find(.from("due_d41"))).y0);
}

test "buttonStyle, dialogStyle, navStyle, cellStyle, dayText: the theme's tokens" {
    const th: Theme = .default;
    try testing.expectEqual(th.control_hot, buttonStyle(&th, .{ .hovered = true }).fill);
    try testing.expectEqual([2]f32{ 160, 0 }, buttonStyle(&th, .{}).min);
    const d = dialogStyle(&th, .{ .x0 = 10, .y0 = 0, .x1 = 170, .y1 = 30 });
    try testing.expectEqual(th.panel, d.fill);
    try testing.expectEqual([2]f32{ 10, 30 + th.gap }, d.offset);
    try testing.expectEqual(types.Color.transparent, navStyle(&th, false).fill);
    try testing.expectEqual(th.control_hot, navStyle(&th, true).fill);
    try testing.expectEqual(types.Color.transparent, cellStyle(&th, .{}).fill);
    try testing.expectEqual(th.control_hot, cellStyle(&th, .{ .hovered = true }).fill);
    try testing.expectEqual(th.accent, cellStyle(&th, .{ .chosen = true }).fill);
    try testing.expectEqual(th.accent, cellStyle(&th, .{ .chosen = true, .hovered = true }).fill);
    try testing.expectEqual(types.Color.transparent, cellStyle(&th, .{}).border_color);
    try testing.expectEqual(th.text, cellStyle(&th, .{ .focused = true }).border_color);
    try testing.expectEqual(th.text, dayText(&th, true).color);
    try testing.expectEqual(th.control_hot, dayText(&th, false).color);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .accent = .rgb(0, 90, 200), .pad = 12, .gap = 10, .radius = 0 };

test "Datepicker: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    var st: DateState = .on(today);
    st.open = true;
    st.focus = today + 1;
    st.hover = 3;
    const t = try setState(&S.h, st);
    // November 2026: cell k is the (k + 1)th.
    try testing.expectEqual(light.accent.bitsOf(), t.c.look[t.find(.from("due_d15"))].fill);
    try testing.expectEqual(light.text.bitsOf(), t.c.look[t.find(.from("due_d16"))].border_color);
    try testing.expectEqual(light.control_hot.bitsOf(), t.c.look[t.find(.from("due_d3"))].fill);
    try testing.expectEqual(light.panel.bitsOf(), t.c.look[t.find(.from("due_dialog"))].fill);
}

test "checkDatepicker: the state field" {
    try testing.expectEqual(null, comptime checkDatepicker(Default.State, "due"));
    try testing.expect(comptime std.mem.endsWith(u8, checkDatepicker(struct {}, "due").?, " has no field 'due'"));
    try testing.expectEqualStrings("datepicker: field 'due' must be a datepicker.DateState", comptime checkDatepicker(struct { due: i32 }, "due").?);
}

test {
    std.testing.refAllDecls(@This());
}
