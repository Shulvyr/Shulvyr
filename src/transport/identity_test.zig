const std = @import("std");
const Assertion = @import("identity/Assertion.zig");
const PublicKey = @import("identity/PublicKey.zig");
const codec = @import("identity/codec.zig");
const Description = @import("sdp/SessionDescription.zig");
const Payload = @import("sdp/FingerprintPayload.zig");
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Fixtures = struct {
    keys: []const struct { name: []const u8, claim: std.json.Value, der_hex: ?[]const u8 = null, digest_hex: ?[]const u8 = null, @"error": bool = false },
    assertions: []const struct {
        name: []const u8,
        attribute: []const u8,
        payload_hex: []const u8,
        domain: ?[]const u8 = null,
        token: ?[]const u8 = null,
        key_digest_hex: ?[]const u8 = null,
        token_signed: bool = false,
        parse_error: bool = false,
        proof_error: bool = false,
        proof_valid: bool = false,
    },
    timestamps: []const struct { name: []const u8, attribute: []const u8, now: i64, leeway: u32, valid: bool },
};

fn load() !std.json.Parsed(Fixtures) {
    return std.json.parseFromSlice(Fixtures, allocator, @embedFile("fixtures/identity.json"), .{ .ignore_unknown_fields = true });
}

fn unhex(hex: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(result);
    return std.fmt.hexToBytes(result, hex);
}

