const std = @import("std");
const Assertion = @import("identity/Assertion.zig");
const Keys = @import("identity/ServiceKeys.zig");
const Service = @import("identity/ServiceIdentity.zig");
const Rsa = @import("identity/RsaPublicKey.zig");
const Description = @import("sdp/SessionDescription.zig");
const codec = @import("identity/codec.zig");
const testing = std.testing;
const allocator = testing.allocator;
const Fixture = struct {
    authority: Keys.Authority,
    now: i64,
    jwks: std.json.Value,
    cases: []const struct { name: []const u8, attribute: []const u8, sdp: []const u8, @"error": ?[]const u8, key_bits: u32 },
};

fn fixture() !std.json.Parsed(Fixture) {
    return std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/service-identity.json"), .{ .ignore_unknown_fields = true });
}

fn keySet(data: *const Fixture) !Keys {
    const text = try std.json.Stringify.valueAlloc(allocator, data.jwks, .{});
    defer allocator.free(text);
    return Keys.load(allocator, text, data.authority, .{});
}

test "service identity matches independent CNG RSA and ES384 policy vectors" {
    const vectors = try fixture();
    defer vectors.deinit();
    const data = &vectors.value;
    try testing.expectEqual(@as(usize, 26), data.cases.len);
    var keys = try keySet(data);
    defer keys.deinit();
    for (data.cases) |case| {
        var assertion = try Assertion.parse(allocator, case.attribute, .{});
        defer assertion.deinit();
        var lines: [Description.max_lines][]const u8 = undefined;
        const description = try Description.parse(case.sdp, &lines, .{});
        var workspace: [16 * 1024]u8 = undefined;
        if (Service.verify(&assertion, &description, &keys, data.now, &workspace, .{})) |verified| {
            if (case.@"error" != null) return error.ExpectedServiceRejection;
            try testing.expectEqualStrings("synthetic-player", verified.subject());
            try testing.expectEqual(data.authority.generation, verified.key_generation);
            try testing.expect(verified.client_key.equals(&assertion.token.public_key));
        } else |err| {
            const expected = case.@"error" orelse {
                std.debug.print("service case {s} failed: {s}\n", .{ case.name, @errorName(err) });
                return error.UnexpectedServiceRejection;
            };
            try testing.expectEqualStrings(expected, @errorName(err));
        }
    }
}

test "service key snapshot owns input and rejects expired or destroyed use" {
    const vectors = try fixture();
    defer vectors.deinit();
    const source = try std.json.Stringify.valueAlloc(allocator, vectors.value.jwks, .{});
    defer allocator.free(source);
    var keys = try Keys.load(allocator, source, vectors.value.authority, .{});
    @memset(source, 0);
    try keys.checkTime(1000);
    try testing.expectError(error.ServiceKeysNotYetValid, keys.checkTime(999));
    try testing.expectError(error.ServiceKeysExpired, keys.checkTime(8000));
    var assertion = try Assertion.parse(allocator, vectors.value.cases[0].attribute, .{});
    defer assertion.deinit();
    try keys.verify("rsa-2048", assertion.token.signing_input, assertion.token.signature, 2000);
    keys.deinit();
    keys.deinit();
    try testing.expectError(error.ServiceKeysDestroyed, keys.checkTime(2000));
}

test "service JWKS rejects duplicate IDs, private keys and unsupported uses" {
    const vectors = try fixture();
    defer vectors.deinit();
    const data = &vectors.value;
    const encoded_key = try std.json.Stringify.valueAlloc(allocator, data.jwks.object.get("keys").?.array.items[0], .{});
    defer allocator.free(encoded_key);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var key = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), encoded_key, .{});
    const duplicate = try std.json.Stringify.valueAlloc(allocator, .{ .keys = [_]std.json.Value{ key, key } }, .{});
    defer allocator.free(duplicate);
    if (Keys.load(allocator, duplicate, data.authority, .{})) |returned| {
        var owner = returned;
        owner.deinit();
        return error.ExpectedDuplicateKeyFailure;
    } else |err| try testing.expect(err == error.DuplicateServiceKey);
    try key.object.put(arena.allocator(), "d", .{ .string = "private-fields-are-forbidden" });
    try testing.expectError(error.PrivateServiceKey, Rsa.fromJwk(key));
    _ = key.object.swapRemove("d");
    try key.object.put(arena.allocator(), "use", .{ .string = "enc" });
    try testing.expectError(error.UnsupportedServiceKey, Rsa.fromJwk(key));
}

test "service JWKS bounds malformed JSON and allocation failures" {
    const vectors = try fixture();
    defer vectors.deinit();
    const data = &vectors.value;
    const json = try std.json.Stringify.valueAlloc(allocator, data.jwks, .{});
    defer allocator.free(json);
    try expectLoadError(error.JwksBytesLimit, json, data.authority, .{ .json_bytes = 1 });
    try expectLoadError(error.JwksKeysLimit, json, data.authority, .{ .keys = 1 });
    try expectLoadError(error.JwksDepthLimit, json, data.authority, .{ .json_depth = 1 });
    try expectLoadError(error.JwksTokensLimit, json, data.authority, .{ .json_tokens = 1 });
    try expectLoadError(error.JwksStorageLimit, json, data.authority, .{ .storage_bytes = 16 });
    try expectLoadError(error.DuplicateField, "{\"keys\":[],\"keys\":[]}", data.authority, .{});
    try testing.checkAllAllocationFailures(allocator, allocationTrial, .{ json, data.authority });
}

