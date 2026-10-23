const std = @import("std");

pub const chunk_width = 16;

pub const Axis = struct {
    chunk: i32,
    local: u4,
};

pub const BlockPos = struct { x: i32, y: i32, z: i32 };
pub const SubchunkPos = struct { x: i32, y: i32, z: i32 };
pub const LocalPos = struct { x: u4, y: u4, z: u4 };
pub const SubchunkLocation = struct { subchunk: SubchunkPos, local: LocalPos };

pub fn floorToBlock(value: f64) error{ NonFinite, CoordinateOverflow }!i32 {
    if (!std.math.isFinite(value)) return error.NonFinite;
    const floored = @floor(value);
    if (floored < std.math.minInt(i32) or floored > std.math.maxInt(i32)) return error.CoordinateOverflow;
    return @intFromFloat(floored);
}

pub fn splitPosition(block: BlockPos) SubchunkLocation {
    const x = split(block.x);
    const y = split(block.y);
    const z = split(block.z);
    return .{ .subchunk = .{ .x = x.chunk, .y = y.chunk, .z = z.chunk }, .local = .{ .x = x.local, .y = y.local, .z = z.local } };
}

pub fn joinPosition(location: SubchunkLocation) error{CoordinateOverflow}!BlockPos {
    return .{
        .x = try join(.{ .chunk = location.subchunk.x, .local = location.local.x }),
        .y = try join(.{ .chunk = location.subchunk.y, .local = location.local.y }),
        .z = try join(.{ .chunk = location.subchunk.z, .local = location.local.z }),
    };
}

/// Floor division keeps local coordinates in 0..15 on both sides of zero.
pub fn split(block: i32) Axis {
    return .{
        .chunk = @divFloor(block, chunk_width),
        .local = @intCast(@mod(block, chunk_width)),
    };
}

pub fn join(axis: Axis) error{CoordinateOverflow}!i32 {
    const value = @as(i64, axis.chunk) * chunk_width + axis.local;
    return std.math.cast(i32, value) orelse error.CoordinateOverflow;
}

test "independent signed coordinate boundary vectors" {
    const vectors = [_]struct { block: i32, chunk: i32, local: u4 }{
        .{ .block = -17, .chunk = -2, .local = 15 },
        .{ .block = -16, .chunk = -1, .local = 0 },
        .{ .block = -1, .chunk = -1, .local = 15 },
        .{ .block = 0, .chunk = 0, .local = 0 },
        .{ .block = 15, .chunk = 0, .local = 15 },
        .{ .block = 16, .chunk = 1, .local = 0 },
        .{ .block = std.math.minInt(i32), .chunk = -134217728, .local = 0 },
        .{ .block = std.math.maxInt(i32), .chunk = 134217727, .local = 15 },
    };
    for (vectors) |vector| {
        const axis = split(vector.block);
        try std.testing.expectEqual(vector.chunk, axis.chunk);
        try std.testing.expectEqual(vector.local, axis.local);
        try std.testing.expectEqual(vector.block, try join(axis));
    }
    try std.testing.expectError(error.CoordinateOverflow, join(.{ .chunk = 134217728, .local = 0 }));
    try std.testing.expectError(error.CoordinateOverflow, join(.{ .chunk = -134217729, .local = 15 }));
}