fn equalHex(hex: []const u8, actual: []const u8) !void {
    const expected = try unhex(hex);
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

fn base64(comptime url: bool, value: []const u8) ![]u8 {
    const encoder = if (url) std.base64.url_safe_no_pad.Encoder else std.base64.standard.Encoder;
    const result = try allocator.alloc(u8, encoder.calcSize(value.len));
    _ = encoder.encode(result, value);
    return result;
}

fn envelope(token: []const u8, proof: []const u8) ![]u8 {
    const inner = try std.json.Stringify.valueAlloc(allocator, .{ .token = token, .fingerprints = proof }, .{});
    defer allocator.free(inner);
    const outer = try std.json.Stringify.valueAlloc(allocator, .{ .assertion = inner, .idp = .{ .domain = "synthetic.example", .protocol = "default" } }, .{});
    defer allocator.free(outer);
    return base64(false, outer);
}

fn proofFrom(attribute: []const u8) ![]u8 {
    const decoded = try allocator.alloc(u8, attribute.len);
    defer allocator.free(decoded);
    const outer = try std.json.parseFromSlice(std.json.Value, allocator, try codec.decode(decoded, attribute, false), .{});
    defer outer.deinit();
    const inner = try std.json.parseFromSlice(std.json.Value, allocator, try codec.text(try codec.field(outer.value, "assertion")), .{});
    defer inner.deinit();
    return allocator.dupe(u8, try codec.text(try codec.field(inner.value, "fingerprints")));
}

test "identity keys match independent SPKI, JWK and compressed-key oracle results" {
    const fixtures = try load();
    defer fixtures.deinit();
    try std.testing.expectEqual(12, fixtures.value.keys.len);
    for (fixtures.value.keys) |case| {
        if (case.@"error") {
            if (PublicKey.fromClaim(case.claim)) |_| return error.ExpectedOracleRejection else |_| {}
        } else {
            const key = try PublicKey.fromClaim(case.claim);
            try equalHex(case.der_hex.?, key.derBytes());
            try equalHex(case.digest_hex.?, &key.digest());
        }
    }
    const der_key = try PublicKey.fromClaim(fixtures.value.keys[0].claim);
    const jwk_key = try PublicKey.fromClaim(fixtures.value.keys[1].claim);
    const compressed = try PublicKey.fromClaim(fixtures.value.keys[2].claim);
    try expect(der_key.equals(&jwk_key));
    try expect(!der_key.equals(&compressed));
    try std.testing.expectEqualSlices(u8, &der_key.key.toUncompressedSec1(), &compressed.key.toUncompressedSec1());
}

test "identity assertions and detached proofs match independent public API oracles" {
    const fixtures = try load();
    defer fixtures.deinit();
    try std.testing.expectEqual(26, fixtures.value.assertions.len);
    for (fixtures.value.assertions) |case| {
        var assertion = Assertion.parse(allocator, case.attribute, .{}) catch |err| {
            if (!case.parse_error and !case.proof_error) return err;
            continue;
        };
        defer assertion.deinit();
        try expect(!case.parse_error and !case.proof_error);
        try std.testing.expectEqualStrings(case.domain.?, assertion.domain);
        try std.testing.expectEqualStrings(case.token.?, assertion.token.compact);
        try equalHex(case.key_digest_hex.?, &assertion.token.public_key.digest());
        try expect(case.token_signed);
        try assertion.token.verifyEs384(&assertion.token.public_key);
        const payload = try unhex(case.payload_hex);
        defer allocator.free(payload);
        if (case.proof_valid) try assertion.verifyFingerprint(payload) else try expectError(error.IdentitySignatureMismatch, assertion.verifyFingerprint(payload));
    }
}

test "identity timestamp checks match the reference leeway and fractional boundaries" {
    const fixtures = try load();
    defer fixtures.deinit();
    try std.testing.expectEqual(15, fixtures.value.timestamps.len);
    for (fixtures.value.timestamps) |case| {
        var assertion = try Assertion.parse(allocator, case.attribute, .{});
        defer assertion.deinit();
        if (case.valid) try assertion.token.checkTimestamps(case.now, case.leeway) else if (assertion.token.checkTimestamps(case.now, case.leeway)) |_| return error.ExpectedOracleRejection else |_| {}
    }
}

test "identity parsing owns retained bytes and releases its single allocation" {
    const fixtures = try load();
    defer fixtures.deinit();
    const attribute = try allocator.dupe(u8, fixtures.value.assertions[0].attribute);
    defer allocator.free(attribute);
    var backing: [128 * 1024]u8 = @splat(0xaa);
    var fixed: std.heap.FixedBufferAllocator = .init(&backing);
    var assertion = try Assertion.parse(fixed.allocator(), attribute, .{});
    @memset(attribute, 0);
    try assertion.token.verifyEs384(&assertion.token.public_key);
    const payload = try unhex(fixtures.value.assertions[0].payload_hex);
    defer allocator.free(payload);
    try assertion.verifyFingerprint(payload);
    assertion.deinit();
    // Allocator.free marks memory undefined after the explicit scrub. Check
    // ownership release instead of reading memory after its allocation ends.
    try std.testing.expectEqual(0, fixed.end_index);
    @memset(&backing, 0xaa);
    if (Assertion.parse(fixed.allocator(), "not base64", .{})) |_| return error.ExpectedRejection else |_| {}
    try std.testing.expectEqual(0, fixed.end_index);
}

fn allocationFailure(gpa: std.mem.Allocator, attribute: []const u8) !void {
    var assertion = try Assertion.parse(gpa, attribute, .{});
    defer assertion.deinit();
    try assertion.token.verifyEs384(&assertion.token.public_key);
}

test "identity parsing handles allocation failure and all configured resource limits" {
    const fixtures = try load();
    defer fixtures.deinit();
    const attribute = fixtures.value.assertions[0].attribute;
    var exact = try Assertion.parse(allocator, attribute, .{ .attribute_bytes = attribute.len });
    exact.deinit();
    try expectError(error.IdentityBytesLimit, Assertion.parse(std.testing.failing_allocator, attribute, .{ .attribute_bytes = attribute.len - 1 }));
    try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{attribute});
    try expectError(error.IdentityBytesLimit, Assertion.parse(std.testing.failing_allocator, attribute, .{ .attribute_bytes = 1 }));
    try expectError(error.OutOfMemory, Assertion.parse(std.testing.failing_allocator, attribute, .{}));
    try expectError(error.IdentityStorageLimit, Assertion.parse(allocator, attribute, .{ .storage_bytes = 1 }));
    try expectError(error.IdentityBytesLimit, Assertion.parse(allocator, attribute, .{ .json_bytes = 1 }));
    try expectError(error.IdentityBytesLimit, Assertion.parse(allocator, attribute, .{ .token_bytes = 1 }));
    try expectError(error.IdentityBytesLimit, Assertion.parse(allocator, attribute, .{ .decoded_bytes = 1 }));
    try expectError(error.IdentityTokensLimit, Assertion.parse(allocator, attribute, .{ .json_tokens = 1 }));
    try expectError(error.IdentityDepthLimit, Assertion.parse(allocator, attribute, .{ .json_depth = 1 }));
    try expectError(error.InvalidLimits, Assertion.parse(allocator, attribute, .{ .json_depth = 33 }));
    try expectError(error.InvalidLimits, Assertion.parse(allocator, attribute, .{ .attribute_bytes = 0 }));
    var scratch: [16 * 1024]u8 = undefined;
    var decoded_total = (try codec.decode(&scratch, attribute, false)).len;
    for (try codec.segments(fixtures.value.assertions[0].token.?)) |part| decoded_total += (try codec.decode(&scratch, part, true)).len;
    const proof = try proofFrom(attribute);
    defer allocator.free(proof);
    const proof_parts = try codec.segments(proof);
    decoded_total += (try codec.decode(&scratch, proof_parts[0], true)).len;
    decoded_total += (try codec.decode(&scratch, proof_parts[2], true)).len;
    const public_key = try PublicKey.fromClaim(fixtures.value.keys[0].claim);
    decoded_total += public_key.derBytes().len;
    var exact_decoded = try Assertion.parse(allocator, attribute, .{ .decoded_bytes = decoded_total });
    exact_decoded.deinit();
    try expectError(error.IdentityBytesLimit, Assertion.parse(allocator, attribute, .{ .decoded_bytes = decoded_total - 1 }));
    var assertion = try Assertion.parse(allocator, attribute, .{ .fingerprint_payload_bytes = 1 });
    defer assertion.deinit();
    try expectError(error.IdentityBytesLimit, assertion.verifyFingerprint("too long"));
}

