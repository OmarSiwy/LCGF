//! A bounded authoring compiler for an explicitly declared CSS-like subset. Its output is
//! ordinary Rule/Declaration data consumed by resolve; the parser is optional and allocates
//! nothing. Compound part.variant:state selectors, comma groups, :not(:state), native
//! properties (underscores or hyphens), a few documented aliases and padding shorthand are
//! supported. Descendant selectors, specificity, @rules, custom property definitions,
//! !important, URLs and unsupported CSS values fail explicitly instead of being ignored.

const std = @import("std");
const types = @import("../core/types.zig");
const resolution = @import("resolve.zig");
const properties = @import("properties.zig");

pub const Error = error{ NoSpace, Syntax, UnexpectedEnd, UnsupportedSelector, UnsupportedProperty, UnsupportedValue, InvalidValue, TooDeep };
pub const Location = struct { byte: usize = 0, line: usize = 1, column: usize = 1 };
pub const Diagnostic = struct { kind: ?Error = null, location: Location = .{} };
pub const Buffers = struct {
    rules: []resolution.Rule,
    declarations: []resolution.Declaration,
    variants: []types.Id,
    /// Optional source locations, one per output rule/declaration. When supplied, their
    /// capacity is checked too. Output slices and locations borrow only these buffers.
    rule_locations: ?[]Location = null,
    declaration_locations: ?[]Location = null,
};
pub const Sheet = struct {
    rules: []const resolution.Rule,
    declarations: []const resolution.Declaration,
    variants: []const types.Id,
    rule_locations: []const Location,
    declaration_locations: []const Location,
};

/// Output buffers are unspecified on error. No partially compiled sheet is returned. A caller
/// may retry with larger buffers. The source can be released after successful compilation.
pub fn compile(source: []const u8, buffers: Buffers, diagnostic: ?*Diagnostic) Error!Sheet {
    if (diagnostic) |out| out.* = .{};
    var parser: Parser = .{ .source = source, .buffers = buffers, .diagnostic = diagnostic };
    try parser.run();
    return .{
        .rules = buffers.rules[0..parser.rule_count],
        .declarations = buffers.declarations[0..parser.declaration_count],
        .variants = buffers.variants[0..parser.variant_count],
        .rule_locations = if (buffers.rule_locations) |rows| rows[0..parser.rule_count] else &.{},
        .declaration_locations = if (buffers.declaration_locations) |rows| rows[0..parser.declaration_count] else &.{},
    };
}

