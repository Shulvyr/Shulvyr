const std = @import("std");
const TickClock = @This();

period_ns: u64,
max_catch_up: u32,
next_ns: u64 = 0,
last_ns: u64 = 0,

pub const Poll = struct {
    ticks: u32,
    missed_deadlines: u64,
    lag_ns: u64,
    wait_ns: u64,
};

pub fn init(period_ns: u64, max_catch_up: u32) error{InvalidClockConfig}!TickClock {
    if (period_ns == 0 or max_catch_up == 0) return error.InvalidClockConfig;
    return .{ .period_ns = period_ns, .max_catch_up = max_catch_up };
}

/// Takes elapsed monotonic nanoseconds, making the same policy usable with a test clock.
/// Caps work per poll and accounts for missed wall-clock deadlines explicitly.
/// Logical tick numbers and queued work are never skipped by this clock.
pub fn poll(self: *TickClock, now_ns: u64) error{ ClockWentBackwards, TimeOverflow }!Poll {
    if (now_ns < self.last_ns) return error.ClockWentBackwards;
    if (now_ns < self.next_ns) {
        self.last_ns = now_ns;
        return .{ .ticks = 0, .missed_deadlines = 0, .lag_ns = 0, .wait_ns = self.next_ns - now_ns };
    }
    const lag = now_ns - self.next_ns;
    const due = std.math.add(u64, lag / self.period_ns, 1) catch return error.TimeOverflow;
    const ticks: u32 = @intCast(@min(due, self.max_catch_up));
    const advance = std.math.mul(u64, due, self.period_ns) catch return error.TimeOverflow;
    const next = std.math.add(u64, self.next_ns, advance) catch return error.TimeOverflow;
    self.last_ns = now_ns;
    self.next_ns = next;
    return .{ .ticks = ticks, .missed_deadlines = due - ticks, .lag_ns = lag, .wait_ns = next - now_ns };
}

test "20 Hz pacing and exact deadlines" {
    var clock = try init(50_000_000, 4);
    try std.testing.expectEqual(@as(u32, 1), (try clock.poll(0)).ticks);
    const waiting = try clock.poll(49_999_999);
    try std.testing.expectEqual(@as(u32, 0), waiting.ticks);
    try std.testing.expectEqual(@as(u64, 1), waiting.wait_ns);
    try std.testing.expectEqual(@as(u32, 1), (try clock.poll(50_000_000)).ticks);
}

test "catch-up is bounded with explicit missed-deadline accounting" {
    var clock = try init(50, 2);
    const delayed = try clock.poll(250);
    try std.testing.expectEqual(@as(u32, 2), delayed.ticks);
    try std.testing.expectEqual(@as(u64, 4), delayed.missed_deadlines);
    try std.testing.expectEqual(@as(u64, 250), delayed.lag_ns);
    try std.testing.expectEqual(@as(u64, 50), delayed.wait_ns);
    try std.testing.expectEqual(@as(u32, 0), (try clock.poll(250)).ticks);
    try std.testing.expectError(error.ClockWentBackwards, clock.poll(249));
    try std.testing.expectEqual(@as(u64, 300), clock.next_ns);
}

test "clock overflow and invalid configuration leave state intact" {
    try std.testing.expectError(error.InvalidClockConfig, init(0, 1));
    try std.testing.expectError(error.InvalidClockConfig, init(1, 0));
    var clock = try init(1, 1);
    try std.testing.expectError(error.TimeOverflow, clock.poll(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 0), clock.next_ns);
    try std.testing.expectEqual(@as(u64, 0), clock.last_ns);
}
