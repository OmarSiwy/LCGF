//! LCGF composition only: draw the projection and append intentions for later dispatch.

const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Id = lcgf.types.Id;
const Frame = lcgf.frame.Frame;
const Page = @import("../../core/navigation.zig").Page;
const Action = @import("entity.zig").Action;
const Model = @import("presenter.zig").Model;
const Commands = @import("../../core/commands.zig").Buffer(Action, 8);
const button = @import("../../ui/button.zig");

pub const id = Id.from("sidebar");
pub const collapse_id = Id.from("sidebar.collapse");

/// IDs come from page identity, so collapsing or reordering cannot move focus to a new page.
pub fn pageId(page: Page) Id {
    return Id.from("sidebar.page").with(@backingInt(page));
}

pub fn draw(f: *Frame, theme: *const w.Theme, model: Model, commands: *Commands) error{Full}!void {
    _ = f.open(id, .{
        .size = .{ .px(if (model.collapsed) 70 else 168), .fill },
        .pad = @splat(12),
        .gap = 10,
        .fill = theme.panel,
        .clip = true,
    });
    defer f.close();

    _ = w.label(f, theme, if (model.collapsed) "NAV" else "WORKSPACE");
    const pages = [_]Page{ .all, .running, .completed };
    for (pages) |page| {
        const caption = if (model.collapsed) shortTitle(page) else page.title();
        const response = button.drawSelected(f, theme, pageId(page), caption, model.page == page, true);
        if (response.clicked) try commands.append(.{ .navigate = page });
    }

    // A layout spacer is a node, not a retained widget object or an allocation.
    _ = f.leaf(.none, .{ .size = .{ .fill, .fill } });
    if (button.draw(f, theme, collapse_id, if (model.collapsed) ">" else "Collapse <").clicked)
        try commands.append(.toggle);
    _ = w.label(f, theme, if (model.collapsed) "L" else "LCGF Lab");
}

fn shortTitle(page: Page) []const u8 {
    return switch (page) {
        .all => "A",
        .running => "R",
        .completed => "C",
    };
}
