const std = @import("std");
const Key = @import("identity/OperatorKey.zig");
const Issuer = @import("identity/Issuer.zig");
const Assertion = @import("identity/Assertion.zig");
const PublicKey = @import("identity/PublicKey.zig");
const codec = @import("identity/codec.zig");
const SignedDescription = @import("identity/SignedDescription.zig");
const Description = @import("sdp/SessionDescription.zig");
const Fingerprints = @import("sdp/FingerprintPayload.zig");
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Case = struct {
    name: []const u8,
    encoding: Issuer.Encoding,
    now: i64,
    lifetime: u32,
    domain: []const u8,
    payload_hex: []const u8,
    public_key_der_hex: []const u8,
    token_input_hex: []const u8,
    token_signature_hex: []const u8,
    proof_input_hex: []const u8,
    proof_signature_hex: []const u8,
    attribute: []const u8,

    fn parameters(self: Case) Issuer.Parameters {
        return .{ .now = self.now, .lifetime_seconds = self.lifetime, .domain = self.domain, .key_encoding = self.encoding };
    }
};
const Fixtures = struct { cases: []const Case };

fn load() !std.json.Parsed(Fixtures) {
    return std.json.parseFromSlice(Fixtures, allocator, @embedFile("fixtures/issuer.json"), .{ .ignore_unknown_fields = true });
}

fn unhex(hex: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(result);
    return std.fmt.hexToBytes(result, hex);
}

// Serialization oracle adapter, not a cryptographic implementation. It returns
// a source-generated valid signature only for the complete recorded input.
const ReplaySigner = struct {
    case: Case,
    calls: usize = 0,
    fail_at: ?usize = null,

    pub fn sign(self: *ReplaySigner, input: []const u8) ![96]u8 {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.TestSigningFailure;
        const wanted_input = switch (self.calls) {
            1 => self.case.token_input_hex,
            2 => self.case.proof_input_hex,
            else => return error.UnexpectedSigningCall,
        };
        var expected: [32 * 1024]u8 = undefined;
        const bytes = try std.fmt.hexToBytes(&expected, wanted_input);
        if (!std.mem.eql(u8, input, bytes)) return error.UnexpectedSigningInput;
        var result: [96]u8 = undefined;
        _ = try std.fmt.hexToBytes(&result, if (self.calls == 1) self.case.token_signature_hex else self.case.proof_signature_hex);
        return result;
    }
};

test "issuer serialization matches original public API bytes with recorded valid signatures" {
    const fixtures = try load();
    defer fixtures.deinit();
    try std.testing.expectEqual(8, fixtures.value.cases.len);
    var output: [16 * 1024]u8 = undefined;
    var workspace: [64 * 1024]u8 = undefined;
    for (fixtures.value.cases) |case| {
        const der = try unhex(case.public_key_der_hex);
        defer allocator.free(der);
        const public = try PublicKey.fromDer(der);
        const payload = try unhex(case.payload_hex);
        defer allocator.free(payload);
        var signer: ReplaySigner = .{ .case = case };
        const actual = try Issuer.writeSigned(&signer, &public, &output, &workspace, payload, case.parameters(), .{});
        try std.testing.expectEqual(2, signer.calls);
        try expect(std.mem.eql(u8, case.attribute, actual));
        var assertion = try Assertion.parse(allocator, actual, .{});
        defer assertion.deinit();
        try assertion.token.verifyEs384(&public);
        try assertion.verifyFingerprint(payload);
        try assertion.token.checkTimestamps(case.now, 0);
        try std.testing.expectEqualStrings(case.domain, assertion.domain);
    }
}

fn syntheticKey() !Key {
    // Public synthetic test scalar, never an operator credential.
    var secret: [48]u8 = @splat(0);
    secret[47] = 1;
    defer std.crypto.secureZero(u8, &secret);
    return Key.fromSecretScalar(&secret);
}

test "operator key copies canonical secret material and survives explicit export and import" {
    var secret: [48]u8 = @splat(0);
    secret[47] = 1;
    var key = try Key.fromSecretScalar(&secret);
    @memset(&secret, 0);
    const public = try key.publicKey();
    try std.testing.expectEqualSlices(u8, &PublicKey.Ecdsa.Curve.basePoint.toUncompressedSec1(), &public.key.toUncompressedSec1());
    const signature = try key.sign("synthetic persistence vector", null);
    try public.verify("synthetic persistence vector", &signature);
    var exported: [48]u8 = undefined;
    defer std.crypto.secureZero(u8, &exported);
    _ = try key.writeSecretScalar(&exported);
    key.deinit();
    for (std.mem.asBytes(&key)) |byte| try std.testing.expectEqual(0, byte);
    var restored = try Key.fromSecretScalar(&exported);
    defer restored.deinit();
    const same = try restored.publicKey();
    try expect(public.equals(&same));
    const restored_signature = try restored.sign("synthetic persistence vector", null);
    try std.testing.expectEqualSlices(u8, &signature, &restored_signature);
}

