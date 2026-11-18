fn Writer(comptime names: anytype) type {
    return struct {
        runtime: *Ui.Signals.Runtime,

        pub fn get(writer: *@This(), comptime field: @EnumLiteral()) @FieldType(SourceState, @tagName(field)) {
            const name = @tagName(field);
            if (comptime @hasField(State, name)) return @field(writer.runtime.state, name);
            return @field(defaults, name);
        }

        pub fn set(writer: *@This(), comptime field: @EnumLiteral(), value: @FieldType(SourceState, @tagName(field))) void {
            inline for (names) |name| {
                if (comptime std.mem.eql(u8, name, @tagName(field)))
                    return writer.runtime.set(@field(Ui.Signals.Field, name), value);
            }
            @compileError("Zig callback has no declared write to '" ++ @tagName(field) ++ "'");
        }
    };
}
