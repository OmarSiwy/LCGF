//! UITextInput on the iOS shell's view: what makes it a text view to UIKit, so the soft
//! keyboard types into it and an IME (Japanese, Chinese, Korean, dictation) can compose.
//!
//! The document UIKit sees is only the IME's marked text: the text being edited lives in the
//! application's widgets, which the core owns, so the view holds nothing else. Positions are
//! UTF-16 offsets into the marked text (LcgrTextPosition), ranges two of them (LcgrTextRange).
//! What the IME does arrives at the translator: committed text through `insertText:`, the
//! composition through `setMarkedText:selectedRange:`, the delete key through
//! `deleteBackward`. Its candidate window and the caret anchor at `Platform.ime_rect`.
//!
//! ponytail: without the document's text around the caret, autocorrection and predictions
//! see an empty field; giving UIKit the focused widget's text needs it in `Platform`.

const std = @import("std");
const lcgr = @import("lcgr");
const metal = @import("metal");
const ios = @import("ios.zig");
const objc = metal.objc;
const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;
const CGRect = ios.CGRect;
const CGPoint = ios.CGPoint;
const Ios = ios.Ios;
const NSRange = extern struct { location: usize, length: usize };
const ns_utf8_encoding: objc.NSUInteger = 4;

pub var position_class: Id = undefined;
pub var range_class: Id = undefined;

const rect_types = "{CGRect={CGPoint=dd}{CGSize=dd}}";

/// The view's UIKeyInput and UITextInput methods, added to LcgrView.
pub const methods = [_]ios.Method{
    .{ .sel = "canBecomeFirstResponder", .imp = &yes, .types = "B@:" },
    .{ .sel = "hasText", .imp = &hasText, .types = "B@:" },
    .{ .sel = "insertText:", .imp = &insertText, .types = "v@:@" },
    .{ .sel = "deleteBackward", .imp = &deleteBackward, .types = "v@:" },
    .{ .sel = "textInRange:", .imp = &textInRange, .types = "@@:@" },
    .{ .sel = "replaceRange:withText:", .imp = &replaceRange, .types = "v@:@@" },
    .{ .sel = "selectedTextRange", .imp = &selectedTextRange, .types = "@@:" },
    .{ .sel = "setSelectedTextRange:", .imp = &setSelectedTextRange, .types = "v@:@" },
    .{ .sel = "markedTextRange", .imp = &markedTextRange, .types = "@@:" },
    .{ .sel = "markedTextStyle", .imp = &nothing, .types = "@@:" },
    .{ .sel = "setMarkedTextStyle:", .imp = &ignore, .types = "v@:@" },
    .{ .sel = "setMarkedText:selectedRange:", .imp = &setMarkedText, .types = "v@:@{_NSRange=QQ}" },
    .{ .sel = "unmarkText", .imp = &unmarkText, .types = "v@:" },
    .{ .sel = "beginningOfDocument", .imp = &beginning, .types = "@@:" },
    .{ .sel = "endOfDocument", .imp = &end, .types = "@@:" },
    .{ .sel = "textRangeFromPosition:toPosition:", .imp = &rangeFrom, .types = "@@:@@" },
    .{ .sel = "positionFromPosition:offset:", .imp = &positionOffset, .types = "@@:@q" },
    .{ .sel = "positionFromPosition:inDirection:offset:", .imp = &positionDirection, .types = "@@:@qq" },
    .{ .sel = "comparePosition:toPosition:", .imp = &compare, .types = "q@:@@" },
    .{ .sel = "offsetFromPosition:toPosition:", .imp = &offsetFrom, .types = "q@:@@" },
    .{ .sel = "inputDelegate", .imp = &inputDelegate, .types = "@@:" },
    .{ .sel = "setInputDelegate:", .imp = &setInputDelegate, .types = "v@:@" },
    .{ .sel = "tokenizer", .imp = &tokenizer, .types = "@@:" },
    .{ .sel = "positionWithinRange:farthestInDirection:", .imp = &farthest, .types = "@@:@q" },
    .{ .sel = "characterRangeByExtendingPosition:inDirection:", .imp = &extend, .types = "@@:@q" },
    .{ .sel = "baseWritingDirectionForPosition:inDirection:", .imp = &natural, .types = "q@:@q" },
    .{ .sel = "setBaseWritingDirection:forRange:", .imp = &ignoreDirection, .types = "v@:q@" },
    .{ .sel = "firstRectForRange:", .imp = &firstRect, .types = rect_types ++ "@:@" },
    .{ .sel = "caretRectForPosition:", .imp = &firstRect, .types = rect_types ++ "@:@" },
    .{ .sel = "selectionRectsForRange:", .imp = &selectionRects, .types = "@@:@" },
    .{ .sel = "closestPositionToPoint:", .imp = &closest, .types = "@@:{CGPoint=dd}" },
    .{ .sel = "closestPositionToPoint:withinRange:", .imp = &closestWithin, .types = "@@:{CGPoint=dd}@" },
    .{ .sel = "characterRangeAtPoint:", .imp = &rangeAtPoint, .types = "@@:{CGPoint=dd}" },
};

