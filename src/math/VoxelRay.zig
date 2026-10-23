const std = @import("std");
const Vec3 = @import("Vec3.zig");
const coordinates = @import("coordinates.zig");
const VoxelRay = @This();

cell: [3]i32,
step: [3]i32,
boundary: [3]f64,
stride: [3]f64,
radius: f64,
remaining: usize,
first: bool = true,
state: enum { active, done, limited, overflowed } = .active,

pub const Error = Vec3.Error || error{ CoordinateOverflow, ZeroLengthRay, InvalidStepLimit, StepLimit };
pub const maximum_steps = 1_000_000;

/// Single-context, allocation-free iterator. The budget includes the first cell.
/// Use next until null or error. Errors are sticky and never imply completion.
pub fn init(start: Vec3, end: Vec3, max_steps: usize) Error!VoxelRay {
    if (max_steps == 0 or max_steps > maximum_steps) return error.InvalidStepLimit;
    const first_cell = try start.floorBlock();
    _ = try end.floorBlock();
    const offset = end.sub(start);
    const direction = try offset.normalized();
    if (direction.lengthSquared() == 0) return error.ZeroLengthRay;
    var result: VoxelRay = .{
        .cell = .{ first_cell.x, first_cell.y, first_cell.z },
        .step = undefined,
        .boundary = undefined,
        .stride = undefined,
        .radius = offset.length(),
        .remaining = max_steps,
    };
    for (start.array(), direction.array(), 0..) |origin, component, axis| {
        const step: i32 = if (component > 0) 1 else if (component < 0) -1 else 0;
        result.step[axis] = step;
        const fraction = origin - @floor(origin);
        result.boundary[axis] = if (component == 0) std.math.inf(f64) else if (component < 0) fraction / -component else (1 - fraction) / component;
        result.stride[axis] = if (component == 0) 0 else @as(f64, @floatFromInt(step)) / component;
    }
    return result;
}

pub fn next(self: *VoxelRay) Error!?coordinates.BlockPos {
    switch (self.state) {
        .done => return null,
        .limited => return error.StepLimit,
        .overflowed => return error.CoordinateOverflow,
        .active => {},
    }
    if (self.first) {
        self.first = false;
    } else {
        // Equal boundary distances cross one axis at a time, in Z, Y, X order.
        const axis: usize = if (self.boundary[0] < self.boundary[1] and self.boundary[0] < self.boundary[2]) 0 else if (self.boundary[1] < self.boundary[2]) 1 else 2;
        if (self.boundary[axis] > self.radius) {
            self.state = .done;
            return null;
        }
        if (self.remaining == 0) {
            self.state = .limited;
            return error.StepLimit;
        }
        self.cell[axis] = std.math.add(i32, self.cell[axis], self.step[axis]) catch {
            self.state = .overflowed;
            return error.CoordinateOverflow;
        };
        self.boundary[axis] += self.stride[axis];
    }
    self.remaining -= 1;
    return .{ .x = self.cell[0], .y = self.cell[1], .z = self.cell[2] };
}
