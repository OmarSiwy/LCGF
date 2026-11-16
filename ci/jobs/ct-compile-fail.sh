# Every comptime spec rule is a compile error with a known message (plans C0137-C0143).
# `zig build ct-compile-fail` builds each src/comptime/compile_fail/*.zig as an object that must
# fail with the message on its `//! expect: ` first line. Then two controls show the harness can
# fail: a case whose spec is valid, and a case whose expected message is wrong.
zig build ct-compile-fail
dir=src/comptime/compile_fail
n=$(ls "$dir"/*.zig | wc -l)
[ "$n" -gt 0 ] || { echo "no compile-fail cases in $dir"; exit 1; }
control="$dir/zz_control.zig"
trap 'rm -f "$control"' EXIT
control_must_fail() {
    printf '%s\n' "//! expect: $1" 'const s = @import("lcgr").spec;' '' 'comptime {' "    $2" '}' > "$control"
    if zig build ct-compile-fail >/dev/null 2>&1; then echo "control '$1' passed: the harness cannot fail"; exit 1; fi
}
control_must_fail "duplicate widget id 'a'" '@import("lcgr").validate.check(struct { a: f32 }, s.slider(.a, .a), .{ .require_names = false });'
control_must_fail "duplicate widget id 'b'" '@import("lcgr").validate.check(struct { a: f32 }, s.row(.{}, .{ s.slider(.a, .a), s.slider(.a, .a) }), .{ .require_names = false });'
rm -f "$control"
zig build ct-compile-fail
echo "$n compile-fail cases match; both controls fail"
