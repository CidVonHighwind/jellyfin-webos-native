//! Rasterised glyph atlas.
//!
//! Glyphs are 8-bit coverage bitmaps rendered from the TV's LG Smart UI font
//! and packed with the gallery renderer's `SkylineBinPack`. The TV demo
//! prewarms printable ASCII; the rendering API stays small and has no FreeType
//! or image renderer dependency.
//!
//! Bitmaps, not MSDF: this UI draws text at a handful of fixed sizes, where a
//! distance field costs three channels and a median-of-three in the shader and
//! buys nothing. `base_px` is the size glyphs are rasterised at; drawing far
//! above it softens, which is the tradeoff. The packing, the gutter and the
//! region bookkeeping are unchanged.

const std = @import("std");
const Skyline = @import("skyline");

pub const base_px: f32 = 48;
const gutter: u16 = 1;
pub const bytes_per_pixel: u3 = 1;

const KernelResult = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    pixel_len: u32 = 0,
    advance: f32 = 0,
    off_x: f32 = 0,
    off_y: f32 = 0,
};

extern fn uiFontCreate(font: [*]const u8, font_len: usize, px_size: u32) callconv(.c) ?*anyopaque;
extern fn uiFontDestroy(context: ?*anyopaque) callconv(.c) void;
extern fn uiFontGlyph(context: ?*anyopaque, codepoint: u32, result: *KernelResult, pixels: [*]u8, pixel_capacity: usize) callconv(.c) u32;

/// Metrics are in pixels at `base_px`; `quad` scales them to the drawn size.
pub const Glyph = struct {
    region: Skyline.Region = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    advance: f32 = 0,
    off_x: f32 = 0,
    off_y: f32 = 0,
};

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    font_path: []const u8,
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
        var packer = try Skyline.init(512, bytes_per_pixel, allocator);
        const kernel = uiFontCreate(bytes.ptr, bytes.len, @intFromFloat(base_px)) orelse {
            packer.deinit();
            return error.InvalidUiFont;
        };
        defer uiFontDestroy(kernel);

        var out: Atlas = .{
            .allocator = allocator,
            .font_path = font_path,
            .packer = packer,
        };
        const scratch = allocator.alloc(u8, 128 * 128 * @as(usize, bytes_per_pixel)) catch |err| {
            out.deinit();
            return err;
        };
        defer allocator.free(scratch);
        for (32..127) |cp| _ = out.generate(kernel, @intCast(cp), scratch) catch |err| {
            out.deinit();
            return err;
        };
        out.packer.dirty = true;
        allocator.free(bytes);
        return out;
    }

    pub fn deinit(self: *Atlas) void {
        self.packer.deinit();
        self.* = undefined;
    }

    pub fn size(self: *const Atlas) u16 {
        return self.packer.size;
    }

    pub fn pixels(self: *const Atlas) []const u8 {
        return self.packer.data;
    }

    pub fn glyph(self: *const Atlas, ch: u8) ?Glyph {
        return self.glyphs[if (ch < 128) ch else '?'];
    }

    pub fn measure(self: *const Atlas, text: []const u8, size_px: f32) f32 {
        const scale = size_px / base_px;
        var width: f32 = 0;
        for (text) |ch| if (self.glyph(ch)) |g| {
            width += g.advance * scale;
        };
        return width;
    }

    fn generate(self: *Atlas, kernel: ?*anyopaque, codepoint: u21, scratch: []u8) !?Glyph {
        var rendered: KernelResult = .{};
        const result = uiFontGlyph(kernel, codepoint, &rendered, scratch.ptr, scratch.len);
        if (result == 1) {
            self.glyphs[codepoint] = null;
            return null;
        }
        if (result != 0) return error.GlyphGenerationFailed;
        if (rendered.width == 0 or rendered.height == 0) {
            const empty: Glyph = .{ .advance = rendered.advance };
            self.glyphs[codepoint] = empty;
            return empty;
        }

        const w = rendered.width;
        const h = rendered.height;
        const padded_w = w + 2 * gutter;
        const padded_h = h + 2 * gutter;
        const padded = try self.allocator.alloc(u8, @as(usize, padded_w) * padded_h * bytes_per_pixel);
        defer self.allocator.free(padded);
        // Transparent gutter, not the edge-replicated one an MSDF needs: these
        // are coverage values, so bilinear at a glyph's edge must fall to zero
        // rather than smear the neighbour that got packed next to it.
        @memset(padded, 0);
        const src = scratch[0..rendered.pixel_len];
        for (0..h) |sy| {
            const dst_at = ((sy + gutter) * padded_w + gutter) * bytes_per_pixel;
            const src_at = sy * w * bytes_per_pixel;
            @memcpy(padded[dst_at..][0 .. @as(usize, w) * bytes_per_pixel], src[src_at..][0 .. @as(usize, w) * bytes_per_pixel]);
        }

        var region = try self.packer.allocResizing(.{ .w = padded_w, .h = padded_h });
        try self.packer.blit(region, padded, @as(usize, padded_w) * bytes_per_pixel);
        region.x += gutter;
        region.y += gutter;
        region.w -= 2 * gutter;
        region.h -= 2 * gutter;
        const glyph_value: Glyph = .{
            .region = region,
            .advance = rendered.advance,
            .off_x = rendered.off_x,
            .off_y = rendered.off_y,
        };
        self.glyphs[codepoint] = glyph_value;
        return glyph_value;
    }
};

pub fn quad(atlas: *const Atlas, glyph_value: Glyph, pen_x: f32, baseline: f32, size_px: f32) struct { rect: [4]f32, uv: [4]f32 } {
    const scale = size_px / base_px;
    const region = glyph_value.region;
    const extent: f32 = @floatFromInt(atlas.packer.size);
    return .{
        .rect = .{
            pen_x + glyph_value.off_x * scale,
            baseline + glyph_value.off_y * scale,
            @as(f32, @floatFromInt(region.w)) * scale,
            @as(f32, @floatFromInt(region.h)) * scale,
        },
        .uv = .{
            @as(f32, @floatFromInt(region.x)) / extent,
            @as(f32, @floatFromInt(region.y)) / extent,
            @as(f32, @floatFromInt(region.x + region.w)) / extent,
            @as(f32, @floatFromInt(region.y + region.h)) / extent,
        },
    };
}
