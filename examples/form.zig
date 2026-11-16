//! Form with validation: two text fields (a name and an age) and a Submit button. Each field is
//! an `Editor` (src/text/edit/edit.zig) over bytes the application owns, fed the focused
//! widget's keys (`Keyboard`); validation is a plain function of the text, run every frame, and
//! its message is shown under the field once the field has been touched. Submit only takes the
//! values when both are valid. No text-field widget is used: src/widgets/textfield.zig (lane
//! w-textfield) is not merged yet, so the example builds the field from tier-0 parts.

const std = @import("std");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const Editor = lcgr.text_edit.Editor;
const Keyboard = lcgr.keyboard.Keyboard;
const Frame = lcgr.frame.Frame;
const types = lcgr.types;
const Id = types.Id;
const Color = types.Color;
const Events = lcgr.shell_iface.Events;

pub const id_name = Id.from("name");
pub const id_age = Id.from("age");
pub const id_submit = Id.from("submit");

const error_color: Color = .rgb(240, 90, 90);

/// Why a name is not accepted; null when it is.
pub fn checkName(s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " ");
    if (t.len == 0) return "Name is required";
    if (t.len < 2) return "Name needs at least 2 letters";
    return null;
}

/// Why an age is not accepted; null when it is.
pub fn checkAge(s: []const u8) ?[]const u8 {
    if (s.len == 0) return "Age is required";
    const n = std.fmt.parseInt(u8, s, 10) catch return "Age must be a whole number";
    if (n > 150) return "Age must be 150 or less";
    return null;
}

const Field = struct {
    bytes: [32]u8 = undefined,
    ed: Editor = undefined,
    /// Edited or submitted once: only then is its error shown.
    touched: bool = false,
};

pub const App = struct {
    theme: w.Theme = .default,
    name: Field = .{},
    age: Field = .{},
    ready: bool = false,
    /// The values taken by the last valid Submit.
    submitted: u32 = 0,
    saved_name: [32]u8 = undefined,
    saved_name_len: usize = 0,
    saved_age: u8 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        if (!app.ready) {
            app.name.ed = Editor.init(&app.name.bytes, "") catch unreachable;
            app.age.ed = Editor.init(&app.age.bytes, "") catch unreachable;
            app.ready = true;
        }
        const k: Keyboard = .{ .in = f.in, .target = f.ctx.inter.focus, .taken = 0 };

        _ = f.open(.from("form"), .{ .size = .{ .px(320), .fit }, .pad = @splat(16), .gap = 6, .fill = th.panel });
        const name_err = field(f, th, &k, id_name, "Name", &app.name, checkName);
        const age_err = field(f, th, &k, id_age, "Age", &app.age, checkAge);
        if (w.button(f, th, id_submit, "Submit").clicked) {
            app.name.touched = true;
            app.age.touched = true;
            if (name_err == null and age_err == null) {
                const n = std.mem.trim(u8, app.name.ed.text(), " ");
                @memcpy(app.saved_name[0..n.len], n);
                app.saved_name_len = n.len;
                app.saved_age = std.fmt.parseInt(u8, app.age.ed.text(), 10) catch unreachable;
                app.submitted += 1;
            }
        }
        var buf: [64]u8 = undefined;
        const status = if (app.submitted == 0) "Not submitted" else std.fmt.bufPrint(&buf, "Saved {s}, {d}", .{ app.saved_name[0..app.saved_name_len], app.saved_age }) catch "?";
        _ = w.label(f, th, status);
        f.close();
    }

    /// A labelled single-line field: the keys of this frame go to its editor when it is
    /// focused, its border shows focus, and its error (if touched) sits under it.
    fn field(f: *Frame, th: *const w.Theme, k: *const Keyboard, id: Id, caption: []const u8, fd: *Field, check: fn ([]const u8) ?[]const u8) ?[]const u8 {
        _ = w.label(f, th, caption);
        const focused = f.ctx.inter.focus == @backingInt(id);
        const box = f.open(id, .{ .size = .{ .fill, .fit }, .pad = @splat(6), .fill = th.control, .radius = th.radius, .border = 1, .border_color = if (focused) th.accent else th.control });
        _ = f.interact(box, .{ .hover = true, .click = true, .focus = true });
        f.setCursor(.text, f.ctx.inter.hot == @backingInt(id));
        if (fd.ed.update(k, id, .{}).changed) fd.touched = true;
        _ = w.label(f, th, fd.ed.text());
        f.close();
        const err = check(fd.ed.text());
        // Always one line, empty when there is nothing to say, so the form does not jump.
        const shown = if (fd.touched) err orelse "" else "";
        _ = f.text(shown, .{ .px = th.text_px, .color = error_color });
        return err;
    }
};

const testing = std.testing;
const host = @import("host");

test "check: what a name and an age must be" {
    try testing.expectEqualStrings("Name is required", checkName("  ").?);
    try testing.expectEqualStrings("Name needs at least 2 letters", checkName("A").?);
    try testing.expectEqual(null, checkName("Ada"));
    try testing.expectEqualStrings("Age must be a whole number", checkAge("4x").?);
    try testing.expectEqualStrings("Age must be 150 or less", checkAge("200").?);
    try testing.expectEqual(null, checkAge("36"));
}

test "form: an invalid Submit shows errors and saves nothing; fixed fields submit" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const name = host.center(s.rect(id_name));
    const age = host.center(s.rect(id_age));
    const submit = host.center(s.rect(id_submit));

    var rec: [1024]u8 = undefined;
    var wr = std.Io.Writer.fixed(&rec);
    try wr.writeAll("frame\nviewport 800 600\n");
    const click = "frame\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\n";
    // Type "A" as the name and "abc" as the age, then Submit: both invalid.
    try wr.print(click ++ "frame\ntext A\n", .{ name[0], name[1] });
    try wr.print(click ++ "frame\ntext abc\n", .{ age[0], age[1] });
    try wr.print(click, .{ submit[0], submit[1] });
    app = .{};
    s = try host.Smoke.run(&app, wr.buffered());
    try testing.expectEqual(@as(u32, 0), app.submitted);
    try testing.expectEqualStrings("A", app.name.ed.text());
    try testing.expectEqualStrings("abc", app.age.ed.text());
    // Both error messages are drawn: the frame has their text runs in the error colour.
    var errors: u32 = 0;
    const tx = s.out.?.texts;
    for (0..tx.len) |i| errors += @intFromBool(tx.c.color[i] == @as(u32, @bitCast(error_color)) and tx.c.bytes[i] != 0);
    try testing.expectEqual(@as(u32, 2), errors);

    // A fresh form: type "Ada" in two runs and "36", Submit: saved.
    wr = std.Io.Writer.fixed(&rec);
    try wr.writeAll("frame\nviewport 800 600\n");
    try wr.print(click ++ "frame\ntext A\nframe\ntext da\n", .{ name[0], name[1] });
    try wr.print(click ++ "frame\ntext 36\n", .{ age[0], age[1] });
    try wr.print(click ++ "frame\n", .{ submit[0], submit[1] });
    app = .{};
    s = try host.Smoke.run(&app, wr.buffered());
    try testing.expectEqual(@as(u32, 1), app.submitted);
    try testing.expectEqualStrings("Ada", app.saved_name[0..app.saved_name_len]);
    try testing.expectEqual(@as(u8, 36), app.saved_age);
}
