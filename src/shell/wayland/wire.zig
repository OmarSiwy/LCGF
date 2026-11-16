//! The Wayland wire protocol over a Unix socket, without libwayland
//! (https://wayland.freedesktop.org/docs/html/ch04.html, "Wire Format"). A message is a header
//! of two words (object id; size << 16 | opcode) and 32-bit arguments in host byte order:
//! int, uint, object and new_id are one word, fixed is 24.8, a string or an array is its byte
//! length then the bytes padded to a word (a string's length counts its NUL). File descriptors
//! do not travel in the bytes: they go beside them as SCM_RIGHTS, in the order the messages
//! name them.
//!
//! `Conn` buffers both directions in fixed arrays: `send` encodes into the out buffer and
//! `flush` writes it; `fill` reads what the socket has without blocking and `next` hands out one
//! whole message at a time. The same type serves the client (src/shell/wayland/wayland.zig) and
//! the fake compositor of the tests.

const std = @import("std");
const linux = std.os.linux;

/// The largest message libwayland sends by default.
pub const max_message = 4096;
/// Descriptors one sendmsg may carry (libwayland's MAX_FDS_OUT).
const max_fds = 28;

/// A 24.8 fixed-point argument.
pub const Fixed = struct {
    raw: i32,
    pub fn from(v: f32) Fixed {
        return .{ .raw = @intFromFloat(@round(v * 256)) };
    }
    pub fn float(x: Fixed) f32 {
        return @as(f32, @floatFromInt(x.raw)) / 256;
    }
};

/// A file descriptor argument: sent beside the bytes, and closed by `flush` once sent, so the
/// caller hands it over.
pub const Fd = struct { fd: i32 };

/// An array argument (a string argument is a plain `[]const u8`).
pub const Array = struct { bytes: []const u8 };

pub const Error = error{ Closed, Overflow };

/// One received message: the target object, the opcode and the argument bytes.
pub const Msg = struct {
    id: u32,
    opcode: u16,
    body: []const u8,

    /// Reads the arguments in order.
    pub fn args(m: Msg) Args {
        return .{ .body = m.body };
    }
};

/// A cursor over a message's arguments. Reading past the end gives zeros and empty strings, so
/// a short message from a broken peer is never read out of bounds.
pub const Args = struct {
    body: []const u8,
    at: usize = 0,

    pub fn uint(a: *Args) u32 {
        if (a.at + 4 > a.body.len) return 0;
        defer a.at += 4;
        return std.mem.readInt(u32, a.body[a.at..][0..4], .little);
    }
    pub fn int(a: *Args) i32 {
        return @bitCast(a.uint());
    }
    pub fn fixed(a: *Args) f32 {
        return (Fixed{ .raw = a.int() }).float();
    }
    /// The bytes of an array argument.
    pub fn array(a: *Args) []const u8 {
        const len: usize = a.uint();
        const start = a.at;
        const end = @min(start + len, a.body.len);
        a.at = @min(start + std.mem.alignForward(usize, len, 4), a.body.len);
        return a.body[@min(start, end)..end];
    }
    /// A string argument without its NUL; a null string is empty.
    pub fn string(a: *Args) []const u8 {
        const s = a.array();
        return s[0..s.len -| 1];
    }
};

