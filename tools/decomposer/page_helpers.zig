// Inserted into the generated module. These helpers resolve during Zig compilation.
fn labelStyle(comptime node: s.Spec, comptime patch: anytype) s.Spec {
    var result = node;
    var text_style = w.labelText(&theme);
    inline for (@typeInfo(@TypeOf(patch)).@"struct".field_names) |name|
        @field(text_style, name) = @field(patch, name);
    result.text_style = text_style;
    return result;
}

fn buttonCaption(comptime node: s.Spec, comptime patch: anytype) s.Spec {
    var result = node;
    result.children = &.{labelStyle(node.children[0], patch)};
    return result;
}
