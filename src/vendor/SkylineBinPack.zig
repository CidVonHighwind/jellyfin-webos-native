//! Adaptation of the skyline binary packing algorithm from
//! http://clb.demon.fi/projects/even-more-rectangle-bin-packing
const std = @import("std");

const Self = @This();

nodes: std.ArrayList(FreeNode),
size: u16,
depth: u3,
used: usize = 0,
data: []u8,
dirty: bool,

gpa: std.mem.Allocator,

const FreeNode = struct { x: u16, y: u16, w: u16 };
pub const Region = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};
const Size = struct { w: u16, h: u16 };

/// initialize an empty atlas of the given dimension and depth.
pub fn init(
    size: u16,
    depth: u3,
    gpa: std.mem.Allocator,
) !Self {
    if (depth == 0) {
        return error.InvalidDepth;
    }

    var nodes = try std.ArrayList(FreeNode).initCapacity(gpa, 512);
    nodes.appendAssumeCapacity(.{ .x = 1, .y = 1, .w = size - 2 });

    const bytes: usize = @as(usize, size) * @as(usize, size) * @as(usize, depth);
    // zeroed like the reference's calloc: stale bytes between glyphs bleed
    // into neighbors under linear filtering
    const data = try gpa.alloc(u8, bytes);
    @memset(data, 0);

    return .{
        .nodes = nodes,
        .size = size,
        .depth = depth,
        .used = 0,
        .data = data,
        .dirty = true,
        .gpa = gpa,
    };
}

pub fn deinit(self: *Self) void {
    self.nodes.deinit(self.gpa);
    self.gpa.free(self.data);
}

/// blit a texture into the given region of the atlas.
pub fn blit(
    self: *Self,
    region: Region,
    data: []const u8,
    stride: usize,
) !void {
    if (region.w == 0 or region.h == 0) {
        return error.InvalidDimensions;
    }
    if (region.x >= self.size - 1 or
        (region.w - 1) > (self.size - 1) or
        region.y > self.size - 1 or
        (region.h - 1) > (self.size - 1))
    {
        return error.OutOfBounds;
    }

    const charsize = @sizeOf(u8);
    for (0..region.h) |i| {
        const length = @as(usize, region.w) * charsize * self.depth;
        const dst_offset: usize = (@as(usize, region.y + i) * self.size + region.x) * charsize * self.depth;
        const dst = self.data[dst_offset..][0..length];
        const src_offset: usize = i * stride * charsize;
        const src = data[src_offset..][0..length];
        @memcpy(dst, src);
    }
    self.dirty = true;
}

// attempts to fit a rect at a given free-node index or later.
fn fit(self: *Self, index: usize, size: Size) !usize {
    var node: FreeNode = self.nodes.items[index];
    const x = node.x;
    var y = node.y;
    var width_left: i32 = @intCast(size.w);
    var i = index;

    if ((x + size.w) > (self.size - 1)) {
        return error.InvalidIndex;
    }

    while (width_left > 0) {
        if (i >= self.nodes.items.len) return error.OutOfSpace;
        node = self.nodes.items[i];
        if (node.y > y) {
            y = node.y;
        }
        if ((y + size.h) > (self.size - 1)) {
            return error.OutOfSpace;
        }
        width_left -= node.w;
        i += 1;
    }
    return y;
}

/// merge adjacent free-nodes if they have the same height.
fn merge(self: *Self) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        var node = &self.nodes.items[i];
        const next = &self.nodes.items[i + 1];
        i += 1;
        if (node.y == next.y) {
            node.w += next.w;
            _ = self.nodes.orderedRemove(i);
            i -= 1;
        }
    }
}

/// Total area claimed beneath the skyline, including the holes that
/// packing left behind. consumedArea() - used is the wasted area.
pub fn consumedArea(self: *const Self) usize {
    var area: usize = 0;
    for (self.nodes.items) |node|
        area += @as(usize, node.w) * (node.y - 1);
    return area;
}

pub fn wastedArea(self: *const Self) usize {
    const consumed = self.consumedArea();
    if (consumed > 0)
        return (consumed - self.used) * 100 / consumed
    else
        return 0;
}

