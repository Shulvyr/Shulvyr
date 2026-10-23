const std = @import("std");
const common = @import("reference_sources.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const max_json_bytes = 2 * 1024 * 1024;
const max_entries = 65_536;
const input_names = [_][]const u8{
    "LICENSE",                    "biome_id_map.json",  "block_state_meta_map.json",
    "canonical_block_states.nbt", "protocol_info.json", "required_item_list.json",
};
const Row = struct { key: []const u8, network_id: i32 };
const Table = struct { rows: []Row, order: []u32 };
const Inputs = struct { manifest: Value, files: [input_names.len][]const u8 };
const Kind = enum { item, biome };

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var output_buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    var error_buffer: [256]u8 = undefined;
    var errors: std.Io.File.Writer = .init(.stderr(), init.io, &error_buffer);
    execute(init.arena.allocator(), init.io, arguments[1..], &output.interface) catch |err| {
        try errors.interface.print("error: {s}\n", .{@errorName(err)});
        try errors.interface.flush();
        return 1;
    };
    try output.interface.flush();
    return 0;
}

fn execute(allocator: Allocator, io: std.Io, arguments: []const []const u8, output: *std.Io.Writer) !void {
    var root: []const u8 = ".";
    var check = false;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--check")) {
            if (check) return error.InvalidArguments;
            check = true;
        } else if (std.mem.eql(u8, argument, "--root")) {
            index += 1;
            if (index == arguments.len) return error.InvalidArguments;
            root = arguments[index];
        } else return error.InvalidArguments;
    }
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    const inputs = try load(allocator, io, directory);
    const source = try directory.readFileAlloc(io, "tools/generate_registries.zig", allocator, .limited(1024 * 1024));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
    const generated = try render(allocator, inputs, &std.fmt.bytesToHex(hash, .lower));
    const destination = "src/registry/generated.zig";
    if (check) {
        const actual = try directory.readFileAlloc(io, destination, allocator, .limited(2 * 1024 * 1024));
        if (!std.mem.eql(u8, actual, generated)) return error.StaleRegistryOutput;
        try output.writeAll("Verified registry input hashes, schemas and generated output\n");
    } else {
        try directory.writeFile(io, .{ .sub_path = destination, .data = generated });
        try output.writeAll("Generated src/registry/generated.zig\n");
    }
}

fn load(allocator: Allocator, io: std.Io, directory: std.Io.Dir) !Inputs {
    const raw = try directory.readFileAlloc(io, "data/bedrock/manifest.json", allocator, .limited(64 * 1024));
    const manifest = try json(allocator, raw);
    if (manifest != .object or manifest.object.count() != 3 or try integer(try field(manifest, "schema"), 1, 1) != 1) return error.InvalidRegistryManifest;
    try sourceMetadata(try field(manifest, "source"));
    const entries = try field(manifest, "files");
    if (entries != .object or entries.object.count() != input_names.len) return error.InvalidRegistryManifest;
    var result: Inputs = .{ .manifest = manifest, .files = undefined };
    for (input_names, &result.files) |name, *bytes| {
        const metadata = try field(entries, name);
        const limit: usize = if (std.mem.eql(u8, name, "canonical_block_states.nbt")) 8 * 1024 * 1024 else max_json_bytes;
        const expected_size = try integer(try field(metadata, "bytes"), 0, @intCast(limit));
        if (metadata != .object or metadata.object.count() != 2) return error.InvalidRegistryManifest;
        const path = try std.fmt.allocPrint(allocator, "data/bedrock/{s}", .{name});
        bytes.* = try directory.readFileAlloc(io, path, allocator, .limited(limit));
        if (bytes.len != @as(usize, @intCast(expected_size))) return error.RegistryInputMismatch;
        try digest(bytes.*, try text(try field(metadata, "sha256")));
    }
    return result;
}

fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidRegistryData;
    return value.object.get(name) orelse error.InvalidRegistryData;
}
fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidRegistryData;
    return value.string;
}
fn integer(value: Value, minimum: i64, maximum: i64) !i64 {
    if (value != .integer or value.integer < minimum or value.integer > maximum) return error.InvalidRegistryData;
    return value.integer;
}
fn flag(value: Value) !bool {
    if (value != .bool) return error.InvalidRegistryData;
    return value.bool;
}
fn json(allocator: Allocator, bytes: []const u8) !Value {
    if (bytes.len > max_json_bytes) return error.RegistryInputTooLong;
    return common.parse(allocator, bytes);
}
fn digest(bytes: []const u8, expected: []const u8) !void {
    var wanted: [32]u8 = undefined;
    if (expected.len != 64) return error.InvalidRegistryManifest;
    for (expected) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidRegistryManifest;
    _ = std.fmt.hexToBytes(&wanted, expected) catch return error.InvalidRegistryManifest;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &wanted, &actual)) return error.RegistryInputMismatch;
}

fn sourceMetadata(value: Value) !void {
    if (value != .object or value.object.count() != 4) return error.InvalidRegistrySource;
    const repository = try text(try field(value, "repository"));
    if (repository.len > 2048 or !std.mem.startsWith(u8, repository, "https://")) return error.InvalidRegistrySource;
    var parts = std.mem.splitScalar(u8, repository[8..], '/');
    const host = parts.next().?;
    if (host.len == 0) return error.InvalidRegistrySource;
    for (host) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return error.InvalidRegistrySource;
    var paths: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidRegistrySource;
        for (part) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._~-", byte) == null) return error.InvalidRegistrySource;
        paths += 1;
    }
    if (paths == 0) return error.InvalidRegistrySource;
    const branch = try text(try field(value, "branch"));
    if (branch.len == 0 or branch.len > 256) return error.InvalidRegistrySource;
    for (branch) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._/-", byte) == null) return error.InvalidRegistrySource;
    const revision = try text(try field(value, "revision"));
    if (revision.len != 40) return error.InvalidRegistrySource;
    for (revision) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidRegistrySource;
    if (!std.mem.eql(u8, try text(try field(value, "license")), "CC0-1.0")) return error.InvalidRegistrySource;
}

fn resourceKey(key: []const u8) !void {
    if (key.len > 256) return error.InvalidRegistryData;
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return error.InvalidRegistryData;
    if (colon == 0 or colon + 1 == key.len) return error.InvalidRegistryData;
    for (key, 0..) |byte, index| {
        if (index == colon) continue;
        if ((byte >= 'a' and byte <= 'z') or std.ascii.isDigit(byte) or std.mem.indexOfScalar(u8, "_.-", byte) != null or (index > colon and byte == '/')) continue;
        return error.InvalidRegistryData;
    }
}

fn canonicalBase64(allocator: Allocator, encoded: []const u8) !void {
    if (encoded.len > 131_072) return error.InvalidRegistryData;
    const decoder = std.base64.standard.Decoder;
    const encoder = std.base64.standard.Encoder;
    const length = decoder.calcSizeForSlice(encoded) catch return error.InvalidRegistryData;
    const decoded = try allocator.alloc(u8, length);
    decoder.decode(decoded, encoded) catch return error.InvalidRegistryData;
    const canonical = try allocator.alloc(u8, encoder.calcSize(length));
    if (!std.mem.eql(u8, encoder.encode(canonical, decoded), encoded)) return error.InvalidRegistryData;
}

