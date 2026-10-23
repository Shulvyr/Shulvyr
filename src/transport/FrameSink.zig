const framing = @import("framing.zig");
const Session = @import("Session.zig");
const FrameSink = @This();

pub const Error = error{ Closed, Failed };
pub const Admission = enum { accepted, blocked };

session_id: Session.Id,
context: *anyopaque,
buffered: *const fn (*anyopaque, framing.Channel) Error!u64,
send: *const fn (*anyopaque, framing.Channel, []const u8) Error!Admission,

/// The single producer's current channel queue size. This does not represent
/// all transport memory or prove remote delivery. Control traffic may add bytes.
pub fn bufferedAmount(self: FrameSink, channel: framing.Channel) Error!u64 {
    return self.buffered(self.context, channel);
}

/// Accepted means the complete frame was copied before returning. Blocked
/// accepts nothing and may be retried. Errors are terminal for the session.
/// The sink must not reenter the outbox or retain the borrowed frame pointer.
pub fn trySend(self: FrameSink, channel: framing.Channel, frame: []const u8) Error!Admission {
    return self.send(self.context, channel, frame);
}
