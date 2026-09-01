const std = @import("std");

pub const Chunk = struct {
    delay_ms: u32,
    len: u32,
};

pub const max_chunks = 1024;
pub const max_delay_ms = 60_000;

pub fn totalLen(chunks: []const Chunk) usize {
    var n: usize = 0;
    for (chunks) |c| n += c.len;
    return n;
}

const testing = std.testing;

test "total length sums the recorded chunks" {
    const chunks = [_]Chunk{
        .{ .delay_ms = 0, .len = 10 },
        .{ .delay_ms = 5, .len = 20 },
    };
    try testing.expectEqual(@as(usize, 30), totalLen(&chunks));
    try testing.expectEqual(@as(usize, 0), totalLen(&.{}));
}
