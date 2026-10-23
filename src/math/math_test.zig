const std = @import("std");
const Vec3 = @import("Vec3.zig");
const Aabb = @import("Aabb.zig");
const VoxelRay = @import("VoxelRay.zig");
const coordinates = @import("coordinates.zig");
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Corpus = struct {
    vectors: []const struct {
        a: [3]f64,
        b: [3]f64,
        add: [3]f64,
        sub: [3]f64,
        scale: [3]f64,
        dot: f64,
        cross: [3]f64,
        normal: [3]f64,
        length_squared: f64,
        distance_squared: f64,
        floor: [3]f64,
    },
    boxes: []const struct {
        a: [6]f64,
        b: [6]f64,
        point: [3]f64,
        epsilon: f64,
        contains: bool,
        intersects: bool,
        positive_offsets: [3]f64,
        negative_offsets: [3]f64,
    },
    rays: []const struct { box: [6]f64, start: [3]f64, end: [3]f64, hit: ?struct { face: u8, point: [3]f64 } },
    voxels: []const struct { start: [3]f64, end: [3]f64, cells: []const [3]f64 },
};

fn load() !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, std.testing.allocator, @embedFile("fixtures/conformance.json"), .{});
}

fn close(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 1e-12 * @max(1, @abs(expected)));
}

fn closeVector(expected: [3]f64, actual: Vec3) !void {
    for (expected, actual.array()) |a, b| try close(a, b);
}

fn box(values: [6]f64) !Aabb {
    return Aabb.init(.{ .x = values[0], .y = values[1], .z = values[2] }, .{ .x = values[3], .y = values[4], .z = values[5] });
}

test "vector arithmetic normalization and floor match current Math oracle" {
    const corpus = try load();
    defer corpus.deinit();
    for (corpus.value.vectors) |case| {
        const a = Vec3.fromArray(case.a);
        const b = Vec3.fromArray(case.b);
        try closeVector(case.add, a.add(b));
        try closeVector(case.sub, a.sub(b));
        try closeVector(case.scale, a.scale(0.5));
        try close(case.dot, a.dot(b));
        try closeVector(case.cross, a.cross(b));
        try closeVector(case.normal, try a.normalized());
        try close(case.length_squared, a.lengthSquared());
        try close(case.distance_squared, a.distanceSquared(b));
        const block = try a.floorBlock();
        try equal(@as(i32, @intFromFloat(case.floor[0])), block.x);
        try equal(@as(i32, @intFromFloat(case.floor[1])), block.y);
        try equal(@as(i32, @intFromFloat(case.floor[2])), block.z);
    }
}

test "AABB containment intersection and collision offsets match Math oracle" {
    const corpus = try load();
    defer corpus.deinit();
    for (corpus.value.boxes) |case| {
        const a = try box(case.a);
        const b = try box(case.b);
        try equal(case.contains, try a.contains(Vec3.fromArray(case.point)));
        try equal(case.intersects, try a.intersects(b, case.epsilon));
        const axes = [_]Aabb.Axis{ .x, .y, .z };
        for (axes, 0..) |axis, index| {
            try close(case.positive_offsets[index], try a.clipOffset(b, axis, 4));
            try close(case.negative_offsets[index], try a.clipOffset(b, axis, -4));
        }
    }
}

test "segment hits faces and misses match Math oracle" {
    const corpus = try load();
    defer corpus.deinit();
    for (corpus.value.rays) |case| {
        const a = try box(case.box);
        const start = Vec3.fromArray(case.start);
        const end = Vec3.fromArray(case.end);
        const result = try a.castSegment(start, end);
        if (case.hit) |expected| {
            const hit = result orelse return error.ExpectedRayHit;
            try equal(expected.face, @backingInt(hit.face));
            try closeVector(expected.point, hit.position);
            try std.testing.expect(hit.fraction >= 0 and hit.fraction <= 1);
            try closeVector(expected.point, start.add(end.sub(start).scale(hit.fraction)));
        } else try equal(@as(?Aabb.Hit, null), result);
    }
}

test "voxel order boundary cells and exact budgets match Math oracle" {
    const corpus = try load();
    defer corpus.deinit();
    for (corpus.value.voxels) |case| {
        var ray = try VoxelRay.init(Vec3.fromArray(case.start), Vec3.fromArray(case.end), case.cells.len);
        for (case.cells) |expected| {
            const cell = (try ray.next()) orelse return error.ExpectedVoxel;
            try equal(@as(i32, @intFromFloat(expected[0])), cell.x);
            try equal(@as(i32, @intFromFloat(expected[1])), cell.y);
            try equal(@as(i32, @intFromFloat(expected[2])), cell.z);
        }
        try equal(@as(?coordinates.BlockPos, null), try ray.next());
        try equal(@as(?coordinates.BlockPos, null), try ray.next());
    }
}

