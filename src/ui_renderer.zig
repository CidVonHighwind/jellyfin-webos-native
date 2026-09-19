//! OpenGL ES backend for the trimmed loom command stream.
//!
//! Every rectangle, border and glyph is one instance of the same unit quad.
//! Per-instance clipping keeps a virtual list in the single batch, so a normal
//! UI frame is exactly one `glDrawArraysInstanced` call.

const std = @import("std");
const gl = @import("gl.zig");
const loom = @import("loom/loom.zig");
const glyphs = @import("glyph_atlas.zig");

const ui_vs = @embedFile("ui_vs");
const ui_fs = @embedFile("ui_fs");

const GL_VERTEX_SHADER = 0x8B31;
const GL_FRAGMENT_SHADER = 0x8B30;
const GL_COMPILE_STATUS = 0x8B81;
const GL_LINK_STATUS = 0x8B82;
const GL_ARRAY_BUFFER = 0x8892;
const GL_UNIFORM_BUFFER = 0x8A11;
const GL_DYNAMIC_DRAW = 0x88E8;
const GL_STATIC_DRAW = 0x88E4;
const GL_FLOAT = 0x1406;
const GL_TRIANGLE_STRIP = 0x0005;
const GL_TEXTURE_2D = 0x0DE1;
const GL_TEXTURE1 = 0x84C1;
const GL_RGB8 = 0x8051;
const GL_RGB = 0x1907;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_LINEAR = 0x2601;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_UNPACK_ALIGNMENT = 0x0CF5;
const GL_BLEND = 0x0BE2;
const GL_SRC_ALPHA = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA = 0x0303;

const Instance = extern struct {
    rect: [4]f32,
    uv: [4]f32,
    color: [4]f32,
    clip: [4]f32,
    shape: [4]f32,
};

var glEnable: *const fn (u32) callconv(.c) void = undefined;
var glBlendFunc: *const fn (u32, u32) callconv(.c) void = undefined;
var glPixelStorei: *const fn (u32, i32) callconv(.c) void = undefined;
var glCreateShader: *const fn (u32) callconv(.c) u32 = undefined;
var glShaderSource: *const fn (u32, i32, [*]const [*]const u8, ?[*]const i32) callconv(.c) void = undefined;
var glCompileShader: *const fn (u32) callconv(.c) void = undefined;
var glGetShaderiv: *const fn (u32, u32, *i32) callconv(.c) void = undefined;
var glGetShaderInfoLog: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void = undefined;
var glCreateProgram: *const fn () callconv(.c) u32 = undefined;
var glAttachShader: *const fn (u32, u32) callconv(.c) void = undefined;
var glLinkProgram: *const fn (u32) callconv(.c) void = undefined;
var glGetProgramiv: *const fn (u32, u32, *i32) callconv(.c) void = undefined;
var glGetProgramInfoLog: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void = undefined;
var glUseProgram: *const fn (u32) callconv(.c) void = undefined;
var glGenBuffers: *const fn (i32, [*]u32) callconv(.c) void = undefined;
var glBindBuffer: *const fn (u32, u32) callconv(.c) void = undefined;
var glBufferData: *const fn (u32, isize, ?*const anyopaque, u32) callconv(.c) void = undefined;
var glBufferSubData: *const fn (u32, isize, isize, *const anyopaque) callconv(.c) void = undefined;
var glBindBufferBase: *const fn (u32, u32, u32) callconv(.c) void = undefined;
var glGenVertexArrays: *const fn (i32, [*]u32) callconv(.c) void = undefined;
var glBindVertexArray: *const fn (u32) callconv(.c) void = undefined;
var glVertexAttribPointer: *const fn (u32, i32, u32, u8, i32, usize) callconv(.c) void = undefined;
var glEnableVertexAttribArray: *const fn (u32) callconv(.c) void = undefined;
var glVertexAttribDivisor: *const fn (u32, u32) callconv(.c) void = undefined;
var glDrawArraysInstanced: *const fn (u32, i32, i32, i32) callconv(.c) void = undefined;
var glGenTextures: *const fn (i32, [*]u32) callconv(.c) void = undefined;
var glBindTexture: *const fn (u32, u32) callconv(.c) void = undefined;
var glActiveTexture: *const fn (u32) callconv(.c) void = undefined;
var glTexStorage2D: *const fn (u32, i32, u32, i32, i32) callconv(.c) void = undefined;
var glTexSubImage2D: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, *const anyopaque) callconv(.c) void = undefined;
var glTexParameteri: *const fn (u32, u32, i32) callconv(.c) void = undefined;