const Parser = struct {
    source: []const u8,
    buffers: Buffers,
    diagnostic: ?*Diagnostic,
    pos: usize = 0,
    rule_count: usize = 0,
    declaration_count: usize = 0,
    variant_count: usize = 0,

    fn fail(p: *Parser, kind_: Error, at: usize) Error {
        if (p.diagnostic) |out| out.* = .{ .kind = kind_, .location = locate(p.source, at) };
        return kind_;
    }

    fn skip(p: *Parser) Error!void {
        while (p.pos < p.source.len) {
            if (std.ascii.isWhitespace(p.source[p.pos])) {
                p.pos += 1;
            } else if (std.mem.startsWith(u8, p.source[p.pos..], "/*")) {
                const end = std.mem.indexOf(u8, p.source[p.pos + 2 ..], "*/") orelse return p.fail(error.UnexpectedEnd, p.pos);
                p.pos += end + 4;
            } else break;
        }
    }

    fn identifier(p: *Parser) Error![]const u8 {
        const start = p.pos;
        if (p.pos == p.source.len) return p.fail(error.UnexpectedEnd, p.pos);
        if (!identStart(p.source[p.pos])) return p.fail(error.Syntax, p.pos);
        p.pos += 1;
        while (p.pos < p.source.len and ident(p.source[p.pos])) p.pos += 1;
        return p.source[start..p.pos];
    }

    fn run(p: *Parser) Error!void {
        try p.skip();
        while (p.pos < p.source.len) {
            const first_rule = p.rule_count;
            while (true) {
                try p.selector();
                try p.skip();
                if (p.pos == p.source.len) return p.fail(error.UnexpectedEnd, p.pos);
                const c = p.source[p.pos];
                p.pos += 1;
                if (c == '{') break;
                if (c != ',') return p.fail(error.UnsupportedSelector, p.pos - 1);
                try p.skip();
            }
            const first_declaration = p.declaration_count;
            while (true) {
                try p.skip();
                if (p.pos == p.source.len) return p.fail(error.UnexpectedEnd, p.pos);
                if (p.source[p.pos] == '}') {
                    p.pos += 1;
                    break;
                }
                try p.declaration();
            }
            for (p.buffers.rules[first_rule..p.rule_count]) |*rule| rule.declarations = p.buffers.declarations[first_declaration..p.declaration_count];
            try p.skip();
        }
    }

    fn selector(p: *Parser) Error!void {
        const start = p.pos;
        if (p.rule_count == p.buffers.rules.len) return p.fail(error.NoSpace, start);
        if (p.buffers.rule_locations) |rows| if (p.rule_count == rows.len) return p.fail(error.NoSpace, start);
        var rule: resolution.Rule = .{ .declarations = &.{} };
        const first_variant = p.variant_count;
        if (p.pos == p.source.len) return p.fail(error.UnexpectedEnd, start);
        if (p.source[p.pos] == '*') {
            p.pos += 1;
        } else if (identStart(p.source[p.pos])) {
            rule.part = .hash(try p.identifier());
        } else if (p.source[p.pos] != '.' and p.source[p.pos] != ':') return p.fail(error.UnsupportedSelector, start);
        while (p.pos < p.source.len) {
            const c = p.source[p.pos];
            if (c == '.') {
                p.pos += 1;
                const name = try p.identifier();
                if (p.variant_count == p.buffers.variants.len) return p.fail(error.NoSpace, p.pos);
                p.buffers.variants[p.variant_count] = .hash(name);
                p.variant_count += 1;
            } else if (c == ':') {
                p.pos += 1;
                const state_start = p.pos;
                const name = try p.identifier();
                var forbid = false;
                var state_name = name;
                if (std.mem.eql(u8, name, "not")) {
                    forbid = true;
                    if (!std.mem.startsWith(u8, p.source[p.pos..], "(:")) return p.fail(error.UnsupportedSelector, state_start);
                    p.pos += 2;
                    state_name = try p.identifier();
                    if (p.pos == p.source.len or p.source[p.pos] != ')') return p.fail(error.UnsupportedSelector, p.pos);
                    p.pos += 1;
                }
                const state = stateOf(state_name) orelse return p.fail(error.UnsupportedSelector, state_start);
                if (forbid) rule.forbid = rule.forbid.merge(state) else rule.require = rule.require.merge(state);
            } else break;
        }
        rule.source = .hash(p.source[start..p.pos]);
        rule.variants = p.buffers.variants[first_variant..p.variant_count];
        p.buffers.rules[p.rule_count] = rule;
        if (p.buffers.rule_locations) |rows| rows[p.rule_count] = locate(p.source, start);
        p.rule_count += 1;
    }

    fn declaration(p: *Parser) Error!void {
        const start = p.pos;
        const name = try p.identifier();
        try p.skip();
        if (p.pos == p.source.len) return p.fail(error.UnexpectedEnd, p.pos);
        if (p.source[p.pos] != ':') return p.fail(error.Syntax, p.pos);
        p.pos += 1;
        try p.skip();
        const value_start = p.pos;
        var depth: u8 = 0;
        while (p.pos < p.source.len) : (p.pos += 1) {
            const c = p.source[p.pos];
            if (c == '(') {
                if (depth == 4) return p.fail(error.TooDeep, p.pos);
                depth += 1;
            } else if (c == ')') {
                if (depth == 0) return p.fail(error.Syntax, p.pos);
                depth -= 1;
            } else if ((c == ';' or c == '}') and depth == 0) break else if (c == '!' or c == '{' or c == '"' or c == '\'') return p.fail(error.UnsupportedValue, p.pos);
        }
        if (p.pos == p.source.len or depth != 0) return p.fail(error.UnexpectedEnd, p.pos);
        const value = trim(p.source[value_start..p.pos]);
        if (value.len == 0) return p.fail(error.InvalidValue, value_start);
        if (std.mem.eql(u8, name, "padding")) {
            var chunks: [4][]const u8 = undefined;
            const count = split(value, &chunks) catch |err| return p.fail(err, value_start);
            if (count == 0) return p.fail(error.InvalidValue, value_start);
            // CSS order top/right/bottom/left becomes the core's left/top/right/bottom.
            const indices: [4]usize = .{ if (count == 4) 3 else if (count > 1) 1 else 0, 0, if (count > 1) 1 else 0, if (count > 2) 2 else 0 };
            const targets = [_]properties.Property{ .padding_left, .padding_top, .padding_right, .padding_bottom };
            for (targets, indices) |target, index| try p.append(target, chunks[index], start, value_start);
        } else {
            const target = propertyOf(name) orelse return p.fail(error.UnsupportedProperty, start);
            try p.append(target, value, start, value_start);
        }
        if (p.source[p.pos] == ';') p.pos += 1;
    }

    fn append(p: *Parser, target: properties.Property, value: []const u8, start: usize, value_start: usize) Error!void {
        if (p.declaration_count == p.buffers.declarations.len) return p.fail(error.NoSpace, start);
        if (p.buffers.declaration_locations) |rows| if (p.declaration_count == rows.len) return p.fail(error.NoSpace, start);
        const source = parseSource(target, value) catch |err| return p.fail(err, value_start);
        p.buffers.declarations[p.declaration_count] = .{ .property = target, .source = source };
        if (p.buffers.declaration_locations) |rows| rows[p.declaration_count] = locate(p.source, start);
        p.declaration_count += 1;
    }
};

