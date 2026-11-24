//! Render the actual LCGF application to a P6 PPM; useful on machines without a window server.
const std = @import("std");
const lcgf = @import("lcgf");
const host = @import("host");
const application = @import("app");
var app: application.App = .{};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "preview.ppm";
    app.init();
    const smoke = try host.Smoke.run(&app, "frame\nviewport 800 600\nframe\n");
    const width = host.smoke_w;
    const height = host.smoke_h;
    const pixels = try init.gpa.alloc(u8, width * height * 3 + 64);
    defer init.gpa.free(pixels);
    const header = try std.fmt.bufPrint(pixels, "P6\n{d} {d}\n255\n", .{ width, height });
    var at = header.len;
    for (0..height) |y| for (0..width) |x| {
        const color = smoke.at(@intCast(x), @intCast(y));
        pixels[at..][0..3].* = .{ color.r, color.g, color.b };
        at += 3;
    };
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = pixels[0..at] });
    std.debug.print("Wrote {s} ({d}x{d})\n", .{ path, width, height });
}