test "identity boundary rejects duplicate JSON fields and unsupported protected headers" {
    const fixtures = try load();
    defer fixtures.deinit();
    const duplicate = try base64(false, "{\"idp\":{\"domain\":\"synthetic\",\"do\\u006dain\":\"duplicate\",\"protocol\":\"default\"},\"assertion\":\"{}\"}");
    defer allocator.free(duplicate);
    try expectError(error.DuplicateField, Assertion.parse(allocator, duplicate, .{}));
    const original = fixtures.value.assertions[0];
    const proof = try proofFrom(original.attribute);
    defer allocator.free(proof);
    const parts = try codec.segments(proof);
    for ([_][]const u8{ "{\"alg\":\"ES384\",\"crit\":[\"unknown\"]}", "{\"alg\":\"ES384\",\"b64\":false}" }) |header| {
        const encoded_header = try base64(true, header);
        defer allocator.free(encoded_header);
        const changed_proof = try std.mem.concat(allocator, u8, &.{ encoded_header, "..", parts[2] });
        defer allocator.free(changed_proof);
        const changed = try envelope(original.token.?, changed_proof);
        defer allocator.free(changed);
        try expectError(error.UnsupportedIdentityHeader, Assertion.parse(allocator, changed, .{}));
    }
    var claim = try PublicKey.fromClaim(fixtures.value.keys[0].claim);
    var der: [121]u8 = @splat(0);
    @memcpy(der[0..120], claim.derBytes());
    try expectError(error.InvalidPublicKeyEncoding, PublicKey.fromDer(&der));
    der[2] = 0x31;
    try expectError(error.InvalidPublicKeyEncoding, PublicKey.fromDer(der[0..120]));
}

