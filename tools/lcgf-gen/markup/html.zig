//! The HTML document as rows: one per element or text node, depth-first, each with its parent
//! and source offset, and one row per attribute. Lexbor's HTML5 tree builder (lexbor.c) does
//! the parsing: optional end tags, implied elements, entities and `<template>` content.

const std = @import("std");
const lx = @import("lexbor.zig");
const diag = @import("diag.zig");

pub const none = diag.none;

pub const Kind = enum(u8) { element, text };

pub const Node = struct {
    kind: Kind,
    parent: u32,
    /// Lower-case tag name, or the text's (entity-decoded) bytes.
    name: []const u8,
    /// Byte offset of `<` or of the text in the file; `none` for an element the parser implied.
    src: u32,
    attr_first: u32,
    attr_count: u32,
    /// Inside a `<template>`'s content (an inert fragment in a browser).
    in_template: bool,
};

pub const Attr = struct { name: []const u8, value: []const u8, name_src: u32, value_src: u32 };

pub const Doc = struct {
    file: u16,
    nodes: std.MultiArrayList(Node),
    attrs: std.MultiArrayList(Attr),
    quirks: bool,
    doctype: bool,

    pub fn loc(d: *const Doc, node: u32) diag.Loc {
        return .{ .file = d.file, .off = d.nodes.items(.src)[node] };
    }

    /// The attribute named `name` on `node`, or null.
    pub fn attr(d: *const Doc, node: u32, name: []const u8) ?u32 {
        const first = d.nodes.items(.attr_first)[node];
        const names = d.attrs.items(.name);
        for (first..first + d.nodes.items(.attr_count)[node]) |a| if (std.mem.eql(u8, names[a], name)) return @intCast(a);
        return null;
    }

    pub fn value(d: *const Doc, node: u32, name: []const u8) ?[]const u8 {
        return if (d.attr(node, name)) |a| d.attrs.items(.value)[a] else null;
    }

    pub fn attrLoc(d: *const Doc, a: u32) diag.Loc {
        return .{ .file = d.file, .off = d.attrs.items(.name_src)[a] };
    }

    pub fn valueLoc(d: *const Doc, a: u32) diag.Loc {
        const v = d.attrs.items(.value_src)[a];
        return .{ .file = d.file, .off = if (v == none) d.attrs.items(.name_src)[a] else v };
    }

    pub fn isElement(d: *const Doc, node: u32, tag: []const u8) bool {
        return d.nodes.items(.kind)[node] == .element and std.mem.eql(u8, d.nodes.items(.name)[node], tag);
    }
};

pub fn parse(arena: std.mem.Allocator, ds: *diag.Diags, file: u16) error{ParseFailed}!Doc {
    const src = ds.files.items[file].bytes;
    var out: lx.Html = undefined;
    defer lx.lcgf_html_free(&out);
    if (lx.lcgf_html_parse(src.ptr, src.len, &out) != 0) return error.ParseFailed;
    const pool: []const u8 = if (out.pool) |p| p[0..out.pool_len] else "";
    var doc: Doc = .{ .file = file, .nodes = .empty, .attrs = .empty, .quirks = out.quirks != 0, .doctype = out.doctype != 0 };
    doc.nodes.ensureTotalCapacity(arena, out.n_nodes) catch @panic("out of memory");
    doc.attrs.ensureTotalCapacity(arena, out.n_attrs) catch @panic("out of memory");
    const bytes = arena.dupe(u8, pool) catch @panic("out of memory");
    if (out.nodes) |nodes| for (nodes[0..out.n_nodes]) |n| doc.nodes.appendAssumeCapacity(.{
        .kind = if (n.kind == 1) .element else .text,
        .parent = n.parent,
        .name = bytes[n.name.off..][0..n.name.len],
        .src = n.src,
        .attr_first = n.attr_first,
        .attr_count = n.attr_count,
        .in_template = n.in_template != 0,
    });
    if (out.attrs) |attrs| for (attrs[0..out.n_attrs]) |a| doc.attrs.appendAssumeCapacity(.{
        .name = bytes[a.name.off..][0..a.name.len],
        .value = bytes[a.value.off..][0..a.value.len],
        .name_src = a.name_src,
        .value_src = a.value_src,
    });
    if (out.diags) |diags| for (diags[0..out.n_diags]) |e|
        ds.warn(.{ .file = file, .off = e.src }, "HTML: {s}", .{pool[e.msg.off..][0..e.msg.len]});
    return doc;
}

test "parse: implied elements, positions of every element and attribute, template content" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ds: diag.Diags = .{ .arena = arena.allocator() };
    const src = "<!doctype html>\n<p class=\"a\" id=x>Hi &amp; bye\n<template lcgf-if=\"on\"><b>t</b></template>";
    const f = ds.addFile("t.html", src);
    const d = try parse(arena.allocator(), &ds, f);
    try std.testing.expect(d.doctype and !d.quirks);
    const names = d.nodes.items(.name);
    // html, head, body (implied), p, text, template, b, text
    try std.testing.expectEqualStrings("html", names[0]);
    try std.testing.expectEqual(none, d.nodes.items(.src)[0]);
    const p = 3;
    try std.testing.expectEqualStrings("p", names[p]);
    try std.testing.expectEqual(2, d.nodes.items(.parent)[p]);
    try std.testing.expectEqual(16, d.nodes.items(.src)[p]);
    try std.testing.expectEqualStrings("Hi & bye\n", names[p + 1]);
    const id = d.attr(p, "id").?;
    try std.testing.expectEqualStrings("x", d.attrs.items(.value)[id]);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "id=").?, d.attrs.items(.name_src)[id]);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "x>").?, d.attrs.items(.value_src)[id]);
    const at = ds.where(d.loc(p));
    try std.testing.expectEqual(2, at.line);
    try std.testing.expectEqual(1, at.col);
    try std.testing.expect(d.isElement(p + 2, "template"));
    try std.testing.expect(d.nodes.items(.in_template)[p + 3]);
    try std.testing.expectEqualStrings("b", names[p + 3]);
    try std.testing.expectEqual(p + 2, d.nodes.items(.parent)[p + 3]);
}
