const std = @import("std");
const TickClock = @import("TickClock.zig");
const Scheduler = @import("Scheduler.zig").Scheduler;
const Queue = @import("../foundation/Queue.zig").Queue;
const Config = @import("../operator/cli.zig").Config;
const Runtime = @This();
const command_capacity = 64;

pub const State = enum { ready, running, stopping, stopped };
pub const Command = enum { stop };

state: State = .ready,
ticks: u64 = 0,
timers: Scheduler(Command, command_capacity) = .{},
commands: Queue(Command, command_capacity) = .{},

pub fn start(self: *Runtime, config: Config) !void {
    if (self.state != .ready) return error.InvalidState;
    try config.validate();
    _ = try self.timers.schedule(config.ticks, .stop);
    self.state = .running;
}

/// Commands and ticks are applied only by the runtime's owner context.
pub fn tick(self: *Runtime) !void {
    if (self.state != .running) return error.InvalidState;
    self.applyCommands();
    if (self.state != .running) return;
    self.ticks = std.math.add(u64, self.ticks, 1) catch return error.TickOverflow;
    while (self.timers.popDue(self.ticks)) |command| try self.commands.push(command);
    self.applyCommands();
}

fn applyCommands(self: *Runtime) void {
    while (self.commands.pop()) |command| switch (command) {
        .stop => self.state = .stopping,
    };
}

pub fn stop(self: *Runtime) void {
    self.state = .stopping;
    while (self.commands.pop() != null) {}
    while (self.timers.popDue(std.math.maxInt(u64)) != null) {}
    self.state = .stopped;
}

/// Uses the platform monotonic clock. No world or transport is created here.
pub fn run(io: std.Io, config: Config) !u64 {
    const resolution = try std.Io.Clock.awake.resolution(io);
    if (resolution.toNanoseconds() <= 0) return error.ClockUnavailable;
    var runtime: Runtime = .{};
    try runtime.start(config);
    defer runtime.stop();
    var clock = try TickClock.init(@as(u64, std.time.ns_per_s) / config.tick_rate, config.max_catch_up);
    const start_time = std.Io.Clock.awake.now(io);
    while (runtime.state == .running) {
        const elapsed = start_time.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        const now = std.math.cast(u64, elapsed) orelse return error.InvalidClock;
        const poll = try clock.poll(now);
        for (0..poll.ticks) |_| {
            try runtime.tick();
            if (runtime.state != .running) break;
        }
        if (runtime.state == .running and poll.ticks == 0) {
            try std.Io.sleep(io, .fromNanoseconds(poll.wait_ns), .awake);
        }
    }
    return runtime.ticks;
}

test "finite lifecycle stops at the exact logical tick" {
    var runtime: Runtime = .{};
    try std.testing.expectError(error.InvalidState, runtime.tick());
    try runtime.start(.{ .ticks = 2 });
    try std.testing.expectError(error.InvalidState, runtime.start(.{}));
    try runtime.tick();
    try std.testing.expectEqual(State.running, runtime.state);
    try runtime.tick();
    try std.testing.expectEqual(State.stopping, runtime.state);
    try std.testing.expectEqual(@as(u64, 2), runtime.ticks);
    runtime.stop();
    try std.testing.expectEqual(State.stopped, runtime.state);
    try std.testing.expectEqual(@as(usize, 0), runtime.timers.count);
    try std.testing.expectEqual(@as(usize, 0), runtime.commands.count);
    runtime.stop();
    try std.testing.expectError(error.InvalidState, runtime.tick());
}

test "failed initialization does not enter running state" {
    var runtime: Runtime = .{};
    try std.testing.expectError(error.InvalidValue, runtime.start(.{ .ticks = 0 }));
    try std.testing.expectEqual(State.ready, runtime.state);
    try std.testing.expectEqual(@as(usize, 0), runtime.timers.count);
}

test "queued stop runs before another logical tick" {
    var runtime: Runtime = .{};
    try runtime.start(.{});
    try runtime.commands.push(.stop);
    try runtime.tick();
    try std.testing.expectEqual(State.stopping, runtime.state);
    try std.testing.expectEqual(@as(u64, 0), runtime.ticks);
    runtime.stop();
    try std.testing.expectEqual(@as(usize, 0), runtime.timers.count);
}

test "tick overflow preserves the logical tick counter" {
    var runtime: Runtime = .{};
    try runtime.start(.{});
    defer runtime.stop();
    runtime.ticks = std.math.maxInt(u64);
    try std.testing.expectError(error.TickOverflow, runtime.tick());
    try std.testing.expectEqual(std.math.maxInt(u64), runtime.ticks);
}
