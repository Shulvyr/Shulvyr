const std = @import("std");

/// Fixed-capacity storage with scoped, generational handles.
/// The owner ID identifies a pool lifetime. Do not reuse it while stale handles can exist.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Handle = struct {
            owner: u64,
            index: u32,
            generation: u64,
        };

        const Slot = struct {
            generation: u64 = 1,
            next: ?u32,
            value: ?T = null,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,
        owner: u64,
        free: ?u32,
        count: u32 = 0,

        /// One allocation. Failure retains no allocations or values.
        pub fn init(allocator: std.mem.Allocator, capacity: u32, owner: u64) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            if (owner == 0) return error.InvalidOwner;
            const slots = try allocator.alloc(Slot, capacity);
            for (slots, 0..) |*slot, index| {
                slot.* = .{ .next = if (index + 1 < capacity) @intCast(index + 1) else null };
            }
            return .{ .allocator = allocator, .slots = slots, .owner = owner, .free = 0 };
        }

        /// Remove live values and release their resources before deinit.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.count == 0);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        /// Successful insertion transfers the value, failure leaves it with the caller.
        pub fn insert(self: *Self, value: T) error{PoolFull}!Handle {
            const index = self.free orelse return error.PoolFull;
            const slot = &self.slots[index];
            self.free = slot.next;
            slot.value = value;
            self.count += 1;
            return .{ .owner = self.owner, .index = index, .generation = slot.generation };
        }

        /// The pointer is borrowed until removal or pool destruction.
        pub fn get(self: *Self, handle: Handle) ?*T {
            if (handle.owner != self.owner or handle.index >= self.slots.len) return null;
            const slot = &self.slots[handle.index];
            if (slot.generation != handle.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        /// Returns ownership of the value. Exhausted generations retire their slots.
        pub fn remove(self: *Self, handle: Handle) ?T {
            const value = (self.get(handle) orelse return null).*;
            const slot = &self.slots[handle.index];
            slot.value = null;
            self.count -= 1;
            if (slot.generation == std.math.maxInt(u64)) {
                slot.next = null;
            } else {
                slot.generation += 1;
                slot.next = self.free;
                self.free = handle.index;
            }
            return value;
        }
    };
}

test "reuse invalidates stale handles and rejects foreign owners" {
    var pool = try Pool(u32).init(std.testing.allocator, 1, 7);
    defer pool.deinit();
    const first = try pool.insert(42);
    try std.testing.expectError(error.PoolFull, pool.insert(99));
    try std.testing.expectEqual(@as(?u32, 42), pool.remove(first));
    const second = try pool.insert(99);
    try std.testing.expectEqual(null, pool.get(first));
    var foreign = second;
    foreign.owner = 8;
    try std.testing.expectEqual(null, pool.get(foreign));
    foreign = second;
    foreign.index = 100;
    try std.testing.expectEqual(null, pool.get(foreign));
    try std.testing.expectEqual(@as(?u32, 99), pool.remove(second));
    try std.testing.expectEqual(null, pool.remove(second));
}

test "generation exhaustion retires a slot instead of resurrecting stale handles" {
    var pool = try Pool(u8).init(std.testing.allocator, 1, 1);
    defer pool.deinit();
    pool.slots[0].generation = std.math.maxInt(u64);
    const last = try pool.insert(1);
    _ = pool.remove(last);
    try std.testing.expectEqual(null, pool.get(last));
    try std.testing.expectError(error.PoolFull, pool.insert(2));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var pool = try Pool(u8).init(allocator, 4, 1);
    defer pool.deinit();
    const handle = try pool.insert(7);
    try std.testing.expectEqual(@as(?u8, 7), pool.remove(handle));
}

test "allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
    try std.testing.expectError(error.InvalidCapacity, Pool(u8).init(std.testing.allocator, 0, 1));
    try std.testing.expectError(error.InvalidOwner, Pool(u8).init(std.testing.allocator, 1, 0));
}

fn ownedPayloadCase(allocator: std.mem.Allocator) !void {
    var pool = try Pool([]u8).init(allocator, 1, 1);
    defer pool.deinit();
    const handle = block: {
        const data = try allocator.dupe(u8, "owned job bytes");
        errdefer allocator.free(data);
        break :block try pool.insert(data);
    };
    try std.testing.expectEqualStrings("owned job bytes", pool.get(handle).?.*);
    const payload = pool.remove(handle).?;
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("owned job bytes", payload);
    try std.testing.expectEqual(null, pool.get(handle));
}

test "owned payloads survive until removal and allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedPayloadCase, .{});
}