test "operator key rejects invalid scalars and prevents use after destruction" {
    const zero: [48]u8 = @splat(0);
    const excessive: [48]u8 = @splat(0xff);
    try expectError(error.InvalidSecretScalar, Key.fromSecretScalar(&zero));
    try expectError(error.InvalidSecretScalar, Key.fromSecretScalar(&excessive));
    try expectError(error.InvalidSecretScalar, Key.fromSecretScalar(zero[0..47]));
    var order: [48]u8 = undefined;
    std.mem.writeInt(u384, &order, PublicKey.Ecdsa.Curve.scalar.field_order, .big);
    try expectError(error.InvalidSecretScalar, Key.fromSecretScalar(&order));
    var key = try syntheticKey();
    var output: [48]u8 = @splat(0xaa);
    try expectError(error.NoSpace, key.writeSecretScalar(output[0..47]));
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    try expectError(error.AliasedBuffer, key.writeSecretScalar(std.mem.asBytes(&key)));
    key.deinit();
    try expectError(error.OperatorKeyDestroyed, key.publicKey());
    try expectError(error.OperatorKeyDestroyed, key.sign("input", null));
    try expectError(error.OperatorKeyDestroyed, key.writeSecretScalar(&output));
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    key.deinit();
}

test "operator generation and ordinary formatting use independent owned keys and redacted text" {
    var first = try Key.generate(std.testing.io);
    defer first.deinit();
    var second = try Key.generate(std.testing.io);
    defer second.deinit();
    const a = try first.publicKey();
    const b = try second.publicKey();
    try expect(!a.equals(&b));
    const signature = try first.sign("synthetic generated-key vector", @as([48]u8, @splat(0x37)));
    try a.verify("synthetic generated-key vector", &signature);
    try expectError(error.IdentitySignatureMismatch, b.verify("synthetic generated-key vector", &signature));
    var formatted: [128]u8 = undefined;
    try std.testing.expectEqualStrings("OperatorKey(redacted)", try std.fmt.bufPrint(&formatted, "{f}", .{&first}));
}

test "owned operator issues JWK and legacy assertions using fresh signing noise" {
    var key = try syntheticKey();
    defer key.deinit();
    const public = try key.publicKey();
    const fixtures = try load();
    defer fixtures.deinit();
    const payload = try unhex(fixtures.value.cases[0].payload_hex);
    defer allocator.free(payload);
    var output: [16 * 1024]u8 = undefined;
    var workspace: [64 * 1024]u8 = undefined;
    for ([_]Issuer.Encoding{ .jwk, .legacy_der }) |encoding| {
        const actual = try Issuer.write(&key, std.testing.io, &output, &workspace, payload, .{ .now = 1000, .key_encoding = encoding }, .{});
        var assertion = try Assertion.parse(allocator, actual, .{});
        defer assertion.deinit();
        try expect(assertion.token.public_key.equals(&public));
        try assertion.token.verifyEs384(&public);
        try assertion.verifyFingerprint(payload);
        try assertion.token.checkTimestamps(1059, 0);
        try expectError(error.IdentityExpired, assertion.token.checkTimestamps(1060, 0));
        const claim = try codec.field(assertion.token.claims, "cpk");
        try expect(if (encoding == .jwk) claim == .object else claim == .string);
    }
}

