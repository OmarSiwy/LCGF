//! expect: page.html:14:5: component <sfy-tool> is missing from app.components: add `pub fn @"sfy-tool"(comptime props: anytype) lcgf.spec.Spec`
const page = @import("components_wrong");

comptime {
    _ = page.spec;
}
