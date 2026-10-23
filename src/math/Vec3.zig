const std = @import("std");
const coordinates = @import("coordinates.zig");
const Vec3 = @This();

x: f64 = 0,
y: f64 = 0,
z: f64 = 0,

pub const Error = error{ NonFinite, ArithmeticOverflow };

pub fn validate(self: Vec3) Error!void {
    if (!std.math.isFinite(self.x) or !std.math.isFinite(self.y) or !std.math.isFinite(self.z)) return error.NonFinite;
}

/// Arithmetic uses strict f64 operations. Validate results at external boundaries.
pub fn add(self: Vec3, other: Vec3) Vec3 {
    return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
}

pub fn sub(self: Vec3, other: Vec3) Vec3 {
    return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
}

pub fn scale(self: Vec3, scalar: f64) Vec3 {
    return .{ .x = self.x * scalar, .y = self.y * scalar, .z = self.z * scalar };
}

pub fn dot(self: Vec3, other: Vec3) f64 {
    return self.x * other.x + self.y * other.y + self.z * other.z;
}

pub fn cross(self: Vec3, other: Vec3) Vec3 {
    return .{
        .x = self.y * other.z - self.z * other.y,
        .y = self.z * other.x - self.x * other.z,
        .z = self.x * other.y - self.y * other.x,
    };
}

pub fn lengthSquared(self: Vec3) f64 {
    return self.dot(self);
}

pub fn length(self: Vec3) f64 {
    return @sqrt(self.lengthSquared());
}

pub fn distanceSquared(self: Vec3, other: Vec3) f64 {
    return self.sub(other).lengthSquared();
}

pub fn normalized(self: Vec3) Error!Vec3 {
    try self.validate();
    const squared = self.lengthSquared();
    if (!std.math.isFinite(squared)) return error.ArithmeticOverflow;
    if (squared == 0) return .{};
    const divisor = @sqrt(squared);
    return .{ .x = self.x / divisor, .y = self.y / divisor, .z = self.z / divisor };
}

pub fn floorBlock(self: Vec3) (Error || error{CoordinateOverflow})!coordinates.BlockPos {
    try self.validate();
    return .{
        .x = try coordinates.floorToBlock(self.x),
        .y = try coordinates.floorToBlock(self.y),
        .z = try coordinates.floorToBlock(self.z),
    };
}

pub fn array(self: Vec3) [3]f64 {
    return .{ self.x, self.y, self.z };
}

pub fn fromArray(values: [3]f64) Vec3 {
    return .{ .x = values[0], .y = values[1], .z = values[2] };
}
