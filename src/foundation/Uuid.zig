const std = @import("std");
const binary = @import("binary.zig");
const Uuid = @This();

/// Canonical most-significant-byte-first representation, independent of host ABI.
bytes: [16]u8,

pub const nil: Uuid = .{ .bytes = @splat(0) };
pub const max: Uuid = .{ .bytes = @splat(0xff) };

/// Accepts canonical 8-4-4-4-12 hexadecimal text, in either case.
/// All 128-bit values are preserved, including nil, max and reserved versions.
pub fn parse(text: []const u8) error{InvalidUuid}!Uuid {
    if (text.len != 36) return error.InvalidUuid;
    var result: Uuid = undefined;
    var position: usize = 0;
    for (&result.bytes) |*byte| {
        if (position == 8 or position == 13 or position == 18 or position == 23) {
            if (text[position] != '-') return error.InvalidUuid;
            position += 1;
        }
        byte.* = (try nibble(text[position])) << 4 | try nibble(text[position + 1]);
        position += 2;
    }
    return result;
}

pub fn toString(self: Uuid) [36]u8 {
    const digits = "0123456789abcdef";
    var text: [36]u8 = undefined;
    var position: usize = 0;
    for (self.bytes) |byte| {
        if (position == 8 or position == 13 or position == 18 or position == 23) {
            text[position] = '-';
            position += 1;
        }
        text[position] = digits[byte >> 4];
        text[position + 1] = digits[byte & 15];
        position += 2;
    }
    return text;
}

pub fn eql(self: Uuid, other: Uuid) bool {
    return std.mem.eql(u8, &self.bytes, &other.bytes);
}

/// Sets RFC 9562 version/variant bits in caller-supplied random bytes.
/// The caller owns entropy selection. This function does not access an RNG.
pub fn v4(random_bytes: [16]u8) Uuid {
    var result: Uuid = .{ .bytes = random_bytes };
    result.bytes[6] = (result.bytes[6] & 0x0f) | 0x40;
    result.bytes[8] = (result.bytes[8] & 0x3f) | 0x80;
    return result;
}

/// Bedrock encodes bytes 7..0 followed by 15..8, as two little-endian u64 words.
pub fn readBedrock(reader: *binary.Reader) binary.ReadError!Uuid {
    const wire = try reader.bytes(16);
    var result: Uuid = undefined;
    for (0..8) |i| {
        result.bytes[i] = wire[7 - i];
        result.bytes[8 + i] = wire[15 - i];
    }
    return result;
}

/// A failed write preserves both destination bytes and cursor.
pub fn writeBedrock(self: Uuid, writer: *binary.Writer) binary.WriteError!void {
    var wire: [16]u8 = undefined;
    for (0..8) |i| {
        wire[i] = self.bytes[7 - i];
        wire[8 + i] = self.bytes[15 - i];
    }
    try writer.bytes(&wire);
}

fn nibble(byte: u8) error{InvalidUuid}!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidUuid,
    };
}

test "UUID canonical bytes case normalization nil and max" {
    const uuid = try parse("00112233-4455-6677-8899-AABBCCDDEEFF");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }, &uuid.bytes);
    try std.testing.expectEqualStrings("00112233-4455-6677-8899-aabbccddeeff", &uuid.toString());
    try std.testing.expect(nil.eql(try parse("00000000-0000-0000-0000-000000000000")));
    try std.testing.expect(max.eql(try parse("ffffffff-ffff-ffff-ffff-ffffffffffff")));
}

test "UUID RFC 9562 appendix A.3 version four vector" {
    const random = (try parse("919108f7-52d1-3320-5bac-f847db4148a8")).bytes;
    try std.testing.expectEqualStrings("919108f7-52d1-4320-9bac-f847db4148a8", &v4(random).toString());
}

test "UUID rejects malformed text without accepting alternate wrappers" {
    for ([_][]const u8{ "", "00112233445566778899aabbccddeeff", "00112233_4455-6677-8899-aabbccddeeff", "00112233-4455-6677-8899-aabbccddeefg", "{00112233-4455-6677-8899-aabbccddeeff}", "00112233-4455-6677-8899-aabbccddeeff\n" }) |text|
        try std.testing.expectError(error.InvalidUuid, parse(text));
    var invalid = (try parse("00112233-4455-6677-8899-aabbccddeeff")).toString();
    for (0..invalid.len) |index| {
        const saved = invalid[index];
        invalid[index] = 0xff;
        try std.testing.expectError(error.InvalidUuid, parse(&invalid));
        invalid[index] = saved;
    }
}

test "UUID Bedrock wire vector and failed buffer operations" {
    const uuid = try parse("00112233-4455-6677-8899-aabbccddeeff");
    const expected = [_]u8{ 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88 };
    var output: [17]u8 = @splat(0xaa);
    var writer: binary.Writer = .{ .output = &output, .position = 1 };
    try uuid.writeBedrock(&writer);
    try std.testing.expectEqualSlices(u8, &expected, output[1..]);
    const saved = output;
    writer.position = 2;
    try std.testing.expectError(error.NoSpace, uuid.writeBedrock(&writer));
    try std.testing.expectEqualSlices(u8, &saved, &output);
    try std.testing.expectEqual(2, writer.position);
    var reader: binary.Reader = .{ .input = &output, .position = 1 };
    try std.testing.expect(uuid.eql(try readBedrock(&reader)));
    try std.testing.expectEqual(17, reader.position);
    for (0..16) |length| {
        reader = .{ .input = output[0 .. length + 1], .position = 1 };
        try std.testing.expectError(error.UnexpectedEnd, readBedrock(&reader));
        try std.testing.expectEqual(1, reader.position);
    }
}