test "issuer preflight rejects capacity and policy errors before calling a signer" {
    const fixtures = try load();
    defer fixtures.deinit();
    const case = fixtures.value.cases[0];
    const der = try unhex(case.public_key_der_hex);
    defer allocator.free(der);
    const public = try PublicKey.fromDer(der);
    const payload = try unhex(case.payload_hex);
    defer allocator.free(payload);
    var signer: ReplaySigner = .{ .case = case };
    var output: [16 * 1024]u8 = @splat(0xaa);
    var workspace: [64 * 1024]u8 = undefined;
    try expectError(error.NoSpace, Issuer.writeSigned(&signer, &public, output[0..1], &workspace, payload, case.parameters(), .{}));
    try expectError(error.IdentityWorkspaceLimit, Issuer.writeSigned(&signer, &public, &output, workspace[0..1], payload, case.parameters(), .{}));
    try expectError(error.IdentityBytesLimit, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, case.parameters(), .{ .attribute_bytes = 1 }));
    try expectError(error.IdentityBytesLimit, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, case.parameters(), .{ .payload_bytes = 1 }));
    try expectError(error.InvalidLimits, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, case.parameters(), .{ .domain_bytes = 0 }));
    var parameters = case.parameters();
    parameters.lifetime_seconds = 0;
    try expectError(error.InvalidIdentityLifetime, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, parameters, .{}));
    parameters = case.parameters();
    parameters.now = std.math.maxInt(i64);
    try expectError(error.InvalidIdentityTimestamp, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, parameters, .{}));
    parameters = case.parameters();
    parameters.domain = "";
    try expectError(error.InvalidIdentityDomain, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, parameters, .{}));
    parameters.domain = "\xff";
    try expectError(error.InvalidIdentityDomain, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, parameters, .{}));
    try std.testing.expectEqual(0, signer.calls);
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    signer = .{ .case = case };
    const actual = try Issuer.writeSigned(&signer, &public, &output, &workspace, payload, case.parameters(), .{ .attribute_bytes = case.attribute.len });
    try std.testing.expectEqual(case.attribute.len, actual.len);
}

test "issuer preserves output when either signing operation fails or the signer returns invalid data" {
    const fixtures = try load();
    defer fixtures.deinit();
    const case = fixtures.value.cases[0];
    const der = try unhex(case.public_key_der_hex);
    defer allocator.free(der);
    const public = try PublicKey.fromDer(der);
    const payload = try unhex(case.payload_hex);
    defer allocator.free(payload);
    var output: [16 * 1024]u8 = @splat(0xaa);
    var workspace: [64 * 1024]u8 = undefined;
    for ([_]usize{ 1, 2 }) |fail_at| {
        var signer: ReplaySigner = .{ .case = case, .fail_at = fail_at };
        try expectError(error.TestSigningFailure, Issuer.writeSigned(&signer, &public, &output, &workspace, payload, case.parameters(), .{}));
        try std.testing.expectEqual(fail_at, signer.calls);
        for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    }
    const InvalidSigner = struct {
        pub fn sign(_: *@This(), _: []const u8) ![96]u8 {
            return @splat(0);
        }
    };
    var invalid: InvalidSigner = .{};
    try expectError(error.IdentitySignatureMismatch, Issuer.writeSigned(&invalid, &public, &output, &workspace, payload, case.parameters(), .{}));
    const InvalidProofSigner = struct {
        replay: ReplaySigner,
        pub fn sign(self: *@This(), input: []const u8) ![96]u8 {
            const signature = try self.replay.sign(input);
            return if (self.replay.calls == 2) @splat(0) else signature;
        }
    };
    var bad_proof: InvalidProofSigner = .{ .replay = .{ .case = case } };
    try expectError(error.IdentitySignatureMismatch, Issuer.writeSigned(&bad_proof, &public, &output, &workspace, payload, case.parameters(), .{}));
    try std.testing.expectEqual(2, bad_proof.replay.calls);
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
}

