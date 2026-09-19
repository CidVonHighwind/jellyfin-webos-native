//! An 8x16 bitmap font and a blitter, shared by the shm apps (which write u32
//! pixels) and the GL apps (which rasterise into an R8 coverage texture).
//!
//! assets/font8x16.bin is the ASCII range of Terminus (OFL-1.1), extracted
//! from Lat2-Terminus16.psfu as 95 glyphs of 16 bytes, one bit per pixel,
//! MSB leftmost.
const font = @embedFile("font");

pub const GLYPH_W = 8;
pub const GLYPH_H = 16;

pub fn glyph(ch: u8) ?*const [GLYPH_H]u8 {
    if (ch < 0x20 or ch >= 0x7f) return null;
    return font[(@as(usize, ch) - 0x20) * GLYPH_H ..][0..GLYPH_H];
}

/// Blit `s` at pixel (x, y) into a `w` x `h` buffer of `P`, `scale`x magnified.
/// Anything off the right or bottom edge is clipped.
pub fn draw(
    comptime P: type,
    dst: []P,
    w: usize,
    h: usize,
    x: usize,
    y: usize,
    scale: usize,
    colour: P,
    s: []const u8,
) void {
    var cx = x;
    for (s) |ch| {
        defer cx += GLYPH_W * scale;
        if (cx + GLYPH_W * scale > w) return;
        const g = glyph(ch) orelse continue;
        for (g, 0..) |bits, gy| {
            if (bits == 0) continue;
            for (0..GLYPH_W) |gx| {
                if (bits >> @intCast(7 - gx) & 1 == 0) continue;
                for (0..scale) |sy| {
                    const py = y + gy * scale + sy;
                    if (py >= h) continue;
                    for (0..scale) |sx| dst[py * w + cx + gx * scale + sx] = colour;
                }
            }
        }
    }
}

/// Width in pixels of `s` at `scale`.
pub fn widthOf(s: []const u8, scale: usize) usize {
    return s.len * GLYPH_W * scale;
}
