const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Kind = enum { signaling, sdp };

pub fn main(init: std.process.Init) !u8 {
    var output_buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    var error_buffer: [256]u8 = undefined;
    var errors: std.Io.File.Writer = .init(.stderr(), init.io, &error_buffer);
    // All file and JSON allocations live for this bounded maintenance command.
    const arena = init.arena.allocator();
    run(arena, init.io, &output.interface) catch |err| {
        try errors.interface.print("error: {s}\n", .{@errorName(err)});
        try errors.interface.flush();
        return 1;
    };
    try output.interface.flush();
    return 0;
}

fn run(arena: Allocator, io: std.Io, output: *std.Io.Writer) !void {
    try checkSignaling(arena, try load(arena, io, .signaling));
    try output.writeAll("Verified 30 independent signaling oracle cases\n");
    try checkSdp(arena, try load(arena, io, .sdp));
    try output.writeAll("Verified 42 SDP descriptions, 18 edits and 17 fingerprint oracle cases\n");
}

fn require(condition: bool) !void {
    if (!condition) return error.InvalidFixture;
}

fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidFixture;
    return value.object.get(name) orelse error.MissingField;
}

fn has(value: Value, name: []const u8) bool {
    return value == .object and value.object.contains(name);
}

fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidFixture;
    return value.string;
}

fn number(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidFixture;
    return @intCast(value.integer);
}

fn items(value: Value) ![]const Value {
    if (value != .array) return error.InvalidFixture;
    return value.array.items;
}

fn same(value: Value, expected: []const u8) !void {
    try require(std.mem.eql(u8, try text(value), expected));
}

fn oracle(value: Value) !void {
    try require(value == .object and value.object.count() == 4);
    try same(try field(value, "repository"), "https://github.com/axolotl-pm/nethernet");
    try same(try field(value, "branch"), "master");
    try same(try field(value, "revision"), "6ecacdaed3b0605a6a523235e5536f9c09ea56fd");
    try same(try field(value, "license"), "LGPL-3.0-or-later");
}

fn digest(bytes: []const u8, expected: []const u8) !void {
    if (expected.len != 64) return error.InvalidDigest;
    for (expected) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return error.InvalidDigest;
    var wanted: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&wanted, expected);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &wanted, &actual)) return error.DigestMismatch;
}

fn read(arena: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
}

fn json(arena: Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always });
}

fn load(arena: Allocator, io: std.Io, kind: Kind) !Value {
    const paths: [3][]const u8 = switch (kind) {
        .signaling => .{ "src/transport/fixtures/signaling-manifest.json", "src/transport/fixtures/signaling.json", "tools/generate_signaling_fixtures.php" },
        .sdp => .{ "src/transport/fixtures/sdp-manifest.json", "src/transport/fixtures/sdp.json", "tools/generate_sdp_fixtures.php" },
    };
    const manifest = try json(arena, try read(arena, io, paths[0]));
    try require(try number(try field(manifest, "schema")) == 1);
    try oracle(try field(manifest, "oracle"));
    const counts = try field(manifest, "cases");
    switch (kind) {
        .signaling => try require(try number(counts) == 30),
        .sdp => {
            try require(counts == .object and counts.object.count() == 3);
            try require(try number(try field(counts, "descriptions")) == 42);
            try require(try number(try field(counts, "edits")) == 18);
            try require(try number(try field(counts, "fingerprints")) == 17);
        },
    }
    // Oracle generators are read as provenance bytes, never executed here.
    try digest(try read(arena, io, paths[2]), try text(try field(manifest, "generator_sha256")));
    const raw = try read(arena, io, paths[1]);
    try require(raw.len == try number(try field(manifest, "bytes")));
    try digest(raw, try text(try field(manifest, "sha256")));
    const fixture = try json(arena, raw);
    try oracle(try field(fixture, "oracle"));
    return fixture;
}

fn unhex(arena: Allocator, value: Value) ![]const u8 {
    const hex = try text(value);
    if (hex.len % 2 != 0) return error.InvalidHex;
    const bytes = try arena.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(bytes, hex);
}

fn unique(cases: []const Value, count: usize) !void {
    try require(cases.len == count);
    for (cases, 0..) |case, index| {
        const name = try text(try field(case, "name"));
        for (cases[0..index]) |other| try require(!std.mem.eql(u8, name, try text(try field(other, "name"))));
    }
}

fn flag(value: Value, name: []const u8) !bool {
    const member = try field(value, name);
    if (member != .bool) return error.InvalidFixture;
    return member.bool;
}