test "issuer refuses output and workspace overlap with each other, inputs, signer and key owner" {
    var key = try syntheticKey();
    defer key.deinit();
    var public = try key.publicKey();
    const fixtures = try load();
    defer fixtures.deinit();
    var signer: ReplaySigner = .{ .case = fixtures.value.cases[0] };
    var output: [16 * 1024]u8 = @splat(0xaa);
    var workspace: [64 * 1024]u8 = @splat(0xbb);
    const input = "synthetic payload";
    try expectError(error.AliasedBuffer, Issuer.writeSigned(&signer, &public, &output, &output, input, .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, Issuer.writeSigned(&signer, &public, &output, &workspace, workspace[0..16], .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, Issuer.writeSigned(&signer, &public, &output, &workspace, input, .{ .now = 1000, .domain = output[0..4] }, .{}));
    try expectError(error.AliasedBuffer, Issuer.writeSigned(&signer, &public, std.mem.asBytes(&signer), &workspace, input, .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, Issuer.writeSigned(&signer, &public, &output, std.mem.asBytes(&public), input, .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, Issuer.write(&key, std.testing.io, std.mem.asBytes(&key), &workspace, input, .{ .now = 1000 }, .{}));
    try std.testing.expectEqual(0, signer.calls);
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    for (workspace) |byte| try std.testing.expectEqual(0xbb, byte);
}

test "SEC1 construction preserves point presentation and rejects malformed points" {
    var key = try syntheticKey();
    defer key.deinit();
    const public = try key.publicKey();
    const uncompressed = try PublicKey.fromSec1(&public.key.toUncompressedSec1());
    const compressed = try PublicKey.fromSec1(&public.key.toCompressedSec1());
    try expect(public.equals(&uncompressed));
    try expect(!public.equals(&compressed));
    try std.testing.expectEqualSlices(u8, &public.key.toUncompressedSec1(), &compressed.key.toUncompressedSec1());
    var invalid = public.key.toUncompressedSec1();
    try expectError(error.InvalidPublicKeyEncoding, PublicKey.fromSec1(invalid[0..96]));
    invalid[0] = 2;
    try expectError(error.InvalidPublicKeyEncoding, PublicKey.fromSec1(&invalid));
    @memset(invalid[1..], 0);
    invalid[0] = 4;
    try expectError(error.InvalidPublicKeyPoint, PublicKey.fromSec1(&invalid));
}

test "issuer normalizes compressed provider keys and rejects wrong signing keys" {
    var key = try syntheticKey();
    defer key.deinit();
    const public = try key.publicKey();
    const compressed = try PublicKey.fromSec1(&public.key.toCompressedSec1());
    const Signer = struct {
        key: *const Key,
        pub fn sign(self: *@This(), input: []const u8) ![96]u8 {
            return self.key.sign(input, null);
        }
    };
    var signer: Signer = .{ .key = &key };
    var output: [16 * 1024]u8 = undefined;
    var workspace: [64 * 1024]u8 = undefined;
    const attribute = try Issuer.writeSigned(&signer, &compressed, &output, &workspace, "synthetic", .{ .now = 1000 }, .{});
    var assertion = try Assertion.parse(allocator, attribute, .{});
    defer assertion.deinit();
    try expect(assertion.token.public_key.equals(&public));
    try assertion.token.verifyEs384(&public);
    try assertion.verifyFingerprint("synthetic");
    var other = try Key.generate(std.testing.io);
    defer other.deinit();
    signer.key = &other;
    @memset(&output, 0xaa);
    try expectError(error.IdentitySignatureMismatch, Issuer.writeSigned(&signer, &public, &output, &workspace, "synthetic", .{ .now = 1000 }, .{}));
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    const oversized: [64 * 1024 + 1]u8 = @splat(0);
    try expectError(error.IdentityBytesLimit, key.sign(&oversized, null));
}

const digest_a = "00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E:1F";
const digest_b = "20:21:22:23:24:25:26:27:28:29:2A:2B:2C:2D:2E:2F:30:31:32:33:34:35:36:37:38:39:3A:3B:3C:3D:3E:3F";
const local_sdp = "v=0\ns=-\nt=0 0\na=fingerprint:sha-256 " ++ digest_a ++ "\na=identity:old-session\n" ++
    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=ice-ufrag:synthetic\na=ice-pwd:synthetic\na=setup:passive\n" ++
    "a=max-message-size:4096\na=fingerprint:SHA-256 " ++ digest_b ++ "\na=identity:old-media\n";

test "signed description replaces every old identity and binds all unchanged fingerprints" {
    var key = try syntheticKey();
    defer key.deinit();
    var input_lines: [32][]const u8 = undefined;
    const input = try Description.parse(local_sdp, &input_lines, .{});
    var output: [16 * 1024]u8 = @splat(0xaa);
    var workspace: [128 * 1024]u8 = undefined;
    const encoded = try SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000 }, .{});
    var output_lines: [32][]const u8 = undefined;
    const result = try Description.parse(encoded, &output_lines, .{});
    var identities = result.attributes("identity", .all);
    const attribute = identities.next().?;
    try expect(identities.next() == null);
    try std.testing.expectEqualStrings(attribute, result.identity().?);
    var assertion = try Assertion.parse(allocator, attribute, .{});
    defer assertion.deinit();
    const public = try key.publicKey();
    try assertion.token.verifyEs384(&public);
    var original_payload: [1024]u8 = undefined;
    var result_payload: [1024]u8 = undefined;
    const original = try Fingerprints.write(&input, &original_payload, .{});
    const bound = try Fingerprints.write(&result, &result_payload, .{});
    try std.testing.expectEqualStrings(original, bound);
    try assertion.verifyFingerprint(bound);
    result_payload[bound.len - 5] ^= 1;
    try expectError(error.IdentitySignatureMismatch, assertion.verifyFingerprint(bound));
    try expect(std.mem.indexOf(u8, encoded, "old-session") == null and std.mem.indexOf(u8, encoded, "old-media") == null);
    for (output[encoded.len..]) |byte| try std.testing.expectEqual(0xaa, byte);
}

test "signed description preserves output on fingerprint, capacity, limit and key failures" {
    var key = try syntheticKey();
    defer key.deinit();
    var lines: [32][]const u8 = undefined;
    const input = try Description.parse(local_sdp, &lines, .{});
    var output: [16 * 1024]u8 = @splat(0xaa);
    var workspace: [128 * 1024]u8 = undefined;
    try expectError(error.NoSpace, SignedDescription.write(&key, std.testing.io, &input, output[0..1], &workspace, .{ .now = 1000 }, .{}));
    try expectError(error.IdentityWorkspaceLimit, SignedDescription.write(&key, std.testing.io, &input, &output, workspace[0..1], .{ .now = 1000 }, .{}));
    try expectError(error.TooManyFingerprints, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000 }, .{ .fingerprints = .{ .fingerprints = 1 } }));
    try expectError(error.InvalidLimits, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000 }, .{ .description = .{ .text_bytes = 64 * 1024 + 1 } }));
    try expectError(error.InvalidLimits, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000 }, .{ .identity = .{ .attribute_bytes = 0 } }));
    var invalid_lines: [8][]const u8 = undefined;
    const missing = try Description.parse("v=0\nm=application\n", &invalid_lines, .{});
    try expectError(error.MissingFingerprint, SignedDescription.write(&key, std.testing.io, &missing, &output, &workspace, .{ .now = 1000 }, .{}));
    const short = try Description.parse("v=0\na=fingerprint:sha-256 AA:BB\nm=application\n", &invalid_lines, .{});
    try expectError(error.InvalidDigestLength, SignedDescription.write(&key, std.testing.io, &short, &output, &workspace, .{ .now = 1000 }, .{}));
    key.deinit();
    try expectError(error.OperatorKeyDestroyed, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000 }, .{}));
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
}

