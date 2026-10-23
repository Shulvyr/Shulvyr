const std = @import("std");
const Description = @import("sdp/SessionDescription.zig");
const Fingerprint = @import("sdp/Fingerprint.zig");
const allocator = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const FingerprintResult = struct { algorithm: []const u8, digest_hex: []const u8, attribute_hex: []const u8, canonical_hex: []const u8 };
const Fixtures = struct {
    descriptions: []const struct {
        name: []const u8,
        input_hex: []const u8,
        parse_error: bool = false,
        normalized_hex: ?[]const u8 = null,
        line_count: usize = 0,
        identity_hex: ?[]const u8 = null,
        candidates: usize = 0,
        session_ufrag: []const []const u8 = &.{},
        media_ufrag: []const []const u8 = &.{},
        valid: bool = false,
        fingerprint: ?FingerprintResult = null,
        fingerprint_error: bool = false,
        maximum: ?u32 = null,
        maximum_error: bool = false,
    },
    edits: []const struct {
        name: []const u8,
        input_hex: []const u8,
        edit: []const u8,
        output_hex: []const u8,
        identity_hex: ?[]const u8 = null,
        candidates_hex: []const []const u8 = &.{},
        limit: usize = 0,
    },
    fingerprints: []const struct { name: []const u8, input_hex: []const u8, result: ?FingerprintResult = null, @"error": bool = false },
};

fn load() !std.json.Parsed(Fixtures) {
    return std.json.parseFromSlice(Fixtures, allocator, @embedFile("fixtures/sdp.json"), .{ .ignore_unknown_fields = true });
}

fn unhex(text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, text);
    return bytes;
}

