const std = @import("std");
const connection = @import("Connection.zig");
const Session = @import("Session.zig");
const teardown = @import("Reaper.zig");
const Pool = @import("../foundation/Pool.zig").Pool;
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const framing = @import("framing.zig");
const outbound = @import("Outbox.zig");
const buffer = @import("buffer.zig");

pub const Limits = struct { connections: u32, payload_bytes: usize };
pub const Budget = struct {
    connection_visits: usize,
    finalizer_results: usize,
    events: usize,
    event_visits: usize,
    connection: connection.Budget,
};
pub const State = enum { uninitialized, running, stopping, joined };
pub const Stats = struct {
    slot_visits: usize = 0,
    connections_updated: usize = 0,
    finalizers: usize = 0,
    event_visits: usize = 0,
    events: usize = 0,
    packets: usize = 0,
    frames_read: usize = 0,
    bytes_read: usize = 0,
    frames_sent: usize = 0,
    bytes_sent: usize = 0,
};

/// One persistent owner, fixed-address connections and one management worker.
/// Initialize at the final address. The thread-safe allocator outlives deinit.
/// Retain external native contexts through their finalized event, then retire.
pub fn Manager(comptime send_capacity: usize, comptime receive_capacity: usize, comptime capacity: usize) type {
    if (capacity == 0 or capacity > 4096) @compileError("Manager requires 1 through 4096 connections");
    return struct {
        const Self = @This();
        pub const Connection = connection.Connection(send_capacity, receive_capacity, capacity);
        const Entry = struct { node: Connection = .{}, storage: []u8, charge: usize };
        const Records = Pool(Entry);
        const Reaper = teardown.Reaper(capacity);

        state: State = .uninitialized,
        allocator: std.mem.Allocator = undefined,
        io: std.Io = undefined,
        limits: Limits = undefined,
        records: Records = undefined,
        reaper: Reaper = .{},
        reserved_bytes: usize = 0,
        last_ns: u64 = 0,
        last_tick: ?u64 = null,
        update_cursor: usize = 0,
        event_cursor: usize = 0,
        remaining_events: usize = 0,
        remaining_event_visits: usize = 0,
        stats: Stats = .{},

        pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, owner: u64, limits: Limits) !void {
            if (self.state != .uninitialized) return error.AlreadyInitialized;
            if (limits.connections == 0 or limits.connections > capacity or limits.payload_bytes == 0) return error.InvalidLimits;
            self.records = try Records.init(allocator, limits.connections, owner);
            errdefer {
                self.records.deinit();
                self.* = .{};
            }
            try self.reaper.init(allocator, io, owner);
            self.allocator = allocator;
            self.io = io;
            self.limits = limits;
            self.state = .running;
        }

        fn initialized(self: *const Self) error{NotInitialized}!void {
            if (self.state == .uninitialized) return error.NotInitialized;
        }

        fn handle(id: Session.Id) Records.Handle {
            return .{ .owner = id.owner, .index = id.index, .generation = id.generation };
        }

        fn resolve(self: *Self, id: Session.Id) !*Entry {
            try self.initialized();
            return self.records.get(handle(id)) orelse error.StaleSession;
        }

        /// Borrow valid until explicit retire. Use ingress only from callbacks,
        /// and perform owner operations through the manager's scoped methods.
        pub fn get(self: *Self, id: Session.Id) !*Connection {
            return &(try self.resolve(id)).node;
        }

        fn overlapsStorage(self: *const Self, bytes: []const u8) bool {
            if (buffer.overlaps(bytes, std.mem.asBytes(self)) or
                buffer.overlaps(bytes, std.mem.sliceAsBytes(self.records.slots)) or
                buffer.overlaps(bytes, std.mem.sliceAsBytes(self.reaper.records.slots))) return true;
            for (self.records.slots) |*slot| {
                if (slot.value) |*entry| {
                    if (buffer.overlaps(bytes, entry.storage)) return true;
                }
            }
            return false;
        }

        /// Conservative application-payload reservation, not allocator or native
        /// memory usage. Covers both receive buffers and maximum retained copies.
        pub fn reservationBytes(config: connection.Config) !usize {
            try config.validate();
            const unreliable = @min(config.receive.message_bytes, config.receive.frame_bytes - 1);
            const storage = std.math.add(usize, config.receive.message_bytes, unreliable) catch return error.PayloadBudgetExceeded;
            const incoming = std.math.add(usize, storage, config.incoming_bytes) catch return error.PayloadBudgetExceeded;
            return std.math.add(usize, incoming, config.outgoing.payload_bytes) catch error.PayloadBudgetExceeded;
        }

        /// Admission and cleanup capacity precede provider creation. A new ID is
        /// registered before open delivery. Failed init retains no live context.
        pub fn admit(self: *Self, config: connection.Config, now_ns: u64) !Session.Id {
            try self.initialized();
            if (self.state != .running) return error.Stopping;
            if (now_ns < self.last_ns) return error.ClockWentBackwards;
            if (self.records.free == null) return error.PoolFull;
            const charge = try reservationBytes(config);
            if (charge > self.limits.payload_bytes - self.reserved_bytes) return error.PayloadBudgetExceeded;
            const reliable = config.receive.message_bytes;
            const total = reliable + @min(reliable, config.receive.frame_bytes - 1);
            const storage = try self.allocator.alloc(u8, total);
            errdefer self.allocator.free(storage);
            const key = try self.records.insert(.{ .storage = storage, .charge = charge });
            errdefer _ = self.records.remove(key).?;
            const entry = self.records.get(key).?;
            const id: Session.Id = .{ .owner = key.owner, .index = key.index, .generation = key.generation };
            try entry.node.init(self.allocator, self.io, &self.reaper, id, storage[0..reliable], storage[reliable..], config, now_ns);
            self.reserved_bytes += charge;
            self.last_ns = now_ns;
            return id;
        }

        pub fn attach(self: *Self, id: Session.Id, pending: *?connection.Provider) !void {
            const node = try self.get(id);
            if (self.overlapsStorage(std.mem.asBytes(pending))) return error.AliasedProvider;
            try node.attach(id, pending);
        }

        pub fn channelOpened(self: *Self, id: Session.Id, channel: framing.Channel, options: Session.ChannelOptions, now_ns: u64) !void {
            const node = try self.get(id);
            if (now_ns < self.last_ns) return error.ClockWentBackwards;
            defer self.last_ns = @max(self.last_ns, @max(node.last_ns, node.session.last_ns));
            try node.channelOpened(id, channel, options, now_ns);
        }

        pub fn sendCopy(self: *Self, id: Session.Id, channel: framing.Channel, bytes: []const u8) !outbound.Ticket {
            return (try self.get(id)).sendCopy(self.allocator, id, channel, bytes);
        }

        pub fn limitSendFrame(self: *Self, id: Session.Id, channel: framing.Channel, maximum: usize) !usize {
            return (try self.get(id)).limitSendFrame(id, channel, maximum);
        }

        pub fn sendOwned(self: *Self, id: Session.Id, channel: framing.Channel, pending: *?OwnedBytes) !outbound.Ticket {
            const node = try self.get(id);
            if (self.overlapsStorage(std.mem.asBytes(pending))) return error.AliasedPayload;
            if (pending.*) |*payload| {
                if (self.overlapsStorage(payload.bytes())) return error.AliasedPayload;
            }
            return node.sendOwned(id, channel, pending);
        }

        pub fn disconnect(self: *Self, id: Session.Id) !void {
            try (try self.get(id)).disconnect(id);
        }

        pub fn forceClose(self: *Self, id: Session.Id, reason: Session.CloseReason) !void {
            try (try self.get(id)).forceClose(id, reason);
        }

        pub fn retryFinalizer(self: *Self, id: Session.Id) !void {
            try (try self.get(id)).retryFinalizer(id);
        }

        /// This manager exclusively owns its reaper. Results cannot be consumed
        /// by another router or discarded while the application pauses input.
        pub fn collectFinalizers(self: *Self, limit: usize) !usize {
            try self.initialized();
            var count: usize = 0;
            while (count < limit) : (count += 1) {
                const completion = (self.reaper.collect() catch |err| {
                    if (err == error.Closed and self.reaper.records.count == 0) break;
                    return err;
                }) orelse break;
                try (try self.get(completion.session)).finalized(completion);
            }
            return count;
        }

        /// Preflight all live storage before any provider call, even for slots
        /// outside this tick's round-robin update window. Scratch is shared.
        fn preflight(self: *Self, tick: u64, now_ns: u64, scratch: []u8, visits: usize, work: connection.Budget) !void {
            if (self.overlapsStorage(scratch)) return error.AliasedScratch;
            const length = self.records.slots.len;
            for (self.records.slots, 0..) |*slot, index| {
                const entry = if (slot.value) |*entry| entry else continue;
                const node = &entry.node;
                if (now_ns < node.last_ns) return error.ClockWentBackwards;
                const selected = (index + length - self.update_cursor) % length < visits;
                if (selected) {
                    if (node.last_tick) |last| {
                        if (tick <= last) return error.StaleTick;
                    }
                }
                node.outbox.checkScratch(&node.session, scratch) catch |err| {
                    if (err != error.NoSpace or (selected and work.send.steps != 0 and
                        (node.phase == .open or node.phase == .draining))) return err;
                };
            }
        }

        /// Visits include empty slots. Per-node work times visited slots bounds
        /// provider/input work. Preflight scans every live outbox for alias safety,
        /// independent of the visit quota, bounded by pool and send capacities.
        pub fn beginTick(self: *Self, tick: u64, now_ns: u64, scratch: []u8, budget: Budget) !void {
            try self.initialized();
            if (self.state == .joined) return error.Joined;
            if (now_ns < self.last_ns) return error.ClockWentBackwards;
            if (self.last_tick) |last| {
                if (tick <= last) return error.StaleTick;
            }
            const visits = @min(budget.connection_visits, self.records.slots.len);
            try self.preflight(tick, now_ns, scratch, visits, budget.connection);
            self.last_tick = tick;
            self.last_ns = now_ns;
            self.stats = .{};
            self.remaining_events = budget.events;
            self.remaining_event_visits = budget.event_visits;
            self.stats.finalizers = try self.collectFinalizers(budget.finalizer_results);
            for (0..visits) |_| {
                const slot = &self.records.slots[self.update_cursor];
                self.update_cursor = (self.update_cursor + 1) % self.records.slots.len;
                self.stats.slot_visits += 1;
                if (slot.value) |*entry| {
                    const node = &entry.node;
                    try node.beginTick(node.session.id, tick, now_ns, scratch, budget.connection);
                    self.stats.connections_updated += 1;
                    self.stats.frames_sent += node.stats.sent.frames;
                    self.stats.bytes_sent += node.stats.sent.wire_bytes;
                }
            }
        }

        /// False pauses application frame reads while retaining control delivery.
        /// Both event count and visited slots are shared budgets for this tick.
        pub fn nextEvent(self: *Self, allow_input: bool) !?connection.Event {
            try self.initialized();
            if (self.last_tick == null) return error.TickRequired;
            if (self.remaining_events == 0) return null;
            var visited: usize = 0;
            while (self.remaining_event_visits != 0 and visited < self.records.slots.len) : (visited += 1) {
                const slot = &self.records.slots[self.event_cursor];
                self.event_cursor = (self.event_cursor + 1) % self.records.slots.len;
                self.remaining_event_visits -= 1;
                self.stats.event_visits += 1;
                const entry = if (slot.value) |*entry| entry else continue;
                const node = &entry.node;
                const frames_before = node.stats.frames;
                const bytes_before = node.stats.bytes;
                const event = if (allow_input and node.last_tick == self.last_tick)
                    try node.nextEvent(node.session.id)
                else
                    try node.nextControlEvent(node.session.id);
                self.stats.frames_read += node.stats.frames - frames_before;
                self.stats.bytes_read += node.stats.bytes - bytes_before;
                if (event) |ready| {
                    self.remaining_events -= 1;
                    self.stats.events += 1;
                    if (ready == .message) self.stats.packets += 1;
                    return ready;
                }
            }
            return null;
        }

        /// Call after handling the finalized event and its returned provider task.
        /// Count and byte credits remain charged until this explicit retirement.
        pub fn retire(self: *Self, id: Session.Id) !void {
            const entry = try self.resolve(id);
            try entry.node.deinit();
            entry.node = .{};
            const removed = self.records.remove(handle(id)).?;
            self.allocator.free(removed.storage);
            self.reserved_bytes -= removed.charge;
        }

        pub fn requestStop(self: *Self) !void {
            try self.initialized();
            if (self.state != .running) return;
            self.state = .stopping;
            try self.reaper.requestStop();
            for (self.records.slots) |*slot| {
                if (slot.value) |*entry| try entry.node.forceClose(entry.node.session.id, .requested);
            }
        }

        pub fn tryJoin(self: *Self) !bool {
            try self.initialized();
            if (self.state == .joined) return true;
            if (self.state != .stopping) return error.StopRequired;
            if (self.records.count != 0) return false;
            if (!try self.reaper.tryJoin()) return false;
            self.state = .joined;
            return true;
        }

        pub fn join(self: *Self) !void {
            try self.initialized();
            if (self.state == .joined) return;
            if (self.state != .stopping) return error.StopRequired;
            if (self.records.count != 0) return error.WorkOutstanding;
            try self.reaper.join();
            self.state = .joined;
        }

        pub fn deinit(self: *Self) error{NotJoined}!void {
            if (self.state != .joined) return error.NotJoined;
            try self.reaper.deinit();
            self.records.deinit();
            self.* = undefined;
        }
    };
}