/// Ends a composition and forgets the marked text (the keyboard went away).
pub fn clear(s: *Ios) void {
    if (s.marked) |m| objc.release(m);
    s.marked = null;
    s.selected = .{ 0, 0 };
    s.t.mark("", .{ 0, 0 });
}

fn len(s: *const Ios) usize {
    const m = s.marked orelse return 0;
    return msg(objc.NSUInteger, m, "length", .{});
}

fn ivarPtr(o: Id, comptime name: [:0]const u8) *isize {
    const cls = msg(Id, o, "class", .{});
    const v = ios.fns.class_getInstanceVariable(cls, name).?;
    const base: [*]u8 = @ptrCast(o);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(ios.fns.ivar_getOffset(v)))));
}

/// A new (autoreleased) position at UTF-16 offset `o`.
fn position(o: usize) Id {
    const p = msg(Id, msg(Id, position_class, "alloc", .{}), "init", .{});
    ivarPtr(p, "o").* = @intCast(o);
    return msg(Id, p, "autorelease", .{});
}

fn offset(p: ?Id) usize {
    return @intCast(@max(ivarPtr(p orelse return 0, "o").*, 0));
}

fn range(a: usize, b: usize) Id {
    const r = msg(Id, msg(Id, range_class, "alloc", .{}), "init", .{});
    ivarPtr(r, "a").* = @intCast(@min(a, b));
    ivarPtr(r, "b").* = @intCast(@max(a, b));
    return msg(Id, r, "autorelease", .{});
}

fn bounds(r: ?Id) [2]usize {
    const o = r orelse return .{ 0, 0 };
    return .{ @intCast(ivarPtr(o, "a").*), @intCast(ivarPtr(o, "b").*) };
}

pub fn rangeStart(self: Id, _: Sel) callconv(.c) Id {
    return position(bounds(self)[0]);
}
pub fn rangeEnd(self: Id, _: Sel) callconv(.c) Id {
    return position(bounds(self)[1]);
}
pub fn rangeEmpty(self: Id, _: Sel) callconv(.c) bool {
    const b = bounds(self);
    return b[0] == b[1];
}

fn yes(_: Id, _: Sel) callconv(.c) bool {
    return true;
}
fn nothing(_: Id, _: Sel) callconv(.c) ?Id {
    return null;
}
fn ignore(_: Id, _: Sel, _: ?Id) callconv(.c) void {}

fn hasText(_: Id, _: Sel) callconv(.c) bool {
    const s = ios.app.shell orelse return false;
    return len(s) > 0;
}

/// UTF-8 of an NSString or NSAttributedString (the IME may hand either).
fn utf8(str: Id) []const u8 {
    const plain = if (msg(bool, str, "isKindOfClass:", .{objc.class("NSAttributedString")})) msg(Id, str, "string", .{}) else str;
    return std.mem.span(msg(?[*:0]const u8, plain, "UTF8String", .{}) orelse return "");
}

fn insertText(_: Id, _: Sel, text: Id) callconv(.c) void {
    const s = ios.app.shell orelse return;
    clear(s);
    s.t.insert(utf8(text));
}

fn deleteBackward(_: Id, _: Sel) callconv(.c) void {
    const s = ios.app.shell orelse return;
    s.t.deleteBackward();
}

fn textInRange(_: Id, _: Sel, r: ?Id) callconv(.c) Id {
    const s = ios.app.shell orelse return objc.string("");
    const m = s.marked orelse return objc.string("");
    const b = bounds(r);
    const n = len(s);
    const a = @min(b[0], n);
    return msg(Id, m, "substringWithRange:", .{NSRange{ .location = a, .length = @min(b[1], n) - a }});
}

fn replaceRange(self: Id, sel: Sel, _: ?Id, text: Id) callconv(.c) void {
    insertText(self, sel, text);
}

fn selectedTextRange(_: Id, _: Sel) callconv(.c) Id {
    const s = ios.app.shell orelse return range(0, 0);
    return range(s.selected[0], s.selected[1]);
}

fn setSelectedTextRange(_: Id, _: Sel, r: ?Id) callconv(.c) void {
    const s = ios.app.shell orelse return;
    s.selected = bounds(r);
}

fn markedTextRange(_: Id, _: Sel) callconv(.c) ?Id {
    const s = ios.app.shell orelse return null;
    if (s.marked == null) return null;
    return range(0, len(s));
}

/// The IME's composition: kept as the document, and handed to the translator as UTF-8 with
/// its selected range converted from UTF-16 units to bytes.
fn setMarkedText(_: Id, _: Sel, text: ?Id, sel: NSRange) callconv(.c) void {
    const s = ios.app.shell orelse return;
    const str = text orelse return clear(s);
    const plain = if (msg(bool, str, "isKindOfClass:", .{objc.class("NSAttributedString")})) msg(Id, str, "string", .{}) else str;
    const copy = msg(Id, plain, "copy", .{});
    if (s.marked) |m| objc.release(m);
    s.marked = copy;
    const n = len(s);
    const a = @min(sel.location, n);
    const b = @min(sel.location + sel.length, n);
    s.selected = .{ a, b };
    if (n == 0) return clear(s);
    s.t.mark(utf8(copy), .{ utf8Bytes(copy, a), utf8Bytes(copy, b) });
}

