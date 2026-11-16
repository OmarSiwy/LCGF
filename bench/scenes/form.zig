//! Static form: 200 nodes of labels, text fields, checkboxes, sliders and buttons in an
//! 800 x 600 window, with the pointer moving across it.
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "form", .frames = 3000, .input = input, .build = build };

const names = [_][]const u8{
    "Name",     "Email", "Phone", "Street",  "City",    "Postcode", "Country",
    "Company",  "Title", "Team",  "Manager", "Website", "Timezone", "Language",
    "Currency", "Theme", "Font",  "Density", "Backup",  "Sync",     "Alerts",
};
var checks: [names.len]bool = @splat(false);
var values: [names.len]f32 = @splat(0.5);

fn input(in: *ui.Input, k: u32) void {
    in.viewport = .{ 800, 600 };
    in.pointer = .{ @floatFromInt(20 + (k * 7) % 760), @floatFromInt(20 + (k * 13) % 560) };
}

/// Root, form, title and separator (4), 21 fields of 9 nodes, a footer of 7: 200 nodes.
fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const base = ui.Id.from("form");
    _ = f.open(base, .{ .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 4, .fill = th.panel });
    _ = f.text("Account settings", .{ .px = 20, .color = th.text });
    _ = f.leaf(.none, .{ .size = .{ .fill, .px(1) }, .fill = th.control_hot });
    for (names, &checks, &values, 0..) |name, *check, *value, r| {
        const id = base.with(@intCast(r));
        _ = f.open(id, .{ .dir = .x, .size = .{ .fill, .fit }, .gap = th.gap, .cross = .center });
        _ = f.textStyled(name, .{ .px = th.text_px, .color = th.text }, .{ .size = .{ .px(90), .fit } });
        _ = f.open(id.with(1), .{ .size = .{ .grow(1), .fit }, .pad = @splat(4), .radius = th.radius, .fill = th.control, .border = 1, .border_color = th.control_hot });
        _ = ui.widgets.label(f, th, name);
        f.close();
        _ = ui.widgets.checkbox(f, th, id.with(2), check, "On");
        _ = ui.widgets.slider(f, th, id.with(3), value, 0, 1);
        f.close();
    }
    _ = f.open(base.with(1000), .{ .dir = .x, .gap = th.gap, .main = .end, .size = .{ .fill, .fit } });
    _ = ui.widgets.button(f, th, base.with(1001), "Cancel");
    _ = ui.widgets.button(f, th, base.with(1002), "Reset");
    _ = ui.widgets.button(f, th, base.with(1003), "Save");
    f.close();
    f.close();
}
