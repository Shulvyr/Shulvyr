const std = @import("std");
const buffer = @import("buffer.zig");
const framing = @import("framing.zig");
const Session = @This();

/// Scoped identity for native callback events, never a wire NetworkID. The
/// owner supplies a non-reused lifetime and increments generation on slot reuse.
pub const Id = struct {
    owner: u64,
    index: u32,
    generation: u64,
};

pub const State = enum { negotiating, open, closed };
pub const CloseReason = enum { requested, transport_closed, outbound_failure, inbound_overflow, inbound_failure, negotiation_timeout, framing_error, assembly_timeout, invalid_channel };
pub const ChannelOptions = struct {
    ordered: bool,
    max_retransmits: ?u32 = null,
    max_packet_lifetime_ms: ?u32 = null,

    pub fn required(channel: framing.Channel) ChannelOptions {
        return if (channel == .reliable) .{ .ordered = true } else .{ .ordered = false, .max_retransmits = 0 };
    }
};

id: Id,
receivers: [2]framing.Receiver,
state: State = .negotiating,
opened: [2]bool = .{ false, false },
created_ns: u64,
last_ns: u64,
negotiation_timeout_ns: u64,
close_reason: ?CloseReason = null,

/// Borrows disjoint channel storage and keeps both channels independent. The
/// session itself must also remain separate from storage and have one owner.
pub fn init(id: Id, reliable: []u8, unreliable: []u8, limits: framing.Limits, now_ns: u64, negotiation_timeout_ns: u64) !Session {
    if (id.owner == 0 or id.generation == 0) return error.InvalidIdentity;
    if (negotiation_timeout_ns == 0) return error.InvalidTimeout;
    if (buffer.overlaps(reliable, unreliable)) return error.AliasedStorage;
    return .{
        .id = id,
        .receivers = .{
            try .init(.reliable, reliable, limits),
            try .init(.unreliable, unreliable, limits),
        },
        .created_ns = now_ns,
        .last_ns = now_ns,
        .negotiation_timeout_ns = negotiation_timeout_ns,
    };
}

fn current(self: *const Session, id: Id) error{ StaleSession, Closed }!void {
    if (!std.meta.eql(id, self.id)) return error.StaleSession;
    if (self.state == .closed) return error.Closed;
}

pub fn close(self: *Session, id: Id, reason: CloseReason) error{StaleSession}!void {
    if (!std.meta.eql(id, self.id)) return error.StaleSession;
    if (self.state == .closed) return;
    self.state = .closed;
    self.close_reason = reason;
    for (&self.receivers) |*receiver| receiver.close();
}

/// Only valid channels become ready. Identity validation happens before any
/// clock, storage or state mutation, including on late close/open events.
pub fn channelOpened(self: *Session, id: Id, channel: framing.Channel, options: ChannelOptions, now_ns: u64) !void {
    try self.current(id);
    try self.poll(now_ns);
    const index = @backingInt(channel);
    if (self.opened[index] or !std.meta.eql(options, ChannelOptions.required(channel))) {
        try self.close(id, .invalid_channel);
        return error.InvalidChannel;
    }
    self.opened[index] = true;
    if (self.opened[0] and self.opened[1]) self.state = .open;
}

pub fn poll(self: *Session, now_ns: u64) !void {
    if (self.state == .closed) return error.Closed;
    if (now_ns < self.last_ns) return error.ClockWentBackwards;
    self.last_ns = now_ns;
    if (self.state == .negotiating and now_ns - self.created_ns >= self.negotiation_timeout_ns) {
        try self.close(self.id, .negotiation_timeout);
        return error.NegotiationTimeout;
    }
    for (&self.receivers) |*receiver| receiver.poll(now_ns) catch |err| {
        try self.close(self.id, .assembly_timeout);
        return err;
    };
}

/// Consumes one copied callback frame on the owner. Complete bytes borrow the
/// channel storage until the next call affecting that receiver. Stale events
/// never alter a replacement session. Protocol errors close both channels.
pub fn accept(self: *Session, id: Id, channel: framing.Channel, frame: []const u8, now_ns: u64) !?[]const u8 {
    try self.current(id);
    // Preserve live storage on local aliasing mistakes before any state change.
    for (&self.receivers) |*receiver| {
        if (buffer.overlaps(receiver.storage, std.mem.asBytes(self))) return error.AliasedStorage;
        if (buffer.overlaps(frame, receiver.storage)) return error.AliasedInput;
    }
    if (buffer.overlaps(frame, std.mem.asBytes(self))) return error.AliasedInput;
    try self.poll(now_ns);
    if (self.state != .open) return error.NotOpen;
    return self.receivers[@backingInt(channel)].accept(frame, now_ns) catch |err| {
        try self.close(id, .framing_error);
        return err;
    };
}
