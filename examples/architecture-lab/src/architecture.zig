//! Build-time architecture selection: no runtime strategy object or virtual dispatch.
pub const Architecture = enum { viper, mvp, mvvp, mvvm, mvvm_c };
