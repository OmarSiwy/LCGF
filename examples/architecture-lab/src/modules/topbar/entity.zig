//! Top bar-owned preferences and its typed user intentions.

pub const State = struct {
    dark: bool = true,
};

pub const Action = union(enum) {
    toggle_theme: void,
    advance: void,
    toggle_sidebar: void,
};