pub const Conn = struct {
    fd: i32,
    out: [max_message * 2]u8 = undefined,
    out_len: usize = 0,
    out_fds: [max_fds]i32 = undefined,
    out_nfds: usize = 0,
    in: [max_message * 2]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    /// Received descriptors not yet taken, oldest first.
    in_fds: [max_fds * 2]i32 = undefined,
    in_nfds: usize = 0,

    /// Encodes one request (or event, for a fake compositor) into the out buffer, flushing first
    /// if it would not fit. `args` is a tuple of u32, i32, Fixed, Fd, Array and []const u8.
    pub fn send(c: *Conn, id: u32, opcode: u16, args: anytype) Error!void {
        var size: usize = 8;
        var nfds: usize = 0;
        inline for (args) |a| switch (@TypeOf(a)) {
            u32, i32, Fixed => size += 4,
            Fd => nfds += 1,
            Array => size += 4 + std.mem.alignForward(usize, a.bytes.len, 4),
            else => size += 4 + std.mem.alignForward(usize, a.len + 1, 4),
        };
        if (size > max_message) return error.Overflow;
        if (c.out_len + size > c.out.len or c.out_nfds + nfds > max_fds) try c.flush();
        const head = [2]u32{ id, (@as(u32, @intCast(size)) << 16) | opcode };
        c.put(std.mem.asBytes(&head));
        inline for (args) |a| switch (@TypeOf(a)) {
            u32, i32 => c.word(@bitCast(a)),
            Fixed => c.word(@bitCast(a.raw)),
            Fd => {
                c.out_fds[c.out_nfds] = a.fd;
                c.out_nfds += 1;
            },
            Array => c.bytes(a.bytes, false),
            else => c.bytes(a, true),
        };
    }

    fn put(c: *Conn, b: []const u8) void {
        @memcpy(c.out[c.out_len..][0..b.len], b);
        c.out_len += b.len;
    }
    fn word(c: *Conn, w: u32) void {
        c.put(std.mem.asBytes(&w));
    }
    /// Length, bytes, then zeros to a whole word; a string adds its NUL.
    fn bytes(c: *Conn, b: []const u8, nul: bool) void {
        const len = b.len + @intFromBool(nul);
        c.word(@intCast(len));
        c.put(b);
        const pad = std.mem.alignForward(usize, len, 4) - b.len;
        @memset(c.out[c.out_len..][0..pad], 0);
        c.out_len += pad;
    }

    /// Writes everything buffered, with the buffered descriptors, then closes them. Blocks only
    /// as long as the socket's buffer is full.
    pub fn flush(c: *Conn) Error!void {
        var control: [cmsgSpace(max_fds)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var sent: usize = 0;
        while (sent < c.out_len) {
            const iov = [1]std.posix.iovec_const{.{ .base = c.out[sent..].ptr, .len = c.out_len - sent }};
            var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            if (c.out_nfds > 0) {
                const len = cmsgLen(c.out_nfds);
                const h: *linux.cmsghdr = @ptrCast(&control);
                h.* = .{ .len = len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                @memcpy(control[@sizeOf(linux.cmsghdr)..][0 .. c.out_nfds * 4], std.mem.sliceAsBytes(c.out_fds[0..c.out_nfds]));
                msg.control = &control;
                msg.controllen = cmsgSpace(c.out_nfds);
            }
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => {
                    var p = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&p, 1, -1);
                    continue;
                },
                else => return error.Closed,
            }
            sent += rc;
            for (c.out_fds[0..c.out_nfds]) |fd| _ = linux.close(fd);
            c.out_nfds = 0;
        }
        c.out_len = 0;
    }

    /// Reads what the socket has, without blocking. False when nothing was waiting; an error
    /// when the peer is gone.
    pub fn fill(c: *Conn) Error!bool {
        if (c.in_start > 0) {
            std.mem.copyForwards(u8, &c.in, c.in[c.in_start..c.in_end]);
            c.in_end -= c.in_start;
            c.in_start = 0;
        }
        if (c.in_end == c.in.len) return error.Overflow;
        var control: [cmsgSpace(max_fds)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const iov = [1]std.posix.iovec{.{ .base = c.in[c.in_end..].ptr, .len = c.in.len - c.in_end }};
        var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = @constCast(&iov), .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
        const rc = linux.recvmsg(c.fd, &msg, linux.MSG.DONTWAIT | linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR => return false,
            else => return error.Closed,
        }
        if (rc == 0) return error.Closed;
        c.in_end += rc;
        // Descriptors, from every SCM_RIGHTS header (one per sendmsg that was coalesced).
        var at: usize = 0;
        while (at + @sizeOf(linux.cmsghdr) <= msg.controllen) {
            const h: *align(1) const linux.cmsghdr = @ptrCast(control[at..].ptr);
            if (h.len < @sizeOf(linux.cmsghdr)) break;
            if (h.level == linux.SOL.SOCKET and h.type == linux.SCM.RIGHTS) {
                const n = (h.len - @sizeOf(linux.cmsghdr)) / 4;
                const fds = control[at + @sizeOf(linux.cmsghdr) ..][0 .. n * 4];
                for (0..n) |k| {
                    const fd = std.mem.readInt(i32, fds[k * 4 ..][0..4], .little);
                    if (c.in_nfds == c.in_fds.len) {
                        _ = linux.close(fd);
                        continue;
                    }
                    c.in_fds[c.in_nfds] = fd;
                    c.in_nfds += 1;
                }
            }
            at += std.mem.alignForward(usize, h.len, @sizeOf(usize));
        }
        return true;
    }

    /// The next whole message received, or null until more arrives. Its body stays valid until
    /// the next `fill`.
    pub fn next(c: *Conn) ?Msg {
        const avail = c.in_end - c.in_start;
        if (avail < 8) return null;
        const id = std.mem.readInt(u32, c.in[c.in_start..][0..4], .little);
        const w = std.mem.readInt(u32, c.in[c.in_start + 4 ..][0..4], .little);
        const size: usize = @max(w >> 16, 8);
        if (avail < size) return null;
        defer c.in_start += size;
        return .{ .id = id, .opcode = @truncate(w), .body = c.in[c.in_start + 8 .. c.in_start + size] };
    }

    /// The oldest received descriptor, for an argument of type fd; -1 if none arrived. The
    /// caller owns it.
    pub fn takeFd(c: *Conn) i32 {
        if (c.in_nfds == 0) return -1;
        const fd = c.in_fds[0];
        std.mem.copyForwards(i32, c.in_fds[0 .. c.in_nfds - 1], c.in_fds[1..c.in_nfds]);
        c.in_nfds -= 1;
        return fd;
    }

    /// Closes the socket and every descriptor still held.
    pub fn close(c: *Conn) void {
        for (c.in_fds[0..c.in_nfds]) |fd| _ = linux.close(fd);
        for (c.out_fds[0..c.out_nfds]) |fd| _ = linux.close(fd);
        c.in_nfds = 0;
        c.out_nfds = 0;
        _ = linux.close(c.fd);
    }
};

fn cmsgLen(n: usize) usize {
    return @sizeOf(linux.cmsghdr) + n * 4;
}
fn cmsgSpace(n: usize) usize {
    return std.mem.alignForward(usize, cmsgLen(n), @sizeOf(usize));
}

/// Connects to the compositor's socket: `display` is `$WAYLAND_DISPLAY` (a name under
/// `runtime_dir`, `$XDG_RUNTIME_DIR`, or an absolute path).
pub fn connect(runtime_dir: []const u8, display: []const u8) error{ NameTooLong, Unavailable }!i32 {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    var path: []u8 = &addr.path;
    if (display.len > 0 and display[0] == '/') {
        if (display.len >= path.len) return error.NameTooLong;
        @memcpy(path[0..display.len], display);
    } else {
        if (runtime_dir.len + 1 + display.len >= path.len) return error.NameTooLong;
        @memcpy(path[0..runtime_dir.len], runtime_dir);
        path[runtime_dir.len] = '/';
        @memcpy(path[runtime_dir.len + 1 ..][0..display.len], display);
    }
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
    const fd: i32 = @intCast(rc);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        _ = linux.close(fd);
        return error.Unavailable;
    }
    return fd;
}