test "signed description preflights every borrowed buffer and owner alias" {
    var key = try syntheticKey();
    defer key.deinit();
    var source: [local_sdp.len]u8 = local_sdp.*;
    var lines: [32][]const u8 = undefined;
    var input = try Description.parse(&source, &lines, .{});
    var output: [16 * 1024]u8 = @splat(0xaa);
    var workspace: [128 * 1024]u8 = @splat(0xbb);
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, &output, &output, .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000, .domain = output[0..4] }, .{}));
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, &source, &workspace, .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, &output, std.mem.asBytes(&lines), .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, std.mem.asBytes(&key), &workspace, .{ .now = 1000 }, .{}));
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, &output, std.mem.asBytes(&input), .{ .now = 1000 }, .{}));
    lines[0] = workspace[0..4];
    try expectError(error.AliasedBuffer, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 1000 }, .{}));
    try std.testing.expectEqualStrings(local_sdp, &source);
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
    for (workspace) |byte| try std.testing.expectEqual(0xbb, byte);
}

test "token rotation preserves the operator pin and signed SDP expansion respects its limit" {
    var key = try syntheticKey();
    defer key.deinit();
    var output: [16 * 1024]u8 = undefined;
    var workspace: [128 * 1024]u8 = undefined;
    const first = try Issuer.write(&key, std.testing.io, &output, &workspace, "synthetic", .{ .now = 1000 }, .{});
    var before = try Assertion.parse(allocator, first, .{});
    defer before.deinit();
    const second = try Issuer.write(&key, std.testing.io, &output, &workspace, "synthetic", .{ .now = 2000 }, .{});
    var after = try Assertion.parse(allocator, second, .{});
    defer after.deinit();
    try expect(before.token.public_key.equals(&after.token.public_key));
    try std.testing.expectEqualSlices(u8, &before.token.public_key.digest(), &after.token.public_key.digest());
    try expectError(error.IdentityExpired, before.token.checkTimestamps(2000, 0));
    try after.token.checkTimestamps(2000, 0);
    try expect(!std.mem.eql(u8, before.token.compact, after.token.compact));
    var lines: [32][]const u8 = undefined;
    const input = try Description.parse(local_sdp, &lines, .{});
    @memset(&output, 0xaa);
    try expectError(error.DescriptionTooLong, SignedDescription.write(&key, std.testing.io, &input, &output, &workspace, .{ .now = 2000 }, .{ .description = .{ .text_bytes = local_sdp.len + 256 } }));
    for (output) |byte| try std.testing.expectEqual(0xaa, byte);
}
