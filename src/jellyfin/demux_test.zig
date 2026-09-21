const std = @import("std");

extern fn jf_demux_open(url: [*:0]const u8) ?*anyopaque;
extern fn jf_demux_close(demux: *anyopaque) void;
extern fn jf_demux_audio_open(demux: *anyopaque, index: c_int, rate: *c_int) c_int;
extern fn jf_demux_next(demux: *anyopaque, data: *?[*]u8, size: *c_int, stream: *c_int, pts: *i64) c_int;
extern fn jf_demux_audio_decode(demux: *anyopaque, out: *?[*]u8, size: *c_int, pts: *i64) c_int;
extern fn jf_demux_reopen(demux: *anyopaque, url: [*:0]const u8) c_int;

test "decoded Opus timestamps account for pre-skip, including after reopen" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "audio.mka", .data = @embedFile("testdata/opus-preskip.mka") });
    const path = try temp.dir.realPathFileAlloc(io, "audio.mka", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    const demux = jf_demux_open(path_z.ptr) orelse return error.DemuxOpenFailed;
    defer jf_demux_close(demux);
    for (0..2) |pass| {
        if (pass != 0) try std.testing.expect(jf_demux_reopen(demux, path_z.ptr) != 0);
        var rate: c_int = 0;
        try std.testing.expect(jf_demux_audio_open(demux, 0, &rate) != 0);
        try std.testing.expectEqual(@as(c_int, 48000), rate);
        for (0..2) |packet_index| {
            var packet: ?[*]u8 = null;
            var size: c_int = 0;
            var stream: c_int = -1;
            var pts: i64 = 0;
            try std.testing.expect(jf_demux_next(demux, &packet, &size, &stream, &pts) != 0);
            try std.testing.expectEqual(@as(i64, if (packet_index == 0) -7_000_000 else 14_000_000), pts);
            var pcm: ?[*]u8 = null;
            var pcm_size: c_int = 0;
            try std.testing.expect(jf_demux_audio_decode(demux, &pcm, &pcm_size, &pts) != 0);
            // Opus removes 312 samples from the first 960-sample packet.
            // The first audible sample belongs at zero, not at packet PTS -7ms.
            try std.testing.expectEqual(@as(c_int, if (packet_index == 0) 648 * 4 else 960 * 4), pcm_size);
            try std.testing.expectEqual(@as(i64, if (packet_index == 0) 0 else 14_000_000), pts);
        }
    }
}
