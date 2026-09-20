//! Blocking packet handoff between the demuxer and the audio/video feeders.
const std = @import("std");

pub const Chunk = struct { bytes: []u8, pts: i64 };

pub const Queue = struct {
    const capacity_bytes = 8 << 20;
    buffer: [512]Chunk = undefined,
    queue: std.Io.Queue(Chunk) = undefined,
    initialized: bool = false,
    mutex: std.Io.Mutex = .init,
    room: std.Io.Condition = .init,
    bytes: usize = 0,
    closed: bool = false,

    /// Only after both producer and consumer have joined.
    pub fn reset(self: *Queue, io: std.Io) void {
        if (self.initialized) {
            self.close(io);
            while (self.queue.getOneUncancelable(io)) |chunk| {
                std.heap.c_allocator.free(chunk.bytes);
            } else |_| {}
        }
        self.queue = .init(&self.buffer);
        self.initialized = true;
        self.bytes = 0;
        self.closed = false;
    }

    /// Takes ownership even if shutdown interrupts a blocked producer.
    pub fn push(self: *Queue, io: std.Io, chunk: Chunk) bool {
        self.mutex.lockUncancelable(io);
        // Permit one oversized packet in an empty queue, but bound read-ahead.
        while (!self.closed and self.bytes != 0 and self.bytes + chunk.bytes.len > capacity_bytes)
            self.room.waitUncancelable(io, &self.mutex);
        if (self.closed) {
            self.mutex.unlock(io);
            std.heap.c_allocator.free(chunk.bytes);
            return false;
        }
        self.bytes += chunk.bytes.len;
        self.mutex.unlock(io);
        self.queue.putOneUncancelable(io, chunk) catch {
            self.releaseBytes(io, chunk.bytes.len);
            std.heap.c_allocator.free(chunk.bytes);
            return false;
        };
        return true;
    }

    pub fn pop(self: *Queue, io: std.Io) ?Chunk {
        const chunk = self.queue.getOneUncancelable(io) catch return null;
        self.releaseBytes(io, chunk.bytes.len);
        return chunk;
    }

    fn releaseBytes(self: *Queue, io: std.Io, len: usize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.bytes -= len;
        self.room.signal(io);
    }

    /// Wakes blocked producers and consumers. Buffered packets can still drain.
    pub fn close(self: *Queue, io: std.Io) void {
        if (!self.initialized) return;
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.room.broadcast(io);
        self.mutex.unlock(io);
        self.queue.close(io);
    }
};

test "closed packet queues drain in order and can start another segment" {
    const io = std.testing.io;
    var queue: Queue = .{};
    queue.reset(io);
    defer queue.reset(io);
    for (0..3) |i| {
        const bytes = try std.heap.c_allocator.dupe(u8, "packet");
        try std.testing.expect(queue.push(io, .{ .bytes = bytes, .pts = @intCast(i) }));
    }
    queue.close(io);
    for (0..3) |i| {
        const chunk = queue.pop(io).?;
        defer std.heap.c_allocator.free(chunk.bytes);
        try std.testing.expectEqual(@as(i64, @intCast(i)), chunk.pts);
    }
    try std.testing.expect(queue.pop(io) == null);
    queue.reset(io);
    try std.testing.expect(queue.push(io, .{ .bytes = try std.heap.c_allocator.dupe(u8, "new"), .pts = 9 }));
}

test "closing an empty packet queue wakes its consumer" {
    const io = std.testing.io;
    var queue: Queue = .{};
    queue.reset(io);
    const Consumer = struct {
        fn run(q: *Queue, thread_io: std.Io) void {
            std.debug.assert(q.pop(thread_io) == null);
        }
    };
    const thread = try std.Thread.spawn(.{}, Consumer.run, .{ &queue, io });
    queue.close(io);
    thread.join();
}

test "closing a byte-limited packet queue releases its producer" {
    const io = std.testing.io;
    var queue: Queue = .{};
    queue.reset(io);
    defer queue.reset(io);
    try std.testing.expect(queue.push(io, .{
        .bytes = try std.heap.c_allocator.alloc(u8, Queue.capacity_bytes),
        .pts = 0,
    }));
    const Producer = struct {
        fn run(q: *Queue, thread_io: std.Io, bytes: []u8) void {
            std.debug.assert(!q.push(thread_io, .{ .bytes = bytes, .pts = 1 }));
        }
    };
    const bytes = try std.heap.c_allocator.dupe(u8, "blocked");
    const thread = try std.Thread.spawn(.{}, Producer.run, .{ &queue, io, bytes });
    queue.close(io);
    thread.join();
}
