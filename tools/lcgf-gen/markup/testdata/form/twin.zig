//! form, written by hand: text controls with literal placeholders, and on:submit on the field
//! and the text area.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const textfield = lcgf.widgets_textfield;
const search = lcgf.widgets_search;
const textarea = lcgf.widgets_textarea;

pub const theme: w.Theme = .{};

/// Accessible names the a11y export must carry (parity.zig).
pub const names = .{ "Sign up", "Search" };

pub const State = struct { name: textfield.Text(256) = .{}, find: textfield.Text(256) = .{}, bio: textfield.Text(256) = .{} };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.named(s.landmark(.form, .{}, .{
        textfield.ct.textfield(theme, .name, .name, "Your name"),
        s.named(search.ct.search(theme, .find, .find, "Find"), "Search"),
        textarea.ct.textarea(theme, .bio, .bio, 4, "About you"),
    }), "Sign up"),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        names: u32 = 0,
        bios: u32 = 0,
        edits: u32 = 0,
        name: [16]u8 = undefined,
        name_len: usize = 0,
        finds: u32 = 0,

        pub fn name_done(h: *@This(), _: *Ui) void {
            h.names += 1;
        }
        pub fn bio_done(h: *@This(), _: *Ui) void {
            h.bios += 1;
        }
        pub fn name_edited(h: *@This(), _: *Ui, text: []const u8) void {
            h.edits += 1;
            @memcpy(h.name[0..text.len], text);
            h.name_len = text.len;
        }
        pub fn found(h: *@This(), _: *Ui, _: []const u8) void {
            h.finds += 1;
        }
    };
}

const Event = lcgf.input.Input.Event;

/// N-SUBMIT: Enter submits the one-line field; in the text area Enter is a newline and
/// Ctrl+Enter submits.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{};
    const t = p.frame(h, &in).tree;
    const field = t.rect(t.find(.from("name")));
    const area = t.rect(t.find(.from("bio")));
    // Focus the field with a click, then type and press Enter.
    in.pointer = .{ (field.x0 + field.x1) / 2, (field.y0 + field.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    // on:change reports the text as it is typed; focus alone changes nothing.
    try std.testing.expectEqual(0, h.edits);
    const typed = [_]Event{.{ .kind = .text, .at = 0, .len = 2 }};
    in.events = &typed;
    in.text = "ab";
    _ = p.frame(h, &in);
    in.text = "";
    in.events = &.{};
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.edits);
    try std.testing.expectEqualStrings("ab", h.name[0..h.name_len]);
    const enter = [_]Event{.{ .kind = .press, .code = 0x28 }};
    in.events = &enter;
    _ = p.frame(h, &in);
    in.events = &.{};
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.names);
    // The text area: Enter adds a line, Ctrl+Enter submits.
    in.pointer = .{ (area.x0 + area.x1) / 2, (area.y0 + area.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    in.events = &enter;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(0, h.bios);
    const ctrl_enter = [_]Event{.{ .kind = .press, .code = 0x28, .mods = .{ .ctrl = true } }};
    in.events = &ctrl_enter;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.bios);
    try std.testing.expectEqual(1, h.names);
    // Enter submitted the name without changing it.
    try std.testing.expectEqual(1, h.edits);
    try std.testing.expectEqual(0, h.finds);
}