/// Two connected sockets: a client end and a fake compositor's end, for tests.
pub fn pair() [2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    std.debug.assert(linux.errno(rc) == .SUCCESS);
    return fds;
}

const testing = std.testing;

test "wire: a request round-trips with every argument type and a descriptor" {
    const fds = pair();
    var a: Conn = .{ .fd = fds[0] };
    var b: Conn = .{ .fd = fds[1] };
    defer a.close();
    defer b.close();
    var p: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })));
    defer _ = linux.close(p[0]);

    try a.send(7, 3, .{ @as(u32, 0xdead_beef), @as(i32, -5), Fixed.from(1.5), @as([]const u8, "xdg_wm_base"), Fd{ .fd = p[1] }, Array{ .bytes = &.{ 1, 2, 3, 4, 5 } } });
    try a.send(1, 0, .{@as(u32, 9)});
    try a.flush();
    try testing.expect(try b.fill());

    const m = b.next().?;
    try testing.expectEqual(@as(u32, 7), m.id);
    try testing.expectEqual(@as(u16, 3), m.opcode);
    var r = m.args();
    try testing.expectEqual(@as(u32, 0xdead_beef), r.uint());
    try testing.expectEqual(@as(i32, -5), r.int());
    try testing.expectEqual(@as(f32, 1.5), r.fixed());
    try testing.expectEqualStrings("xdg_wm_base", r.string());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, r.array());
    // Past the end: zeros, never out of bounds.
    try testing.expectEqual(@as(u32, 0), r.uint());

    const m2 = b.next().?;
    try testing.expectEqual(@as(u32, 1), m2.id);
    try testing.expectEqual(@as(u16, 0), m2.opcode);
    try testing.expectEqual(null, b.next());

    // The descriptor arrived and is the pipe's write end: what goes in comes out of p[0].
    const fd = b.takeFd();
    try testing.expect(fd >= 0);
    try testing.expectEqual(@as(i32, -1), b.takeFd());
    _ = linux.write(fd, "hi", 2);
    _ = linux.close(fd);
    var got: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), linux.read(p[0], &got, 2));
    try testing.expectEqualStrings("hi", &got);
}

test "wire: a message split across reads waits for its tail; nothing waiting is not an error" {
    const fds = pair();
    var a: Conn = .{ .fd = fds[0] };
    var b: Conn = .{ .fd = fds[1] };
    defer a.close();
    defer b.close();
    try testing.expect(!try b.fill());
    try a.send(2, 1, .{@as([]const u8, "abc")});
    // Send the header alone, then the rest.
    const all = a.out[0..a.out_len];
    _ = linux.write(a.fd, all.ptr, 6);
    _ = try b.fill();
    try testing.expectEqual(null, b.next());
    _ = linux.write(a.fd, all[6..].ptr, all.len - 6);
    a.out_len = 0;
    _ = try b.fill();
    var r = b.next().?.args();
    try testing.expectEqualStrings("abc", r.string());
}
