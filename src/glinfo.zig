//! Enumerates what the TV's OpenGL ES driver can do: EGL and GL strings,
//! every extension, and the limits that decide how an app is written.
//!
//! Run with `zig build run -Dapp=glinfo`. Output is kept in docs/opengl.md.
const std = @import("std");
const gl = @import("gl.zig");

const GL_VENDOR = 0x1F00;
const GL_RENDERER = 0x1F01;
const GL_VERSION = 0x1F02;
const GL_EXTENSIONS = 0x1F03;
const GL_SHADING_LANGUAGE_VERSION = 0x8B8C;
const GL_NUM_EXTENSIONS = 0x821D;

var glGetString: *const fn (u32) callconv(.c) ?[*:0]const u8 = undefined;
var glGetStringi: *const fn (u32, u32) callconv(.c) ?[*:0]const u8 = undefined;
var glGetIntegerv: *const fn (u32, [*]i32) callconv(.c) void = undefined;

fn str(name: u32) []const u8 {
    const s = glGetString(name) orelse return "(null)";
    return std.mem.sliceTo(s, 0);
}
fn geti(name: u32) i32 {
    var v: [4]i32 = @splat(0);
    glGetIntegerv(name, &v);
    return v[0];
}

/// The limits worth knowing before writing anything; the names are the GL
/// enum names with the GL_ prefix dropped.
const limits = [_]struct { u32, []const u8 }{
    .{ 0x0D33, "MAX_TEXTURE_SIZE" },
    .{ 0x8073, "MAX_3D_TEXTURE_SIZE" },
    .{ 0x851C, "MAX_CUBE_MAP_TEXTURE_SIZE" },
    .{ 0x88FF, "MAX_ARRAY_TEXTURE_LAYERS" },
    .{ 0x84E8, "MAX_RENDERBUFFER_SIZE" },
    .{ 0x8869, "MAX_VERTEX_ATTRIBS" },
    .{ 0x8DFB, "MAX_VERTEX_UNIFORM_VECTORS" },
    .{ 0x8DFD, "MAX_FRAGMENT_UNIFORM_VECTORS" },
    .{ 0x8DFC, "MAX_VARYING_VECTORS" },
    .{ 0x8872, "MAX_TEXTURE_IMAGE_UNITS" },
    .{ 0x8B4D, "MAX_COMBINED_TEXTURE_IMAGE_UNITS" },
    .{ 0x8824, "MAX_DRAW_BUFFERS" },
    .{ 0x8CDF, "MAX_COLOR_ATTACHMENTS" },
    .{ 0x8D57, "MAX_SAMPLES" },
    .{ 0x8A30, "MAX_UNIFORM_BLOCK_SIZE" },
    .{ 0x8A2B, "MAX_VERTEX_UNIFORM_BLOCKS" },
    .{ 0x8A2D, "MAX_FRAGMENT_UNIFORM_BLOCKS" },
    .{ 0x8A2F, "MAX_UNIFORM_BUFFER_BINDINGS" },
    .{ 0x90DE, "MAX_SHADER_STORAGE_BLOCK_SIZE" },
    .{ 0x91BB, "MAX_COMPUTE_WORK_GROUP_INVOCATIONS" },
    .{ 0x8F9F, "MAX_VERTEX_ATTRIB_BINDINGS" },
    .{ 0x82E8, "MAX_LABEL_LENGTH" },
    .{ 0x9143, "MAX_DEBUG_MESSAGE_LENGTH" },
};

pub fn main() !void {
    try gl.init("dev.hookedbehemoth.glinfo", "gl info", 1920, 1080);
    glGetString = gl.proc(@TypeOf(glGetString), "glGetString");
    glGetIntegerv = gl.proc(@TypeOf(glGetIntegerv), "glGetIntegerv");
    glGetStringi = gl.proc(@TypeOf(glGetStringi), "glGetStringi");

    std.debug.print(
        \\
        \\EGL_VERSION     {s}
        \\EGL_VENDOR      {s}
        \\EGL_CLIENT_APIS {s}
        \\
        \\GL_VENDOR       {s}
        \\GL_RENDERER     {s}
        \\GL_VERSION      {s}
        \\GL_SL_VERSION   {s}
        \\
    , .{
        gl.eglString(gl.egl_string.version),
        gl.eglString(gl.egl_string.vendor),
        gl.eglString(gl.egl_string.client_apis),
        str(GL_VENDOR),
        str(GL_RENDERER),
        str(GL_VERSION),
        str(GL_SHADING_LANGUAGE_VERSION),
    });

    std.debug.print("limits:\n", .{});
    for (limits) |l| std.debug.print("  {s:<38} {d}\n", .{ l[1], geti(l[0]) });

    std.debug.print("\nEGL extensions:\n", .{});
    var it = std.mem.tokenizeScalar(u8, gl.eglString(gl.egl_string.extensions), ' ');
    while (it.next()) |e| std.debug.print("  {s}\n", .{e});

    // ES 3 reports extensions one at a time; the old space-separated
    // GL_EXTENSIONS string is an ES 2 leftover and may be absent.
    const n = geti(GL_NUM_EXTENSIONS);
    std.debug.print("\nGL extensions ({d}):\n", .{n});
    for (0..@intCast(n)) |i| {
        const e = glGetStringi(GL_EXTENSIONS, @intCast(i)) orelse continue;
        std.debug.print("  {s}\n", .{std.mem.sliceTo(e, 0)});
    }
}
