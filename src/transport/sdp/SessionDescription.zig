const std = @import("std");
const Fingerprint = @import("Fingerprint.zig");
const buffer = @import("../buffer.zig");
const Description = @This();

pub const max_lines = 1024;
pub const Limits = struct {
    text_bytes: usize = 16 * 1024,
    line_bytes: usize = 16 * 1024,
    lines: usize = max_lines,

    fn validate(self: Limits) !void {
        if (self.text_bytes == 0 or self.line_bytes == 0 or self.lines == 0 or self.lines > max_lines) return error.InvalidLimits;
    }
};
pub const Scope = enum { session, media, all };
pub const Edit = union(enum) {
    none,
    without_identity,
    without_candidates,
    without_connection_address,
    candidates: []const []const u8,
    candidate_limit: usize,
    identity: []const u8,
};

/// Both source and the descriptor storage remain borrowed and immutable for the
/// view's lifetime. Parse or write does not allocate or retain native objects.
source: []const u8,
lines: []const []const u8,
media_start: usize,
limits: Limits,

/// Normalizes CRLF, bare CR and LF by borrowing nonempty lines. A failed parse
/// leaves the descriptor storage unchanged. Byte/line limits precede mutation.
pub fn parse(text: []const u8, storage: [][]const u8, limits: Limits) !Description {
    try limits.validate();
    if (text.len > limits.text_bytes) return error.DescriptionTooLong;
    if (buffer.overlaps(text, std.mem.sliceAsBytes(storage))) return error.AliasedBuffer;
    var count: usize = 0;
    var scan = std.mem.tokenizeAny(u8, text, "\r\n");
    while (scan.next()) |line| {
        if (count == limits.lines) return error.TooManyLines;
        if (line.len > limits.line_bytes) return error.LineTooLong;
        count += 1;
    }
    if (count == 0) return error.EmptyDescription;
    if (count > storage.len) return error.NoSpace;
    var result: Description = .{ .source = text, .lines = storage[0..count], .media_start = count, .limits = limits };
    scan = std.mem.tokenizeAny(u8, text, "\r\n");
    for (storage[0..count], 0..) |*slot, index| {
        slot.* = scan.next().?;
        if (result.media_start == count and std.mem.startsWith(u8, slot.*, "m=")) result.media_start = index;
    }
    return result;
}

pub const Attributes = struct {
    remaining: []const []const u8,
    name: []const u8,

    pub fn next(self: *Attributes) ?[]const u8 {
        while (self.remaining.len != 0) {
            const line = self.remaining[0];
            self.remaining = self.remaining[1..];
            if (!std.mem.startsWith(u8, line, "a=")) continue;
            const rest = line[2..];
            if (rest.len > self.name.len and rest[self.name.len] == ':' and std.mem.startsWith(u8, rest, self.name)) return rest[self.name.len + 1 ..];
        }
        return null;
    }
};

pub fn attributes(self: Description, name: []const u8, scope: Scope) Attributes {
    return .{ .name = name, .remaining = switch (scope) {
        .session => self.lines[0..self.media_start],
        .media => self.lines[self.media_start..],
        .all => self.lines,
    } };
}

pub fn fingerprint(self: Description) !Fingerprint {
    var values = self.attributes("fingerprint", .media);
    const first = values.next() orelse blk: {
        values = self.attributes("fingerprint", .session);
        break :blk values.next() orelse return error.MissingFingerprint;
    };
    if (values.next() != null) return error.DuplicateFingerprint;
    return Fingerprint.parse(first, self.limits.line_bytes);
}

pub fn maxMessageSize(self: Description) !u32 {
    var values = self.attributes("max-message-size", .media);
    const text = values.next() orelse return error.MissingMaxMessageSize;
    if (values.next() != null) return error.DuplicateMaxMessageSize;
    if (text.len == 0) return error.InvalidMaxMessageSize;
    var value: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidMaxMessageSize;
        value = std.math.mul(u32, value, 10) catch return error.InvalidMaxMessageSize;
        value = std.math.add(u32, value, byte - '0') catch return error.InvalidMaxMessageSize;
    }
    if (value <= 1) return error.InvalidMaxMessageSize;
    return value;
}

pub fn identity(self: Description) ?[]const u8 {
    var values = self.attributes("identity", .session);
    return values.next();
}

pub fn candidateCount(self: Description) usize {
    var values = self.attributes("candidate", .all);
    var count: usize = 0;
    while (values.next() != null) count += 1;
    return count;
}

/// Structural validation only. Empty required ICE values are present according
/// to the reference, but this is not native SDP, identity or DTLS validation.
pub fn validate(self: Description) !void {
    var media: usize = 0;
    for (self.lines) |line| if (std.mem.startsWith(u8, line, "m=")) {
        media += 1;
    };
    if (media != 1) return error.InvalidMediaSections;
    for ([_][]const u8{ "ice-ufrag", "ice-pwd", "setup", "max-message-size" }) |name| {
        var values = self.attributes(name, .media);
        if (values.next() == null) return error.MissingMediaAttribute;
    }
    _ = try self.fingerprint();
    _ = try self.maxMessageSize();
}

