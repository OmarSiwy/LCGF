//! The Java Native Interface, by hand: the few calls the Android shell makes into the
//! framework's Java classes (the clipboard, the soft keyboard) from its own thread. No header:
//! JNIEnv and JavaVM are tables of function pointers whose order the JNI specification fixes
//! (Oracle, "JNI Functions", the index of each function in the table), so a call is the table
//! entry cast to the function's C signature. Only the `...A` forms (arguments as a `jvalue`
//! array) are used, never the C-variadic ones.
//!
//!     var env = jni.attach(activity.vm) orelse return;
//!     env.pushFrame(16);                     // local references die with the frame
//!     defer env.popFrame();
//!     const cls = env.findClass("android/content/ClipData") orelse return;

const std = @import("std");

pub const Object = *opaque {};
pub const Method = *opaque {};
pub const Value = extern union { z: u8, i: i32, j: i64, f: f32, d: f64, l: ?Object };

/// A JNIEnv: a pointer to the table of functions, valid on the thread it belongs to.
pub const Env = struct {
    env: *const *const [table_len]?*const anyopaque,

    const table_len = 229;

    fn at(e: Env, comptime index: usize, comptime F: type) *const F {
        return @ptrCast(@alignCast(e.env.*[index].?));
    }

    /// Clears a pending Java exception; true if there was one (the call that raised it failed).
    pub fn failed(e: Env) bool {
        if (e.at(228, fn (Env.Raw) callconv(.c) u8)(e.raw()) == 0) return false; // ExceptionCheck
        e.at(17, fn (Env.Raw) callconv(.c) void)(e.raw()); // ExceptionClear
        return true;
    }

    const Raw = *const anyopaque;
    fn raw(e: Env) Raw {
        return @ptrCast(e.env);
    }

    /// Local references made until `popFrame` are freed by it (PushLocalFrame, PopLocalFrame).
    pub fn pushFrame(e: Env, capacity: i32) void {
        _ = e.at(19, fn (Raw, i32) callconv(.c) i32)(e.raw(), capacity);
    }
    pub fn popFrame(e: Env) void {
        _ = e.at(20, fn (Raw, ?Object) callconv(.c) ?Object)(e.raw(), null);
    }

    pub fn findClass(e: Env, name: [*:0]const u8) ?Object {
        const c = e.at(6, fn (Raw, [*:0]const u8) callconv(.c) ?Object)(e.raw(), name);
        return if (e.failed()) null else c;
    }

    pub fn objectClass(e: Env, o: Object) Object {
        return e.at(31, fn (Raw, Object) callconv(.c) Object)(e.raw(), o);
    }

    pub fn method(e: Env, class: Object, name: [*:0]const u8, sig: [*:0]const u8) ?Method {
        const m = e.at(33, fn (Raw, Object, [*:0]const u8, [*:0]const u8) callconv(.c) ?Method)(e.raw(), class, name, sig);
        return if (e.failed()) null else m;
    }

    pub fn staticMethod(e: Env, class: Object, name: [*:0]const u8, sig: [*:0]const u8) ?Method {
        const m = e.at(113, fn (Raw, Object, [*:0]const u8, [*:0]const u8) callconv(.c) ?Method)(e.raw(), class, name, sig);
        return if (e.failed()) null else m;
    }

    /// `o.m(args)` returning an object (null for a Java null, or when it threw).
    pub fn callObject(e: Env, o: Object, m: Method, args: []const Value) ?Object {
        const r = e.at(36, fn (Raw, Object, Method, [*]const Value) callconv(.c) ?Object)(e.raw(), o, m, args.ptr);
        return if (e.failed()) null else r;
    }

    /// `o.m(args)` returning a boolean; false when it threw.
    pub fn callBool(e: Env, o: Object, m: Method, args: []const Value) bool {
        const r = e.at(39, fn (Raw, Object, Method, [*]const Value) callconv(.c) u8)(e.raw(), o, m, args.ptr);
        return !e.failed() and r != 0;
    }

    pub fn callInt(e: Env, o: Object, m: Method, args: []const Value) ?i32 {
        const r = e.at(51, fn (Raw, Object, Method, [*]const Value) callconv(.c) i32)(e.raw(), o, m, args.ptr);
        return if (e.failed()) null else r;
    }

    /// `o.m(args)` returning nothing; false when it threw.
    pub fn callVoid(e: Env, o: Object, m: Method, args: []const Value) bool {
        e.at(63, fn (Raw, Object, Method, [*]const Value) callconv(.c) void)(e.raw(), o, m, args.ptr);
        return !e.failed();
    }

    pub fn callStaticObject(e: Env, class: Object, m: Method, args: []const Value) ?Object {
        const r = e.at(116, fn (Raw, Object, Method, [*]const Value) callconv(.c) ?Object)(e.raw(), class, m, args.ptr);
        return if (e.failed()) null else r;
    }

    pub fn newObject(e: Env, class: Object, ctor: Method, args: []const Value) ?Object {
        const r = e.at(30, fn (Raw, Object, Method, [*]const Value) callconv(.c) ?Object)(e.raw(), class, ctor, args.ptr);
        return if (e.failed()) null else r;
    }

    /// A java.lang.String from UTF-16 units (NewString).
    pub fn string(e: Env, utf16: []const u16) ?Object {
        const r = e.at(163, fn (Raw, [*]const u16, i32) callconv(.c) ?Object)(e.raw(), utf16.ptr, @intCast(utf16.len));
        return if (e.failed()) null else r;
    }

    /// A java.lang.String from ASCII (NewStringUTF; fine for names and constants).
    pub fn ascii(e: Env, s: [*:0]const u8) ?Object {
        const r = e.at(167, fn (Raw, [*:0]const u8) callconv(.c) ?Object)(e.raw(), s);
        return if (e.failed()) null else r;
    }

    /// A java.lang.String's UTF-16 units in `out`, or null if it does not fit
    /// (GetStringLength, GetStringRegion).
    pub fn units(e: Env, s: Object, out: []u16) ?[]u16 {
        const n: usize = @intCast(e.at(164, fn (Raw, Object) callconv(.c) i32)(e.raw(), s));
        if (n > out.len) return null;
        e.at(220, fn (Raw, Object, i32, i32, [*]u16) callconv(.c) void)(e.raw(), s, 0, @intCast(n), out.ptr);
        return if (e.failed()) null else out[0..n];
    }

    pub fn staticField(e: Env, class: Object, name: [*:0]const u8, sig: [*:0]const u8) ?Object {
        const f = e.at(144, fn (Raw, Object, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque)(e.raw(), class, name, sig) orelse {
            _ = e.failed();
            return null;
        };
        const r = e.at(145, fn (Raw, Object, *anyopaque) callconv(.c) ?Object)(e.raw(), class, f);
        return if (e.failed()) null else r;
    }
};

/// The JavaVM's invocation table: attaches the calling thread (AttachCurrentThread, index 4)
/// and detaches it (DetachCurrentThread, 5).
pub const Vm = *const *const [7]?*const anyopaque;

pub fn attach(vm: *anyopaque) ?Env {
    const v: Vm = @ptrCast(@alignCast(vm));
    const f: *const fn (Vm, *?*anyopaque, ?*anyopaque) callconv(.c) i32 = @ptrCast(@alignCast(v.*[4].?));
    var env: ?*anyopaque = null;
    if (f(v, &env, null) != 0) return null;
    return .{ .env = @ptrCast(@alignCast(env orelse return null)) };
}

pub fn detach(vm: *anyopaque) void {
    const v: Vm = @ptrCast(@alignCast(vm));
    const f: *const fn (Vm) callconv(.c) i32 = @ptrCast(@alignCast(v.*[5].?));
    _ = f(v);
}

pub fn obj(o: ?Object) Value {
    return .{ .l = o };
}
