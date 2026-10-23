const std = @import("std");
const Mailbox = @import("../foundation/Mailbox.zig").Mailbox;
const Pool = @import("../foundation/Pool.zig").Pool;
const Session = @import("Session.zig");
const buffer = @import("buffer.zig");

pub const Task = struct {
    session: Session.Id,
    context: *anyopaque,
    /// Management worker only. Return success only after callbacks using the
    /// context have quiesced. Do not free it, access owner state, reenter the
    /// reaper or wait for owner work. Failure retains the context for retry.
    finalize: *const fn (*anyopaque) error{Failed}!void,
};
pub const Outcome = enum { quiesced, failed };
pub const Phase = enum { reserved, submitted, quiesced, failed };
pub const State = enum { uninitialized, running, stopping, joined };

/// One owner, one management worker. Keep at its initialized address and never
/// copy it. Credits cover reservations, jobs, completions and retained contexts.
/// The worker touches only immutable jobs, provider contexts and mailboxes.
pub fn Reaper(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 4096) @compileError("Reaper requires 1 through 4096 slots");
    return struct {
        const Self = @This();
        const Record = struct { session: Session.Id, phase: Phase = .reserved, task: ?Task = null };
        const Records = Pool(Record);
        pub const Ticket = Records.Handle;
        pub const Completion = struct { ticket: Ticket, session: Session.Id, outcome: Outcome };
        const Job = struct { ticket: Ticket, task: Task };

        state: State = .uninitialized,
        io: std.Io = undefined,
        records: Records = undefined,
        jobs: Mailbox(Job, capacity) = .{},
        completions: Mailbox(Completion, capacity) = .{},
        worker: ?std.Thread = null,
        finished: std.atomic.Value(bool) = .init(false),

        /// Allocates the owner records once and starts an idle worker. The
        /// allocator outlives deinit. Failed initialization owns no resources.
        pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, owner: u64) !void {
            if (self.state != .uninitialized) return error.AlreadyInitialized;
            self.records = try Records.init(allocator, @intCast(capacity), owner);
            errdefer {
                self.records.deinit();
                self.* = .{};
            }
            self.io = io;
            try self.jobs.init();
            try self.completions.init();
            self.worker = try std.Thread.spawn(.{}, run, .{self});
            self.state = .running;
        }

        fn resolve(self: *Self, ticket: Ticket) error{ NotInitialized, StaleTicket }!*Record {
            if (self.state == .uninitialized) return error.NotInitialized;
            return self.records.get(ticket) orelse error.StaleTicket;
        }

        /// Reserve before publishing a native connection that will need cleanup.
        /// One reservation per session lifetime. No provider ownership moves yet.
        pub fn reserve(self: *Self, session: Session.Id) !Ticket {
            if (self.state == .uninitialized) return error.NotInitialized;
            if (self.state != .running) return error.Stopping;
            if (session.owner == 0 or session.generation == 0) return error.InvalidIdentity;
            for (self.records.slots) |slot| {
                if (slot.value) |record| {
                    if (std.meta.eql(record.session, session)) return error.DuplicateSession;
                }
            }
            return self.records.insert(.{ .session = session });
        }

        pub fn phase(self: *Self, ticket: Ticket) !Phase {
            return (try self.resolve(ticket)).phase;
        }

        fn finishStop(self: *Self) void {
            if (self.state == .stopping and self.records.count == 0) self.jobs.close(self.io);
        }

        /// Only an unused reservation can be canceled. Finalization cannot be
        /// canceled after submission, even during shutdown or provider failure.
        pub fn cancelReservation(self: *Self, ticket: Ticket) !void {
            const record = try self.resolve(ticket);
            if (record.phase != .reserved) return error.NotReserved;
            _ = self.records.remove(ticket).?;
            self.finishStop();
        }

        /// Success transfers exclusive finalizer access until takeFinalized.
        /// Failure leaves the task with the caller. Existing reservations remain
        /// usable after requestStop, so shutdown cannot strand native resources.
        pub fn submit(self: *Self, ticket: Ticket, pending: *?Task) !void {
            const record = try self.resolve(ticket);
            if (record.phase != .reserved) return error.NotReserved;
            if (buffer.overlaps(std.mem.asBytes(pending), std.mem.asBytes(self)) or
                buffer.overlaps(std.mem.asBytes(pending), std.mem.sliceAsBytes(self.records.slots))) return error.AliasedTask;
            const task = pending.* orelse return error.EmptyTransfer;
            if (!std.meta.eql(task.session, record.session)) return error.WrongSession;
            var job: ?Job = .{ .ticket = ticket, .task = task };
            try self.jobs.send(self.io, &job);
            record.task = task;
            record.phase = .submitted;
            pending.* = null;
        }

        /// Failed contexts retain their original task and credit. The provider
        /// finalizer must handle partial progress safely when retrying.
        pub fn retry(self: *Self, ticket: Ticket) !void {
            const record = try self.resolve(ticket);
            if (record.phase != .failed) return error.NotFailed;
            var job: ?Job = .{ .ticket = ticket, .task = record.task.? };
            try self.jobs.send(self.io, &job);
            record.phase = .submitted;
        }

        /// Non-waiting owner observation. Collecting does not release a context
        /// or credit. Validate the returned session before applying owner state.
        pub fn collect(self: *Self) !?Completion {
            if (self.state == .uninitialized) return error.NotInitialized;
            const completion = (try self.completions.receive(self.io)) orelse return null;
            const record = try self.resolve(completion.ticket);
            if (record.phase != .submitted or !std.meta.eql(record.session, completion.session)) return error.InvalidCompletion;
            record.phase = if (completion.outcome == .quiesced) .quiesced else .failed;
            return completion;
        }

        /// Transfers the quiesced context back once. Only now may the owner free
        /// or reuse it. Failed or merely submitted work never releases a credit.
        pub fn takeFinalized(self: *Self, ticket: Ticket) !Task {
            if ((try self.resolve(ticket)).phase != .quiesced) return error.NotQuiesced;
            const record = self.records.remove(ticket).?;
            self.finishStop();
            return record.task.?;
        }

        /// Refuses new reservations, retaining existing ones and failed tasks.
        /// The owner must submit/cancel reservations, collect results, retry
        /// failures and take quiesced contexts. No running task is interrupted.
        pub fn requestStop(self: *Self) error{NotInitialized}!void {
            if (self.state == .uninitialized) return error.NotInitialized;
            if (self.state == .running) self.state = .stopping;
            self.finishStop();
        }

        pub fn tryJoin(self: *Self) !bool {
            if (self.state == .uninitialized) return error.NotInitialized;
            if (self.state == .joined) return true;
            if (self.state != .stopping) return error.StopRequired;
            if (self.records.count != 0 or !self.finished.load(.acquire)) return false;
            try self.join();
            return true;
        }

        /// Waits only for worker exit after every context has returned. Refuses
        /// to wait for provider work or for results an owner still must collect.
        pub fn join(self: *Self) !void {
            if (self.state == .uninitialized) return error.NotInitialized;
            if (self.state == .joined) return;
            if (self.state != .stopping) return error.StopRequired;
            if (self.records.count != 0) return error.WorkOutstanding;
            self.worker.?.join();
            self.worker = null;
            self.state = .joined;
        }

        pub fn deinit(self: *Self) error{NotJoined}!void {
            if (self.state != .joined) return error.NotJoined;
            self.records.deinit();
            self.* = undefined;
        }

        fn run(self: *Self) void {
            defer self.finished.store(true, .release);
            defer self.completions.close(self.io);
            while (true) {
                const job = self.jobs.waitReceive(self.io) catch |err| switch (err) {
                    error.Closed => return,
                    error.NotInitialized => @panic("Reaper input was not initialized"),
                };
                const outcome: Outcome = if (job.task.finalize(job.task.context)) .quiesced else |_| .failed;
                var completion: ?Completion = .{ .ticket = job.ticket, .session = job.task.session, .outcome = outcome };
                // Each occupied record can produce only one uncollected result.
                // Retaining its credit guarantees a free completion queue slot.
                self.completions.send(self.io, &completion) catch @panic("Reaper completion capacity invariant failed");
            }
        }
    };
}
