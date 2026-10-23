const std = @import("std");
const Mailbox = @import("../foundation/Mailbox.zig").Mailbox;
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const Session = @import("Session.zig");
const framing = @import("framing.zig");

pub const Config = struct {
    frame_bytes: usize = framing.max_frame_bytes,
    payload_bytes: usize = 4 * 1024 * 1024,
};
pub const StopReason = enum { requested, transport_closed, transport_failed, invalid_frame, invalid_channel, queue_full, byte_budget, out_of_memory, delivery_failure };
pub const Status = struct { reason: ?StopReason, outstanding: usize, payload_bytes: usize };

/// One provider lifetime, concurrent producers and one owner. Initialize at its
/// final address and never copy it. Providers serialize callbacks per channel.
/// Admission counts reserved, queued and leased frames until their bytes free.
pub fn Inbox(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 4096) @compileError("Inbox requires 1 through 4096 slots");
    return struct {
        const Self = @This();
        const Frame = struct { channel: framing.Channel, payload: OwnedBytes };

        pub const Lease = struct {
            inbox: ?*Self,
            session: Session.Id,
            channel: framing.Channel,
            payload: OwnedBytes,
            accepted: bool = false,

            /// Borrows the copied frame until deinit. Do not copy a live lease.
            pub fn bytes(self: *const Lease) []const u8 {
                return self.payload.bytes();
            }

            /// Only the owner applies frames to a resolved current session.
            /// NotOpen retains the lease for retry. Complete output borrows the
            /// session receiver until its next mutation, not this lease.
            pub fn accept(self: *Lease, session: *Session, now_ns: u64) !?[]const u8 {
                const inbox = self.inbox orelse return error.RetiredLease;
                if (!std.meta.eql(self.session, session.id)) return error.StaleSession;
                if (self.accepted) return error.AlreadyAccepted;
                if (try inbox.applyStop(session)) return error.Closed;
                const complete = try session.accept(self.session, self.channel, self.bytes(), now_ns);
                self.accepted = true;
                return complete;
            }

            /// Frees before returning count/byte credits. The allocator and inbox
            /// must outlive the lease. Repeated deinit on the same value is safe.
            pub fn deinit(self: *Lease) void {
                const inbox = self.inbox orelse return;
                const length = self.payload.bytes().len;
                self.payload.deinit();
                self.inbox = null;
                inbox.release(length);
            }
        };

        initialized: bool = false,
        io: std.Io = undefined,
        allocator: std.mem.Allocator = undefined,
        session: Session.Id = undefined,
        config: Config = undefined,
        mutex: std.Io.Mutex = .init,
        frames: Mailbox(Frame, capacity) = .{},
        reason: ?StopReason = null,
        outstanding: usize = 0,
        payload_bytes: usize = 0,

        /// The allocator must support concurrent callback allocations and owner
        /// frees. No allocation occurs here. Retain the inbox through the native
        /// callback deletion barrier, then discard queued frames before deinit.
        pub fn init(self: *Self, io: std.Io, allocator: std.mem.Allocator, session: Session.Id, config: Config) !void {
            if (self.initialized) return error.AlreadyInitialized;
            if (session.owner == 0 or session.generation == 0) return error.InvalidIdentity;
            if (config.frame_bytes < 2 or config.frame_bytes > framing.max_frame_bytes or
                config.payload_bytes < config.frame_bytes) return error.InvalidBudget;
            try self.frames.init();
            self.io = io;
            self.allocator = allocator;
            self.session = session;
            self.config = config;
            self.initialized = true;
        }

        fn identity(self: *const Self, session: Session.Id) error{ NotInitialized, StaleSession }!void {
            if (!self.initialized) return error.NotInitialized;
            if (!std.meta.eql(self.session, session)) return error.StaleSession;
        }

        pub fn status(self: *Self) error{NotInitialized}!Status {
            if (!self.initialized) return error.NotInitialized;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return .{ .reason = self.reason, .outstanding = self.outstanding, .payload_bytes = self.payload_bytes };
        }

        /// First reason wins outside the frame queue, including when it is full.
        /// In-flight copies may finish, but cannot publish after queue closure.
        /// This is not a native callback barrier or a native peer close.
        pub fn stop(self: *Self, session: Session.Id, reason: StopReason) error{ NotInitialized, StaleSession }!void {
            try self.identity(session);
            self.mutex.lockUncancelable(self.io);
            if (self.reason == null) self.reason = reason;
            self.mutex.unlock(self.io);
            self.frames.close(self.io);
        }

        fn release(self: *Self, length: usize) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.debug.assert(self.outstanding > 0 and length <= self.payload_bytes);
            self.outstanding -= 1;
            self.payload_bytes -= length;
        }

        fn reserve(self: *Self, length: usize) error{ Closed, QueueFull, PayloadBudgetExceeded }!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.reason != null) return error.Closed;
            if (self.outstanding == capacity) {
                self.reason = .queue_full;
                return error.QueueFull;
            }
            if (length > self.config.payload_bytes - self.payload_bytes) {
                self.reason = .byte_budget;
                return error.PayloadBudgetExceeded;
            }
            self.outstanding += 1;
            self.payload_bytes += length;
        }

        /// Copies borrowed binary frames before the provider callback returns.
        /// Limits/reservations precede allocation. Saturation or OOM stops future
        /// admission. Locks and the allocator may wait, capacity admission never
        /// waits for an owner to make room. Callbacks never access owner state.
        pub fn post(self: *Self, session: Session.Id, channel: framing.Channel, input: []const u8) !void {
            try self.identity(session);
            if (input.len < 2 or input.len > self.config.frame_bytes) {
                try self.stop(session, .invalid_frame);
                return error.InvalidFrame;
            }
            self.reserve(input.len) catch |err| {
                self.frames.close(self.io);
                return err;
            };
            var frame: ?Frame = .{ .channel = channel, .payload = OwnedBytes.copy(self.allocator, input, self.config.frame_bytes) catch |err| {
                self.release(input.len);
                try self.stop(session, .out_of_memory);
                return err;
            } };
            errdefer {
                frame.?.payload.deinit();
                self.release(input.len);
            }
            self.frames.send(self.io, &frame) catch |err| {
                try self.stop(session, .delivery_failure);
                return err;
            };
        }

        /// Returns queued frames even after stop. Closed means fully drained,
        /// but in-flight producers and outstanding leases may still exist.
        pub fn receive(self: *Self) error{ NotInitialized, Closed }!?Lease {
            if (!self.initialized) return error.NotInitialized;
            const frame = (try self.frames.receive(self.io)) orelse return null;
            return .{ .inbox = self, .session = self.session, .channel = frame.channel, .payload = frame.payload };
        }

        /// Propagates sticky callback termination on the owner before mutation.
        /// No native API or game authentication is performed here.
        pub fn applyStop(self: *Self, session: *Session) error{ NotInitialized, StaleSession }!bool {
            try self.identity(session.id);
            const snapshot = try self.status();
            const reason = snapshot.reason orelse return false;
            try session.close(self.session, switch (reason) {
                .requested => .requested,
                .transport_closed => .transport_closed,
                .transport_failed => .transport_failure,
                .invalid_channel => .invalid_channel,
                .invalid_frame => .framing_error,
                .queue_full, .byte_budget => .inbound_overflow,
                .out_of_memory, .delivery_failure => .inbound_failure,
            });
            return true;
        }

        /// Bounded owner cleanup after stopping admission. Repeat after producers
        /// quiesce, until outstanding is zero. Live leases remain their owner's.
        pub fn discard(self: *Self, limit: usize) !usize {
            if ((try self.status()).reason == null) return error.NotStopped;
            var count: usize = 0;
            while (count < limit) : (count += 1) {
                var lease = (self.receive() catch |err| switch (err) {
                    error.Closed => return count,
                    else => return err,
                }) orelse return count;
                lease.deinit();
            }
            return count;
        }

        /// All producers must be quiescent and all leases/frames released.
        /// Zero outstanding alone cannot prove the native callback barrier.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.initialized);
            const snapshot = self.status() catch unreachable;
            std.debug.assert(snapshot.reason != null and snapshot.outstanding == 0 and snapshot.payload_bytes == 0);
            self.* = undefined;
        }
    };
}
