const std = @import("std");

/// Owner-context timers ordered by logical tick and then insertion sequence.
/// Values belong to the scheduler until returned by popDue or cancel.
/// Tickets are scoped to this scheduler instance.
/// Cancel or dispatch owned payloads before discarding the scheduler.
pub fn Scheduler(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Scheduler capacity must be positive");
    return struct {
        const Self = @This();
        pub const Ticket = struct { sequence: u64 };
        const Entry = struct { tick: u64, sequence: u64, value: T };
        entries: [capacity]?Entry = @splat(null),
        count: usize = 0,
        next_sequence: u64 = 1,

        pub fn schedule(self: *Self, tick: u64, value: T) error{ SchedulerFull, SequenceExhausted }!Ticket {
            if (self.count == capacity) return error.SchedulerFull;
            if (self.next_sequence == 0) return error.SequenceExhausted;
            for (&self.entries) |*slot| {
                if (slot.* != null) continue;
                const sequence = self.next_sequence;
                slot.* = .{ .tick = tick, .sequence = sequence, .value = value };
                self.next_sequence +%= 1;
                self.count += 1;
                return .{ .sequence = sequence };
            }
            unreachable;
        }

        pub fn cancel(self: *Self, ticket: Ticket) ?T {
            for (&self.entries) |*slot| {
                if (slot.*) |entry| {
                    if (entry.sequence == ticket.sequence) {
                        slot.* = null;
                        self.count -= 1;
                        return entry.value;
                    }
                }
            }
            return null;
        }

        pub fn popDue(self: *Self, tick: u64) ?T {
            var selected: ?usize = null;
            for (self.entries, 0..) |slot, index| {
                const entry = slot orelse continue;
                if (entry.tick > tick) continue;
                if (selected) |previous| {
                    const best = self.entries[previous].?;
                    if (entry.tick > best.tick or (entry.tick == best.tick and entry.sequence > best.sequence)) continue;
                }
                selected = index;
            }
            const index = selected orelse return null;
            const value = self.entries[index].?.value;
            self.entries[index] = null;
            self.count -= 1;
            return value;
        }
    };
}

test "deadlines and same-tick insertion order are deterministic" {
    var scheduler: Scheduler(u8, 4) = .{};
    _ = try scheduler.schedule(3, 30);
    _ = try scheduler.schedule(2, 20);
    _ = try scheduler.schedule(2, 21);
    try std.testing.expectEqual(null, scheduler.popDue(1));
    try std.testing.expectEqual(@as(?u8, 20), scheduler.popDue(3));
    try std.testing.expectEqual(@as(?u8, 21), scheduler.popDue(3));
    try std.testing.expectEqual(@as(?u8, 30), scheduler.popDue(3));
    try std.testing.expectEqual(null, scheduler.popDue(3));
}

test "cancellation cannot cancel a replacement timer" {
    var scheduler: Scheduler(u8, 1) = .{};
    const first = try scheduler.schedule(1, 1);
    try std.testing.expectError(error.SchedulerFull, scheduler.schedule(2, 2));
    try std.testing.expectEqual(@as(?u8, 1), scheduler.cancel(first));
    _ = try scheduler.schedule(2, 2);
    try std.testing.expectEqual(null, scheduler.cancel(first));
    try std.testing.expectEqual(@as(?u8, 2), scheduler.popDue(2));
    try std.testing.expectEqual(null, scheduler.cancel(first));
}

test "sequence IDs never wrap into a reusable ticket" {
    var scheduler: Scheduler(u8, 1) = .{};
    scheduler.next_sequence = std.math.maxInt(u64);
    _ = try scheduler.schedule(0, 1);
    _ = scheduler.popDue(0);
    try std.testing.expectError(error.SequenceExhausted, scheduler.schedule(0, 2));
}