test "fingerprint possession does not authenticate forged token claims or algorithms" {
    const fixtures = try load();
    defer fixtures.deinit();
    const original = fixtures.value.assertions[0];
    const proof = try proofFrom(original.attribute);
    defer allocator.free(proof);
    const token_parts = try codec.segments(original.token.?);
    var buffer: [8192]u8 = undefined;
    const raw = try codec.decode(&buffer, token_parts[1], true);
    const claims = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer claims.deinit();
    var forged_claims = claims.value;
    try forged_claims.object.put(claims.arena.allocator(), "synthetic_account", .{ .string = "unverified" });
    const encoded_claims = try std.json.Stringify.valueAlloc(allocator, forged_claims, .{});
    defer allocator.free(encoded_claims);
    const claim_part = try base64(true, encoded_claims);
    defer allocator.free(claim_part);
    const forged_token = try std.mem.concat(allocator, u8, &.{ token_parts[0], ".", claim_part, ".", token_parts[2] });
    defer allocator.free(forged_token);
    const changed = try envelope(forged_token, proof);
    defer allocator.free(changed);
    var assertion = try Assertion.parse(allocator, changed, .{});
    defer assertion.deinit();
    const payload = try unhex(original.payload_hex);
    defer allocator.free(payload);
    try assertion.verifyFingerprint(payload);
    try expectError(error.IdentitySignatureMismatch, assertion.token.verifyEs384(&assertion.token.public_key));
    assertion.token.header.object.getPtr("alg").?.* = .{ .string = "RS256" };
    try expectError(error.UnsupportedIdentityAlgorithm, assertion.token.verifyEs384(&assertion.token.public_key));
    try assertion.verifyFingerprint(payload);
}

test "identity timestamp arithmetic cannot overflow and rejects nonfinite or out-of-range values" {
    const fixtures = try load();
    defer fixtures.deinit();
    var assertion = try Assertion.parse(allocator, fixtures.value.assertions[0].attribute, .{});
    defer assertion.deinit();
    const expiry = assertion.token.claims.object.getPtr("exp").?;
    expiry.* = .{ .integer = std.math.maxInt(i64) };
    try assertion.token.checkTimestamps(std.math.maxInt(i64), 1);
    try expectError(error.IdentityExpired, assertion.token.checkTimestamps(std.math.maxInt(i64), 0));
    const issued = assertion.token.claims.object.getPtr("iat").?;
    issued.* = .{ .integer = std.math.minInt(i64) };
    try assertion.token.checkTimestamps(std.math.minInt(i64), std.math.maxInt(u32));
    for ([_]f64{ std.math.inf(f64), std.math.nan(f64), 0x1p63, -0x1p64 }) |value| {
        expiry.* = .{ .float = value };
        try expectError(error.InvalidIdentityTimestamp, assertion.token.checkTimestamps(0, 0));
    }
}

test "identity base64 and key boundaries reject noncanonical, private and oversized inputs" {
    var output: [4]u8 = undefined;
    for ([_][]const u8{ "Y R==", "YR==", "A", "====" }) |value| if (codec.decode(&output, value, false)) |_| return error.ExpectedRejection else |_| {};
    try std.testing.expectEqualStrings("a", try codec.decode(&output, "YQ", false));
    const fixtures = try load();
    defer fixtures.deinit();
    var jwk = fixtures.value.keys[1].claim;
    try jwk.object.put(fixtures.arena.allocator(), "d", .{ .string = "not-private-key-material" });
    try expectError(error.PrivateKeyClaim, PublicKey.fromClaim(jwk));
    const key = try PublicKey.fromClaim(fixtures.value.keys[0].claim);
    try expectError(error.InvalidIdentitySignatureLength, key.verify("input", "short"));
    const invalid_signature: [96]u8 = @splat(0xff);
    try expectError(error.IdentitySignatureMismatch, key.verify("input", &invalid_signature));
}

