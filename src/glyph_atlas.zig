//! MSDF glyph atlas adapted from `gallery-glfw/src/render/TextRenderer.zig`.
//!
//! The pure-Zig MSDF generator reads the TV's LG Smart UI font and glyphs are
//! packed with the gallery renderer's `SkylineBinPack`. The TV demo prewarms
//! printable ASCII; the rendering API stays small and has no FreeType or image
//! renderer dependency.

const std = @import("std");
const Generator = @import("msdf");
const Skyline = @import("skyline");

pub const base_px: f32 = 48;
const glyph_px_size: u16 = 48;
const glyph_px_range: u16 = 8;
const gutter: u16 = 1;
pub const bytes_per_pixel: u3 = 3;

const gen_opts: Generator.GenerationOptions = .{
    .sdf_type = .msdf,
    .px_size = glyph_px_size,
    .px_range = glyph_px_range,
    .scanline_fill_rule = .non_zero,
    .error_correction_opts = .{ .check_distance = false },
};

pub const Glyph = struct {
    region: Skyline.Region = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    advance: f32 = 0,
    bearing_x: f32 = 0,
    bearing_y: f32 = 0,
};

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    font_bytes: []u8,
    font_path: []const u8,
    generator: Generator,
    packer: Skyline,
    glyphs: [128]?Glyph = @splat(null),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Atlas {
        const candidates = [_][]const u8{
            "/usr/share/fonts/LG_Smart_UI-Regular.ttf",
            "/usr/share/fonts/DroidSans.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        };

        var font_bytes: ?[]u8 = null;
        var font_path: []const u8 = "";
        if (std.c.getenv("UI_FONT")) |override_z| {
            const override = std.mem.sliceTo(override_z, 0);
            font_bytes = try std.Io.Dir.cwd().readFileAlloc(io, override, allocator, .limited(64 << 20));
            font_path = override;
        } else {
            for (candidates) |path| {
                font_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20)) catch continue;
                font_path = path;
                break;
            }
        }
        const bytes = font_bytes orelse return error.NoUiFont;
        errdefer allocator.free(bytes);
        var generator = try Generator.create(bytes);
        errdefer generator.destroy();
        var packer = try Skyline.init(512, bytes_per_pixel, allocator);
        errdefer packer.deinit();

        var out: Atlas = .{
            .allocator = allocator,
            .font_bytes = bytes,
            .font_path = font_path,
            .generator = generator,
            .packer = packer,
        };
        errdefer out.deinit();
        for (32..127) |cp| _ = try out.generate(@intCast(cp));
        out.packer.dirty = true;
        return out;
    }

    pub fn deinit(self: *Atlas) void {
        self.packer.deinit();
        self.generator.destroy();
        self.allocator.free(self.font_bytes);
        self.* = undefined;
    }

    pub fn size(self: *const Atlas) u16 {
        return self.packer.size;
    }

    pub fn pixels(self: *const Atlas) []const u8 {
        return self.packer.data;
    }

    pub fn unitRange(self: *const Atlas) [2]f32 {
        const extent: f32 = @floatFromInt(self.packer.size);
        const range: f32 = glyph_px_range;
        return .{ range / extent, range / extent };
    }

    pub fn glyph(self: *const Atlas, ch: u8) ?Glyph {
        return self.glyphs[if (ch < 128) ch else '?'];
    }

    pub fn measure(self: *const Atlas, text: []const u8, size_px: f32) f32 {
        const scale = size_px / base_px;
        var width: f32 = 0;
        for (text) |ch| if (self.glyph(ch)) |g| {
            width += g.advance * base_px * scale;
        };
        return width;
    }

    fn generate(self: *Atlas, codepoint: u21) !?Glyph {
        var shape = self.generator.extractShape(self.allocator, codepoint, gen_opts) catch {
            self.glyphs[codepoint] = null;
            return null;
        };
        defer shape.deinit(self.allocator);

        if (shape.shape.contours.items.len == 0) {
            const empty: Glyph = .{ .advance = @floatCast(shape.advance) };
            self.glyphs[codepoint] = empty;
            return empty;
        }

        const rendered = try Generator.renderShape(self.allocator, &shape, gen_opts);
        defer rendered.deinit(self.allocator);
        const w: u16 = rendered.glyph_data.width;
        const h: u16 = rendered.glyph_data.height;
        const padded_w = w + 2 * gutter;
        const padded_h = h + 2 * gutter;
        const padded = try self.allocator.alloc(u8, @as(usize, padded_w) * padded_h * bytes_per_pixel);
        defer self.allocator.free(padded);
        const src = switch (rendered.pixels) {
            .normal => |data| data,
            .msdf10 => unreachable,
        };
        for (0..padded_h) |dy| {
            const sy = @min(@as(usize, h) - 1, dy -| gutter);
            for (0..padded_w) |dx| {
                const sx = @min(@as(usize, w) - 1, dx -| gutter);
                const src_at = (sy * w + sx) * bytes_per_pixel;
                const dst_at = (dy * padded_w + dx) * bytes_per_pixel;
                @memcpy(padded[dst_at..][0..bytes_per_pixel], src[src_at..][0..bytes_per_pixel]);
            }
        }

        var region = try self.packer.allocResizing(.{ .w = padded_w, .h = padded_h });
        try self.packer.blit(region, padded, @as(usize, padded_w) * bytes_per_pixel);
        region.x += gutter;
        region.y += gutter;
        region.w -= 2 * gutter;
        region.h -= 2 * gutter;
        const glyph_value: Glyph = .{
            .region = region,
            .advance = @floatCast(rendered.glyph_data.advance),
            .bearing_x = @floatCast(rendered.glyph_data.bearing_x),
            .bearing_y = @floatCast(rendered.glyph_data.bearing_y),
        };
        self.glyphs[codepoint] = glyph_value;
        return glyph_value;
    }
};

pub fn quad(atlas: *const Atlas, glyph_value: Glyph, pen_x: f32, baseline: f32, size_px: f32) struct { rect: [4]f32, uv: [4]f32 } {
    const scale = size_px / base_px;
    const inv_gen = 1.0 / @as(f32, glyph_px_size);
    const half_range_em = 0.5 * @as(f32, glyph_px_range) * inv_gen;
    const s = base_px * scale;
    const region = glyph_value.region;
    const extent: f32 = @floatFromInt(atlas.packer.size);
    return .{
        .rect = .{
            pen_x + (glyph_value.bearing_x - half_range_em) * s,
            baseline - (glyph_value.bearing_y + half_range_em) * s,
            @as(f32, @floatFromInt(region.w)) * inv_gen * s,
            @as(f32, @floatFromInt(region.h)) * inv_gen * s,
        },
        .uv = .{
            @as(f32, @floatFromInt(region.x)) / extent,
            @as(f32, @floatFromInt(region.y)) / extent,
            @as(f32, @floatFromInt(region.x + region.w)) / extent,
            @as(f32, @floatFromInt(region.y + region.h)) / extent,
        },
    };
}
