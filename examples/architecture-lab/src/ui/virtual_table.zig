//! A view primitive, not another VIPER module. It knows visible positions, never domain IDs.
//! Reuse LCGF's row geometry and keyboard rules while formatting only rows on screen.
const lcgf = @import("lcgf");
const list = lcgf.widgets_list;
const virtual = lcgf.widgets_vlist;
const Frame = lcgf.frame.Frame;
const Theme = lcgf.widgets_base.Theme;
const Id = lcgf.types.Id;
const none = lcgf.types.none;

pub const Result = struct {
    window: virtual.Window,
    selected: u32,
    scroll: f32,
    under: u32,
    hovered: bool,
    node: lcgf.types.Node,
};

/// Opens the table; caller adds exactly the visible rows and closes it. Returned changes are
/// draft values to turn into actions. The drawing still uses this frame's committed snapshot.
pub fn begin(f: *Frame, theme: *const Theme, id: Id, count: u32, visible: u32, selected: u32, scroll: f32) Result {
    const response = f.ctx.inter.response(id);
    const offset = virtual.wheel(theme, scroll, 0, count, visible);
    const under = if (count == 0) none else virtual.rowAt(theme, f.lastRect(id).y0, f.in.pointer[1], offset, count);
    var next_selected = selected;
    if (response.clicked and count != 0) next_selected = under;
    if (response.focused) {
        for (f.in.events) |event| switch (event.kind) {
            .press, .repeat => next_selected = list.step(next_selected, count, event.code, &list.default_keys),
            .release, .text => {},
        };
    }
    var next_scroll = offset;
    if (next_selected != selected) next_scroll = virtual.reveal(theme, next_scroll, next_selected, visible);
    const delta = if (response.hovered) f.in.wheel[1] * list.rowHeight(theme) + f.in.scroll[1] else 0;
    next_scroll = virtual.wheel(theme, next_scroll, delta, count, visible);

    var style = virtual.vlistStyle(theme, visible, offset);
    style.size[0] = .fill;
    style.border_color = list.listBorder(theme, response.focused);
    const node = f.open(id, style);
    _ = f.interact(node, .button);
    f.tree().c.value[node.ix()] = list.selectedValue(selected);
    return .{
        .window = virtual.window(theme, count, visible, offset),
        .selected = next_selected,
        .scroll = next_scroll,
        .under = under,
        .hovered = response.hovered,
        .node = node,
    };
}
