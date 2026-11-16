//! A host's own GL ES drawing for inline custom draws, as an application would write it: the
//! goldens' host draw (src/render/conformance/render.py `scene_pipe`), a gradient over the target,
//! scissored to the custom rect. Its own program, buffer, scissor and no blending, so after it
//! the context holds nothing the UI set; the conformance scene `custom` checks that the renderer
//! rebinds everything (iface.zig, "Full state rebinding"). GLSL ES 1.00, so it runs on both paths.
//!
//!     var i = iface.drawUntilCustom(&gfx, {}, draw, 0);
//!     while (i < draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, {}, draw, i + 1))
//!         gradient.draw(gfx.customScissor(draw.customs[draw.command(i).custom]), gfx.extent);

const gl = @import("gl.zig");
const program = @import("program.zig");

const vert =
    \\#version 100
    \\attribute vec2 a_pos;
    \\void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }
;
// gl_FragCoord rows count from the top here as in WGSL: the UI's shaders flip y (host.zig
// `readback`), and this full-target triangle is symmetric, so it needs no flip of its own.
const frag =
    \\#version 100
    \\precision highp float;
    \\uniform vec2 u_size;
    \\void main() {
    \\    vec2 p = gl_FragCoord.xy;
    \\    gl_FragColor = vec4(p.x / u_size.x * 0.5, 0.25, p.y / u_size.y * 0.6, 1.0);
    \\}
;

pub const Gradient = struct {
    f: *const gl.Fns,
    program: gl.Uint,
    size_at: gl.Int,
    triangle: gl.Uint = 0,

    pub fn init(f: *const gl.Fns) program.Error!Gradient {
        const names = [_][:0]const u8{"a_pos"};
        const p = try program.link(f, vert, frag, &names);
        var g: Gradient = .{ .f = f, .program = p, .size_at = f.glGetUniformLocation(p, "u_size") };
        // One triangle over the whole target.
        const pos = [_]f32{ -1, -1, 3, -1, -1, 3 };
        f.glGenBuffers(1, @ptrCast(&g.triangle));
        f.glBindBuffer(gl.ARRAY_BUFFER, g.triangle);
        f.glBufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(pos)), &pos, gl.STATIC_DRAW);
        return g;
    }

    pub fn deinit(g: *Gradient) void {
        g.f.glDeleteProgram(g.program);
        g.f.glDeleteBuffers(1, @ptrCast(&g.triangle));
    }

    /// Draws the gradient inside `scissor` (x, y, width, height, rows from the top) over a
    /// target of `extent` pixels. Leaves its program, buffer and scissor bound, blending off.
    pub fn draw(g: *const Gradient, scissor: [4]i32, extent: [2]u32) void {
        if (scissor[2] == 0 or scissor[3] == 0) return;
        const f = g.f;
        f.glUseProgram(g.program);
        f.glUniform2f(g.size_at, @floatFromInt(extent[0]), @floatFromInt(extent[1]));
        f.glBindBuffer(gl.ARRAY_BUFFER, g.triangle);
        f.glEnableVertexAttribArray(0);
        f.glVertexAttribPointer(0, 2, gl.FLOAT, 0, 0, null);
        f.glDisable(gl.BLEND);
        f.glEnable(gl.SCISSOR_TEST);
        f.glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
        f.glViewport(0, 0, @intCast(extent[0]), @intCast(extent[1]));
        f.glDrawArrays(gl.TRIANGLES, 0, 3);
    }
};
