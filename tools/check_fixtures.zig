const std = @import("std");
const transport = @import("check_transport_fixtures.zig");
const references = @import("reference_sources.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const require = transport.require;
const field = transport.field;
const text = transport.text;
const number = transport.number;
const items = transport.items;
const same = transport.same;
const digest = transport.digest;
const json = transport.json;
const unhex = transport.unhex;

pub fn main(init: std.process.Init) !u8 {
    var output_buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    var error_buffer: [256]u8 = undefined;
    var errors: std.Io.File.Writer = .init(.stderr(), init.io, &error_buffer);
    const checker: Checker = .{ .arena = init.arena.allocator(), .io = init.io };
    inline for (.{ "nbt", "math", "registry", "blocks", "framing" }) |group| {
        @field(Checker, group)(checker, &output.interface) catch |err| {
            try output.interface.flush();
            try errors.interface.print("error checking {s}: {s}\n", .{ group, @errorName(err) });
            try errors.interface.flush();
            return 1;
        };
    }
    transport.run(checker.arena, init.io, &output.interface) catch |err| {
        try output.interface.flush();
        try errors.interface.print("error checking signaling/SDP: {s}\n", .{@errorName(err)});
        try errors.interface.flush();
        return 1;
    };
    try output.interface.flush();
    return 0;
}

// A command owns all allocations through its arena. Paths come from fixed file
// sets, never unchecked manifest names. Each read is capped before allocation.
const Checker = struct {
    arena: Allocator,
    io: std.Io,

    fn read(self: Checker, file_path: []const u8) ![]const u8 {
        return transport.read(self.arena, self.io, file_path);
    }

    fn value(self: Checker, file_path: []const u8) !Value {
        return json(self.arena, try self.read(file_path));
    }

    fn path(self: Checker, directory: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ directory, name });
    }

    fn manifest(self: Checker, directory: []const u8, schema: u64, generator: []const u8) !Value {
        const result = try self.value(try self.path(directory, "manifest.json"));
        try require(try number(try field(result, "schema")) == schema);
        // Match the frozen producer record without requiring its runtime or source checkout.
        const sources = try references.Snapshot.load(self.arena, self.io);
        try sources.expect(generator, try text(try field(result, "generator_sha256")));
        return result;
    }

    fn files(self: Checker, directory: []const u8, manifest_value: Value, names: []const []const u8) !void {
        const entries = try field(manifest_value, "files");
        try keys(entries, names);
        for (names) |name| try fileMetadata(try self.read(try self.path(directory, name)), try field(entries, name));
    }

    fn directoryFiles(self: Checker, directory: []const u8, names: []const []const u8, nbt_only: bool) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, directory, .{ .iterate = true });
        defer dir.close(self.io);
        var iterator = dir.iterate();
        var count: usize = 0;
        while (try iterator.next(self.io)) |entry| {
            if (nbt_only and !std.mem.endsWith(u8, entry.name, ".nbt")) continue;
            try require(entry.kind == .file and contains(names, entry.name));
            count += 1;
        }
        try require(count == names.len);
    }

    fn nbt(self: Checker, output: *std.Io.Writer) !void {
        const directory = "src/foundation/fixtures/nbt";
        const manifest_value = try self.manifest(directory, 2, "tools/generate_nbt_fixtures.php");
        const sources = try field(manifest_value, "sources");
        try keys(sources, &.{ "NBT", "BinaryUtils", "BedrockProtocol" });
        for (sources.object.values()) |source| try sourceMetadata(source, null, null);
        var names: [12][]const u8 = undefined;
        var index: usize = 0;
        for ([_][]const u8{ "all-tags", "scalar", "nested-lists", "sequence" }) |case| {
            for ([_][]const u8{ "big", "little", "network" }) |variant| {
                names[index] = try std.fmt.allocPrint(self.arena, "{s}.{s}.nbt", .{ case, variant });
                index += 1;
            }
        }
        try self.files(directory, manifest_value, &names);
        try self.directoryFiles(directory, &names, true);
        try output.writeAll("Verified 12 NBT fixtures and recorded producer\n");
    }

    fn math(self: Checker, output: *std.Io.Writer) !void {
        const directory = "src/math/fixtures";
        const manifest_value = try self.manifest(directory, 1, "tools/generate_math_fixtures.php");
        try sourceMetadata(try field(manifest_value, "oracle"), "https://github.com/pmmp/Math", "stable");
        try self.files(directory, manifest_value, &.{"conformance.json"});
        const cases = try self.value(directory ++ "/conformance.json");
        try require(cases == .object);
        var count: usize = 0;
        for (cases.object.values()) |group| count += (try items(group)).len;
        try output.print("Verified {d} math oracle cases\n", .{count});
    }

    fn registry(self: Checker, output: *std.Io.Writer) !void {
        const directory = "src/registry/fixtures";
        const manifest_value = try self.manifest(directory, 1, "tools/generate_registry_fixtures.php");
        try sourcesMetadata(try field(manifest_value, "oracles"), false);
        try self.files(directory, manifest_value, &.{ "input.json", "expected.json" });
        const data_manifest = try self.value("data/bedrock/manifest.json");
        try require(equal(try field(manifest_value, "data_source"), try field(data_manifest, "source"), 0));
        const raw = try self.read("data/bedrock/required_item_list.json");
        try digest(raw, try text(try field(manifest_value, "data_sha256")));
        try fileMetadata(raw, try field(try field(data_manifest, "files"), "required_item_list.json"));
        const source = try json(self.arena, raw);
        const expected = try self.value(directory ++ "/expected.json");
        try require(source == .object and source.object.count() == try number(try field(expected, "source_entry_count")));
        const mapping = try mappingDigest(self.arena, source);
        try same(try field(expected, "source_mapping_sha256"), &mapping);
        const inputs = try self.value(directory ++ "/input.json");
        var count: usize = 0;
        inline for (.{ "source", "synthetic" }) |group| {
            const queries = try items(try field(inputs, group ++ "_queries"));
            try require(queries.len == (try items(try field(expected, group ++ "_answers"))).len);
            count += queries.len;
        }
        try output.print("Verified {d} registry oracle queries and {d} complete mappings\n", .{ count, source.object.count() });
    }

    fn blocks(self: Checker, output: *std.Io.Writer) !void {
        const directory = "src/registry/fixtures/blocks";
        const manifest_value = try self.manifest(directory, 1, "tools/generate_block_fixtures.php");
        try sourcesMetadata(try field(manifest_value, "oracles"), true);
        const inputs = try self.value(directory ++ "/input.json");
        const count = (try items(try field(inputs, "cases"))).len;
        const names = try blockFiles(self.arena, count);
        try self.files(directory, manifest_value, names);
        const directory_names = try self.arena.alloc([]const u8, names.len + 1);
        @memcpy(directory_names[0..names.len], names);
        directory_names[names.len] = "manifest.json";
        try self.directoryFiles(directory, directory_names, false);
        const data_manifest = try self.value("data/bedrock/manifest.json");
        try require(equal(try field(manifest_value, "data_source"), try field(data_manifest, "source"), 0));
        const palette = try std.Io.Dir.cwd().readFileAlloc(self.io, "data/bedrock/canonical_block_states.nbt", self.arena, .limited(4 * 1024 * 1024));
        try digest(palette, try text(try field(manifest_value, "palette_sha256")));
        try fileMetadata(palette, try field(try field(data_manifest, "files"), "canonical_block_states.nbt"));
        const metadata = try self.read("data/bedrock/block_state_meta_map.json");
        try digest(metadata, try text(try field(manifest_value, "metadata_sha256")));
        try fileMetadata(metadata, try field(try field(data_manifest, "files"), "block_state_meta_map.json"));
        const expected = try self.value(directory ++ "/expected.json");
        const cases = try items(try field(expected, "cases"));
        try require(cases.len == count and (try items(try field(expected, "equalities"))).len == (try items(try field(inputs, "equality_pairs"))).len);
        for (cases, 0..) |case, index| try same(try field(case, "file"), names[index + 4]);
        const roots = try blockSummary(try field(expected, "palette"));
        try output.print("Verified {d} block schema cases and {d} palette states\n", .{ count, roots });
    }

    fn framing(self: Checker, output: *std.Io.Writer) !void {
        const directory = "src/transport/fixtures";
        const manifest_value = try self.manifest(directory, 1, "tools/generate_framing_fixtures.php");
        const oracle = try field(manifest_value, "oracle");
        try transport.oracle(oracle);
        try self.files(directory, manifest_value, &.{ "framing.json", "receipts.json", "lifecycle.json" });
        const counts = try field(manifest_value, "cases");
        try keys(counts, &.{ "send", "receive", "boundaries", "receipts", "lifecycle" });
        const fixture = try self.value(directory ++ "/framing.json");
        try require(equal(try field(fixture, "oracle"), oracle, 0));
        inline for (.{ "send", "receive", "boundaries", "receipts", "lifecycle" }, .{ 10, 11, 5, 6, 7 }) |group, count| {
            try require(try number(try field(counts, group)) == count);
            if (!std.mem.eql(u8, group, "receipts") and !std.mem.eql(u8, group, "lifecycle")) try require((try items(try field(fixture, group))).len == count);
        }
        for (try items(try field(fixture, "send"))) |case| try sender(self.arena, case);
        for (try items(try field(fixture, "receive"))) |case| try receiver(case);
        const receipts_value = try self.value(directory ++ "/receipts.json");
        try require(equal(try field(receipts_value, "oracle"), oracle, 0));
        const cases = try items(try field(receipts_value, "cases"));
        try require(cases.len == 6);
        for (cases) |case| try receipts(self.arena, case);
        const lifecycle_value = try self.value(directory ++ "/lifecycle.json");
        try require(equal(try field(lifecycle_value, "oracle"), oracle, 0));
        try require(try number(try field(lifecycle_value, "packet_limit")) == 64 and try number(try field(lifecycle_value, "flush_timeout_ns")) == 2_000_000_000);
        const sequences = try items(try field(lifecycle_value, "cases"));
        try require(sequences.len == 7);
        for (sequences) |case| try lifecycle(case);
        try output.writeAll("Verified 10 sender cases, 11 receive sequences, 5 SCTP boundary cases, 6 receipt sequences and 7 lifecycle sequences\n");
    }
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |wanted| if (std.mem.eql(u8, wanted, name)) return true;
    return false;
}

