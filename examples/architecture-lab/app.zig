//! Package entry point. Keep the application independent of the window-system adapter.
pub const options = @import("app_options");
pub const Viper = @import("src/app.zig").App;
pub const Mvp = @import("src/architectures/mvp/root.zig").App;
pub const Mvvp = @import("src/architectures/mvvp/root.zig").App;
pub const Mvvm = @import("src/architectures/mvvm/root.zig").App;
pub const MvvmC = @import("src/architectures/mvvm_c/root.zig").App;
pub const App = switch (options.architecture) {
    .viper => Viper,
    .mvp => Mvp,
    .mvvp => Mvvp,
    .mvvm => Mvvm,
    .mvvm_c => MvvmC,
};
pub const limits = @import("src/config.zig").limits;

test {
    _ = @import("src/tests.zig");
    _ = @import("src/architecture_tests.zig");
}