test "independent vector and geometry invariants" {
    const x: Vec3 = .{ .x = 1 };
    const y: Vec3 = .{ .y = 1 };
    try equal(Vec3{ .z = 1 }, x.cross(y));
    try equal(Vec3{ .z = -1 }, y.cross(x));
    try equal(@as(f64, 0), x.dot(y));
    const normal = try (Vec3{ .x = 3, .y = 4 }).normalized();
    try closeVector(.{ 0.6, 0.8, 0 }, normal);
    const a = try box(.{ 0, 0, 0, 1, 1, 1 });
    const touching = try box(.{ 1, 0, 0, 2, 1, 1 });
    try equal(false, try a.intersects(touching, 0));
    try equal(false, try a.contains(.{ .x = 0, .y = 0.5, .z = 0.5 }));
    try equal(true, try a.contains(.{ .x = 0.5, .y = 0.5, .z = 0.5 }));
    const hit = (try a.castSegment(.{ .x = -1, .y = 0.5, .z = 0.5 }, .{ .x = 2, .y = 0.5, .z = 0.5 })).?;
    try equal(Aabb.Face.west, hit.face);
    try close(1.0 / 3.0, hit.fraction);
    var ray = try VoxelRay.init(.{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 1.5, .y = 1.5, .z = 1.5 }, 4);
    for ([_]coordinates.BlockPos{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 1 }, .{ .x = 0, .y = 1, .z = 1 }, .{ .x = 1, .y = 1, .z = 1 } }) |expected|
        try equal(expected, (try ray.next()).?);
    try equal(@as(?coordinates.BlockPos, null), try ray.next());
}

test "floating block conversion signed subchunks and overflow" {
    const cases = [_]struct { value: f64, expected: i32 }{
        .{ .value = -16.01, .expected = -17 },                       .{ .value = -0.01, .expected = -1 },
        .{ .value = -0.0, .expected = 0 },                           .{ .value = 15.99, .expected = 15 },
        .{ .value = -2147483648, .expected = std.math.minInt(i32) }, .{ .value = 2147483647.5, .expected = std.math.maxInt(i32) },
    };
    for (cases) |case| try equal(case.expected, try coordinates.floorToBlock(case.value));
    for ([_]f64{ -2147483648.5, 2147483648 }) |value| try expectError(error.CoordinateOverflow, coordinates.floorToBlock(value));
    const location = coordinates.splitPosition(.{ .x = -17, .y = -1, .z = 16 });
    try equal(coordinates.SubchunkPos{ .x = -2, .y = -1, .z = 1 }, location.subchunk);
    try equal(coordinates.LocalPos{ .x = 15, .y = 15, .z = 0 }, location.local);
    try equal(coordinates.BlockPos{ .x = -17, .y = -1, .z = 16 }, try coordinates.joinPosition(location));
    try expectError(error.CoordinateOverflow, coordinates.joinPosition(.{ .subchunk = .{ .x = 134217728, .y = 0, .z = 0 }, .local = .{ .x = 0, .y = 0, .z = 0 } }));
}

test "nonfinite geometry invalid bounds and arithmetic overflow fail explicitly" {
    const a = try box(.{ 0, 0, 0, 1, 1, 1 });
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
        const invalid: Vec3 = .{ .x = value };
        try expectError(error.NonFinite, invalid.normalized());
        try expectError(error.NonFinite, invalid.floorBlock());
        try expectError(error.NonFinite, a.contains(invalid));
        try expectError(error.NonFinite, a.castSegment(invalid, .{}));
        try expectError(error.NonFinite, VoxelRay.init(invalid, .{}, 10));
        try expectError(error.InvalidEpsilon, a.intersects(a, value));
    }
    try expectError(error.InvalidBounds, Aabb.init(.{ .x = 2 }, .{ .x = 1 }));
    try expectError(error.InvalidEpsilon, a.intersects(a, -1));
    const huge: Vec3 = .{ .x = std.math.floatMax(f64) };
    try expectError(error.ArithmeticOverflow, huge.normalized());
    try expectError(error.ArithmeticOverflow, a.castSegment(huge, huge.scale(-1)));
}

test "voxel limits zero directions and coordinate overflow are sticky" {
    const start: Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 };
    try expectError(error.ZeroLengthRay, VoxelRay.init(start, start, 1));
    try expectError(error.ZeroLengthRay, VoxelRay.init(.{}, .{ .x = 1e-200 }, 1));
    try expectError(error.InvalidStepLimit, VoxelRay.init(.{}, start, 0));
    try expectError(error.InvalidStepLimit, VoxelRay.init(.{}, start, VoxelRay.maximum_steps + 1));
    var limited = try VoxelRay.init(start, .{ .x = 10.5, .y = 0.5, .z = 0.5 }, 1);
    _ = try limited.next();
    try expectError(error.StepLimit, limited.next());
    try expectError(error.StepLimit, limited.next());
    var overflow = try VoxelRay.init(.{ .x = -2147483647.5 }, .{ .x = -2147483648 }, 3);
    try equal(std.math.minInt(i32), (try overflow.next()).?.x);
    try expectError(error.CoordinateOverflow, overflow.next());
    try expectError(error.CoordinateOverflow, overflow.next());
}
