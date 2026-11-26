//! AccessKit's C interface (accesskit-c 0.23.2, include/accesskit.h): the part the bridge uses,
//! declared by hand (docs/DEPENDENCIES.md: a small API needs no header translation). Enum
//! values are the header's declaration order; a test checks the ones the bridge writes against
//! the library's own debug output.

const builtin = @import("builtin");

pub const NodeId = u64;
pub const Node = opaque {};
pub const TreeInfo = opaque {};
pub const TreeUpdate = opaque {};

/// `accesskit_role`: one byte. Only the values the bridge maps to are named.
pub const Role = enum(u8) {
    unknown = 0,
    text_run = 1,
    cell = 2,
    label = 3,
    image = 4,
    link = 5,
    row = 6,
    list_item = 7,
    tree_item = 9,
    list_box_option = 10,
    menu_item = 11,
    generic_container = 14,
    check_box = 15,
    radio_button = 16,
    text_input = 17,
    multiline_text_input = 31,
    search_input = 32,
    button = 18,
    row_header = 21,
    column_header = 22,
    row_group = 23,
    list = 24,
    table = 25,
    @"switch" = 29,
    menu = 30,
    alert = 44,
    alert_dialog = 45,
    article = 47,
    banner = 49,
    combo_box = 56,
    complementary = 58,
    content_info = 62,
    dialog = 66,
    feed = 71,
    form = 75,
    grid = 76,
    group = 78,
    heading = 80,
    list_box = 87,
    main = 89,
    menu_bar = 93,
    menu_item_check_box = 94,
    menu_item_radio = 95,
    meter = 97,
    navigation = 98,
    progress_indicator = 101,
    radio_group = 102,
    region = 103,
    scroll_bar = 107,
    scroll_view = 108,
    search = 109,
    slider = 113,
    spin_button = 114,
    splitter = 115,
    status = 116,
    tab = 120,
    tab_list = 121,
    tab_panel = 122,
    toolbar = 127,
    tooltip = 128,
    tree = 129,
    tree_grid = 130,
    window = 133,
    _,
};

/// `accesskit_action`.
pub const Action = enum(u8) {
    click = 0,
    focus = 1,
    blur = 2,
    collapse = 3,
    expand = 4,
    decrement = 6,
    increment = 7,
    set_value = 20,
    _,
};

pub const Toggled = enum(u8) { false, true, mixed };
pub const Live = enum(u8) { off, polite, assertive };
pub const AriaCurrent = enum(u8) { false, true, page, step, location, date, time };
pub const Invalid = enum(u8) { true, grammar, spelling };

pub const Rect = extern struct { x0: f64, y0: f64, x1: f64, y1: f64 };
pub const Affine = extern struct { m: [6]f64 };

/// `accesskit_action_data`: a C enum tag, then a union whose largest member (a text selection,
/// two node-and-index pairs) is four words.
pub const ActionData = extern struct {
    tag: Tag,
    u: extern union {
        custom_action: i32,
        value: ?[*:0]u8,
        numeric_value: f64,
        words: [4]u64,
    },

    pub const Tag = enum(c_int) { custom_action, value, numeric_value, scroll_unit, scroll_hint, scroll_to_point, set_scroll_offset, set_text_selection, _ };
};

/// `accesskit_action_request`. Owned by the action handler, which frees it.
pub const ActionRequest = extern struct {
    action: Action,
    target_tree: [16]u8,
    target_node: NodeId,
    data: extern struct { has_value: bool, value: ActionData },
};

pub const TreeUpdateFactory = *const fn (userdata: ?*anyopaque) callconv(.c) ?*TreeUpdate;
pub const ActivationHandler = *const fn (userdata: ?*anyopaque) callconv(.c) ?*TreeUpdate;
pub const ActionHandler = *const fn (request: *ActionRequest, userdata: ?*anyopaque) callconv(.c) void;
pub const DeactivationHandler = *const fn (userdata: ?*anyopaque) callconv(.c) void;

pub extern fn accesskit_node_new(role: Role) *Node;
pub extern fn accesskit_node_free(node: *Node) void;
pub extern fn accesskit_node_add_action(node: *Node, action: Action) void;
pub extern fn accesskit_node_set_children(node: *Node, length: usize, values: [*]const NodeId) void;
pub extern fn accesskit_node_set_label_with_length(node: *Node, value: [*]const u8, length: usize) void;
pub extern fn accesskit_node_set_value_with_length(node: *Node, value: [*]const u8, length: usize) void;
pub extern fn accesskit_node_set_character_lengths(node: *Node, length: usize, values: [*]const u8) void;
pub extern fn accesskit_node_set_placeholder_with_length(node: *Node, value: [*]const u8, length: usize) void;
pub extern fn accesskit_node_set_bounds(node: *Node, value: Rect) void;
pub extern fn accesskit_node_set_transform(node: *Node, value: Affine) void;
pub extern fn accesskit_node_set_level(node: *Node, value: usize) void;
pub extern fn accesskit_node_set_numeric_value(node: *Node, value: f64) void;
pub extern fn accesskit_node_set_toggled(node: *Node, value: Toggled) void;
pub extern fn accesskit_node_set_expanded(node: *Node, value: bool) void;
pub extern fn accesskit_node_set_selected(node: *Node, value: bool) void;
pub extern fn accesskit_node_set_disabled(node: *Node) void;
pub extern fn accesskit_node_set_read_only(node: *Node) void;
pub extern fn accesskit_node_set_required(node: *Node) void;
pub extern fn accesskit_node_set_busy(node: *Node) void;
pub extern fn accesskit_node_set_invalid(node: *Node, value: Invalid) void;
pub extern fn accesskit_node_set_live(node: *Node, value: Live) void;
pub extern fn accesskit_node_set_aria_current(node: *Node, value: AriaCurrent) void;
pub extern fn accesskit_node_set_min_numeric_value(node: *Node, value: f64) void;
pub extern fn accesskit_node_set_max_numeric_value(node: *Node, value: f64) void;
pub extern fn accesskit_node_set_numeric_value_step(node: *Node, value: f64) void;

pub extern fn accesskit_tree_info_new(root: NodeId) *TreeInfo;
pub extern fn accesskit_tree_info_set_toolkit_name_with_length(tree: *TreeInfo, name: [*]const u8, length: usize) void;
pub extern fn accesskit_tree_update_with_capacity_and_focus(capacity: usize, focus: NodeId) *TreeUpdate;
pub extern fn accesskit_tree_update_free(update: *TreeUpdate) void;
pub extern fn accesskit_tree_update_push_node(update: *TreeUpdate, id: NodeId, node: *Node) void;
pub extern fn accesskit_tree_update_set_tree_info(update: *TreeUpdate, tree: *TreeInfo) void;
pub extern fn accesskit_tree_update_debug(update: *const TreeUpdate) [*:0]u8;

pub extern fn accesskit_action_request_free(request: *ActionRequest) void;
pub extern fn accesskit_string_free(string: [*:0]u8) void;
pub extern fn accesskit_affine_scale(s: f64) Affine;
