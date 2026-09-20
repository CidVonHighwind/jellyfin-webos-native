//! Small TV-facing subset of loom.
//!
//! This keeps a useful boundary: layout emits
//! backend-neutral draw commands and the renderer knows nothing about widgets.
//! The TV does not need custom 3D commands, clipboard, drag and drop,
//! right-click state, or retained desktop-window machinery. An image is a
//! texture plus a UV rectangle, so art from one shared atlas stays in the same
//! instanced batch and art loaded at runtime costs only a binding change.

const std = @import("std");

pub const Color = [4]u8;

pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn inset(self: Rect, n: f32) Rect {
        return .{ .x = self.x + n, .y = self.y + n, .w = @max(0, self.w - n * 2), .h = @max(0, self.h - n * 2) };
    }
};

pub const Rectangle = struct {
    color: Color,
    radius: f32 = 0,
};

pub const Border = struct {
    color: Color,
    width: f32 = 1,
    radius: f32 = 0,
};

pub const Text = struct {
    contents: []const u8,
    color: Color,
    size: f32,
};

pub const Image = struct {
    uv: [4]f32,
    tint: Color = .{ 255, 255, 255, 255 },
    radius: f32 = 0,
    /// Which texture to sample. 0 means the renderer's default media texture;
    /// anything else is a texture the application made, and each distinct one
    /// costs a draw call, because this GPU has no bindless textures.
    texture: u32 = 0,
};

pub const Command = struct {
    rect: Rect,
    clip: Rect,
    data: union(enum) {
        rectangle: Rectangle,
        border: Border,
        text: Text,
        image: Image,
    },
};

/// One frame's command arena. Strings must remain alive through rendering;
/// view literals and the demo's persistent status buffer satisfy that rule.
pub const Context = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(Command) = .empty,
    viewport: Rect = .{},

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Context) void {
        self.commands.deinit(self.allocator);
    }

    pub fn begin(self: *Context, width: f32, height: f32) void {
        self.commands.clearRetainingCapacity();
        self.viewport = .{ .w = width, .h = height };
    }

    pub fn fill(self: *Context, rect: Rect, clip: ?Rect, color: Color, radius: f32) void {
        self.append(rect, clip, .{ .rectangle = .{ .color = color, .radius = radius } });
    }

    pub fn stroke(self: *Context, rect: Rect, clip: ?Rect, color: Color, width: f32, radius: f32) void {
        self.append(rect, clip, .{ .border = .{ .color = color, .width = width, .radius = radius } });
    }

    pub fn label(self: *Context, rect: Rect, clip: ?Rect, contents: []const u8, color: Color, size: f32) void {
        self.append(rect, clip, .{ .text = .{ .contents = contents, .color = color, .size = size } });
    }

    pub fn image(self: *Context, rect: Rect, clip: ?Rect, uv: [4]f32, tint: Color, radius: f32) void {
        self.append(rect, clip, .{ .image = .{ .uv = uv, .tint = tint, .radius = radius } });
    }

    /// Same, from a texture the application owns rather than the default one.
    pub fn textured(self: *Context, rect: Rect, clip: ?Rect, texture: u32, uv: [4]f32, tint: Color, radius: f32) void {
        self.append(rect, clip, .{ .image = .{ .uv = uv, .tint = tint, .radius = radius, .texture = texture } });
    }

    fn append(self: *Context, rect: Rect, clip: ?Rect, data: @FieldType(Command, "data")) void {
        const effective = self.viewport.intersect(clip orelse self.viewport);
        if (effective.w <= 0 or effective.h <= 0 or rect.w <= 0 or rect.h <= 0) return;
        self.commands.append(self.allocator, .{ .rect = rect, .clip = effective, .data = data }) catch {};
    }
};

/// Cursor layout is the retained loom flex machinery reduced to what a TV
/// screen uses most: ordered rows/columns with padding and a gap.
pub const Axis = enum { horizontal, vertical };

pub const Stack = struct {
    rect: Rect,
    axis: Axis,
    gap: f32,
    cursor: f32,

    pub fn init(rect: Rect, axis: Axis, padding: f32, gap: f32) Stack {
        const inner = rect.inset(padding);
        return .{ .rect = inner, .axis = axis, .gap = gap, .cursor = if (axis == .horizontal) inner.x else inner.y };
    }

    pub fn take(self: *Stack, extent: f32) Rect {
        const out: Rect = switch (self.axis) {
            .horizontal => .{ .x = self.cursor, .y = self.rect.y, .w = extent, .h = self.rect.h },
            .vertical => .{ .x = self.rect.x, .y = self.cursor, .w = self.rect.w, .h = extent },
        };
        self.cursor += extent + self.gap;
        return out;
    }
};

/// Geometry-only virtual list. Only `[first,last)` is declared and rendered;
/// item coordinates remain stable in the full logical list.
pub const VirtualList = struct {
    viewport: Rect,
    count: usize,
    item_height: f32,
    scroll: f32,
    first: usize,
    last: usize,

    pub fn init(viewport: Rect, count: usize, item_height: f32, requested_scroll: f32) VirtualList {
        const content = @as(f32, @floatFromInt(count)) * item_height;
        const max_scroll = @max(0, content - viewport.h);
        const scroll = std.math.clamp(requested_scroll, 0, max_scroll);
        const first: usize = @min(count, @as(usize, @intFromFloat(@floor(scroll / item_height))));
        const visible: usize = @intFromFloat(@ceil(viewport.h / item_height));
        return .{
            .viewport = viewport,
            .count = count,
            .item_height = item_height,
            .scroll = scroll,
            .first = first,
            .last = @min(count, first + visible + 1),
        };
    }

    pub fn itemRect(self: VirtualList, index: usize) Rect {
        return .{
            .x = self.viewport.x,
            .y = self.viewport.y + @as(f32, @floatFromInt(index)) * self.item_height - self.scroll,
            .w = self.viewport.w,
            .h = self.item_height,
        };
    }

    pub fn maxScroll(self: VirtualList) f32 {
        return @max(0, @as(f32, @floatFromInt(self.count)) * self.item_height - self.viewport.h);
    }

    pub fn scrollToReveal(self: VirtualList, index: usize) f32 {
        const top = @as(f32, @floatFromInt(index)) * self.item_height;
        const bottom = top + self.item_height;
        if (top < self.scroll) return top;
        if (bottom > self.scroll + self.viewport.h) return bottom - self.viewport.h;
        return self.scroll;
    }
};

test "virtual list builds only visible rows" {
    const list = VirtualList.init(.{ .w = 400, .h = 200 }, 10_000, 40, 1234);
    try std.testing.expect(list.first > 0);
    try std.testing.expect(list.last - list.first <= 6);
    try std.testing.expect(list.itemRect(list.first).y <= 0);
}
