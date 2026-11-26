//! The twin's page as the generated module names it, for cost_probe.zig.

const lcgf = @import("lcgf");
const twin = @import("twin");

pub const State = if (@hasDecl(twin, "State")) twin.State else struct {};
pub const Ui = if (@hasDecl(twin, "Tokens"))
    lcgf.widgets_base.ComptimeUiTokens(State, twin.spec, twin.theme, twin.Tokens)
else
    lcgf.widgets_base.ComptimeUi(State, twin.spec, twin.theme);
