//! Build a bounded set of rows from a borrowed presentation model. No domain writes or heap.
const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const list = lcgf.widgets_list;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const entity = @import("entity.zig");
const Model = @import("presenter.zig").Model;
const Commands = @import("../../core/commands.zig").Buffer(entity.Action, 8);
const table = @import("../../ui/virtual_table.zig");
const config = @import("../../config.zig");

pub const id = Id.from("workspace");
pub const table_id = Id.from("workspace.table");
pub const details_id = Id.from("workspace.details");

pub fn rowId(item: entity.ItemId) Id {
    return Id.from("workspace.row").with(@backingInt(item));
}

/// Keep enough room for chrome at the default 800x600 size; never build unbounded UI rows.
pub fn visibleRows(theme: *const w.Theme, height: f32) u32 {
    const available = @max(height - 250, list.rowHeight(theme));
    return @intFromFloat(@min(@floor(available / list.rowHeight(theme)), config.max_visible_rows));
}

pub fn draw(f: *Frame, theme: *const w.Theme, model: Model, commands: *Commands) error{Full}!void {
    _ = f.open(id, .{ .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 10, .clip = true });
    defer f.close();

    _ = f.text("Work queue", .{ .px = 22, .color = theme.text });
    var caption: [96]u8 = undefined;
    _ = w.label(f, theme, std.fmt.bufPrint(&caption, "{d} jobs in this view / {d} total", .{ model.indices.len, model.store.len }) catch unreachable);

    const selected = model.selected_index orelse lcgf.types.none;
    const visible = visibleRows(theme, f.in.viewport[1]);
    {
        const result = table.begin(f, theme, table_id, @intCast(model.indices.len), visible, selected, model.scroll);
        defer f.close();
        const tree = f.tree();
        tree.c.role[result.node.ix()] = @backingInt(lcgf.a11y_tree.Role.listbox);
        for (result.window.first..result.window.first + result.window.len) |position| {
            const index = model.indices[position];
            const item = model.store.idAt(index);
            const row = f.open(rowId(item), list.optionStyle(theme));
            f.setFill(row, list.optionFill(theme, result.hovered and result.under == position, selected == position));
            tree.c.role[row.ix()] = @backingInt(lcgf.a11y_tree.Role.option);
            var text: [80]u8 = undefined;
            const status: []const u8 = if (model.store.progress[index] == 1000) "done" else if (model.store.active[index]) "running" else "paused";
            _ = w.label(f, theme, std.fmt.bufPrint(&text, "Job {d:0>6}   {d:>3}%   {s}", .{ @backingInt(item), model.store.progress[index] / 10, status }) catch unreachable);
            f.close();
        }
        if (result.selected != selected) {
            const selection: ?entity.ItemId = if (result.selected == lcgf.types.none) null else model.store.idAt(model.indices[result.selected]);
            try commands.append(.{ .select = selection });
        }
        if (result.scroll != model.scroll) try commands.append(.{ .scroll = result.scroll });
    }

    if (model.indices.len == 0) _ = w.label(f, theme, "No matches. Choose another page.");
    _ = w.label(f, theme, "Wheel to scroll. Click a row, then use Up / Down / Home / End.");
    _ = f.open(details_id, .{ .size = .{ .fill, .fit }, .pad = @splat(10), .gap = 6, .radius = theme.radius, .fill = theme.panel });
    defer f.close();
    if (model.selected) |item| {
        if (model.store.indexOf(item)) |index| {
            var detail: [100]u8 = undefined;
            _ = w.label(f, theme, std.fmt.bufPrint(&detail, "Selected: Job {d}  |  {d}% complete", .{ @backingInt(item), model.store.progress[index] / 10 }) catch unreachable);
            _ = w.label(f, theme, if (selected == lcgf.types.none) "The selected job is hidden by this filter." else if (model.store.active[index]) "This job is running." else if (model.store.progress[index] == 1000) "This job is complete." else "This job is paused.");
        }
    } else {
        _ = w.label(f, theme, "Select a job to inspect it.");
        _ = w.label(f, theme, "Advance moves running jobs forward one step.");
    }
}