fn checkSignaling(arena: Allocator, fixture: Value) !void {
    const cases = try items(try field(fixture, "cases"));
    try unique(cases, 30);
    for (cases) |case| {
        const wire = try unhex(arena, try field(case, "wire_hex"));
        if (has(case, "error") and try flag(case, "error")) {
            try require(case.object.count() == 3);
            continue;
        }
        const kind = try text(try field(case, "kind"));
        try require(std.mem.eql(u8, kind, "CONNECTREQUEST") or std.mem.eql(u8, kind, "CONNECTRESPONSE") or std.mem.eql(u8, kind, "CANDIDATEADD") or std.mem.eql(u8, kind, "CONNECTERROR"));
        const id = try text(try field(case, "connection_id"));
        try require(id.len > 0 and id.len <= 20 and (id.len == 1 or id[0] != '0'));
        for (id) |byte| try require(byte >= '0' and byte <= '9');
        _ = try std.fmt.parseInt(u64, id, 10);
        const data = try unhex(arena, try field(case, "data_hex"));
        const encoded = try unhex(arena, try field(case, "encoded_hex"));
        const wanted = try std.mem.concat(arena, u8, &.{ kind, " ", id, " ", data });
        try require(std.mem.eql(u8, encoded, wanted));
        const first = std.mem.indexOfScalar(u8, wire, ' ') orelse return error.InvalidFixture;
        const rest = wire[first + 1 ..];
        const second = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidFixture;
        try require(std.mem.eql(u8, rest[second + 1 ..], data));
    }
}

fn fingerprint(arena: Allocator, value: Value) !void {
    try require(std.ascii.eqlIgnoreCase(try text(try field(value, "algorithm")), "sha-256"));
    for ([_][]const u8{ "digest_hex", "attribute_hex", "canonical_hex" }) |name| _ = try unhex(arena, try field(value, name));
}

fn checkSdp(arena: Allocator, fixture: Value) !void {
    const descriptions = try items(try field(fixture, "descriptions"));
    const edits = try items(try field(fixture, "edits"));
    const fingerprints = try items(try field(fixture, "fingerprints"));
    try unique(descriptions, 42);
    try unique(edits, 18);
    try unique(fingerprints, 17);
    for (descriptions) |case| {
        _ = try unhex(arena, try field(case, "input_hex"));
        if (has(case, "parse_error") and try flag(case, "parse_error")) {
            try require(case.object.count() == 3);
            continue;
        }
        try require(std.mem.endsWith(u8, try unhex(arena, try field(case, "normalized_hex")), "\r\n"));
        _ = try flag(case, "valid");
        const count = try number(try field(case, "line_count"));
        try require(count >= 1 and count <= 1024);
        _ = try number(try field(case, "candidates"));
        try require(has(case, "fingerprint") != has(case, "fingerprint_error"));
        try require(has(case, "maximum") != has(case, "maximum_error"));
        if (has(case, "fingerprint")) try fingerprint(arena, try field(case, "fingerprint")) else try require(try flag(case, "fingerprint_error"));
        if (has(case, "maximum")) {
            const maximum = try number(try field(case, "maximum"));
            try require(maximum >= 2 and maximum <= std.math.maxInt(u32));
        } else try require(try flag(case, "maximum_error"));
        for ([_][]const u8{ "session_ufrag", "media_ufrag" }) |name| {
            for (try items(try field(case, name))) |value| _ = try unhex(arena, value);
        }
        const identity = try field(case, "identity_hex");
        if (identity != .null) _ = try unhex(arena, identity);
    }
    for (edits) |case| {
        _ = try unhex(arena, try field(case, "input_hex"));
        const edit = try text(try field(case, "edit"));
        var known = false;
        for ([_][]const u8{ "none", "without_identity", "without_candidates", "without_connection_address", "candidates", "candidate_limit", "identity" }) |name| known = known or std.mem.eql(u8, edit, name);
        try require(known and std.mem.endsWith(u8, try unhex(arena, try field(case, "output_hex")), "\r\n"));
        if (has(case, "candidates_hex")) for (try items(try field(case, "candidates_hex"))) |value| {
            _ = try unhex(arena, value);
        };
        if (has(case, "identity_hex")) _ = try unhex(arena, try field(case, "identity_hex"));
    }
    for (fingerprints) |case| {
        _ = try unhex(arena, try field(case, "input_hex"));
        try require(has(case, "result") != has(case, "error"));
        if (has(case, "result")) try fingerprint(arena, try field(case, "result")) else try require(try flag(case, "error"));
    }
}

test "fixture integrity rejects changed bytes and malformed digest metadata" {
    const expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try digest("abc", expected);
    try std.testing.expectError(error.DigestMismatch, digest("abd", expected));
    try std.testing.expectError(error.InvalidDigest, digest("abc", "bad"));
    try std.testing.expectError(error.InvalidDigest, digest("abc", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
}

test "fixture shape validation rejects duplicate cases, wrong types and malformed hex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const duplicate = try json(gpa, "[{\"name\":\"same\"},{\"name\":\"same\"}]");
    try std.testing.expectError(error.InvalidFixture, unique(try items(duplicate), 2));
    try std.testing.expectError(error.InvalidFixture, number(.{ .integer = -1 }));
    try std.testing.expectError(error.InvalidFixture, number(.{ .string = "1" }));
    try std.testing.expectError(error.MissingField, field(try json(gpa, "{}"), "schema"));
    try std.testing.expectError(error.InvalidHex, unhex(gpa, .{ .string = "a" }));
    try std.testing.expectError(error.InvalidCharacter, unhex(gpa, .{ .string = "zz" }));
}
