const std = @import("std");
const buffer = @import("buffer.zig");

pub const Channel = enum {
    reliable,
    unreliable,

    pub fn label(self: Channel) [:0]const u8 {
        return switch (self) {
            .reliable => "ReliableDataChannel",
            .unreliable => "UnreliableDataChannel",
        };
    }

    pub fn fromLabel(value: []const u8) ?Channel {
        inline for (std.meta.tags(Channel)) |channel| {
            if (std.mem.eql(u8, value, channel.label())) return channel;
        }
        return null;
    }
};
pub const max_frame_bytes = 262_144;
pub const max_send_fragments = 255;
pub const max_message_bytes = (max_frame_bytes - 1) * max_send_fragments;

pub const Limits = struct {
    frame_bytes: usize = max_frame_bytes,
    message_bytes: usize = max_message_bytes,
    assembly_timeout_ns: u64 = 10 * std.time.ns_per_s,

    pub fn validate(self: Limits) error{InvalidLimits}!void {
        if (self.frame_bytes < 2 or self.frame_bytes > max_frame_bytes or
            self.message_bytes == 0 or self.message_bytes > max_message_bytes or
            self.assembly_timeout_ns == 0) return error.InvalidLimits;
    }
};

/// Borrows an immutable application message until all fragments are committed.
/// Write does not advance. Commit only after the provider accepts the fragment.
/// One owner must serialize a reliable message's complete fragment sequence.
pub const Sender = struct {
    input: []const u8,
    payload_bytes: usize,
    position: usize = 0,
    remaining: u8,

    pub fn init(channel: Channel, input: []const u8, limits: Limits) error{ InvalidLimits, MessageTooLarge, TooManyFragments, UnreliableFragmentation }!Sender {
        try limits.validate();
        if (input.len > limits.message_bytes) return error.MessageTooLarge;
        const capacity = limits.frame_bytes - 1;
        if (channel == .unreliable and input.len > capacity) return error.UnreliableFragmentation;
        const fragments = if (input.len == 0) 0 else (input.len - 1) / capacity + 1;
        if (fragments > max_send_fragments) return error.TooManyFragments;
        return .{ .input = input, .payload_bytes = capacity, .remaining = @intCast(fragments) };
    }

    pub fn done(self: *const Sender) bool {
        return self.remaining == 0;
    }

    /// The written region cannot overlap borrowed input or sender metadata.
    /// Failed writes preserve output and iterator state, allowing backpressure.
    pub fn write(self: *const Sender, output: []u8) error{ NoSpace, AliasedOutput }!?[]const u8 {
        if (self.done()) return null;
        const length = @min(self.payload_bytes, self.input.len - self.position);
        if (output.len < length + 1) return error.NoSpace;
        const frame = output[0 .. length + 1];
        if (buffer.overlaps(frame, self.input) or buffer.overlaps(frame, std.mem.asBytes(self)))
            return error.AliasedOutput;
        frame[0] = self.remaining - 1;
        @memcpy(frame[1..], self.input[self.position..][0..length]);
        return frame;
    }

    pub fn commit(self: *Sender) bool {
        if (self.done()) return false;
        self.position += @min(self.payload_bytes, self.input.len - self.position);
        self.remaining -= 1;
        return true;
    }
};

/// One channel of one session, called only by its owner. Never share storage
/// with another channel or a live receiver. No allocation occurs after init.
/// A completed view borrows storage until the next accept/reset/close call.
pub const Receiver = struct {
    channel: Channel,
    storage: []u8,
    limits: Limits,
    used: usize = 0,
    remaining: u8 = 0,
    started_ns: u64 = 0,
    last_ns: u64 = 0,
    closed: bool = false,

    pub const Error = error{
        Closed,
        ClockWentBackwards,
        AssemblyTimeout,
        InvalidFrame,
        FrameTooLarge,
        MessageTooLarge,
        UnreliableFragmentation,
        UnexpectedCountdown,
        AliasedInput,
        AliasedStorage,
    };

    pub fn init(channel: Channel, storage: []u8, limits: Limits) error{ InvalidLimits, InsufficientStorage }!Receiver {
        try limits.validate();
        const capacity = if (channel == .reliable) limits.message_bytes else @min(limits.message_bytes, limits.frame_bytes - 1);
        if (storage.len < capacity) return error.InsufficientStorage;
        return .{ .channel = channel, .storage = storage[0..capacity], .limits = limits };
    }

    /// Discards an incomplete message. Reset does not reopen a closed receiver
    /// or move its monotonic clock backwards. Use a new instance on reconnect.
    pub fn reset(self: *Receiver) void {
        self.used = 0;
        self.remaining = 0;
        self.started_ns = 0;
    }

    pub fn close(self: *Receiver) void {
        self.reset();
        self.closed = true;
    }

    /// The deadline is measured from the first fragment, never refreshed by a
    /// slow stream. Owners must poll even when no more input arrives.
    pub fn poll(self: *Receiver, now_ns: u64) Error!void {
        if (self.closed) return error.Closed;
        if (now_ns < self.last_ns) return error.ClockWentBackwards;
        self.last_ns = now_ns;
        if (self.remaining > 0 and now_ns - self.started_ns >= self.limits.assembly_timeout_ns) {
            self.reset();
            return error.AssemblyTimeout;
        }
    }

    /// Frame/protocol failures discard the incomplete sequence. An owner should
    /// close that session to prevent later fragments being treated as new data.
    /// Local aliasing errors preserve the receiver and its storage.
    pub fn accept(self: *Receiver, frame: []const u8, now_ns: u64) Error!?[]const u8 {
        if (buffer.overlaps(self.storage, std.mem.asBytes(self))) return error.AliasedStorage;
        if (buffer.overlaps(frame, self.storage) or buffer.overlaps(frame, std.mem.asBytes(self)))
            return error.AliasedInput;
        try self.poll(now_ns);
        errdefer self.reset();
        if (frame.len < 2) return error.InvalidFrame;
        if (frame.len > self.limits.frame_bytes) return error.FrameTooLarge;
        const countdown = frame[0];
        if (self.channel == .unreliable and countdown != 0) return error.UnreliableFragmentation;
        if (self.remaining > 0 and countdown != self.remaining - 1) return error.UnexpectedCountdown;
        const payload = frame[1..];
        if (payload.len > self.storage.len - self.used) return error.MessageTooLarge;
        if (self.remaining == 0 and countdown > 0) self.started_ns = now_ns;
        @memcpy(self.storage[self.used..][0..payload.len], payload);
        self.used += payload.len;
        self.remaining = countdown;
        if (countdown != 0) return null;
        const message = self.storage[0..self.used];
        self.reset();
        return message;
    }
};
