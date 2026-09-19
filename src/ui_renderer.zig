//! OpenGL ES backend for the trimmed loom command stream.
//!
//! Every rectangle, border, image and glyph is one instance of the same unit
//! quad, and per-instance clipping keeps a virtual list inside the batch.
//!
//! There is no bindless texture support on this GPU, so the batch is bounded by
//! its *bindings*, not by the command count: instances accumulate until a
//! command needs a different texture or different uniforms, and only then does
//! the batch flush. Untextured commands -- fills and borders, the bulk of a UI
//! -- join whichever batch is open instead of breaking it, so alternating
//! rect/glyph/rect costs one draw, not three.

const std = @import("std");
const gl = @import("gl.zig");
const loom = @import("loom/loom.zig");
const glyphs = @import("glyph_atlas.zig");

const ui_vs = @embedFile("ui_vs");

/// One program per kind of instance, so no fragment ever executes another
/// kind's code. `Kind` is also part of the batch state, so switching program
/// costs a flush and nothing else.
const Kind = enum(u8) { fill, round, border, glyph, image };

const fragment_sources = [_][]const u8{
    @embedFile("ui_fill"),
    @embedFile("ui_round"),
    @embedFile("ui_border"),
    @embedFile("ui_glyph"),
    @embedFile("ui_image"),
};
/// A default texture for `Context.image`, for an application whose artwork is
/// known up front -- `uidemo`'s baked atlas. An application that loads images
/// at runtime passes null and makes its own textures with `createTexture`.
pub const Media = struct {
    width: u32,
    height: u32,
    /// RGB8, `width * height * 3` bytes.
    pixels: []const u8,
};

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
const GL_R8 = 0x8229;
const GL_RED = 0x1903;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_LINEAR = 0x2601;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_UNPACK_ALIGNMENT = 0x0CF5;

/// Slang hands out bindings in declaration order and the uniform block takes 0,
/// so the shader's single sampler is binding 1. Check the generated GLSL if the
/// shader's declarations are ever reordered.
const ATLAS_UNIT = GL_TEXTURE1;
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

/// Everything a draw call needs bound. Two batches merge iff these match.
/// std140 pads a float2 block to 16 bytes, so the tail is explicit.
const State = struct {
    kind: Kind,
    texture: u32,
    uniforms: Uniforms,
    /// Off for square opaque fills. Measured at 1080p: alpha blending over this
    /// scene's 3.1x overdraw costs 1.6 ms, and a fill with no soft edge and no
    /// alpha does not need any of it. It also lets the driver treat the
    /// full-screen background as a tile clear rather than a blend over whatever
    /// was in the framebuffer.
    blend: bool,

    fn eql(a: State, b: State) bool {
        return a.kind == b.kind and a.texture == b.texture and
            a.blend == b.blend and std.meta.eql(a.uniforms, b.uniforms);
    }
};

const Uniforms = extern struct {
    viewport: [2]f32,
    padding: [2]f32 = .{ 0, 0 },
};

var glEnable: *const fn (u32) callconv(.c) void = undefined;
var glDisable: *const fn (u32) callconv(.c) void = undefined;
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
var glDeleteTextures: *const fn (i32, [*]const u32) callconv(.c) void = undefined;