fn loadGl() void {
    inline for (.{
        .{ "glEnable", &glEnable },                           .{ "glBlendFunc", &glBlendFunc },                             .{ "glPixelStorei", &glPixelStorei },
        .{ "glCreateShader", &glCreateShader },               .{ "glShaderSource", &glShaderSource },                       .{ "glCompileShader", &glCompileShader },
        .{ "glGetShaderiv", &glGetShaderiv },                 .{ "glGetShaderInfoLog", &glGetShaderInfoLog },               .{ "glCreateProgram", &glCreateProgram },
        .{ "glAttachShader", &glAttachShader },               .{ "glLinkProgram", &glLinkProgram },                         .{ "glGetProgramiv", &glGetProgramiv },
        .{ "glGetProgramInfoLog", &glGetProgramInfoLog },     .{ "glUseProgram", &glUseProgram },                           .{ "glGenBuffers", &glGenBuffers },
        .{ "glBindBuffer", &glBindBuffer },                   .{ "glBufferData", &glBufferData },                           .{ "glBufferSubData", &glBufferSubData },
        .{ "glBindBufferBase", &glBindBufferBase },           .{ "glGenVertexArrays", &glGenVertexArrays },                 .{ "glBindVertexArray", &glBindVertexArray },
        .{ "glVertexAttribPointer", &glVertexAttribPointer }, .{ "glEnableVertexAttribArray", &glEnableVertexAttribArray }, .{ "glVertexAttribDivisor", &glVertexAttribDivisor },
        .{ "glDrawArraysInstanced", &glDrawArraysInstanced }, .{ "glGenTextures", &glGenTextures },                         .{ "glBindTexture", &glBindTexture },
        .{ "glActiveTexture", &glActiveTexture },             .{ "glTexStorage2D", &glTexStorage2D },                       .{ "glTexSubImage2D", &glTexSubImage2D },
        .{ "glTexParameteri", &glTexParameteri },
    }) |entry| entry[1].* = gl.proc(@TypeOf(entry[1].*), entry[0]);
}

fn compile(kind: u32, source: []const u8) u32 {
    const shader = glCreateShader(kind);
    const ptr: [*]const u8 = source.ptr;
    const len: i32 = @intCast(source.len);
    glShaderSource(shader, 1, @ptrCast(&ptr), @ptrCast(&len));
    glCompileShader(shader);
    var ok: i32 = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [4096]u8 = @splat(0);
        glGetShaderInfoLog(shader, log.len, null, &log);
        std.debug.panic("UI shader compile failed:\n{s}", .{std.mem.sliceTo(&log, 0)});
    }
    return shader;
}