fn table(allocator: Allocator, value: Value, kind: Kind) !Table {
    if (value != .object or value.object.count() == 0 or value.object.count() > max_entries) return error.InvalidRegistryData;
    const rows = try allocator.alloc(Row, value.object.count());
    var entries = value.object.iterator();
    var index: usize = 0;
    while (entries.next()) |entry| : (index += 1) {
        var name = entry.key_ptr.*;
        const data = entry.value_ptr.*;
        const network_id = switch (kind) {
            .item => blk: {
                try resourceKey(name);
                if (data != .object or (data.object.count() != 3 and data.object.count() != 4)) return error.InvalidRegistryData;
                _ = try flag(try field(data, "component_based"));
                _ = try integer(try field(data, "version"), 0, 2);
                if (data.object.get("component_nbt")) |component| try canonicalBase64(allocator, try text(component)) else if (data.object.count() != 3) return error.InvalidRegistryData;
                break :blk try integer(try field(data, "runtime_id"), -32768, 32767);
            },
            .biome => blk: {
                if (std.mem.indexOfScalar(u8, name, ':') != null) return error.InvalidRegistryData;
                name = try std.fmt.allocPrint(allocator, "minecraft:{s}", .{name});
                try resourceKey(name);
                break :blk try integer(data, 0, std.math.maxInt(i32));
            },
        };
        rows[index] = .{ .key = name, .network_id = @intCast(network_id) };
    }
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);
    const order = try allocator.alloc(u32, rows.len);
    for (order, 0..) |*slot, position| slot.* = @intCast(position);
    std.mem.sort(u32, order, rows, struct {
        fn less(values: []const Row, a: u32, b: u32) bool {
            return values[a].network_id < values[b].network_id;
        }
    }.less);
    for (order[1..], order[0 .. order.len - 1]) |current, previous| if (rows[current].network_id == rows[previous].network_id) return error.DuplicateNetworkId;
    return .{ .rows = rows, .order = order };
}

fn required(rows: []const Row, name: []const u8) !void {
    for (rows) |row| if (std.mem.eql(u8, row.key, name)) return;
    return error.MissingRequiredMapping;
}
fn parseMetadata(value: Value) !void {
    if (value != .array or value.array.items.len > max_entries) return error.InvalidRegistryData;
    for (value.array.items) |entry| _ = try integer(entry, std.math.minInt(i32), std.math.maxInt(i32));
}

fn render(allocator: Allocator, inputs: Inputs, generator_hash: []const u8) ![]u8 {
    const items = try table(allocator, try json(allocator, inputs.files[5]), .item);
    const biomes = try table(allocator, try json(allocator, inputs.files[1]), .biome);
    try parseMetadata(try json(allocator, inputs.files[2]));
    try required(items.rows, "minecraft:air");
    try required(items.rows, "minecraft:stone");
    try required(biomes.rows, "minecraft:ocean");
    try required(biomes.rows, "minecraft:plains");
    const version = try field(try json(allocator, inputs.files[4]), "version");
    if (version != .object or version.object.count() != 6) return error.InvalidRegistryData;
    var numbers: [5]i64 = undefined;
    for ([_][]const u8{ "major", "minor", "patch", "revision", "protocol_version" }, &numbers) |name, *number| number.* = try integer(try field(version, name), 0, std.math.maxInt(i32));
    const beta = try flag(try field(version, "beta"));
    const source = try field(inputs.manifest, "source");
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    const writer = &allocating.writer;
    try writer.writeAll("// Generated by tools/generate_registries.zig. Do not edit.\n// Source data: CC0-1.0, see data/bedrock/LICENSE.\nconst Row = @import(\"Registry.zig\").Row;\n\npub const source = .{\n");
    for ([_][]const u8{ "repository", "branch", "revision" }) |name| try writer.print("    .{s} = \"{s}\",\n", .{ name, try text(try field(source, name)) });
    try writer.print("    .generator_sha256 = \"{s}\",\n    .protocol = @as(u32, {d}),\n    .version = \"{d}.{d}.{d}.{d}\",\n    .beta = {s},\n}};\n", .{ generator_hash, numbers[4], numbers[0], numbers[1], numbers[2], numbers[3], if (beta) "true" else "false" });
    for ([_]struct { name: []const u8, value: Table }{ .{ .name = "item", .value = items }, .{ .name = "biome", .value = biomes } }) |entry| {
        try writer.print("\npub const {s}s = [_]Row{{\n", .{entry.name});
        for (entry.value.rows) |row| try writer.print("    .{{ .key = \"{s}\", .network_id = {d} }},\n", .{ row.key, row.network_id });
        try writer.print("}};\n\npub const {s}_network_order = [_]u32{{\n", .{entry.name});
        for (entry.value.order) |position| try writer.print("    {d},\n", .{position});
        try writer.writeAll("};\n");
    }
    return allocating.toOwnedSlice();
}