pub fn locate(source: []const u8, byte: usize) Location {
    var out: Location = .{ .byte = @min(byte, source.len) };
    for (source[0..out.byte]) |c| {
        if (c == '\n') {
            out.line += 1;
            out.column = 1;
        } else out.column += 1;
    }
    return out;
}

fn identStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}
fn ident(c: u8) bool {
    return identStart(c) or std.ascii.isDigit(c);
}
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}
fn equalsName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if ((if (x == '-') '_' else x) != y) return false;
    return true;
}

pub fn propertyOf(name: []const u8) ?properties.Property {
    inline for (@typeInfo(properties.Property).@"enum".field_names) |field| {
        if (equalsName(name, field)) return @field(properties.Property, field);
    }
    const aliases = .{
        .{ "background-color", properties.Property.fill },
        .{ "color", properties.Property.text_color },
        .{ "border-radius", properties.Property.radius },
        .{ "font-size", properties.Property.text_size },
        .{ "font-handle", properties.Property.text_font },
        .{ "flow", properties.Property.direction },
        .{ "justify-content", properties.Property.main_align },
        .{ "align-items", properties.Property.cross_align },
    };
    inline for (aliases) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    return null;
}

fn stateOf(name: []const u8) ?resolution.States {
    inline for (@typeInfo(resolution.States).@"struct".field_names) |field| {
        if (comptime !std.mem.eql(u8, field, "custom")) {
            if (equalsName(name, field)) {
                var state: resolution.States = .{};
                @field(state, field) = true;
                return state;
            }
        }
    }
    if (std.mem.eql(u8, name, "hover")) return .{ .hovered = true };
    if (std.mem.eql(u8, name, "active")) return .{ .held = true };
    if (std.mem.eql(u8, name, "focus")) return .{ .focused = true };
    return null;
}

fn parseSource(target: properties.Property, value: []const u8) Error!resolution.Source {
    if (std.mem.eql(u8, value, "inherit")) return .inherit;
    if (std.mem.eql(u8, value, "initial")) return .initial;
    if (function(value, "token")) |name| {
        if (!tokenName(name)) return error.InvalidValue;
        return .{ .token = .hash(name) };
    }
    if (function(value, "var")) |name| {
        if (name.len <= 2 or !std.mem.startsWith(u8, name, "--") or !tokenName(name[2..])) return error.UnsupportedValue;
        return .{ .token = .hash(name[2..]) };
    }
    const parsed: properties.Value = switch (properties.kind(target)) {
        .color => .{ .color = try color(value) },
        .number => .{ .number = if ((target == .max_width or target == .max_height) and std.mem.eql(u8, value, "none")) types.inf else try number(value, target != .opacity) },
        .size => .{ .size = try size(value) },
        .axis => .{ .axis = if (std.mem.eql(u8, value, "row") or std.mem.eql(u8, value, "x")) .x else if (std.mem.eql(u8, value, "column") or std.mem.eql(u8, value, "y")) .y else return error.UnsupportedValue },
        .alignment => .{ .alignment = std.meta.stringToEnum(types.Align, value) orelse return error.UnsupportedValue },
        .boolean => .{ .boolean = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.UnsupportedValue },
        .texture => .{ .texture = @fromBackingInt(try handle(value)) },
        .material => .{ .material = @fromBackingInt(try handle(value)) },
        .font => .{ .font = @fromBackingInt(try handle(value)) },
        .vector2 => .{ .vector2 = try vector(2, value, target == .transform_origin) },
        .vector4 => .{ .vector4 = try vector(4, value, false) },
        .matrix => .{ .matrix = try vector(6, function(value, "matrix") orelse value, false) },
        .participation => .{ .participation = if (std.mem.eql(u8, value, "all")) .all else if (std.mem.eql(u8, value, "hidden")) .hidden else if (std.mem.eql(u8, value, "collapsed")) .collapsed else return error.UnsupportedValue },
    };
    properties.validate(target, parsed) catch return error.InvalidValue;
    return .{ .literal = parsed };
}

