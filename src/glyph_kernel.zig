//! Hardware-FP glyph rasterisation kernel.
//!
//! The ARM build compiles this file as `gnueabihf`, but its exported boundary
//! contains only pointers and integers. That boundary is identical to base
//! AAPCS (`gnueabi`/softfp), while all floating-point work behind it uses VFP.
//! Never add a float argument or float return value to these exports.
//! (Floats *inside* the result struct are fine -- it is memory, not registers.)
//!
//! Rasterises 8-bit coverage, one byte per pixel, which is what the atlas
//! stores and what the shader samples. This replaced an MSDF generator: MSDF
//! buys resolution independence, and this UI draws glyphs at a handful of fixed
//! sizes, so it was paying three channels and a median-of-three shader for
//! nothing.

const std = @import("std");
const TrueType = @import("TrueType");

pub const Result = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    pixel_len: u32 = 0,
    /// All three in pixels at the raster size the context was created with.
    advance: f32 = 0,
    /// Pen position to the left edge of the bitmap.
    off_x: f32 = 0,
    /// Baseline to the top edge of the bitmap; negative is above the baseline.
    off_y: f32 = 0,
};

const Context = struct {
    font: TrueType,
    scale: f32,
    pixels: std.ArrayListUnmanaged(u8) = .empty,
};

/// `px_size` is the em size to rasterise at, as an integer so the ABI rule holds.
export fn uiFontCreate(font: [*]const u8, font_len: usize, px_size: u32) callconv(.c) ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const loaded = TrueType.load(font[0..font_len]) catch return null;
    const context = allocator.create(Context) catch return null;
    const units: f32 = @floatFromInt(loaded.unitsPerEM());
    context.* = .{
        .font = loaded,
        .scale = @as(f32, @floatFromInt(px_size)) / units,
    };
    return context;
}

export fn uiFontDestroy(raw: ?*anyopaque) callconv(.c) void {
    const context: *Context = @ptrCast(@alignCast(raw orelse return));
    context.pixels.deinit(std.heap.c_allocator);
    std.heap.c_allocator.destroy(context);
}

/// Returns 0 on success, 1 when the font has no glyph, 2 when `pixels` is too
/// small, and 3 on allocation/rasterisation failure.
export fn uiFontGlyph(
    raw: ?*anyopaque,
    codepoint: u32,
    result: *Result,
    pixels: [*]u8,
    pixel_capacity: usize,
) callconv(.c) u32 {
    const context: *Context = @ptrCast(@alignCast(raw orelse return 3));
    const allocator = std.heap.c_allocator;
    const index = context.font.codepointGlyphIndex(@intCast(codepoint));
    if (index == .notdef) return 1;

    const metrics = context.font.glyphHMetrics(index);
    const advance = @as(f32, @floatFromInt(metrics.advance_width)) * context.scale;

    context.pixels.clearRetainingCapacity();
    const bitmap = context.font.glyphBitmap(
        allocator,
        &context.pixels,
        index,
        context.scale,
        context.scale,
    ) catch return 3;

    // Space and friends: real advance, no pixels.
    if (bitmap.width == 0 or bitmap.height == 0) {
        result.* = .{ .advance = advance };
        return 0;
    }
    if (context.pixels.items.len > pixel_capacity) return 2;
    @memcpy(pixels[0..context.pixels.items.len], context.pixels.items);
    result.* = .{
        .width = bitmap.width,
        .height = bitmap.height,
        .pixel_len = @intCast(context.pixels.items.len),
        .advance = advance,
        .off_x = @floatFromInt(bitmap.off_x),
        .off_y = @floatFromInt(bitmap.off_y),
    };
    return 0;
}