fn makeProgram() u32 {
    const p = glCreateProgram();
    glAttachShader(p, compile(GL_VERTEX_SHADER, ui_vs));
    glAttachShader(p, compile(GL_FRAGMENT_SHADER, ui_fs));
    glLinkProgram(p);
    var ok: i32 = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [4096]u8 = @splat(0);
        glGetProgramInfoLog(p, log.len, null, &log);
        std.debug.panic("UI program link failed:\n{s}", .{std.mem.sliceTo(&log, 0)});
    }
    return p;
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    atlas: glyphs.Atlas,
    instances: std.ArrayListUnmanaged(Instance) = .empty,
    program: u32,
    vao: u32,
    instance_buffer: u32,
    uniform_buffer: u32,
    texture: u32,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Renderer {
        loadGl();
        var atlas = try glyphs.Atlas.init(allocator, io);
        errdefer atlas.deinit();

        var vao: u32 = 0;
        glGenVertexArrays(1, @ptrCast(&vao));
        glBindVertexArray(vao);
        var buffers: [3]u32 = @splat(0);
        glGenBuffers(buffers.len, &buffers);
        const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        glBufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, 0, 8, 0);

        glBindBuffer(GL_ARRAY_BUFFER, buffers[1]);
        glBufferData(GL_ARRAY_BUFFER, 1, null, GL_DYNAMIC_DRAW);
        inline for (0..5) |i| {
            const loc: u32 = @intCast(i + 1);
            glEnableVertexAttribArray(loc);
            glVertexAttribPointer(loc, 4, GL_FLOAT, 0, @sizeOf(Instance), i * 16);
            glVertexAttribDivisor(loc, 1);
        }

        glBindBuffer(GL_UNIFORM_BUFFER, buffers[2]);
        glBufferData(GL_UNIFORM_BUFFER, 16, null, GL_DYNAMIC_DRAW);

        var texture: u32 = 0;
        glGenTextures(1, @ptrCast(&texture));
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, texture);
        const atlas_size: i32 = @intCast(atlas.size());
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGB8, atlas_size, atlas_size);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, atlas_size, atlas_size, GL_RGB, GL_UNSIGNED_BYTE, atlas.pixels().ptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        std.debug.print("UI font: {s}\n", .{atlas.font_path});
        return .{
            .allocator = allocator,
            .atlas = atlas,
            .program = makeProgram(),
            .vao = vao,
            .instance_buffer = buffers[1],
            .uniform_buffer = buffers[2],
            .texture = texture,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.instances.deinit(self.allocator);
        self.atlas.deinit();
    }

    pub fn measure(self: *const Renderer, text: []const u8, size: f32) f32 {
        return self.atlas.measure(text, size);
    }

    pub fn draw(self: *Renderer, commands: []const loom.Command, width: f32, height: f32) void {
        self.instances.clearRetainingCapacity();
        for (commands) |command| switch (command.data) {
            .rectangle => |r| self.push(command.rect, command.clip, .{ 0, 0, 0, 0 }, r.color, r.radius, 0, 0),
            .border => |b| self.push(command.rect, command.clip, .{ 0, 0, 0, 0 }, b.color, b.radius, b.width, 1),
            .text => |t| self.appendText(command.rect, command.clip, t),
        };
        if (self.instances.items.len == 0) return;

        const range = self.atlas.unitRange();
        const viewport = [4]f32{ width, height, range[0], range[1] };
        glUseProgram(self.program);
        glBindBuffer(GL_UNIFORM_BUFFER, self.uniform_buffer);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, @sizeOf(@TypeOf(viewport)), &viewport);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, self.uniform_buffer);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, self.texture);
        glBindVertexArray(self.vao);
        glBindBuffer(GL_ARRAY_BUFFER, self.instance_buffer);
        glBufferData(GL_ARRAY_BUFFER, @intCast(self.instances.items.len * @sizeOf(Instance)), self.instances.items.ptr, GL_DYNAMIC_DRAW);
        glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, @intCast(self.instances.items.len));
    }

    fn appendText(self: *Renderer, rect: loom.Rect, clip: loom.Rect, text: loom.Text) void {
        const scale = text.size / glyphs.base_px;
        var pen_x = rect.x;
        const baseline = rect.y + text.size;
        for (text.contents) |byte| {
            const ch: u8 = if (byte >= 32 and byte < 127) byte else '?';
            if (self.atlas.glyph(ch)) |g| {
                if (g.region.w != 0 and g.region.h != 0) {
                    const placed = glyphs.quad(&self.atlas, g, pen_x, baseline, text.size);
                    self.push(.{ .x = placed.rect[0], .y = placed.rect[1], .w = placed.rect[2], .h = placed.rect[3] }, clip, placed.uv, text.color, 0, 0, 2);
                }
                pen_x += g.advance * glyphs.base_px * scale;
            }
        }
    }

    fn push(self: *Renderer, rect: loom.Rect, clip: loom.Rect, uv: [4]f32, color: loom.Color, radius: f32, border: f32, mode: f32) void {
        self.instances.append(self.allocator, .{
            .rect = .{ rect.x, rect.y, rect.w, rect.h },
            .uv = uv,
            .color = norm(color),
            .clip = .{ clip.x, clip.y, clip.x + clip.w, clip.y + clip.h },
            .shape = .{ radius, border, mode, 0 },
        }) catch {};
    }
};

fn norm(color: loom.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(color[0])) / 255.0,
        @as(f32, @floatFromInt(color[1])) / 255.0,
        @as(f32, @floatFromInt(color[2])) / 255.0,
        @as(f32, @floatFromInt(color[3])) / 255.0,
    };
}