test "service RSA rejects altered messages, signature widths and out of range values" {
    const vectors = try fixture();
    defer vectors.deinit();
    const key = try Rsa.fromJwk(vectors.value.jwks.object.get("keys").?.array.items[0]);
    var assertion = try Assertion.parse(allocator, vectors.value.cases[0].attribute, .{});
    defer assertion.deinit();
    const token = assertion.token;
    try key.verify(token.signing_input, token.signature);
    try testing.expectError(error.ServiceSignatureMismatch, key.verify("different signing input", token.signature));
    try testing.expectError(error.InvalidServiceSignatureLength, key.verify(token.signing_input, token.signature[1..]));
    var changed: [256]u8 = token.signature[0..256].*;
    changed[0] ^= 1;
    try testing.expectError(error.ServiceSignatureMismatch, key.verify(token.signing_input, &changed));
    @memset(&changed, 0xff);
    try testing.expectError(error.ServiceSignatureMismatch, key.verify(token.signing_input, &changed));
}

test "service RSA rejects weak and noncanonical public keys" {
    const vectors = try fixture();
    defer vectors.deinit();
    const encoded = try std.json.Stringify.valueAlloc(allocator, vectors.value.jwks.object.get("keys").?.array.items[0], .{});
    defer allocator.free(encoded);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var key = try std.json.parseFromSliceLeaky(std.json.Value, scratch, encoded, .{});
    const original_n = key.object.get("n").?;
    const original_e = key.object.get("e").?;
    for ([_][]const u8{ "AA", "Ag", "AAAAAQ", "AQAB=", "AQABAQAB", "" }) |exponent| {
        try key.object.put(scratch, "e", .{ .string = exponent });
        if (Rsa.fromJwk(key)) |_| return error.ExpectedInvalidRsaExponent else |_| {}
    }
    try key.object.put(scratch, "e", original_e);
    var weak: [128]u8 = @splat(0xff);
    var weak_base64: [172]u8 = undefined;
    try key.object.put(scratch, "n", .{ .string = std.base64.url_safe_no_pad.Encoder.encode(&weak_base64, &weak) });
    try testing.expectError(error.UnsupportedServiceKeySize, Rsa.fromJwk(key));
    try key.object.put(scratch, "n", original_n);
    try key.object.put(scratch, "alg", .{ .string = "ES384" });
    try testing.expectError(error.UnsupportedServiceKey, Rsa.fromJwk(key));
    _ = key.object.swapRemove("alg");
    var operations: std.json.Value = .{ .array = .init(scratch) };
    try operations.array.append(.{ .string = "sign" });
    try key.object.put(scratch, "key_ops", operations);
    try testing.expectError(error.UnsupportedServiceKey, Rsa.fromJwk(key));
}

test "service authority requires a bounded expiry window and explicit anchors" {
    const vectors = try fixture();
    defer vectors.deinit();
    const json = try std.json.Stringify.valueAlloc(allocator, vectors.value.jwks, .{});
    defer allocator.free(json);
    var authority = vectors.value.authority;
    authority.generation = 0;
    try expectLoadError(error.InvalidServiceAuthority, json, authority, .{});
    authority = vectors.value.authority;
    authority.expires_at = authority.not_before + 86401;
    try expectLoadError(error.InvalidServiceAuthority, json, authority, .{});
    authority = vectors.value.authority;
    authority.audience = "";
    try expectLoadError(error.InvalidServiceIdentifier, json, authority, .{});
}

fn allocationTrial(gpa: std.mem.Allocator, json: []const u8, authority: Keys.Authority) !void {
    var keys = try Keys.load(gpa, json, authority, .{});
    defer keys.deinit();
}

fn expectLoadError(expected: anyerror, json: []const u8, authority: Keys.Authority, limits: Keys.Limits) !void {
    if (Keys.load(allocator, json, authority, limits)) |returned| {
        var owner = returned;
        owner.deinit();
        return error.ExpectedJwksFailure;
    } else |actual| try testing.expect(actual == expected);
}

test "service verifier preserves input owners and returns an independent identity" {
    const vectors = try fixture();
    defer vectors.deinit();
    var keys = try keySet(&vectors.value);
    defer keys.deinit();
    var assertion = try Assertion.parse(allocator, vectors.value.cases[0].attribute, .{});
    defer assertion.deinit();
    var lines: [Description.max_lines][]const u8 = undefined;
    const description = try Description.parse(vectors.value.cases[0].sdp, &lines, .{});
    var workspace: [16 * 1024]u8 = undefined;
    try testing.expectError(error.AliasedBuffer, Service.verify(&assertion, &description, &keys, 2000, assertion.storage, .{}));
    try testing.expectError(error.AliasedBuffer, Service.verify(&assertion, &description, &keys, 2000, keys.storage, .{}));
    try testing.expectError(error.InvalidLimits, Service.verify(&assertion, &description, &keys, 2000, &workspace, .{ .leeway_seconds = 301 }));
    const verified = try Service.verify(&assertion, &description, &keys, 2000, &workspace, .{});
    const original_key = assertion.token.public_key;
    @memset(assertion.storage, 0);
    keys.deinit();
    try testing.expectEqualStrings("synthetic-player", verified.subject());
    try testing.expectEqual(@as(u64, 7), verified.key_generation);
    try testing.expect(verified.client_key.equals(&original_key));
}