test "target fingerprint payload covers all scopes and preserves exact spelling and order" {
    const fixtures = try load();
    defer fixtures.deinit();
    const first = try unhex(fixtures.value.assertions[0].payload_hex);
    defer allocator.free(first);
    var single = try Assertion.parse(allocator, fixtures.value.assertions[0].attribute, .{});
    defer single.deinit();
    const digest = "00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E:1F";
    const input = "v=0\r\na=fingerprint:sha-256 " ++ digest ++ "\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fingerprint:SHA-256 " ++ digest ++ "\r\n";
    var storage: [8][]const u8 = undefined;
    const description = try Description.parse(input, &storage, .{});
    var output: [1024]u8 = undefined;
    const actual = try Payload.write(&description, &output, .{});
    const expected = "{\"fingerprint\":[{\"algorithm\":\"sha-256\",\"digest\":\"" ++ digest ++ "\"},{\"algorithm\":\"SHA-256\",\"digest\":\"" ++ digest ++ "\"}]}";
    try std.testing.expectEqualStrings(expected, actual);
    try expectError(error.IdentitySignatureMismatch, single.verifyFingerprint(actual));
    var found = false;
    for (fixtures.value.assertions) |case| {
        if (!std.mem.eql(u8, case.name, "all_fingerprints")) continue;
        try equalHex(case.payload_hex, actual);
        var multiple = try Assertion.parse(allocator, case.attribute, .{});
        defer multiple.deinit();
        try multiple.verifyFingerprint(actual);
        found = true;
    }
    try expect(found);
    const only = try Description.parse("a=fingerprint:sha-256 " ++ digest, &storage, .{});
    try std.testing.expectEqualSlices(u8, first, try Payload.write(&only, &output, .{}));
    try single.verifyFingerprint(output[0..first.len]);
}

test "target fingerprint payload preserves output across invalid digests, limits and aliases" {
    const digest = "00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E:1F";
    var input: [1024]u8 = @splat(0xaa);
    const text = "a=fingerprint:sha-256 " ++ digest;
    @memcpy(input[0..text.len], text);
    var storage: [64][]const u8 = @splat("");
    var description = try Description.parse(input[0..text.len], &storage, .{});
    var output: [1024]u8 = @splat(0xbb);
    try expectError(error.FingerprintPayloadTooLong, Payload.write(&description, &output, .{ .bytes = 1 }));
    try expectError(error.NoSpace, Payload.write(&description, output[0..1], .{}));
    for (output) |byte| try std.testing.expectEqual(0xbb, byte);
    const before = input;
    try expectError(error.AliasedBuffer, Payload.write(&description, &input, .{}));
    try std.testing.expectEqualSlices(u8, &before, &input);
    const previous_storage = storage;
    try expectError(error.AliasedBuffer, Payload.write(&description, std.mem.sliceAsBytes(&storage), .{}));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&previous_storage), std.mem.sliceAsBytes(&storage));
    var owner: struct { description: Description, tail: [512]u8 } = .{ .description = description, .tail = @splat(0xcc) };
    try expectError(error.AliasedBuffer, Payload.write(&owner.description, std.mem.asBytes(&owner), .{}));
    for ([_][]const u8{ "a=fingerprint:sha-256 AA", "a=fingerprint:sha-512 " ++ digest }) |invalid| {
        description = try Description.parse(invalid, &storage, .{});
        if (Payload.write(&description, &output, .{})) |_| return error.ExpectedRejection else |_| {}
        for (output) |byte| try std.testing.expectEqual(0xbb, byte);
    }
    description = try Description.parse("v=0", &storage, .{});
    try expectError(error.MissingFingerprint, Payload.write(&description, &output, .{}));
    description = try Description.parse(text ++ "\na=fingerprint:sha-256 " ++ digest, &storage, .{});
    try expectError(error.TooManyFingerprints, Payload.write(&description, &output, .{ .fingerprints = 1 }));
}
