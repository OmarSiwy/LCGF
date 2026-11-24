//! Explicit budgets: domain capacity and visible UI capacity are deliberately independent.
const lcgf = @import("lcgf");

pub const initial_items: u32 = 100_000;
pub const max_visible_rows: u32 = 32;
pub const limits: lcgf.context.Limits = .{
    .nodes = 384,
    .texts = 160,
    .strings = 12 * 1024,
    .customs = 1,
    .signals = 8,
    .memos = 8,
    .anims = 8,
    .tweens = 8,
    .flips = 8,
    .timers = 4,
    .depth = 16,
};