fn equalHex(hex: []const u8, actual: []const u8) !void {
    const expected = try unhex(hex);
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

fn checkFingerprint(actual: Fingerprint, expected: FingerprintResult) !void {
    try std.testing.expectEqualStrings(expected.algorithm, actual.algorithm);
    try equalHex(expected.digest_hex, actual.digest);
    var output: [1024]u8 = undefined;
    try equalHex(expected.attribute_hex, try actual.writeAttribute(&output, output.len));
    try equalHex(expected.canonical_hex, try actual.writeCanonical(&output, output.len));
}

test "SDP normalization, attribute scopes and validation match the public Axolotl oracle" {
    const fixtures = try load();
    defer fixtures.deinit();
    try equal(@as(usize, 42), fixtures.value.descriptions.len);
    var storage: [1024][]const u8 = undefined;
    var output: [16 * 1024]u8 = undefined;
    for (fixtures.value.descriptions) |case| {
        const input = try unhex(case.input_hex);
        defer allocator.free(input);
        const parsed = Description.parse(input, &storage, .{});
        if (case.parse_error) {
            if (parsed) |_| return error.ExpectedOracleRejection else |_| continue;
        }
        const description = try parsed;
        try equal(case.line_count, description.lines.len);
        try equalHex(case.normalized_hex.?, try description.write(&output, .none, .{}));
        if (case.identity_hex) |value| try equalHex(value, description.identity().?) else try equal(null, description.identity());
        try equal(case.candidates, description.candidateCount());
        for ([_]Description.Scope{ .session, .media }) |scope| {
            const expected = if (scope == .session) case.session_ufrag else case.media_ufrag;
            var attributes = description.attributes("ice-ufrag", scope);
            for (expected) |value| try equalHex(value, attributes.next().?);
            try equal(null, attributes.next());
        }
        if (case.valid) {
            try description.validate();
        } else if (description.validate()) |_| return error.ExpectedOracleRejection else |_| {}
        if (case.fingerprint_error) {
            if (description.fingerprint()) |_| return error.ExpectedOracleRejection else |_| {}
        } else try checkFingerprint(try description.fingerprint(), case.fingerprint.?);
        if (case.maximum_error) {
            if (description.maxMessageSize()) |_| return error.ExpectedOracleRejection else |_| {}
        } else try equal(case.maximum.?, try description.maxMessageSize());
    }
}

test "SDP identity and candidate edits preserve the public Axolotl wire output" {
    const fixtures = try load();
    defer fixtures.deinit();
    try equal(@as(usize, 18), fixtures.value.edits.len);
    var storage: [1024][]const u8 = undefined;
    var output: [16 * 1024]u8 = undefined;
    for (fixtures.value.edits) |case| {
        const input = try unhex(case.input_hex);
        defer allocator.free(input);
        const identity = try unhex(case.identity_hex orelse "");
        defer allocator.free(identity);
        const candidates = try allocator.alloc([]const u8, case.candidates_hex.len);
        defer allocator.free(candidates);
        var populated: usize = 0;
        defer for (candidates[0..populated]) |candidate| allocator.free(candidate);
        for (case.candidates_hex, 0..) |hex, index| {
            candidates[index] = try unhex(hex);
            populated += 1;
        }
        const kind = std.meta.stringToEnum(std.meta.Tag(Description.Edit), case.edit) orelse return error.InvalidOracleEdit;
        const edit: Description.Edit = switch (kind) {
            .none => .none,
            .without_identity => .without_identity,
            .without_candidates => .without_candidates,
            .without_connection_address => .without_connection_address,
            .identity => .{ .identity = identity },
            .candidates => .{ .candidates = candidates },
            .candidate_limit => .{ .candidate_limit = case.limit },
        };
        const description = try Description.parse(input, &storage, .{});
        try equalHex(case.output_hex, try description.write(&output, edit, .{}));
    }
}

test "SDP fingerprint syntax and signed payload spelling match the independent oracle" {
    const fixtures = try load();
    defer fixtures.deinit();
    try equal(@as(usize, 17), fixtures.value.fingerprints.len);
    for (fixtures.value.fingerprints) |case| {
        const input = try unhex(case.input_hex);
        defer allocator.free(input);
        const parsed = Fingerprint.parse(input, 1024);
        if (case.@"error") {
            if (parsed) |_| return error.ExpectedOracleRejection else |_| continue;
        }
        try checkFingerprint(try parsed, case.result.?);
    }
}

test "SDP parse preflights byte, line, storage and alias bounds without mutation" {
    var storage: [8][]const u8 = @splat("kept");
    const input = "v=0\nm=x\n";
    try expectError(error.InvalidLimits, Description.parse(input, &storage, .{ .text_bytes = 0 }));
    try expectError(error.InvalidLimits, Description.parse(input, &storage, .{ .lines = 1025 }));
    try expectError(error.DescriptionTooLong, Description.parse(input, &storage, .{ .text_bytes = input.len - 1 }));
    try expectError(error.LineTooLong, Description.parse(input, &storage, .{ .line_bytes = 2 }));
    try expectError(error.TooManyLines, Description.parse(input, &storage, .{ .lines = 1 }));
    try expectError(error.NoSpace, Description.parse(input, storage[0..1], .{}));
    try expectError(error.EmptyDescription, Description.parse("\r\n", &storage, .{}));
    try expectError(error.AliasedBuffer, Description.parse(std.mem.asBytes(&storage), &storage, .{}));
    for (storage) |line| try std.testing.expectEqualStrings("kept", line);
    const exact = try Description.parse(input, storage[0..2], .{ .text_bytes = input.len, .lines = 2, .line_bytes = 3 });
    try equal(@as(usize, 2), exact.lines.len);
    try expect(exact.lines[0].ptr == input.ptr);
}

test "SDP writes preflight expansion, attribute insertion and all borrowed aliases" {
    var storage: [8][]const u8 = undefined;
    var description = try Description.parse("v=0\nm=x\n", &storage, .{});
    var output: [256]u8 = @splat(0xa5);
    const before = output;
    try expectError(error.NoSpace, description.write(output[0..9], .none, .{}));
    try expectError(error.DescriptionTooLong, description.write(&output, .none, .{ .text_bytes = 9 }));
    try expectError(error.LineTooLong, description.write(&output, .{ .identity = "x" }, .{ .line_bytes = 3 }));
    try expectError(error.TooManyLines, description.write(&output, .{ .identity = "x" }, .{ .lines = 2 }));
    try expectError(error.InvalidAttributeValue, description.write(&output, .{ .identity = "x\r\nm=x" }, .{}));
    try expectError(error.InvalidAttributeValue, description.write(&output, .{ .candidates = &.{"x\ny"} }, .{}));
    try expectError(error.AliasedBuffer, description.write(std.mem.asBytes(&description), .none, .{}));
    try expectError(error.AliasedBuffer, description.write(std.mem.asBytes(&storage), .none, .{}));
    try expectError(error.AliasedBuffer, description.write(&output, .{ .identity = output[0..1] }, .{}));
    const values = [_][]const u8{output[0..1]};
    try expectError(error.AliasedBuffer, description.write(&output, .{ .candidates = &values }, .{}));
    var descriptors: [4][]const u8 = @splat("candidate");
    try expectError(error.AliasedBuffer, description.write(std.mem.asBytes(&descriptors), .{ .candidates = descriptors[0..1] }, .{}));
    for (descriptors) |value| try std.testing.expectEqualStrings("candidate", value);
    try std.testing.expectEqualSlices(u8, &before, &output);
    @memcpy(output[0..8], "v=0\nm=x\n");
    description = try Description.parse(output[0..8], &storage, .{});
    try expectError(error.AliasedBuffer, description.write(&output, .none, .{}));
    try std.testing.expectEqualStrings("v=0\nm=x\n", output[0..8]);
}

test "SDP fingerprint byte conversion distinguishes syntax from a certificate digest" {
    const upper = try Fingerprint.parse("SHA-256 AB:CD", 128);
    const lower = try Fingerprint.parse("sha-256 ab:cd", 128);
    try expect(upper.equals(lower));
    try expectError(error.InvalidDigestLength, upper.sha256Bytes());
    try expectError(error.InvalidLimits, Fingerprint.parse("sha-256 AB", 0));
    try expectError(error.FingerprintTooLong, Fingerprint.parse("sha-256 AB", 9));
    var output: [256]u8 = @splat(0xa5);
    const before = output;
    try expectError(error.NoSpace, upper.writeCanonical(output[0..1], output.len));
    try expectError(error.FingerprintTooLong, upper.writeCanonical(&output, 8));
    try std.testing.expectEqualSlices(u8, &before, &output);
    var own = upper;
    try expectError(error.AliasedBuffer, own.writeAttribute(std.mem.asBytes(&own), 128));
    try expect(own.equals(upper));
    var alias: Fingerprint = .{ .algorithm = "sha-256", .digest = output[0..2] };
    @memcpy(output[0..2], "AB");
    const with_digest = output;
    try expectError(error.AliasedBuffer, alias.writeAttribute(&output, output.len));
    try std.testing.expectEqualSlices(u8, &with_digest, &output);
    @memcpy(&output, &before);
    const fixture = try load();
    defer fixture.deinit();
    const encoded = try unhex(fixture.value.fingerprints[0].input_hex);
    defer allocator.free(encoded);
    const complete = try Fingerprint.parse(encoded, 128);
    var expected: [32]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @intCast(index);
    try equal(expected, try complete.sha256Bytes());
}