test "registry state metadata preserves signed i32 values and rejects other types" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try parseMetadata(try json(allocator, "[-2147483648,0,509,2147483647]"));
    for ([_][]const u8{ "{}", "[true]", "[1.0]", "[\"1\"]", "[-2147483649]", "[2147483648]" }) |raw| try std.testing.expectError(error.InvalidRegistryData, parseMetadata(try json(allocator, raw)));
}

test "registry JSON refuses duplicate fields at every depth and oversized input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "{\"a\":1,\"a\":2}", "{\"a\":{\"id\":1,\"id\":1}}" }) |raw| try std.testing.expectError(error.DuplicateField, json(arena.allocator(), raw));
    const excessive = try arena.allocator().alloc(u8, max_json_bytes + 1);
    try std.testing.expectError(error.RegistryInputTooLong, json(arena.allocator(), excessive));
}

test "registry rejects duplicate network IDs independently of domain" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.DuplicateNetworkId, table(allocator, try json(allocator, "{\"one\":7,\"two\":7}"), .biome));
    const item = "{\"runtime_id\":7,\"component_based\":false,\"version\":2}";
    try std.testing.expectError(error.DuplicateNetworkId, table(allocator, try json(allocator, "{\"a:b\":" ++ item ++ ",\"a:c\":" ++ item ++ "}"), .item));
}

test "registry requires explicit mappings and a nonempty source dictionary" {
    try std.testing.expectError(error.MissingRequiredMapping, required(&.{.{ .key = "minecraft:stone", .network_id = 1 }}, "minecraft:air"));
    try required(&.{.{ .key = "minecraft:stone", .network_id = 1 }}, "minecraft:stone");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRegistryData, table(arena.allocator(), try json(arena.allocator(), "{}"), .item));
}

test "registry item schema changes require explicit support" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{
        "{\"runtime_id\":7}",
        "{\"runtime_id\":7,\"component_based\":false,\"version\":2,\"extra\":1}",
        "{\"runtime_id\":7,\"component_based\":false,\"version\":3}",
        "{\"runtime_id\":7,\"component_based\":1,\"version\":2}",
    }) |item| {
        const raw = try std.fmt.allocPrint(allocator, "{{\"a:b\":{s}}}", .{item});
        try std.testing.expectError(error.InvalidRegistryData, table(allocator, try json(allocator, raw), .item));
    }
}

test "registry numeric domains reject coercion and retain signed item boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "true", "1.0", "\"1\"", "-32769", "32768" }) |value| {
        const raw = try std.fmt.allocPrint(allocator, "{{\"a:b\":{{\"runtime_id\":{s},\"component_based\":false,\"version\":2}}}}", .{value});
        try std.testing.expectError(error.InvalidRegistryData, table(allocator, try json(allocator, raw), .item));
    }
    for ([_][]const u8{ "true", "-1", "2147483648" }) |value| {
        const raw = try std.fmt.allocPrint(allocator, "{{\"one\":{s}}}", .{value});
        try std.testing.expectError(error.InvalidRegistryData, table(allocator, try json(allocator, raw), .biome));
    }
    const result = try table(allocator, try json(allocator, "{\"a:a\":{\"runtime_id\":-32768,\"component_based\":false,\"version\":2},\"a:b\":{\"runtime_id\":32767,\"component_based\":false,\"version\":2}}"), .item);
    try std.testing.expectEqual(-32768, result.rows[0].network_id);
    try std.testing.expectEqual(32767, result.rows[1].network_id);
}

test "registry resource keys reject invalid namespaces, bytes and lengths" {
    for ([_][]const u8{ "stone", "a:", ":a", "a:B", "a:b:c", "a:b\x00", "a/b:c" }) |key| try std.testing.expectError(error.InvalidRegistryData, resourceKey(key));
    var long: [257]u8 = @splat('a');
    long[1] = ':';
    try std.testing.expectError(error.InvalidRegistryData, resourceKey(&long));
    try resourceKey("minecraft:path/to_stone-1.0");
}

