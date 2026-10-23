const std = @import("std");
const Vec3 = @import("Vec3.zig");
const Aabb = @This();

min: Vec3,
max: Vec3,

pub const Error = Vec3.Error || error{ InvalidBounds, InvalidEpsilon };
pub const Axis = enum { x, y, z };
pub const Face = enum(u8) { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 };
pub const Hit = struct { face: Face, position: Vec3, fraction: f64 };
pub const default_epsilon: f64 = 0.00001;

pub fn init(min: Vec3, max: Vec3) Error!Aabb {
    const box: Aabb = .{ .min = min, .max = max };
    try box.validate();
    return box;
}

pub fn validate(self: Aabb) Error!void {
    try self.min.validate();
    try self.max.validate();
    if (self.min.x > self.max.x or self.min.y > self.max.y or self.min.z > self.max.z) return error.InvalidBounds;
}

/// Interior containment excludes all six faces, matching the selected oracle.
pub fn contains(self: Aabb, point: Vec3) Error!bool {
    try self.validate();
    try point.validate();
    const low = self.min.array();
    const high = self.max.array();
    for (point.array(), 0..) |value, axis| if (value <= low[axis] or value >= high[axis]) return false;
    return true;
}

pub fn intersects(self: Aabb, other: Aabb, epsilon: f64) Error!bool {
    try self.validate();
    try other.validate();
    if (!std.math.isFinite(epsilon) or epsilon < 0) return error.InvalidEpsilon;
    const a_min = self.min.array();
    const a_max = self.max.array();
    const b_min = other.min.array();
    const b_max = other.max.array();
    for (0..3) |axis| {
        if (b_max[axis] - a_min[axis] <= epsilon or a_max[axis] - b_min[axis] <= epsilon) return false;
    }
    return true;
}

/// Treats self as the obstacle and clips a moving box's signed displacement.
pub fn clipOffset(self: Aabb, moving: Aabb, axis: Axis, requested: f64) Error!f64 {
    try self.validate();
    try moving.validate();
    if (!std.math.isFinite(requested)) return error.NonFinite;
    const selected: usize = @backingInt(axis);
    const low = self.min.array();
    const high = self.max.array();
    const moving_low = moving.min.array();
    const moving_high = moving.max.array();
    for (0..3) |other| {
        if (other != selected and (moving_high[other] <= low[other] or moving_low[other] >= high[other])) return requested;
    }
    if (requested > 0 and moving_high[selected] <= low[selected]) return @min(requested, low[selected] - moving_high[selected]);
    if (requested < 0 and moving_low[selected] >= high[selected]) return @max(requested, high[selected] - moving_low[selected]);
    return requested;
}

/// Intersects the segment with the six box faces. Ties prefer west, east,
/// down, up, north, south. Near-parallel axes use the oracle's squared threshold.
pub fn castSegment(self: Aabb, start: Vec3, end: Vec3) Error!?Hit {
    try self.validate();
    try start.validate();
    try end.validate();
    const delta = end.sub(start);
    delta.validate() catch return error.ArithmeticOverflow;
    const origin = start.array();
    const direction = delta.array();
    const low = self.min.array();
    const high = self.max.array();
    var nearest: f64 = @floatFromInt(std.math.maxInt(i64));
    var hit: ?Hit = null;
    const faces = [_]Face{ .west, .east, .down, .up, .north, .south };
    for (faces, 0..) |face, index| {
        const axis = index / 2;
        if (direction[axis] * direction[axis] < 0.0000001) continue;
        const plane = if (index % 2 == 0) low[axis] else high[axis];
        const fraction = (plane - origin[axis]) / direction[axis];
        if (!std.math.isFinite(fraction)) return error.ArithmeticOverflow;
        if (fraction < 0 or fraction > 1) continue;
        var point = start.add(delta.scale(fraction)).array();
        point[axis] = plane;
        var inside = true;
        for (0..3) |other| {
            if (!std.math.isFinite(point[other])) return error.ArithmeticOverflow;
            if (other != axis and (point[other] < low[other] or point[other] > high[other])) inside = false;
        }
        if (!inside) continue;
        const position = Vec3.fromArray(point);
        const distance = start.distanceSquared(position);
        if (!std.math.isFinite(distance)) return error.ArithmeticOverflow;
        if (distance < nearest) {
            nearest = distance;
            hit = .{ .face = face, .position = position, .fraction = fraction };
        }
    }
    return hit;
}