/// allocate a rect in the current atlas. Fails if no space is available.
/// Min-height scoring, like the 2010 RectangleBinPack SkylineBinPack.
pub fn alloc(self: *Self, size: Size) !Region {
    var region: Region = .{ .x = 0, .y = 0, .w = size.w, .h = size.h };
    var best_width: usize = std.math.maxInt(u32);
    var best_height: usize = std.math.maxInt(u32);
    var best_index: ?usize = null;

    const padded_size: Size = .{ .w = size.w + 1, .h = size.h + 1 };

    // find the node that fits the requested size best
    for (0..self.nodes.items.len) |i| {
        const y = self.fit(i, padded_size) catch continue;
        const node = self.nodes.items[i];
        if (((y + padded_size.h) < best_height) or
            (((y + padded_size.h) == best_height) and (node.w > 0 and node.w < best_width)))
        {
            best_height = y + padded_size.h;
            best_index = @intCast(i);
            best_width = node.w;
            region.x = node.x;
            region.y = @intCast(y);
        }
    }

    if (best_index == null) {
        return error.NoSpace;
    }
    const index: usize = best_index.?;
    const padded: Size = .{ .w = region.w + 1, .h = region.h + 1 };

    // split free-node in two
    try self.nodes.insert(self.gpa, index, .{ .x = region.x, .y = region.y + padded.h, .w = padded.w });

    const i: usize = index + 1;
    while (i < self.nodes.items.len) {
        var node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x >= (prev.x + prev.w)) break;
        const shrink: i32 = @as(i32, prev.x) + @as(i32, prev.w) - @as(i32, node.x);
        node.x = @intCast(@as(i32, node.x) + shrink);
        const remaining_width = @as(i32, node.w) - shrink;
        if (remaining_width > 0) {
            node.w = @intCast(remaining_width);
            break;
        }
        _ = self.nodes.orderedRemove(i);
    }

    self.merge();
    self.used += @as(usize, padded.w) * @as(usize, padded.h);

    return region;
}

/// allocate a rect. Attempts to 4x the atlas if no space is available.
pub fn allocResizing(self: *Self, size: Size) !Region {
    const region = self.alloc(size) catch {
        try self.enlargeTexture(self.size * 2);
        return try self.alloc(size);
    };
    return region;
}

pub fn enlargeTexture(self: *Self, size: u16) !void {
    if (@popCount(size) != 1) return error.NonPowerOfTwo;
    if (size == self.size) return;
    if (size < self.size) return error.CantShrink;
    const old_size = self.size;
    const old_data = self.data;
    const new_texture_size = @as(usize, size) * @as(usize, size) * @as(usize, self.depth);
    self.data = try self.gpa.alloc(u8, new_texture_size);
    @memset(self.data, 0);
    self.size = size;
    errdefer {
        self.gpa.free(self.data);
        self.data = old_data;
        self.size = old_size;
    }
    try self.nodes.append(self.gpa, .{ .x = old_size - 1, .y = 1, .w = size - old_size });
    const pixel_size = @sizeOf(u8) * self.depth;
    const old_row_size = @as(usize, old_size) * pixel_size;
    try self.blit(.{ .x = 1, .y = 1, .w = old_size - 2, .h = old_size - 2 }, old_data[(old_row_size + pixel_size)..], old_row_size);
    self.gpa.free(old_data);
}

test {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var atlas = try Self.init(512, 4, gpa);
    {
        try std.testing.expectEqual(
            Region{ .x = 1, .y = 1, .w = 100, .h = 100 },
            try atlas.alloc(.{ .w = 100, .h = 100 }),
        );
        try std.testing.expectEqual(atlas.nodes.items.len, 2);
    }
    {
        // implicit 1px spacing
        try std.testing.expectEqual(
            Region{ .x = 102, .y = 1, .w = 100, .h = 100 },
            try atlas.alloc(.{ .w = 100, .h = 100 }),
        );
        try std.testing.expectEqual(atlas.nodes.items.len, 2);
    }
    try std.testing.expectError(error.NonPowerOfTwo, atlas.enlargeTexture(123));
    try std.testing.expectError(error.CantShrink, atlas.enlargeTexture(256));
    try atlas.enlargeTexture(1024);
    try std.testing.expectEqual(1024, atlas.size);
}

test "random packing stays in bounds with no overlaps" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var atlas = try Self.init(512, 1, std.testing.allocator);
    defer atlas.deinit();

    var placed: std.ArrayList(Region) = .empty;
    defer placed.deinit(std.testing.allocator);

    while (true) {
        const w = random.intRangeAtMost(u16, 3, 60);
        const h = random.intRangeAtMost(u16, 3, 60);
        const r = atlas.alloc(.{ .w = w, .h = h }) catch break;
        try std.testing.expect(r.x >= 1 and r.y >= 1);
        try std.testing.expect(r.x + r.w <= atlas.size - 1);
        try std.testing.expect(r.y + r.h <= atlas.size - 1);
        for (placed.items) |p| {
            // +1: the implicit spacing must hold between any two regions
            const overlaps = r.x < p.x + p.w + 1 and p.x < r.x + r.w + 1 and
                r.y < p.y + p.h + 1 and p.y < r.y + r.h + 1;
            try std.testing.expect(!overlaps);
        }
        try placed.append(std.testing.allocator, r);
    }
    // the atlas should hold a substantial number of regions before filling up
    try std.testing.expect(placed.items.len > 100);
}