fn tokenName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!ident(c) and c != '.') return false;
    return true;
}
fn function(value: []const u8, name: []const u8) ?[]const u8 {
    if (value.len < name.len + 2 or !std.mem.startsWith(u8, value, name) or value[name.len] != '(' or value[value.len - 1] != ')') return null;
    return trim(value[name.len + 1 .. value.len - 1]);
}
fn number(value: []const u8, pixels: bool) Error!f32 {
    var raw = value;
    if (pixels and std.mem.endsWith(u8, raw, "px")) raw = raw[0 .. raw.len - 2];
    const n = std.fmt.parseFloat(f32, raw) catch return error.UnsupportedValue;
    if (!std.math.isFinite(n)) return error.InvalidValue;
    return n;
}
fn handle(value: []const u8) Error!u16 {
    return std.fmt.parseInt(u16, value, 10) catch error.UnsupportedValue;
}
fn size(value: []const u8) Error!types.Size {
    if (std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "fit")) return .fit;
    if (std.mem.eql(u8, value, "fill")) return .fill;
    if (function(value, "grow")) |weight| return .grow(try number(weight, false));
    if (std.mem.endsWith(u8, value, "%")) return .pct(try number(value[0 .. value.len - 1], false) / 100);
    return .px(try number(value, true));
}

/// Split by whitespace or commas outside token(...). Empty comma fields are rejected.
fn split(value: []const u8, out: [][]const u8) Error!usize {
    var count: usize = 0;
    var at: usize = 0;
    var comma = false;
    while (at < value.len) {
        while (at < value.len and std.ascii.isWhitespace(value[at])) at += 1;
        if (at == value.len) break;
        if (value[at] == ',') {
            if (comma or count == 0) return error.InvalidValue;
            comma = true;
            at += 1;
            continue;
        }
        if (count == out.len) return error.UnsupportedValue;
        const start = at;
        var depth: usize = 0;
        while (at < value.len) : (at += 1) {
            const c = value[at];
            if (c == '(') depth += 1 else if (c == ')') {
                if (depth == 0) return error.InvalidValue;
                depth -= 1;
            } else if (depth == 0 and (std.ascii.isWhitespace(c) or c == ',')) break;
        }
        if (depth != 0) return error.InvalidValue;
        out[count] = value[start..at];
        count += 1;
        comma = false;
    }
    if (comma) return error.InvalidValue;
    return count;
}
fn vector(comptime len: usize, value: []const u8, fractions: bool) Error![len]f32 {
    var chunks: [len][]const u8 = undefined;
    if (try split(value, &chunks) != len) return error.InvalidValue;
    var result: [len]f32 = undefined;
    for (chunks, &result) |chunk, *out| {
        if (fractions and std.mem.endsWith(u8, chunk, "%")) out.* = try number(chunk[0 .. chunk.len - 1], false) / 100 else out.* = try number(chunk, !fractions);
    }
    return result;
}
fn color(value: []const u8) Error!types.Color {
    if (std.mem.eql(u8, value, "transparent")) return .transparent;
    if (std.mem.eql(u8, value, "black")) return .black;
    if (std.mem.eql(u8, value, "white")) return .white;
    if (value.len == 0 or value[0] != '#') return error.UnsupportedValue;
    const hex = value[1..];
    var channels: [4]u8 = .{ 0, 0, 0, 255 };
    if (hex.len == 3 or hex.len == 4) {
        for (hex, 0..) |c, i| channels[i] = (std.fmt.charToDigit(c, 16) catch return error.InvalidValue) * 17;
    } else if (hex.len == 6 or hex.len == 8) {
        for (0..hex.len / 2) |i| channels[i] = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch return error.InvalidValue;
    } else return error.InvalidValue;
    return .rgba(channels[0], channels[1], channels[2], channels[3]);
}

