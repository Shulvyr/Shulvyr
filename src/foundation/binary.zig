const std = @import("std");

pub const ReadError = error{
    UnexpectedEnd,
    VarIntOverflow,
    NonCanonicalVarInt,
    StringTooLong,
    InvalidUtf8,
};

/// Borrows input bytes. Returned slices must not outlive the input.
/// Failed compound reads restore the cursor and never allocate.
pub const Reader = struct {
    input: []const u8,
    position: usize = 0,

    pub fn remaining(self: Reader) usize {
        return self.input.len - self.position;
    }

    pub fn bytes(self: *Reader, length: usize) ReadError![]const u8 {
        if (length > self.remaining()) return error.UnexpectedEnd;
        const start = self.position;
        self.position += length;
        return self.input[start..self.position];
    }

    pub fn integer(self: *Reader, comptime T: type, endian: std.builtin.Endian) ReadError!T {
        const data = try self.bytes(@sizeOf(T));
        return std.mem.readInt(T, data[0..@sizeOf(T)], endian);
    }

    pub fn varUInt(self: *Reader, comptime T: type) ReadError!T {
        comptime validateVarIntType(T);
        const start = self.position;
        errdefer self.position = start;
        const bits = @bitSizeOf(T);
        const count = (bits + 6) / 7;
        var value: T = 0;
        for (0..count) |index| {
            const byte = (try self.bytes(1))[0];
            const payload = byte & 0x7f;
            const shift = index * 7;
            const available = bits - shift;
            if (available < 7 and payload >= (@as(u8, 1) << @intCast(available))) {
                return error.VarIntOverflow;
            }
            value |= @as(T, payload) << @intCast(shift);
            if (byte & 0x80 == 0) {
                if (index != 0 and payload == 0) return error.NonCanonicalVarInt;
                return value;
            }
        }
        return error.VarIntOverflow;
    }

    pub fn varInt(self: *Reader, comptime T: type) ReadError!T {
        comptime validateSignedVarIntType(T);
        const U = @Int(.unsigned, @bitSizeOf(T));
        const value = try self.varUInt(U);
        return @bitCast((value >> 1) ^ (0 -% (value & 1)));
    }

    /// The u32 prefix is a byte length, not a Unicode code-point count.
    pub fn text(self: *Reader, maximum_bytes: usize) ReadError![]const u8 {
        const start = self.position;
        errdefer self.position = start;
        const length = try self.varUInt(u32);
        if (length > maximum_bytes) return error.StringTooLong;
        const value = try self.bytes(length);
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return value;
    }
};

pub const WriteError = error{ NoSpace, StringTooLong, InvalidUtf8 };

/// Borrows caller-owned storage. A failed write leaves bytes and cursor intact.
pub const Writer = struct {
    output: []u8,
    position: usize = 0,

    pub fn written(self: Writer) []const u8 {
        return self.output[0..self.position];
    }

    pub fn bytes(self: *Writer, value: []const u8) WriteError!void {
        if (value.len > self.output.len - self.position) return error.NoSpace;
        @memmove(self.output[self.position..][0..value.len], value);
        self.position += value.len;
    }

    pub fn integer(self: *Writer, comptime T: type, value: T, endian: std.builtin.Endian) WriteError!void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, endian);
        try self.bytes(&encoded);
    }

    pub fn varUInt(self: *Writer, comptime T: type, value: T) WriteError!void {
        comptime validateVarIntType(T);
        var encoded: [(@bitSizeOf(T) + 6) / 7]u8 = undefined;
        const length = encodeVarUInt(T, value, &encoded);
        try self.bytes(encoded[0..length]);
    }

    pub fn varInt(self: *Writer, comptime T: type, value: T) WriteError!void {
        comptime validateSignedVarIntType(T);
        const U = @Int(.unsigned, @bitSizeOf(T));
        const bits: U = @bitCast(value);
        const sign: U = @bitCast(value >> (@bitSizeOf(T) - 1));
        try self.varUInt(U, (bits << 1) ^ sign);
    }

    pub fn text(self: *Writer, value: []const u8, maximum_bytes: usize) WriteError!void {
        if (value.len > maximum_bytes or value.len > std.math.maxInt(u32)) return error.StringTooLong;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        var prefix: [5]u8 = undefined;
        const length = encodeVarUInt(u32, @intCast(value.len), &prefix);
        const space = self.output.len - self.position;
        if (length > space or value.len > space - length) return error.NoSpace;
        @memmove(self.output[self.position + length ..][0..value.len], value);
        @memcpy(self.output[self.position..][0..length], prefix[0..length]);
        self.position += length + value.len;
    }
};

fn validateVarIntType(comptime T: type) void {
    if (T != u32 and T != u64) @compileError("Variable integers require u32 or u64");
}

fn validateSignedVarIntType(comptime T: type) void {
    if (T != i32 and T != i64) @compileError("Signed variable integers require i32 or i64");
}

fn encodeVarUInt(comptime T: type, value: T, output: []u8) usize {
    var remaining = value;
    var length: usize = 0;
    while (true) {
        const low: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        output[length] = low | @as(u8, if (remaining != 0) 0x80 else 0);
        length += 1;
        if (remaining == 0) return length;
    }
}