test "registry component payloads require canonical padded standard base64" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try canonicalBase64(allocator, "Zg==");
    try canonicalBase64(allocator, "");
    for ([_][]const u8{ "!!!!", "Zh==", "Zg", "Zg==\n", "-_==" }) |value| try std.testing.expectError(error.InvalidRegistryData, canonicalBase64(allocator, value));
    const excessive = try allocator.alloc(u8, 131_073);
    try std.testing.expectError(error.InvalidRegistryData, canonicalBase64(allocator, excessive));
}

test "registry table output and numeric order do not depend on JSON object order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const a = try table(allocator, try json(allocator, "{\"one\":9,\"two\":1}"), .biome);
    const b = try table(allocator, try json(allocator, "{\"two\":1,\"one\":9}"), .biome);
    for (a.rows, b.rows) |first, second| {
        try std.testing.expectEqualStrings(first.key, second.key);
        try std.testing.expectEqual(first.network_id, second.network_id);
    }
    try std.testing.expectEqualSlices(u32, a.order, b.order);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, a.order);
}

test "registry provenance accepts a different supplier without network access" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const inputs = try load(arena.allocator(), std.testing.io, .cwd());
    const source = try field(inputs.manifest, "source");
    source.object.getPtr("repository").?.* = .{ .string = "https://example.invalid/owned/bedrock-data" };
    source.object.getPtr("branch").?.* = .{ .string = "data/client-snapshot" };
    try sourceMetadata(source);
    const generated = try render(arena.allocator(), inputs, "synthetic-generator-hash");
    try std.testing.expect(std.mem.indexOf(u8, generated, ".repository = \"https://example.invalid/owned/bedrock-data\"") != null);
}

test "registry replacement provenance still rejects credentials, injection and unpinned revisions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const inputs = try load(arena.allocator(), std.testing.io, .cwd());
    const source = try field(inputs.manifest, "source");
    const repository = source.object.getPtr("repository").?;
    for ([_][]const u8{ "http://example.invalid/a/b", "https://token@example.invalid/a/b", "https://example.invalid/a/b?token=secret", "https://example.invalid/a/\"", "https://example.invalid/a/\n" }) |value| {
        repository.* = .{ .string = value };
        try std.testing.expectError(error.InvalidRegistrySource, sourceMetadata(source));
    }
    repository.* = .{ .string = "https://example.invalid/a/b" };
    source.object.getPtr("revision").?.* = .{ .string = "main" };
    try std.testing.expectError(error.InvalidRegistrySource, sourceMetadata(source));
}

test "registry input hashes detect byte changes and malformed digest metadata" {
    const hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try digest("abc", hash);
    try std.testing.expectError(error.RegistryInputMismatch, digest("abd", hash));
    try std.testing.expectError(error.InvalidRegistryManifest, digest("abc", "bad"));
}

test "registry generation retains every source mapping" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const inputs = try load(allocator, std.testing.io, .cwd());
    const generated = try render(allocator, inputs, "synthetic-generator-hash");
    const items = try json(allocator, inputs.files[5]);
    const biomes = try json(allocator, inputs.files[1]);
    try std.testing.expectEqual(items.object.count() + biomes.object.count(), std.mem.count(u8, generated, ".{ .key ="));
    var entries = items.object.iterator();
    while (entries.next()) |entry| {
        const expected = try std.fmt.allocPrint(allocator, ".{{ .key = \"{s}\", .network_id = {d} }},", .{ entry.key_ptr.*, try integer(try field(entry.value_ptr.*, "runtime_id"), -32768, 32767) });
        try std.testing.expect(std.mem.indexOf(u8, generated, expected) != null);
    }
    entries = biomes.object.iterator();
    while (entries.next()) |entry| {
        const expected = try std.fmt.allocPrint(allocator, ".{{ .key = \"minecraft:{s}\", .network_id = {d} }},", .{ entry.key_ptr.*, try integer(entry.value_ptr.*, 0, std.math.maxInt(i32)) });
        try std.testing.expect(std.mem.indexOf(u8, generated, expected) != null);
    }
}