test "compiler caller resolves parsed parts, variants, combined states and explicit transparency" {
    var rules: [8]resolution.Rule = undefined;
    var declarations: [24]resolution.Declaration = undefined;
    var variants: [8]types.Id = undefined;
    var origins: [24]Location = undefined;
    const sheet = try compile(
        \\/* borrowed input needs no interning */
        \\root { padding: 2px 4px; color: #112233; width: 80px; }
        \\root.primary:hover:not(:disabled), root.selected { background-color: #abcdef80; }
        \\label:focus-visible { color: transparent; font-size: token(text.large); }
    , .{ .rules = &rules, .declarations = &declarations, .variants = &variants, .declaration_locations = &origins }, null);
    const box = try resolution.resolve(.{ .rules = sheet.rules, .variants = &.{.from("primary")}, .states = .{ .hovered = true } }, null);
    try std.testing.expectEqual([4]f32{ 4, 2, 4, 2 }, box.box.pad);
    try std.testing.expectEqual(types.Color.rgba(0xab, 0xcd, 0xef, 0x80), box.box.fill);
    try std.testing.expectEqual(types.Size.px(80), box.box.size[0]);
    const tokens = @import("tokens.zig");
    const rows = [_]tokens.Entry{tokens.literal(.text_size, .from("text.large"), 24)};
    const scopes = [_]tokens.Scope{.{ .entries = &rows }};
    const label = try resolution.resolve(.{ .part = .from("label"), .rules = sheet.rules, .parent = &box, .tokens = .{ .scopes = &scopes }, .scope = 0, .states = .{ .focus_visible = true } }, null);
    try std.testing.expectEqual(types.Color.transparent, label.text.color);
    try std.testing.expectEqual(@as(f32, 24), label.text.px);
    try std.testing.expectEqual(@as(usize, 2), sheet.declaration_locations[0].line);
}

test "compiler errors report unsupported input and bounded storage without ignoring declarations" {
    var rules: [2]resolution.Rule = undefined;
    var declarations: [4]resolution.Declaration = undefined;
    var variants: [2]types.Id = undefined;
    const buffers: Buffers = .{ .rules = &rules, .declarations = &declarations, .variants = &variants };
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedSelector, compile("root > label { color: white; }", buffers, &diagnostic));
    try std.testing.expectEqual(@as(usize, 6), diagnostic.location.column);
    try std.testing.expectError(error.UnsupportedProperty, compile("root { filter: blur(2px); }", buffers, null));
    try std.testing.expectError(error.UnsupportedValue, compile("root { color: red !important; }", buffers, null));
    try std.testing.expectError(error.InvalidValue, compile("root { opacity: 2; }", buffers, null));
    try std.testing.expectError(error.NoSpace, compile("root { padding: 1px; gap: 2px; }", buffers, null));
    try std.testing.expectError(error.UnexpectedEnd, compile("root { color: #fff", buffers, null));
}

test "compiled declarations feed the actual frame text and layout consumer" {
    const context = @import("../runtime/context.zig");
    const caps: context.Limits = .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 128, .depth = 4, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
    const bytes = comptime blk: {
        @setEvalBranchQuota(30_000);
        break :blk context.Context.requiredBytes(caps);
    };
    var memory: [bytes]u8 align(64) = undefined;
    var context_ = try context.Context.init(&memory, caps);
    var rules: [2]resolution.Rule = undefined;
    var declarations: [8]resolution.Declaration = undefined;
    var variants: [1]types.Id = undefined;
    const sheet = try compile("label { width: 90px; height: 30px; color: #135; font-size: 18px; background-color: #fed; }", .{ .rules = &rules, .declarations = &declarations, .variants = &variants }, null);
    const computed = try resolution.resolve(.{ .part = .from("label"), .rules = sheet.rules }, null);
    var frame = context_.begin(&.{ .viewport = .{ 200, 100 } });
    const node = frame.textStyled("Compiled", computed.text, computed.box);
    const output = frame.end(.{});
    try std.testing.expectEqual(@as(f32, 90), output.tree.rect(node.ix()).w());
    try std.testing.expectEqual(@as(f32, 30), output.tree.rect(node.ix()).h());
    try std.testing.expectEqual(@as(f32, 18), output.texts.c.px[0]);
    try std.testing.expect(output.draw.quad_len > 0);
    try std.testing.expect(output.status.ok());
}

test {
    std.testing.refAllDecls(@This());
}
