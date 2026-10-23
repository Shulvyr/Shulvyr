const std = @import("std");

/// Bounded FIFO owned by one execution context. No internal synchronization.
/// Successful push transfers the value to the queue. Pop transfers it back.
/// Drain and release owned payloads before discarding the queue.
pub fn Queue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Queue capacity must be positive");
    return struct {
        const Self = @This();
        items: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        pub fn push(self: *Self, value: T) error{QueueFull}!void {
            if (self.count == capacity) return error.QueueFull;
            self.items[self.tail] = value;
            self.tail = next(self.tail);
            self.count += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const value = self.items[self.head];
            self.head = next(self.head);
            self.count -= 1;
            return value;
        }

        fn next(index: usize) usize {
            return if (index == capacity - 1) 0 else index + 1;
        }
    };
}

test "FIFO wraps and rejects overload without losing work" {
    var queue: Queue(u8, 2) = .{};
    try std.testing.expectEqual(null, queue.pop());
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectError(error.QueueFull, queue.push(3));
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try queue.push(3);
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, 3), queue.pop());
    try std.testing.expectEqual(null, queue.pop());
}