fn utf8Bytes(str: Id, units: usize) u32 {
    const head = msg(Id, str, "substringToIndex:", .{@as(objc.NSUInteger, units)});
    return @intCast(msg(objc.NSUInteger, head, "lengthOfBytesUsingEncoding:", .{ns_utf8_encoding}));
}

fn unmarkText(_: Id, _: Sel) callconv(.c) void {
    const s = ios.app.shell orelse return;
    s.t.unmark();
    if (s.marked) |m| objc.release(m);
    s.marked = null;
    s.selected = .{ 0, 0 };
}

fn beginning(_: Id, _: Sel) callconv(.c) Id {
    return position(0);
}

fn end(_: Id, _: Sel) callconv(.c) Id {
    const s = ios.app.shell orelse return position(0);
    return position(len(s));
}

fn rangeFrom(_: Id, _: Sel, a: ?Id, b: ?Id) callconv(.c) Id {
    return range(offset(a), offset(b));
}

/// `p + by`, or nil outside the document.
fn moved(p: ?Id, by: isize) ?Id {
    const s = ios.app.shell orelse return null;
    const o = @as(isize, @intCast(offset(p))) + by;
    if (o < 0 or o > @as(isize, @intCast(len(s)))) return null;
    return position(@intCast(o));
}

fn positionOffset(_: Id, _: Sel, p: ?Id, by: isize) callconv(.c) ?Id {
    return moved(p, by);
}

/// UITextLayoutDirection: right 2, left 3, up 4, down 5. One line: up and down go to the ends.
fn positionDirection(_: Id, _: Sel, p: ?Id, dir: isize, by: isize) callconv(.c) ?Id {
    return moved(p, if (dir == 2 or dir == 5) by else -by);
}

fn compare(_: Id, _: Sel, a: ?Id, b: ?Id) callconv(.c) isize {
    const x = offset(a);
    const y = offset(b);
    return @as(isize, @intFromBool(x > y)) - @intFromBool(x < y);
}

fn offsetFrom(_: Id, _: Sel, a: ?Id, b: ?Id) callconv(.c) isize {
    return @as(isize, @intCast(offset(b))) - @as(isize, @intCast(offset(a)));
}

fn inputDelegate(_: Id, _: Sel) callconv(.c) ?Id {
    const s = ios.app.shell orelse return null;
    return s.input_delegate;
}

/// Weak, as UIKit expects: the delegate belongs to the text system.
fn setInputDelegate(_: Id, _: Sel, d: ?Id) callconv(.c) void {
    const s = ios.app.shell orelse return;
    s.input_delegate = d;
}

fn tokenizer(self: Id, _: Sel) callconv(.c) ?Id {
    const s = ios.app.shell orelse return null;
    if (s.tokenizer == null) s.tokenizer = msg(Id, msg(Id, objc.class("UITextInputStringTokenizer"), "alloc", .{}), "initWithTextInput:", .{self});
    return s.tokenizer;
}

fn farthest(_: Id, _: Sel, r: ?Id, dir: isize) callconv(.c) Id {
    const b = bounds(r);
    return position(if (dir == 3 or dir == 4) b[0] else b[1]);
}

fn extend(_: Id, _: Sel, p: ?Id, dir: isize) callconv(.c) ?Id {
    const o = offset(p);
    const to = moved(p, if (dir == 3 or dir == 4) -1 else 1) orelse return null;
    return range(o, offset(to));
}

/// UITextWritingDirectionNatural.
fn natural(_: Id, _: Sel, _: ?Id, _: isize) callconv(.c) isize {
    return -1;
}

fn ignoreDirection(_: Id, _: Sel, _: isize, _: ?Id) callconv(.c) void {}

/// Every range and the caret are at `ime_rect`, the focused widget's caret (points).
fn firstRect(_: Id, _: Sel, _: ?Id) callconv(.c) CGRect {
    const s = ios.app.shell orelse return std.mem.zeroes(CGRect);
    const r = s.text.rect;
    return .{ .origin = .{ .x = r.x0, .y = r.y0 }, .size = .{ .width = r.x1 - r.x0, .height = r.y1 - r.y0 } };
}

fn selectionRects(_: Id, _: Sel, _: ?Id) callconv(.c) Id {
    return msg(Id, objc.class("NSArray"), "array", .{});
}

fn closest(_: Id, _: Sel, _: CGPoint) callconv(.c) Id {
    const s = ios.app.shell orelse return position(0);
    return position(len(s));
}

fn closestWithin(_: Id, _: Sel, _: CGPoint, r: ?Id) callconv(.c) Id {
    return position(bounds(r)[1]);
}

fn rangeAtPoint(_: Id, _: Sel, _: CGPoint) callconv(.c) ?Id {
    return null;
}
