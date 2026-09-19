//! Hardware-FP MSDF generation kernel.
//!
//! The ARM build compiles this file as `gnueabihf`, but its exported boundary
//! contains only pointers and integers. That boundary is identical to base
//! AAPCS (`gnueabi`/softfp), while all floating-point work behind it uses VFP.
//! Never add a float argument or float return value to these exports.

const std = @import("std");
const Generator = @import("msdf");

const glyph_px_size = 48;
const glyph_px_range = 8;

const gen_opts: Generator.GenerationOptions = .{
    .sdf_type = .msdf,
    .px_size = glyph_px_size,
    .px_range = glyph_px_range,
    .scanline_fill_rule = .non_zero,
    .error_correction_opts = .{ .check_distance = false },
};

const Context = struct {
    generator: Generator,
};

pub const Result = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    pixel_len: u32 = 0,
    advance: f32 = 0,
    bearing_x: f32 = 0,
    bearing_y: f32 = 0,
};

export fn uiMsdfCreate(font: [*]const u8, font_len: usize) callconv(.c) ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const context = allocator.create(Context) catch return null;
    context.* = .{ .generator = Generator.create(font[0..font_len]) catch {
        allocator.destroy(context);
        return null;
    } };
    return context;
}

export fn uiMsdfDestroy(raw: ?*anyopaque) callconv(.c) void {
    const context: *Context = @ptrCast(@alignCast(raw orelse return));
    context.generator.destroy();
    std.heap.c_allocator.destroy(context);
}

/// Returns 0 on success, 1 when the font has no glyph, 2 when `pixels` is too
/// small, and 3 on allocation/generation failure.
export fn uiMsdfGlyph(
    raw: ?*anyopaque,
    codepoint: u32,
    result: *Result,
    pixels: [*]u8,
    pixel_capacity: usize,
) callconv(.c) u32 {
    const context: *Context = @ptrCast(@alignCast(raw orelse return 3));
    const allocator = std.heap.c_allocator;
    var shape = context.generator.extractShape(allocator, @intCast(codepoint), gen_opts) catch return 1;
    defer shape.deinit(allocator);

    if (shape.shape.contours.items.len == 0) {
        result.* = .{ .advance = @floatCast(shape.advance) };
        return 0;
    }

    const rendered = Generator.renderShape(allocator, &shape, gen_opts) catch return 3;
    defer rendered.deinit(allocator);
    const source = switch (rendered.pixels) {
        .normal => |data| data,
        .msdf10 => return 3,
    };
    if (source.len > pixel_capacity) return 2;
    @memcpy(pixels[0..source.len], source);
    result.* = .{
        .width = rendered.glyph_data.width,
        .height = rendered.glyph_data.height,
        .pixel_len = @intCast(source.len),
        .advance = @floatCast(rendered.glyph_data.advance),
        .bearing_x = @floatCast(rendered.glyph_data.bearing_x),
        .bearing_y = @floatCast(rendered.glyph_data.bearing_y),
    };
    return 0;
}