const Parts = struct { prefix: []const u8 = "", text: []const u8 };
const Stream = struct {
    description: *const Description,
    edit: Edit,
    position: usize = 0,
    inserted: bool = false,
    extra: usize = 0,
    candidates: usize = 0,

    fn next(self: *Stream) ?Parts {
        const lines = self.description.lines;
        while (true) {
            if (!self.inserted) switch (self.edit) {
                .identity => |value| if (self.position == self.description.media_start) {
                    self.inserted = true;
                    return .{ .prefix = "a=identity:", .text = value };
                },
                .candidates => if (self.position == lines.len or std.mem.startsWith(u8, lines[self.position], "a=candidate:") or std.mem.eql(u8, lines[self.position], "a=end-of-candidates")) {
                    self.inserted = true;
                },
                else => {},
            };
            if (self.inserted and self.edit == .candidates and self.extra < self.edit.candidates.len) {
                const value = self.edit.candidates[self.extra];
                self.extra += 1;
                return .{ .prefix = "a=candidate:", .text = value };
            }
            if (self.position == lines.len) return null;
            const line = lines[self.position];
            self.position += 1;
            switch (self.edit) {
                .without_identity, .identity => if (std.mem.startsWith(u8, line, "a=identity:")) continue,
                .without_candidates => if (std.mem.startsWith(u8, line, "a=candidate:") or std.mem.eql(u8, line, "a=end-of-candidates")) continue,
                .candidates => if (std.mem.startsWith(u8, line, "a=candidate:")) continue,
                .candidate_limit => |limit| if (std.mem.startsWith(u8, line, "a=candidate:")) {
                    self.candidates += 1;
                    if (self.candidates > limit) continue;
                },
                .without_connection_address => if (std.mem.startsWith(u8, line, "c=")) return .{ .text = "c=IN IP4 0.0.0.0" },
                .none => {},
            }
            return .{ .text = line };
        }
    }
};

fn addedValue(value: []const u8, prefix: []const u8, limits: Limits) !void {
    if (prefix.len > limits.line_bytes or value.len > limits.line_bytes - prefix.len) return error.LineTooLong;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidAttributeValue;
}

/// Writes one reference transformation with CRLF and a final CRLF. Reparse into
/// separate storage to chain edits. Added attribute values must be single lines.
/// The written region must not overlap input, descriptors, edit data or this view.
/// Every failure leaves output unchanged. Output may contain credentials.
pub fn write(self: *const Description, output: []u8, edit: Edit, limits: Limits) ![]const u8 {
    try limits.validate();
    switch (edit) {
        .identity => |value| try addedValue(value, "a=identity:", limits),
        .candidates => |values| {
            if (values.len > limits.lines) return error.TooManyLines;
            for (values) |value| try addedValue(value, "a=candidate:", limits);
        },
        else => {},
    }
    var count: usize = 0;
    var needed: usize = 0;
    var stream: Stream = .{ .description = self, .edit = edit };
    while (stream.next()) |parts| {
        if (count == limits.lines) return error.TooManyLines;
        count += 1;
        const length = std.math.add(usize, parts.prefix.len, parts.text.len) catch return error.LineTooLong;
        if (length > limits.line_bytes) return error.LineTooLong;
        const terminated = std.math.add(usize, length, 2) catch return error.DescriptionTooLong;
        needed = std.math.add(usize, needed, terminated) catch return error.DescriptionTooLong;
        if (needed > limits.text_bytes) return error.DescriptionTooLong;
    }
    if (count == 0) needed = 2; // The reference serializes an empty line list as CRLF.
    if (needed > limits.text_bytes) return error.DescriptionTooLong;
    if (needed > output.len) return error.NoSpace;
    const destination = output[0..needed];
    if (buffer.overlaps(destination, self.source) or buffer.overlaps(destination, std.mem.sliceAsBytes(self.lines)) or buffer.overlaps(destination, std.mem.asBytes(self))) return error.AliasedBuffer;
    switch (edit) {
        .identity => |value| if (buffer.overlaps(destination, value)) return error.AliasedBuffer,
        .candidates => |values| {
            if (buffer.overlaps(destination, std.mem.sliceAsBytes(values))) return error.AliasedBuffer;
            for (values) |value| if (buffer.overlaps(destination, value)) return error.AliasedBuffer;
        },
        else => {},
    }
    stream = .{ .description = self, .edit = edit };
    var position: usize = 0;
    while (stream.next()) |parts| {
        for ([_][]const u8{ parts.prefix, parts.text, "\r\n" }) |part| {
            @memcpy(destination[position..][0..part.len], part);
            position += part.len;
        }
    }
    if (count == 0) @memcpy(destination, "\r\n");
    return destination;
}