fn loadGl() void {
    inline for (.{
        .{ "glEnable", &glEnable },                           .{ "glDisable", &glDisable },                         .{ "glBlendFunc", &glBlendFunc },                     .{ "glPixelStorei", &glPixelStorei },
        .{ "glCreateShader", &glCreateShader },               .{ "glShaderSource", &glShaderSource },               .{ "glCompileShader", &glCompileShader },             .{ "glGetShaderiv", &glGetShaderiv },
        .{ "glGetShaderInfoLog", &glGetShaderInfoLog },       .{ "glCreateProgram", &glCreateProgram },             .{ "glAttachShader", &glAttachShader },               .{ "glLinkProgram", &glLinkProgram },
        .{ "glGetProgramiv", &glGetProgramiv },               .{ "glGetProgramInfoLog", &glGetProgramInfoLog },     .{ "glUseProgram", &glUseProgram },                   .{ "glGenBuffers", &glGenBuffers },
        .{ "glBindBuffer", &glBindBuffer },                   .{ "glBufferData", &glBufferData },                   .{ "glBufferSubData", &glBufferSubData },             .{ "glBindBufferBase", &glBindBufferBase },
        .{ "glGenVertexArrays", &glGenVertexArrays },         .{ "glBindVertexArray", &glBindVertexArray },         .{ "glVertexAttribPointer", &glVertexAttribPointer }, .{ "glEnableVertexAttribArray", &glEnableVertexAttribArray },
        .{ "glVertexAttribDivisor", &glVertexAttribDivisor }, .{ "glDrawArraysInstanced", &glDrawArraysInstanced }, .{ "glGenTextures", &glGenTextures },                 .{ "glBindTexture", &glBindTexture },
        .{ "glActiveTexture", &glActiveTexture },             .{ "glTexStorage2D", &glTexStorage2D },               .{ "glTexSubImage2D", &glTexSubImage2D },             .{ "glTexParameteri", &glTexParameteri },        .{ "glDeleteTextures", &glDeleteTextures },
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

fn makeProgram(fragment: []const u8) u32 {
    const p = glCreateProgram();
    glAttachShader(p, compile(GL_VERTEX_SHADER, ui_vs));
    glAttachShader(p, compile(GL_FRAGMENT_SHADER, fragment));
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
    programs: [fragment_sources.len]u32,
    vao: u32,
    instance_buffer: u32,
    uniform_buffer: u32,
    texture: u32,
    media_texture: u32,

    /// Open batch: the state it needs, and where its instances start.
    state: ?State = null,
    blend_enabled: bool = true,
    batch_start: usize = 0,
    /// Draw calls issued by the last `draw`, which is the number worth watching.
    batches: u32 = 0,
    /// Fragments the last frame actually rasterised, after the vertex shader's
    /// geometric clipping. Divided by the screen area this is the overdraw
    /// factor. Indexed by `Kind`, so it says *which* program is expensive.
    covered_by_kind: [fragment_sources.len]f64 = @splat(0),

    pub fn covered(self: *const Renderer) f64 {
        var total: f64 = 0;
        for (self.covered_by_kind) |n| total += n;
        return total;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, media: ?Media) !Renderer {
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
        glBufferData(GL_UNIFORM_BUFFER, @sizeOf(Uniforms), null, GL_DYNAMIC_DRAW);

        var texture: u32 = 0;
        glGenTextures(1, @ptrCast(&texture));
        glActiveTexture(ATLAS_UNIT);
        glBindTexture(GL_TEXTURE_2D, texture);
        const atlas_size: i32 = @intCast(atlas.size());
        // One channel: rasterised coverage, not a three-channel distance field.
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_R8, atlas_size, atlas_size);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, atlas_size, atlas_size, GL_RED, GL_UNSIGNED_BYTE, atlas.pixels().ptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Same unit as the glyph atlas: only one texture is bound at a time.
        const media_texture = if (media) |m| makeTexture(m.width, m.height, m.pixels) else texture;
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        std.debug.print("UI font: {s}\n", .{atlas.font_path});
        return .{
            .allocator = allocator,
            .atlas = atlas,
            .programs = blk: {
                var out: [fragment_sources.len]u32 = undefined;
                for (fragment_sources, &out) |source, *program| program.* = makeProgram(source);
                break :blk out;
            },
            .vao = vao,
            .instance_buffer = buffers[1],
            .uniform_buffer = buffers[2],
            .texture = texture,
            .media_texture = media_texture,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.instances.deinit(self.allocator);
        self.atlas.deinit();
    }

    /// A texture of its own for one image, for `Context.textured`.
    ///
    /// Deliberately not an atlas: artwork arrives at whatever size the server
    /// felt like returning, an atlas would have to crop every image to a fixed
    /// tile, and recycling tiles in a scrolling grid means uploading over a
    /// tile something else may still be drawing from. The cost is one draw
    /// call per distinct texture on screen, which is what the batcher already
    /// does for a binding change.
    pub fn createTexture(self: *Renderer, width: u32, height: u32, rgb: []const u8) u32 {
        std.debug.assert(rgb.len >= @as(usize, width) * height * 3);
        const id = makeTexture(width, height, rgb);
        // The batcher tracks what it bound last; this bypassed it.
        self.state = null;
        return id;
    }

    pub fn destroyTexture(self: *Renderer, id: u32) void {
        if (id == 0) return;
        glDeleteTextures(1, @ptrCast(&id));
        self.state = null;
    }

    pub fn measure(self: *const Renderer, text: []const u8, size: f32) f32 {
        return self.atlas.measure(text, size);
    }

    pub fn draw(self: *Renderer, commands: []const loom.Command, width: f32, height: f32) void {
        self.instances.clearRetainingCapacity();
        self.state = null;
        self.batch_start = 0;
        self.batches = 0;
        self.covered_by_kind = @splat(0);

        const uniforms = Uniforms{ .viewport = .{ width, height } };
        glBindVertexArray(self.vao);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, self.uniform_buffer);
        glActiveTexture(ATLAS_UNIT);

        for (commands) |command| switch (command.data) {
            .rectangle => |r| {
                // A square-cornered fill needs no corner code at all, and the
                // background alone is a full screen of them.
                const square = r.radius <= 0;
                self.want(if (square) .fill else .round, null, uniforms, !(square and r.color[3] == 255));
                self.push(command.rect, command.clip, .{ 0, 0, 0, 0 }, r.color, r.radius, 0);
            },
            .border => |b| {
                self.want(.border, null, uniforms, true);
                self.push(command.rect, command.clip, .{ 0, 0, 0, 0 }, b.color, b.radius, b.width);
            },
            .text => |t| {
                self.want(.glyph, self.texture, uniforms, true);
                self.appendText(command.rect, command.clip, t);
            },
            .image => |i| {
                self.want(.image, if (i.texture != 0) i.texture else self.media_texture, uniforms, true);
                self.push(command.rect, command.clip, i.uv, i.tint, i.radius, 0);
            },
        };
        self.flush();
    }

    /// Declare what the next instances need. `texture` of null means "whatever
    /// is already bound" -- an untextured instance never forces a flush.
    fn want(self: *Renderer, kind: Kind, texture: ?u32, uniforms: Uniforms, blend: bool) void {
        const current = self.state orelse {
            self.state = .{ .kind = kind, .texture = texture orelse self.texture, .uniforms = uniforms, .blend = blend };
            return;
        };
        const next = State{ .kind = kind, .texture = texture orelse current.texture, .uniforms = uniforms, .blend = blend };
        if (current.eql(next)) return;
        self.flush();
        self.state = next;
    }

    /// Bind this batch's state and draw the instances collected under it.
    fn flush(self: *Renderer) void {
        const state = self.state orelse return;
        const pending = self.instances.items[self.batch_start..];
        if (pending.len == 0) return;

        if (state.blend != self.blend_enabled) {
            if (state.blend) glEnable(GL_BLEND) else glDisable(GL_BLEND);
            self.blend_enabled = state.blend;
        }
        glUseProgram(self.programs[@intFromEnum(state.kind)]);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, @sizeOf(Uniforms), &state.uniforms);
        glBindTexture(GL_TEXTURE_2D, state.texture);
        glBindBuffer(GL_ARRAY_BUFFER, self.instance_buffer);
        glBufferData(GL_ARRAY_BUFFER, @intCast(pending.len * @sizeOf(Instance)), pending.ptr, GL_DYNAMIC_DRAW);
        glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, @intCast(pending.len));

        self.batch_start = self.instances.items.len;
        self.batches += 1;
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
                    self.push(.{ .x = placed.rect[0], .y = placed.rect[1], .w = placed.rect[2], .h = placed.rect[3] }, clip, placed.uv, text.color, 0, 0);
                }
                pen_x += g.advance * scale;
            }
        }
    }

    fn push(self: *Renderer, rect: loom.Rect, clip: loom.Rect, uv: [4]f32, color: loom.Color, radius: f32, border: f32) void {
        // Match the vertex shader: the quad is shrunk to its clip rectangle,
        // so a fully clipped instance rasterises nothing.
        const visible = loom.Rect.intersect(rect, .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h });
        const kind = (self.state orelse return).kind;
        self.covered_by_kind[@intFromEnum(kind)] += @as(f64, visible.w) * @as(f64, visible.h);
        self.instances.append(self.allocator, .{
            .rect = .{ rect.x, rect.y, rect.w, rect.h },
            .uv = uv,
            .color = norm(color),
            .clip = .{ clip.x, clip.y, clip.x + clip.w, clip.y + clip.h },
            .shape = .{ radius, border, 0, 0 },
        }) catch {};
    }
};

/// RGB8 into a fresh immutable-storage texture, clamped and linear -- the
/// settings every texture here wants.
fn makeTexture(width: u32, height: u32, rgb: []const u8) u32 {
    var id: u32 = 0;
    glGenTextures(1, @ptrCast(&id));
    glActiveTexture(ATLAS_UNIT);
    glBindTexture(GL_TEXTURE_2D, id);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGB8, @intCast(width), @intCast(height));
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, @intCast(width), @intCast(height), GL_RGB, GL_UNSIGNED_BYTE, rgb.ptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return id;
}

fn norm(color: loom.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(color[0])) / 255.0,
        @as(f32, @floatFromInt(color[1])) / 255.0,
        @as(f32, @floatFromInt(color[2])) / 255.0,
        @as(f32, @floatFromInt(color[3])) / 255.0,
    };
}