fn keys(value: Value, expected: []const []const u8) !void {
    try require(value == .object and value.object.count() == expected.len);
    for (expected) |name| try require(value.object.contains(name));
}

fn hexString(value: []const u8, length: usize) !void {
    try require(value.len == length);
    for (value) |byte| try require((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
}

fn repositoryUrl(url: []const u8) !void {
    const prefix = "https://github.com/";
    try require(std.mem.startsWith(u8, url, prefix));
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '/');
    for (0..2) |_| {
        const part = parts.next() orelse return error.InvalidFixture;
        try require(part.len != 0);
        for (part) |byte| try require(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-');
    }
    try require(parts.next() == null);
}

fn sourceMetadata(source: Value, repository: ?[]const u8, branch: ?[]const u8) !void {
    try keys(source, &.{ "repository", "branch", "revision" });
    const url = try text(try field(source, "repository"));
    try repositoryUrl(url);
    if (repository) |expected| try same(try field(source, "repository"), expected);
    const actual_branch = try text(try field(source, "branch"));
    try require(actual_branch.len != 0);
    if (branch) |expected| try same(try field(source, "branch"), expected);
    try hexString(try text(try field(source, "revision")), 40);
}

fn sourcesMetadata(sources: Value, blocks: bool) !void {
    try keys(sources, if (blocks) &.{ "NBT", "BinaryUtils", "BedrockProtocol", "PocketMine-MP" } else &.{ "NBT", "BedrockProtocol" });
    try sourceMetadata(try field(sources, "NBT"), "https://github.com/pmmp/NBT", "stable");
    try sourceMetadata(try field(sources, "BedrockProtocol"), "https://github.com/axolotl-pm/BedrockProtocol", "master");
    if (blocks) {
        try sourceMetadata(try field(sources, "BinaryUtils"), "https://github.com/pmmp/BinaryUtils", "stable");
        try sourceMetadata(try field(sources, "PocketMine-MP"), "https://github.com/axolotl-pm/PocketMine-MP", "stable");
    }
}

fn fileMetadata(raw: []const u8, metadata: Value) !void {
    try keys(metadata, &.{ "bytes", "sha256" });
    try require(raw.len == try number(try field(metadata, "bytes")));
    try digest(raw, try text(try field(metadata, "sha256")));
}

fn equal(a: Value, b: Value, depth: usize) bool {
    if (depth == 16) return false;
    return switch (a) {
        .object => blk: {
            if (b != .object or a.object.count() != b.object.count()) break :blk false;
            var iterator = a.object.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equal(entry.value_ptr.*, other, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .array => blk: {
            if (b != .array or a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |left, right| if (!equal(left, right, depth + 1)) break :blk false;
            break :blk true;
        },
        .string => b == .string and std.mem.eql(u8, a.string, b.string),
        .integer => b == .integer and a.integer == b.integer,
        .bool => b == .bool and a.bool == b.bool,
        .null => b == .null,
        else => false,
    };
}

fn mappingDigest(arena: Allocator, source: Value) ![64]u8 {
    try require(source == .object and source.object.count() <= 65536);
    const names = try arena.dupe([]const u8, source.object.keys());
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (names) |name| {
        for (name) |byte| try require(byte < 128);
        const id = try field(try field(source, name), "runtime_id");
        try require(id == .integer);
        var buffer: [24]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&buffer, "\t{d}\n", .{id.integer});
        hasher.update(name);
        hasher.update(suffix);
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

fn blockFiles(arena: Allocator, count: usize) ![][]const u8 {
    try require(count > 0 and count <= 64);
    const names = try arena.alloc([]const u8, count + 4);
    @memcpy(names[0..4], &[_][]const u8{ "input.json", "expected.json", "dictionary.json", "dictionary.network.nbt" });
    for (0..count) |index| names[index + 4] = try std.fmt.allocPrint(arena, "case-{d}.network.nbt", .{index});
    return names;
}

fn blockSummary(summary: Value) !u64 {
    const names = try number(try field(summary, "names"));
    const roots = try number(try field(summary, "roots"));
    try require(names > 0 and names <= roots and roots <= 65536);
    try hexString(try text(try field(summary, "semantic_sha256")), 64);
    return roots;
}

fn sender(arena: Allocator, case: Value) !void {
    if (transport.has(case, "error")) {
        const err = try field(case, "error");
        try require(err == .bool);
        if (err.bool) return;
    }
    const payload = try unhex(arena, try field(case, "payload_hex"));
    const frames = try items(try field(case, "frames_hex"));
    const capacity = try number(try field(case, "capacity"));
    var offset: usize = 0;
    for (frames, 0..) |frame_hex, index| {
        const frame = try unhex(arena, frame_hex);
        try require(frame.len > 0 and frame.len - 1 <= capacity and frame[0] == frames.len - index - 1);
        const length = frame.len - 1;
        try require(length <= payload.len - offset);
        try require(std.mem.eql(u8, frame[1..], payload[offset..][0..length]));
        offset += length;
    }
    try require(offset == payload.len);
}

fn receiver(case: Value) !void {
    const frames = try items(try field(case, "frames_hex"));
    const results = try items(try field(case, "results"));
    try require(frames.len == results.len);
    for (results) |result| try require(result == .object and result.object.count() == 1 and (transport.has(result, "pending") or transport.has(result, "error") or transport.has(result, "payload_hex")));
}

fn receipts(arena: Allocator, case: Value) !void {
    const packets = try items(try field(case, "packets"));
    const seen = try arena.alloc(bool, packets.len);
    @memset(seen, false);
    for (try items(try field(case, "phases"))) |phase| {
        for (try items(try field(phase, "acknowledged"))) |value| {
            const ticket = try number(value);
            try require(ticket >= 1 and ticket <= packets.len);
            try require(!seen[@intCast(ticket - 1)]);
            seen[@intCast(ticket - 1)] = true;
        }
    }
}

fn lifecycle(case: Value) !void {
    var previous: u64 = 0;
    for (try items(try field(case, "phases"))) |phase| {
        const time = try number(try field(phase, "time_ns"));
        try require(time >= previous);
        try require(contains(&.{ "CONNECTED", "CLOSED", "FAILED" }, try text(try field(phase, "transport"))));
        previous = time;
    }
}

test "fixture file metadata rejects size, digest and file-set drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const metadata = try json(arena.allocator(), "{\"bytes\":3,\"sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}");
    try fileMetadata("abc", metadata);
    try std.testing.expectError(error.InvalidFixture, fileMetadata("ab", metadata));
    try std.testing.expectError(error.DigestMismatch, fileMetadata("abd", metadata));
    try std.testing.expectError(error.InvalidFixture, keys(try json(arena.allocator(), "{\"../unexpected\":{}}"), &.{"expected.json"}));
}

test "fixture source metadata rejects malformed or unrecorded provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try json(arena.allocator(), "{\"repository\":\"https://github.com/pmmp/NBT\",\"branch\":\"stable\",\"revision\":\"5429a21c9321eb154f7fcdaa789d2b5ccbcc6ea3\"}");
    try sourceMetadata(source, "https://github.com/pmmp/NBT", "stable");
    try std.testing.expectError(error.InvalidFixture, sourceMetadata(source, "https://github.com/pmmp/Math", "stable"));
    try std.testing.expectError(error.InvalidFixture, sourceMetadata(source, null, "other"));
    for ([_][]const u8{ "http://github.com/a/b", "https://github.com//b", "https://github.com/a/b/c", "https://github.com/a/b?x" }) |url| try std.testing.expectError(error.InvalidFixture, repositoryUrl(url));
    try std.testing.expectError(error.InvalidFixture, hexString("main", 40));
    try std.testing.expectError(error.InvalidFixture, hexString("ABCDEF", 6));
    const changed = try json(arena.allocator(), "{\"repository\":\"https://github.com/pmmp/NBT\",\"branch\":\"other\",\"revision\":\"5429a21c9321eb154f7fcdaa789d2b5ccbcc6ea3\"}");
    try std.testing.expect(!equal(source, changed, 0));
}

test "complete mapping digest sorts ASCII keys and retains signed IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const a = try json(gpa, "{\"z\":{\"runtime_id\":32767},\"a\":{\"runtime_id\":-32768}}");
    const b = try json(gpa, "{\"a\":{\"runtime_id\":-32768},\"z\":{\"runtime_id\":32767}}");
    const actual = try mappingDigest(gpa, a);
    try std.testing.expectEqualSlices(u8, &actual, &(try mappingDigest(gpa, b)));
    try digest("a\t-32768\nz\t32767\n", &actual);
    try std.testing.expectError(error.InvalidFixture, mappingDigest(gpa, try json(gpa, "{\"a\":{\"runtime_id\":\"1\"}}")));
}

test "block fixture file set and semantic summary have bounded counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectError(error.InvalidFixture, blockFiles(gpa, 0));
    try std.testing.expectError(error.InvalidFixture, blockFiles(gpa, 65));
    const names = try blockFiles(gpa, 64);
    try std.testing.expectEqualStrings("case-63.network.nbt", names[67]);
    const summary = try json(gpa, "{\"names\":2,\"roots\":1,\"semantic_sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}");
    try std.testing.expectError(error.InvalidFixture, blockSummary(summary));
}

test "framing fixture validation rejects countdown, payload and result drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try sender(gpa, try json(gpa, "{\"error\":true}"));
    try sender(gpa, try json(gpa, "{\"capacity\":1,\"payload_hex\":\"6162\",\"frames_hex\":[\"0161\",\"0062\"]}"));
    for ([_][]const u8{
        "{\"capacity\":1,\"payload_hex\":\"6162\",\"frames_hex\":[\"0061\",\"0062\"]}",
        "{\"capacity\":1,\"payload_hex\":\"61\",\"frames_hex\":[\"0062\"]}",
        "{\"capacity\":1,\"payload_hex\":\"61\",\"frames_hex\":[\"006162\"]}",
        "{\"capacity\":1,\"payload_hex\":\"61\",\"frames_hex\":[]}",
        "{\"capacity\":1,\"payload_hex\":\"61\",\"frames_hex\":[\"\"]}",
    }) |raw| try std.testing.expectError(error.InvalidFixture, sender(gpa, try json(gpa, raw)));
    try std.testing.expectError(error.InvalidFixture, receiver(try json(gpa, "{\"frames_hex\":[\"0061\"],\"results\":[]}")));
    try std.testing.expectError(error.InvalidFixture, receiver(try json(gpa, "{\"frames_hex\":[\"0061\"],\"results\":[{\"pending\":true,\"payload_hex\":\"61\"}]}")));
}

test "receipt and lifecycle fixtures reject duplicate tickets and reversed clocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try receipts(gpa, try json(gpa, "{\"packets\":[{}],\"phases\":[{\"acknowledged\":[1]}]}"));
    for ([_][]const u8{
        "{\"packets\":[{}],\"phases\":[{\"acknowledged\":[1]},{\"acknowledged\":[1]}]}",
        "{\"packets\":[{}],\"phases\":[{\"acknowledged\":[0]}]}",
        "{\"packets\":[{}],\"phases\":[{\"acknowledged\":[2]}]}",
    }) |raw| try std.testing.expectError(error.InvalidFixture, receipts(gpa, try json(gpa, raw)));
    try std.testing.expectError(error.InvalidFixture, lifecycle(try json(gpa, "{\"phases\":[{\"time_ns\":1,\"transport\":\"CONNECTED\"},{\"time_ns\":0,\"transport\":\"CLOSED\"}]}")));
    try std.testing.expectError(error.InvalidFixture, lifecycle(try json(gpa, "{\"phases\":[{\"time_ns\":0,\"transport\":\"UNKNOWN\"}]}")));
}
