//! Rasterised glyph atlas.
//!
//! Glyphs are 8-bit coverage bitmaps rendered from the TV's LG Smart UI font
//! and packed with the gallery renderer's `SkylineBinPack`. The TV demo
//! prewarms ASCII and adds Unicode glyphs on demand; the API has no FreeType
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
const fallback_paths = [_][]const u8{
    "/usr/share/fonts/DroidSansFallback.ttf",
    "/usr/share/fonts/DroidSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
};
const Font = struct { bytes: []u8, kernel: *anyopaque };

/// Decode once per character, including invalid/truncated server strings.
/// Measurement and rendering must agree on advances for UTF-8 UI symbols.
pub const Codepoints = struct {
    text: []const u8,

    pub fn next(self: *Codepoints) ?u21 {
        if (self.text.len == 0) return null;
        const size = std.unicode.utf8ByteSequenceLength(self.text[0]) catch {
            self.text = self.text[1..];
            return '?';
        };
        if (size > self.text.len) {
            self.text = "";
            return '?';
        }
        const cp = std.unicode.utf8Decode(self.text[0..size]) catch '?';
        self.text = self.text[size..];
        return cp;
    }
};

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
    io: std.Io,
    fonts: std.ArrayListUnmanaged(Font) = .empty,
    fallbacks_loaded: bool = false,
    glyphs: std.AutoHashMapUnmanaged(u21, ?Glyph) = .empty,
    scratch: []u8,
    /// GLES guarantees at least 2048; the renderer replaces this with the GPU limit.
    max_size: u16 = 2048,

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
        var out: Atlas = .{
            .allocator = allocator,
            .io = io,
            .font_path = font_path,
            .packer = undefined,
            .scratch = &.{},
        };
        // addFont owns bytes even on failure.
        try out.addFont(bytes);
        errdefer {
            for (out.fonts.items) |font| {
                uiFontDestroy(font.kernel);
                allocator.free(font.bytes);
            }
            out.fonts.deinit(allocator);
        }
        out.packer = try Skyline.init(512, bytes_per_pixel, allocator);
        errdefer out.packer.deinit();
        out.scratch = try allocator.alloc(u8, 128 * 128);
        errdefer allocator.free(out.scratch);
        errdefer out.glyphs.deinit(allocator);
        for (32..127) |cp| try out.ensure(@intCast(cp));
        out.packer.dirty = true;
        return out;
    }

    fn addFont(self: *Atlas, bytes: []u8) !void {
        errdefer self.allocator.free(bytes);
        const kernel = uiFontCreate(bytes.ptr, bytes.len, @intFromFloat(base_px)) orelse return error.InvalidUiFont;
        errdefer uiFontDestroy(kernel);
        try self.fonts.append(self.allocator, .{ .bytes = bytes, .kernel = kernel });
    }

    fn loadFallbacks(self: *Atlas) void {
        if (self.fallbacks_loaded) return;
        self.fallbacks_loaded = true;
        for (fallback_paths) |path| {
            if (std.mem.eql(u8, path, self.font_path)) continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 << 20)) catch continue;
            self.addFont(bytes) catch continue;
        }
    }

    pub fn deinit(self: *Atlas) void {
        for (self.fonts.items) |font| {
            uiFontDestroy(font.kernel);
            self.allocator.free(font.bytes);
        }
        self.fonts.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.allocator.free(self.scratch);
        self.packer.deinit();
        self.* = undefined;
    }

    pub fn size(self: *const Atlas) u16 {
        return self.packer.size;
    }

    pub fn pixels(self: *const Atlas) []const u8 {
        return self.packer.data;
    }

    pub fn glyph(self: *const Atlas, ch: u21) ?Glyph {
        return (self.glyphs.get(ch) orelse null) orelse (self.glyphs.get('?') orelse null);
    }

    pub fn prepare(self: *Atlas, text: []const u8) void {
        var codepoints: Codepoints = .{ .text = text };
        while (codepoints.next()) |ch| self.ensure(ch) catch {};
    }

    pub fn ensure(self: *Atlas, ch: u21) !void {
        if (self.glyphs.contains(ch)) return;
        try self.glyphs.ensureUnusedCapacity(self.allocator, 1);
        var found = try self.generate(self.fonts.items[0].kernel, ch);
        if (found == null) {
            self.loadFallbacks();
            for (self.fonts.items[1..]) |font| {
                found = try self.generate(font.kernel, ch);
                if (found != null) break;
            }
        }
        // Cache misses too; unsupported characters shouldn't rasterise every frame.
        self.glyphs.putAssumeCapacity(ch, found);
    }

    pub fn measure(self: *Atlas, text: []const u8, size_px: f32) f32 {
        self.prepare(text);
        const scale = size_px / base_px;
        var width: f32 = 0;
        var codepoints: Codepoints = .{ .text = text };
        while (codepoints.next()) |ch| if (self.glyph(ch)) |g| {
            width += g.advance * scale;
        };
        return width;
    }

    fn generate(self: *Atlas, kernel: ?*anyopaque, codepoint: u21) !?Glyph {
        var rendered: KernelResult = .{};
        var result = uiFontGlyph(kernel, codepoint, &rendered, self.scratch.ptr, self.scratch.len);
        while (result == 2 and self.scratch.len < 1024 * 1024) {
            self.scratch = try self.allocator.realloc(self.scratch, self.scratch.len * 2);
            result = uiFontGlyph(kernel, codepoint, &rendered, self.scratch.ptr, self.scratch.len);
        }
        if (result == 1) return null;
        if (result != 0) return error.GlyphGenerationFailed;
        if (rendered.width == 0 or rendered.height == 0) {
            const empty: Glyph = .{ .advance = rendered.advance };
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
        const src = self.scratch[0..rendered.pixel_len];
        for (0..h) |sy| {
            const dst_at = ((sy + gutter) * padded_w + gutter) * bytes_per_pixel;
            const src_at = sy * w * bytes_per_pixel;
            @memcpy(padded[dst_at..][0 .. @as(usize, w) * bytes_per_pixel], src[src_at..][0 .. @as(usize, w) * bytes_per_pixel]);
        }

        var region = while (true) {
            if (self.packer.alloc(.{ .w = padded_w, .h = padded_h })) |region| break region else |err| {
                if (err != error.NoSpace) return err;
                if (self.packer.size >= self.max_size) return error.AtlasFull;
                try self.packer.enlargeTexture(@min(self.packer.size * 2, self.max_size));
            }
        };
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

test "UTF-8 symbols occupy one glyph and truncated strings are safe" {
    var text: Codepoints = .{ .text = "★ 8.2\xe2\x80" };
    for ([_]u21{ '★', ' ', '8', '.', '2', '?' }) |cp|
        try std.testing.expectEqual(cp, text.next().?);
    try std.testing.expect(text.next() == null);
}

test "atlas grows on demand without moving existing glyphs or changing advances" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var atlas = Atlas.init(std.testing.allocator, threaded.io()) catch |err| {
        if (err == error.NoUiFont) return error.SkipZigTest;
        return err;
    };
    defer atlas.deinit();
    const original_size = atlas.size();
    const a = atlas.glyph('A').?;
    const width = atlas.measure("Atlas", 24);
    const pixels = try std.testing.allocator.alloc(u8, @as(usize, a.region.w) * a.region.h);
    defer std.testing.allocator.free(pixels);
    for (0..a.region.h) |row| {
        const offset = (a.region.y + row) * atlas.size() + a.region.x;
        @memcpy(pixels[row * a.region.w ..][0..a.region.w], atlas.pixels()[offset..][0..a.region.w]);
    }
    atlas.packer.dirty = false;
    atlas.prepare("é Ω Ж ★ ✓");
    try std.testing.expect(atlas.glyphs.contains('Ж'));
    try std.testing.expect(atlas.glyphs.get('★').? != null);
    for (0x100..0x600) |cp| try atlas.ensure(@intCast(cp));
    try std.testing.expect(atlas.size() > original_size);
    try std.testing.expect(atlas.packer.dirty);
    try std.testing.expectEqual(a, atlas.glyph('A').?);
    try std.testing.expectEqual(width, atlas.measure("Atlas", 24));
    for (0..a.region.h) |row| {
        const offset = (a.region.y + row) * atlas.size() + a.region.x;
        try std.testing.expectEqualSlices(u8, pixels[row * a.region.w ..][0..a.region.w], atlas.pixels()[offset..][0..a.region.w]);
    }
    try atlas.ensure(0x10ffff);
    const count = atlas.glyphs.count();
    try atlas.ensure(0x10ffff);
    try std.testing.expectEqual(count, atlas.glyphs.count());
}