test "independent unsigned encoding vectors" {
    const vectors = [_]struct { value: u64, bytes: []const u8 }{
        .{ .value = 0, .bytes = &.{0} },
        .{ .value = 127, .bytes = &.{0x7f} },
        .{ .value = 128, .bytes = &.{ 0x80, 0x01 } },
        .{ .value = 300, .bytes = &.{ 0xac, 0x02 } },
        .{ .value = 0xffffffff, .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f } },
        .{ .value = 0xffffffffffffffff, .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 } },
    };
    for (vectors) |vector| {
        var reader: Reader = .{ .input = vector.bytes };
        try std.testing.expectEqual(vector.value, try reader.varUInt(u64));
        try std.testing.expectEqual(0, reader.remaining());
        var storage: [10]u8 = undefined;
        var writer: Writer = .{ .output = &storage };
        try writer.varUInt(u64, vector.value);
        try std.testing.expectEqualSlices(u8, vector.bytes, writer.written());
    }
}

test "signed zigzag extremes have fixed wire bytes" {
    const vectors = [_]struct { value: i32, bytes: []const u8 }{
        .{ .value = 0, .bytes = &.{0} },
        .{ .value = -1, .bytes = &.{1} },
        .{ .value = 1, .bytes = &.{2} },
        .{ .value = std.math.minInt(i32), .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f } },
        .{ .value = std.math.maxInt(i32), .bytes = &.{ 0xfe, 0xff, 0xff, 0xff, 0x0f } },
    };
    for (vectors) |vector| {
        var reader: Reader = .{ .input = vector.bytes };
        try std.testing.expectEqual(vector.value, try reader.varInt(i32));
        var storage: [5]u8 = undefined;
        var writer: Writer = .{ .output = &storage };
        try writer.varInt(i32, vector.value);
        try std.testing.expectEqualSlices(u8, vector.bytes, writer.written());
    }
}

test "malformed variable integers roll back the cursor" {
    const vectors = [_]struct { bytes: []const u8, failure: ReadError }{
        .{ .bytes = &.{0x80}, .failure = error.UnexpectedEnd },
        .{ .bytes = &.{ 0x80, 0x00 }, .failure = error.NonCanonicalVarInt },
        .{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x10 }, .failure = error.VarIntOverflow },
        .{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80 }, .failure = error.VarIntOverflow },
    };
    for (vectors) |vector| {
        var reader: Reader = .{ .input = vector.bytes };
        try std.testing.expectError(vector.failure, reader.varUInt(u32));
        try std.testing.expectEqual(0, reader.position);
    }
}

test "fixed endian vectors and truncated integers" {
    var reader: Reader = .{ .input = &.{ 0x12, 0x34, 0xfe, 0xff } };
    try std.testing.expectEqual(@as(u16, 0x1234), try reader.integer(u16, .big));
    try std.testing.expectEqual(@as(i16, -2), try reader.integer(i16, .little));
    try std.testing.expectError(error.UnexpectedEnd, reader.integer(u32, .big));
    try std.testing.expectEqual(4, reader.position);
    var storage: [4]u8 = undefined;
    var writer: Writer = .{ .output = &storage };
    try writer.integer(u16, 0x1234, .big);
    try writer.integer(i16, -2, .little);
    try std.testing.expectEqualSlices(u8, reader.input, writer.written());
}

test "text validates byte budgets and UTF-8 without consuming failed input" {
    var reader: Reader = .{ .input = &.{ 2, 0xc3, 0xa9, 0 } };
    try std.testing.expectError(error.StringTooLong, reader.text(1));
    try std.testing.expectEqual(0, reader.position);
    try std.testing.expectEqualStrings("\xc3\xa9", try reader.text(2));
    try std.testing.expectEqualStrings("", try reader.text(0));
    var invalid: Reader = .{ .input = &.{ 2, 0xc0, 0x80 } };
    try std.testing.expectError(error.InvalidUtf8, invalid.text(2));
    try std.testing.expectEqual(0, invalid.position);
    var short: Reader = .{ .input = &.{ 2, 0x61 } };
    try std.testing.expectError(error.UnexpectedEnd, short.text(2));
    try std.testing.expectEqual(0, short.position);
    try std.testing.expectError(error.UnexpectedEnd, short.bytes(std.math.maxInt(usize)));
}

test "failed writes preserve the entire destination" {
    var storage: [3]u8 = @splat(0xaa);
    var writer: Writer = .{ .output = &storage };
    try writer.bytes(&.{0x42});
    try std.testing.expectError(error.NoSpace, writer.varUInt(u64, std.math.maxInt(u64)));
    try std.testing.expectError(error.NoSpace, writer.text("hi", 2));
    try std.testing.expectError(error.InvalidUtf8, writer.text("\xff", 1));
    try std.testing.expectError(error.StringTooLong, writer.text("hi", 1));
    try std.testing.expectEqual(1, writer.position);
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0xaa, 0xaa }, &storage);
}

test "u64 final-byte overflow and i64 minimum" {
    var overflow: Reader = .{ .input = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2 } };
    try std.testing.expectError(error.VarIntOverflow, overflow.varUInt(u64));
    var storage: [10]u8 = undefined;
    var writer: Writer = .{ .output = &storage };
    try writer.varInt(i64, std.math.minInt(i64));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1 }, writer.written());
    var reader: Reader = .{ .input = writer.written() };
    try std.testing.expectEqual(std.math.minInt(i64), try reader.varInt(i64));
}

test "in-place text encoding preserves overlapping input" {
    var storage = [_]u8{ 'a', 'b', 'c', 0 };
    var writer: Writer = .{ .output = &storage };
    try writer.text(storage[0..3], 3);
    try std.testing.expectEqualSlices(u8, &.{ 3, 'a', 'b', 'c' }, writer.written());
    var empty: [1]u8 = undefined;
    writer = .{ .output = &empty };
    try writer.text("", 0);
    try std.testing.expectEqualSlices(u8, &.{0}, writer.written());
}
