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
const keys = @import("keys.zig");
const a11y = @import("../a11y/tree.zig");
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
    pub fn role(b: *TableBuilder, i: u32, r: a11y.Role) void {
        b.t.c.role[i] = @backingInt(r);
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
    pub fn role(b: *FrameBuilder, i: u32, r: a11y.Role) void {
        b.f.tree().c.role[i] = @backingInt(r);
    }
};

/// The button's rows: the button (filled by its response `r`) and its label, the chosen date.
pub fn buildButton(b: anytype, th: *const Theme, comptime name: []const u8, st: DateState, r: Response) u32 {
    var buf: [48]u8 = undefined;
    const i = b.open(.from(name), valued(buttonStyle(th, r), st));
    b.text(valueText(&buf, st.value), base.labelText(th));
    b.close();
    return i;
}

/// The dialog's rows, below the button's rect `at` (last frame's): a header (previous month,
/// the month's title, next month), the weekdays, and six weeks of days.
pub fn buildDialog(b: anytype, th: *const Theme, comptime name: []const u8, st: DateState, at: Rect) void {
    var buf: [48]u8 = undefined;
    b.role(b.open(.from(partName(name, "dialog")), dialogStyle(th, at)), .dialog);
    _ = b.open(.none, headerStyle(th));
    b.role(b.open(.from(partName(name, "prev")), navStyle(th, st.hover == Target.prev)), .button);
    b.text("<", base.labelText(th));
    b.close();
    b.role(b.open(.from(partName(name, "title")), titleStyle()), .heading);
    b.text(title(&buf, st.focus), base.labelText(th));
    b.close();
    b.role(b.open(.from(partName(name, "next")), navStyle(th, st.hover == Target.next)), .button);
    b.text(">", base.labelText(th));
    b.close();
    b.close();
    b.role(b.open(.from(partName(name, "grid")), gridStyle(th)), .grid);
    b.role(b.open(.none, weekStyle()), .row);
    for (weekday_texts) |w| {
        b.role(b.open(.none, cellStyle(th, .{})), .column_header);
        b.text(w, base.labelText(th));
        b.close();
    }
    b.close();
    const start = gridStart(st.focus);
    const month = civil(st.focus).month;
    inline for (0..6) |week| {
        b.role(b.open(.none, weekStyle()), .row);
        inline for (0..7) |wd| {
            const k: u8 = week * 7 + wd;
            const day: i32 = start + @as(i32, k);
            const d = civil(day);
            b.role(b.open(cellId(name, k), cellStyle(th, .{ .hovered = st.hover == k, .focused = day == st.focus, .chosen = day == st.value })), .cell);
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

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// What the pointer did to a date picker this frame.
pub const Hits = struct {
    /// The button was clicked.
    toggle: bool = false,
    /// The left button is down.
    down: bool = false,
    /// What the pointer is over in last frame's dialog (`targetAt`).
    target: u8 = no_target,
};

/// `press` after a press outside the open dialog closed it, so the click it ends on the button
/// does not open it again.
const dismissed: u8 = 0xfe;

/// One frame of a date picker (APG date picker dialog). The button's click opens the dialog on
/// the chosen date; a press outside it closes it. In the dialog, a click (press and release on
/// the same part) on a day chooses it and closes the dialog, on the month buttons shows the
/// previous or next month. While it is open, keys move the focused day: Left and Right by a
/// day, Up and Down by a week, Home and End to the week's first and last day, Page Up and Page
/// Down by a month (with Shift, a year), each shown in its month's grid; Enter or Space choose
/// it and close; Escape closes. Keys are read in order.
pub fn advance(st: DateState, hits: Hits, evs: []const Input.Event) DateState {
    var s = st;
    const press = hits.down and !st.down;
    const release = !hits.down and st.down;
    s.down = hits.down;
    s.hover = hits.target;
    const was = st.press;
    if (press) {
        s.press = hits.target;
        if (st.open and hits.target == no_target) {
            s.open = false;
            s.press = dismissed;
        }
    }
    if (hits.toggle and was != dismissed) {
        s.open = !st.open;
        s.focus = s.value;
    }
    if (release) {
        if (s.open and was == hits.target and was < Target.dialog) s = activate(s, was);
        s.press = no_target;
    }
    for (evs) |e| {
        if (!s.open) break;
        if (e.kind != .press and e.kind != .repeat) continue;
        const years: i32 = if (e.mods.shift) 12 else 1;
        const wd: i32 = weekday(s.focus);
        switch (e.code) {
            keys.right => s.focus += 1,
            keys.left => s.focus -= 1,
            keys.down => s.focus += 7,
            keys.up => s.focus -= 7,
            keys.home => s.focus -= wd,
            keys.end => s.focus += 6 - wd,
            keys.page_up => s.focus = addMonths(s.focus, -years),
            keys.page_down => s.focus = addMonths(s.focus, years),
            keys.enter, keys.space => {
                s.value = s.focus;
                s.open = false;
            },
            popover.keys.escape => s.open = false,
            else => {},
        }
    }
    if (!s.open) s.hover = no_target;
    return s;
}

/// Clicking target `t` of the open dialog: a day is chosen (and focused) and the dialog closes;
/// the month buttons show the previous or next month.
fn activate(st: DateState, t: u8) DateState {
    var s = st;
    switch (t) {
        Target.prev => s.focus = addMonths(s.focus, -1),
        Target.next => s.focus = addMonths(s.focus, 1),
        else => {
            s.value = gridStart(s.focus) + @as(i32, t);
            s.focus = s.value;
            s.open = false;
        },
    }
    return s;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The button's style with the value column set: the chosen date, days since 1970-01-01 (exact
/// in an f32 for any date a calendar shows).
pub fn valued(s: Style, st: DateState) Style {
    var out = s;
    out.value = @floatFromInt(st.value);
    return out;
}

/// The semantics of date picker `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`. The columns hold the roles (the
/// button `button`, valued by `valued`, named by its text, the chosen date; the dialog
/// `dialog`; its title `heading`; the month buttons `button`; the grid `grid` of `row`s, the
/// weekdays `column_header`, the days `cell`, named by their number). Here: the button is
/// expandable and expanded while the dialog is shown (`aria-expanded`), the dialog is named by
/// its title (`aria-labelledby`, the month shown) and the chosen day is `selected`
/// (`aria-selected`). Works on either front end's tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8, st: DateState) void {
    const b = t.find(.from(name));
    if (b == types.none) return;
    const d = t.find(.from(partName(name, "dialog")));
    s.c.state[b] |= a11y.State.bitsOf(.{ .expandable = true, .expanded = d != types.none });
    if (d == types.none) return;
    s.c.labelled_by[d] = t.find(.from(partName(name, "title")));
    const k = st.value - gridStart(st.focus);
    inline for (0..cells) |c| {
        if (k == c) s.c.state[t.find(cellId(name, c))] |= a11y.State.bitsOf(.{ .selected = true });
    }
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
            /// The button's click, the pointer over last frame's tree and the keys, through
            /// `advance`; and the button's rect, kept for `push`.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = row;
                const U = @TypeOf(ui.*);
                const me = @field(U.Events.Widget, id);
                const clicked = if (event) |e| std.meta.activeTag(e) == me else false;
                const t = &ui.tables.t;
                const at: Rect = if (ui.built) rectIn(t, .from(id)) else .{};
                ui.keep(Layer).* = .{ at.x0, at.y0, at.x1, at.y1 };
                const hits: Hits = .{ .toggle = clicked, .down = in.buttons.left, .target = if (ui.built) targetAt(t, id, in.pointer) else no_target };
                ui.signals.set(comptime U.field(field_name), advance(@field(ui.signals.state, field_name), hits, in.events));
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
    // Input is applied before anything is built, from last frame's tree, as in the comptime
    // front end.
    const r = f.ctx.inter.response(.from(name));
    st.* = advance(st.*, .{ .toggle = r.clicked, .down = f.in.buttons.left, .target = targetAt(f.prevTree(), name, f.in.pointer) }, f.in.events);
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

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example's first value: 2026-11-16, a Monday.
pub const today: i32 = 20773;

/// The example page: a toolbar with a caption and the date picker, and the date picker's
/// dialog, in both front ends, in theme `th`. The tests and the golden images
/// (tools/golden/) run it.
pub fn Example(comptime th: Theme) type {
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

/// Input for `Example(.default)` at 800 x 600, one commented line per frame.
pub const replay = @embedFile("testdata/datepicker.replay");

/// The frames of `replay` kept as golden images, by name (tools/golden/ref/widgets/<name>.png).
pub const golden_frames = .{
    .{ "datepicker-open", 2 },
    .{ "datepicker-keyed", 4 },
    .{ "datepicker-month", 5 },
    .{ "datepicker-hover", 6 },
    .{ "datepicker-chosen", 8 },
};

/// What tools/golden/ dumps: the page's harness over `replay`.
pub const golden = struct {
    pub const Run = Example(.default).Run;
    pub const src = replay;
    pub const frames = golden_frames;
};

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;
const Page = Example;

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
    const t = try setState(&S.h, st);
    // November 2026: cell k is the (k + 1)th.
    try testing.expectEqual(light.accent.bitsOf(), t.c.look[t.find(.from("due_d15"))].fill);
    try testing.expectEqual(light.text.bitsOf(), t.c.look[t.find(.from("due_d16"))].border_color);
    try testing.expectEqual(types.Color.transparent.bitsOf(), t.c.look[t.find(.from("due_d3"))].fill); // the pointer is not over it
    try testing.expectEqual(light.panel.bitsOf(), t.c.look[t.find(.from("due_dialog"))].fill);
}

test "Datepicker: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var r: Replay = .{ .src = replay };
    var st: [12]DateState = undefined;
    while (try r.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        try testing.expectEqual(h.app.due, h.ui.signals.state.due);
        st[k] = h.app.due;
        if (k == 2) {
            // The rects the replay's comments give.
            const want = [_]struct { []const u8, Rect }{
                .{ "due", .{ .x0 = 41, .y0 = 8, .x1 = 201, .y1 = 42 } },
                .{ "due_dialog", .{ .x0 = 41, .y0 = 48, .x1 = 281, .y1 = 294 } },
                .{ "due_d0", .{ .x0 = 49, .y0 = 118, .x1 = 81, .y1 = 146 } },
                .{ "due_d32", .{ .x0 = 177, .y0 = 230, .x1 = 209, .y1 = 258 } },
            };
            for (want) |w| try testing.expectEqual(w[1], t.rect(t.find(.hash(w[0]))));
        }
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    const open = [_]bool{ false, false, true, true, true, true, true, true, false, false, true, false };
    const d = daysFromCivil;
    const focus = [_]i32{ today, today, today, today + 1, today + 8, d(2026, 12, 24), d(2026, 12, 24), d(2026, 12, 24), d(2026, 12, 31), d(2026, 12, 31), d(2026, 12, 31), d(2026, 12, 31) };
    for (st, open, focus) |s, o, f| {
        try testing.expectEqual(o, s.open);
        try testing.expectEqual(f, s.focus);
    }
    try testing.expectEqual(today, st[7].value);
    try testing.expectEqual(d(2026, 12, 31), st[8].value);
    try testing.expectEqual(@as(u8, 32), st[6].hover);
    try testing.expectEqual(d(2026, 12, 31), st[11].value);
}

test "golden_frames: name frames the replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 12);
}

fn ev(comptime codes: []const u8) [codes.len]Input.Event {
    var out: [codes.len]Input.Event = undefined;
    for (&out, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
    return out;
}

test "advance: the button opens on the value; keys move by day, week, month and year; Enter chooses" {
    var s = advance(.on(today), .{ .toggle = true }, &.{});
    try testing.expect(s.open and s.focus == today);
    s = advance(s, .{}, &ev(&.{ keys.right, keys.down })); // Tuesday the 24th
    try testing.expectEqual(today + 8, s.focus);
    s = advance(s, .{}, &ev(&.{ keys.home, keys.left, keys.up })); // Sunday 22nd, Saturday 21st, 14th
    try testing.expectEqual(daysFromCivil(2026, 11, 14), s.focus);
    s = advance(s, .{}, &ev(&.{keys.end}));
    try testing.expectEqual(daysFromCivil(2026, 11, 14), s.focus); // already Saturday
    s = advance(s, .{}, &ev(&.{ keys.page_down, keys.page_down, keys.page_down })); // 2027-02-14
    try testing.expectEqual(daysFromCivil(2027, 2, 14), s.focus);
    const shift_up = [1]Input.Event{.{ .kind = .press, .code = keys.page_up, .mods = .{ .shift = true } }};
    s = advance(s, .{}, &shift_up);
    try testing.expectEqual(daysFromCivil(2026, 2, 14), s.focus);
    s = advance(s, .{}, &ev(&.{keys.enter}));
    try testing.expect(!s.open and s.value == daysFromCivil(2026, 2, 14));
    s = advance(s, .{}, &ev(&.{keys.right})); // closed: keys do nothing
    try testing.expectEqual(daysFromCivil(2026, 2, 14), s.focus);
    s = advance(s, .{ .toggle = true }, &ev(&.{ keys.right, popover.keys.escape }));
    try testing.expect(!s.open and s.value == daysFromCivil(2026, 2, 14));
}

test "advance: clicks choose a day or move a month; a press outside closes and does not reopen" {
    var s = advance(.on(today), .{ .toggle = true }, &.{});
    s = advance(s, .{ .down = true, .target = Target.next }, &.{});
    s = advance(s, .{ .target = Target.next }, &.{});
    try testing.expectEqual(daysFromCivil(2026, 12, 16), s.focus);
    // December 2026's grid starts on Sunday November 29th: cell 5 is December 4th.
    s = advance(s, .{ .down = true, .target = 5 }, &.{});
    try testing.expectEqual(@as(u8, 5), s.hover);
    s = advance(s, .{ .target = 6 }, &.{}); // released elsewhere: no click
    try testing.expect(s.open);
    s = advance(s, .{ .down = true, .target = 5 }, &.{});
    s = advance(s, .{ .target = 5 }, &.{});
    try testing.expect(!s.open and s.value == daysFromCivil(2026, 12, 4));
    s = advance(s, .{ .toggle = true }, &.{});
    s = advance(s, .{ .down = true }, &.{}); // on the button: outside the dialog
    try testing.expect(!s.open);
    s = advance(s, .{ .toggle = true }, &.{}); // the click ends on the button
    try testing.expect(!s.open);
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null };

/// Runs `script` through both front ends, aiming at last frame's rects, with the picker's
/// state equal in both after every step; returns the state after each.
fn runScript(comptime n: usize, script: [n]Step) ![n]DateState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var e: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]DateState = undefined;
    for (script, &out) |st, *o| {
        in.pointer = switch (st.aim) {
            .at => |p| p,
            .part => |name| blk: {
                const r = last.rect(last.find(.hash(name)));
                break :blk .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
            },
        };
        in.buttons.left = st.left;
        in.events = &.{};
        if (st.key) |k| {
            e[0] = .{ .kind = .press, .code = k };
            in.events = &e;
        }
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(h.app.due, h.ui.signals.state.due);
        o.* = h.app.due;
    }
    return out;
}

test "Datepicker: open, keys, month buttons, clicks and Escape in both front ends" {
    const s = try runScript(12, .{
        .{ .aim = .{ .part = "due" }, .left = true },
        .{ .aim = .{ .part = "due" } }, // open on the 16th
        .{ .aim = .{ .part = "due" }, .key = keys.down }, // the 23rd
        .{ .aim = .{ .part = "due" }, .key = keys.page_down }, // December 23rd
        .{ .aim = .{ .part = "due_prev" } },
        .{ .aim = .{ .part = "due_prev" }, .left = true },
        .{ .aim = .{ .part = "due_prev" } }, // November 23rd
        .{ .aim = .{ .part = "due_d9" } }, // hover the 10th
        .{ .aim = .{ .part = "due_d9" }, .left = true },
        .{ .aim = .{ .part = "due_d9" } }, // chosen
        .{ .aim = .{ .part = "due" }, .key = keys.enter }, // closed: nothing
        .{ .aim = .{ .at = .{ 390, 290 } }, .left = true },
    });
    try testing.expect(s[1].open and s[1].focus == today);
    try testing.expectEqual(today + 7, s[2].focus);
    try testing.expectEqual(daysFromCivil(2026, 12, 23), s[3].focus);
    try testing.expectEqual(Target.prev, s[4].hover);
    try testing.expectEqual(today + 7, s[6].focus);
    try testing.expectEqual(@as(u8, 9), s[7].hover);
    try testing.expect(!s[9].open and s[9].value == daysFromCivil(2026, 11, 10));
    try testing.expect(!s[10].open and !s[11].open);
}

var sem: [2]@import("popover.zig").Semantic(160) = .{ .{}, .{} };

test "Datepicker: a button valued by its date, opening a dialog named by its month with a grid of days" {
    const pop = @import("popover.zig");
    const h = &harness;
    h.init();
    var st: DateState = .on(today);
    st.open = true;
    const t = try setState(h, st);
    const cp = &h.ui.tables.t;
    semantics(t, sem[0].begin(), "due", h.app.due);
    semantics(cp, sem[1].begin(), "due", h.ui.signals.state.due);
    const e = sem[0].finish(t, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(pop.sameSemantics(e, sem[1].finish(cp, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const row = struct {
        fn of(x: *const a11y.Export, tr: *const Tree, comptime id: []const u8) u32 {
            return pop.exportRow(x, tr.find(.from(id)));
        }
    }.of;
    const H = std.hash.Fnv1a_32;
    const b = row(e, t, "due");
    try testing.expectEqual(@backingInt(a11y.Role.button), e.c.role[b]);
    try testing.expectEqual(H.hash("November 16, 2026"), e.c.name_hash[b]);
    try testing.expectEqual(@as(f32, today), e.c.value[b]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true, .expanded = true }), e.c.state[b]);
    const d = row(e, t, "due_dialog");
    try testing.expectEqual(@backingInt(a11y.Role.dialog), e.c.role[d]);
    try testing.expectEqual(H.hash("November 2026"), e.c.name_hash[d]);
    try testing.expectEqual(@backingInt(a11y.Role.heading), e.c.role[row(e, t, "due_title")]);
    try testing.expectEqual(@backingInt(a11y.Role.grid), e.c.role[row(e, t, "due_grid")]);
    const c = row(e, t, "due_d15"); // the 16th
    try testing.expectEqual(@backingInt(a11y.Role.cell), e.c.role[c]);
    try testing.expectEqual(H.hash("16"), e.c.name_hash[c]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .selected = true }), e.c.state[c]);
    try testing.expectEqual(@as(u8, 0), e.c.state[row(e, t, "due_d14")]);
    // A week row and a weekday heading.
    const week = t.c.parent[t.find(.from("due_d15"))];
    try testing.expectEqual(@backingInt(a11y.Role.row), t.c.role[week]);
    try testing.expectEqual(@backingInt(a11y.Role.column_header), t.c.role[t.find(.from("due_grid")) + 2]);
    // Closed: collapsed.
    const t2 = try setState(h, .on(today));
    semantics(t2, sem[0].begin(), "due", h.app.due);
    const e2 = sem[0].finish(t2, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true }), e2.c.state[row(e2, t2, "due")]);
}

test "checkDatepicker: the state field" {
    try testing.expectEqual(null, comptime checkDatepicker(Default.State, "due"));
    try testing.expect(comptime std.mem.endsWith(u8, checkDatepicker(struct {}, "due").?, " has no field 'due'"));
    try testing.expectEqualStrings("datepicker: field 'due' must be a datepicker.DateState", comptime checkDatepicker(struct { due: i32 }, "due").?);
}

test {
    std.testing.refAllDecls(@This());
}
