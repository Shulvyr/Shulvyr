const std = @import("std");
const buffer = @import("buffer.zig");

const Signal = @This();

pub const Kind = enum {
    CONNECTREQUEST,
    CONNECTRESPONSE,
    CANDIDATEADD,
    CONNECTERROR,
};

pub const Limits = struct {
    text_bytes: usize = 65535,
    data_bytes: usize = 16 * 1024,

    fn validate(self: Limits) error{InvalidLimits}!void {
        if (self.text_bytes == 0 or self.data_bytes > self.text_bytes) return error.InvalidLimits;
    }
};

kind: Kind,
connection_id: u64,
/// Borrows the input. Copy it before queueing or retaining beyond that input.
/// SDP and candidate data may contain credentials. Never log the text.
data: []const u8,

/// Parses the first two literal spaces. Data is opaque and may be empty.
/// Connection IDs use their leading decimal digits, matching the selected
/// upstream behavior. A suffix is ignored, leading zeroes are normalized.
/// Resource limits are checked before scans and no allocation is performed.
pub fn parse(text: []const u8, limits: Limits) !Signal {
    try limits.validate();
    if (text.len > limits.text_bytes) return error.TextTooLong;
    const first = std.mem.indexOfScalar(u8, text, ' ') orelse return error.MissingFields;
    const rest = text[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MissingFields;
    const kind = std.meta.stringToEnum(Kind, text[0..first]) orelse return error.UnknownKind;
    const field = rest[0..second];
    var digits: usize = 0;
    var id: u64 = 0;
    for (field) |byte| {
        if (byte < '0' or byte > '9') break;
        id = std.math.mul(u64, id, 10) catch return error.ConnectionIdOverflow;
        id = std.math.add(u64, id, byte - '0') catch return error.ConnectionIdOverflow;
        digits += 1;
    }
    if (digits == 0) return error.InvalidConnectionId;
    const data = rest[second + 1 ..];
    if (data.len > limits.data_bytes) return error.DataTooLong;
    return .{ .kind = kind, .connection_id = id, .data = data };
}

/// Writes a canonical decimal ID into caller storage. The returned view borrows
/// output. On failure output stays unchanged. It must not overlap this signal
/// or its borrowed data. Payload meaning is validated by the negotiation layer.
pub fn write(self: *const Signal, output: []u8, limits: Limits) ![]const u8 {
    try limits.validate();
    if (self.data.len > limits.data_bytes) return error.DataTooLong;
    var header: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&header, "{s} {d} ", .{ @tagName(self.kind), self.connection_id }) catch unreachable;
    if (prefix.len > limits.text_bytes or self.data.len > limits.text_bytes - prefix.len) return error.TextTooLong;
    const needed = prefix.len + self.data.len;
    if (needed > output.len) return error.NoSpace;
    const destination = output[0..needed];
    if (buffer.overlaps(destination, self.data) or buffer.overlaps(destination, std.mem.asBytes(self))) return error.AliasedBuffer;
    @memcpy(destination[0..prefix.len], prefix);
    @memcpy(destination[prefix.len..], self.data);
    return destination;
}
