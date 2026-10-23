const std = @import("std");
const BlockState = @import("BlockState.zig");
const ResourceKey = @import("ResourceKey.zig");
const BlockPalette = @This();

// Owns three allocations. Do not copy a live palette or use views after deinit.

pub const Id = struct { owner: u64, index: u32 };
pub const NetworkId = struct { value: u32 };
pub const Limits = struct {
    max_bytes: usize = 8 * 1024 * 1024,
    max_states: usize = 65_536,
    max_allocated_bytes: usize = 32 * 1024 * 1024,
    max_work: usize = 64 * 1024 * 1024,
};
pub const Error = BlockState.Error || error{ InvalidOwner, StateLimit, MetadataMismatch, DuplicateState };
pub const View = struct {
    key: ResourceKey,
    version: i32,
    metadata: i32,
    property_key: []const u8,
};
const Entry = struct {
    key: ResourceKey,
    version: i32,
    metadata: i32,
    input_offset: u32,
    input_length: u32,
    property_offset: u32,
    property_length: u32,
    internal_index: u32,
};
const Budget = struct {
    remaining: usize,

    fn spend(self: *Budget, amount: usize) Error!void {
        if (amount > self.remaining) return error.WorkLimit;
        self.remaining -= amount;
    }
};

allocator: std.mem.Allocator,
input: []const u8,
entries: []Entry,
order: []u32,
property_storage: []u8,
owner: u64,
source_sha256: [32]u8,
build_work: usize,

/// Borrows immutable input until deinit. Metadata values are copied.
/// Owner identifies this palette lifetime and must not be reused for stale IDs.
pub fn init(allocator: std.mem.Allocator, input: []const u8, metadata: []const i32, owner: u64, limits: Limits) Error!BlockPalette {
    if (owner == 0) return error.InvalidOwner;
    if (limits.max_states > 65_536 or limits.max_bytes > 8 * 1024 * 1024) return error.InvalidLimits;
    if (input.len > limits.max_bytes) return error.ByteLimit;
    if (metadata.len > limits.max_states) return error.StateLimit;
    var budget: Budget = .{ .remaining = limits.max_work };
    var offset: usize = 0;
    var state_count: usize = 0;
    var property_bytes: usize = 0;
    var scratch: [16 * 1024]u8 = undefined;
    while (offset < input.len) {
        if (state_count == limits.max_states) return error.StateLimit;
        try budget.spend(1);
        const prefix = try BlockState.decodePrefix(allocator, input[offset..], .network, rootLimits(limits.max_allocated_bytes, budget.remaining));
        const properties = try prefix.state.encodeProperties(&scratch);
        try budget.spend(prefix.bytes_read + properties.len);
        property_bytes = std.math.add(usize, property_bytes, properties.len) catch return error.AllocationLimit;
        offset += prefix.bytes_read;
        state_count += 1;
    }
    if (state_count != metadata.len) return error.MetadataMismatch;
    const entry_bytes = std.math.mul(usize, state_count, @sizeOf(Entry)) catch return error.AllocationLimit;
    const index_bytes = std.math.mul(usize, state_count, @sizeOf(u32)) catch return error.AllocationLimit;
    const retained = std.math.add(usize, entry_bytes, index_bytes) catch return error.AllocationLimit;
    const total = std.math.add(usize, retained, property_bytes) catch return error.AllocationLimit;
    if (total > limits.max_allocated_bytes or property_bytes > std.math.maxInt(u32)) return error.AllocationLimit;
    const entries = try allocator.alloc(Entry, state_count);
    errdefer allocator.free(entries);
    const order = try allocator.alloc(u32, state_count);
    errdefer allocator.free(order);
    const storage = try allocator.alloc(u8, property_bytes);
    errdefer allocator.free(storage);
    var result: BlockPalette = .{
        .allocator = allocator,
        .input = input,
        .entries = entries,
        .order = order,
        .property_storage = storage,
        .owner = owner,
        .source_sha256 = undefined,
        .build_work = undefined,
    };
    offset = 0;
    var property_offset: usize = 0;
    for (entries, order, metadata, 0..) |*entry, *ordered, meta, index| {
        try budget.spend(1);
        const prefix = try BlockState.decodePrefix(allocator, input[offset..], .network, rootLimits(limits.max_allocated_bytes - total, budget.remaining));
        const properties = try prefix.state.encodeProperties(&scratch);
        try budget.spend(prefix.bytes_read + properties.len);
        @memcpy(storage[property_offset..][0..properties.len], properties);
        entry.* = .{
            .key = prefix.state.key,
            .version = prefix.state.version,
            .metadata = meta,
            .input_offset = @intCast(offset),
            .input_length = @intCast(prefix.bytes_read),
            .property_offset = @intCast(property_offset),
            .property_length = @intCast(properties.len),
            .internal_index = undefined,
        };
        ordered.* = @intCast(index);
        offset += prefix.bytes_read;
        property_offset += properties.len;
    }
    try result.sort(&budget);
    for (order, 0..) |network, internal| {
        if (internal > 0 and try result.compareEntries(order[internal - 1], network, &budget) == .eq) return error.DuplicateState;
        entries[network].internal_index = @intCast(internal);
    }
    try budget.spend(input.len);
    std.crypto.hash.sha2.Sha256.hash(input, &result.source_sha256, .{});
    result.build_work = limits.max_work - budget.remaining;
    return result;
}

pub fn deinit(self: *BlockPalette) void {
    self.allocator.free(self.property_storage);
    self.allocator.free(self.order);
    self.allocator.free(self.entries);
    self.* = undefined;
}

pub fn count(self: *const BlockPalette) usize {
    return self.entries.len;
}

pub fn fromNetwork(self: *const BlockPalette, id: NetworkId) ?Id {
    if (id.value >= self.entries.len) return null;
    return .{ .owner = self.owner, .index = self.entries[id.value].internal_index };
}

pub fn toNetwork(self: *const BlockPalette, id: Id) ?NetworkId {
    if (id.owner != self.owner or id.index >= self.order.len) return null;
    return .{ .value = self.order[id.index] };
}

pub fn get(self: *const BlockPalette, id: Id) ?View {
    const network = self.toNetwork(id) orelse return null;
    const entry = self.entries[network.value];
    return .{ .key = entry.key, .version = entry.version, .metadata = entry.metadata, .property_key = self.propertyKey(entry) };
}

/// Borrows exactly the original encoded root, for decoding or diagnostics.
pub fn encodedRoot(self: *const BlockPalette, id: Id) ?[]const u8 {
    const network = self.toNetwork(id) orelse return null;
    const entry = self.entries[network.value];
    return self.input[entry.input_offset..][0..entry.input_length];
}

/// Version is deliberately excluded from identity. No default-state fallback.
pub fn find(self: *const BlockPalette, state: *const BlockState, max_work: usize) Error!?Id {
    if (state.property_count > BlockState.max_properties) return error.InvalidBlockState;
    _ = try ResourceKey.parse(state.key.bytes);
    for (state.properties(), 0..) |property, position| {
        if (property.name.len > BlockState.max_property_name_bytes) return error.PropertyLimit;
        if (position > 0 and std.mem.order(u8, state.property_storage[position - 1].name, property.name) != .lt) return error.InvalidBlockState;
        switch (property.value) {
            .string => |text| if (text.len > BlockState.max_property_string_bytes) return error.PropertyLimit,
            else => {},
        }
    }
    var scratch: [16 * 1024]u8 = undefined;
    const properties = try state.encodeProperties(&scratch);
    var budget: Budget = .{ .remaining = max_work };
    try budget.spend(state.key.bytes.len + properties.len + 1);
    var lower: usize = 0;
    var upper = self.order.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const entry = self.entries[self.order[middle]];
        const name_order = try compareBytes(entry.key.bytes, state.key.bytes, &budget);
        const comparison = if (name_order == .eq) try compareBytes(self.propertyKey(entry), properties, &budget) else name_order;
        switch (comparison) {
            .lt => lower = middle + 1,
            .gt => upper = middle,
            .eq => return .{ .owner = self.owner, .index = @intCast(middle) },
        }
    }
    return null;
}

/// Matches the reference metadata shortcut and last-input-entry selection.
pub fn findByMetadata(self: *const BlockPalette, name: []const u8, metadata: i32, max_work: usize) Error!?Id {
    _ = ResourceKey.parse(name) catch return null;
    var budget: Budget = .{ .remaining = max_work };
    var lower: usize = 0;
    var upper = self.order.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        if (try compareBytes(self.entries[self.order[middle]].key.bytes, name, &budget) == .lt) {
            lower = middle + 1;
        } else upper = middle;
    }
    var only_metadata: ?i32 = null;
    var multiple = false;
    var last_any: ?u32 = null;
    var last_match: ?u32 = null;
    for (self.order[lower..]) |network| {
        const entry = self.entries[network];
        if (try compareBytes(entry.key.bytes, name, &budget) != .eq) break;
        try budget.spend(1);
        if (only_metadata) |value| {
            if (value != entry.metadata) multiple = true;
        } else only_metadata = entry.metadata;
        if (last_any == null or network > last_any.?) last_any = network;
        if (entry.metadata == metadata and (last_match == null or network > last_match.?)) last_match = network;
    }
    const selected = (if (multiple) last_match else last_any) orelse return null;
    return self.fromNetwork(.{ .value = selected });
}

fn rootLimits(available: usize, work: usize) BlockState.Limits {
    var limits: BlockState.Limits = .{};
    limits.codec.max_allocated_bytes = @min(limits.codec.max_allocated_bytes, available);
    limits.codec.max_work = @min(limits.codec.max_work, work);
    return limits;
}

fn propertyKey(self: *const BlockPalette, entry: Entry) []const u8 {
    return self.property_storage[entry.property_offset..][0..entry.property_length];
}

fn compareBytes(a: []const u8, b: []const u8, budget: *Budget) Error!std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |left, right| {
        try budget.spend(1);
        if (left != right) return std.math.order(left, right);
    }
    try budget.spend(1);
    return std.math.order(a.len, b.len);
}

fn compareEntries(self: *const BlockPalette, a: u32, b: u32, budget: *Budget) Error!std.math.Order {
    const name_order = try compareBytes(self.entries[a].key.bytes, self.entries[b].key.bytes, budget);
    if (name_order != .eq) return name_order;
    return compareBytes(self.propertyKey(self.entries[a]), self.propertyKey(self.entries[b]), budget);
}

/// Fallible heapsort keeps comparisons bounded and propagates work exhaustion.
fn sort(self: *BlockPalette, budget: *Budget) Error!void {
    var start = self.order.len / 2;
    while (start > 0) {
        start -= 1;
        try self.sift(start, self.order.len, budget);
    }
    var end = self.order.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(u32, &self.order[0], &self.order[end]);
        try self.sift(0, end, budget);
    }
}

fn sift(self: *BlockPalette, start: usize, end: usize, budget: *Budget) Error!void {
    var root = start;
    while (root < end / 2) {
        var child = root * 2 + 1;
        if (child + 1 < end and try self.compareEntries(self.order[child], self.order[child + 1], budget) == .lt) child += 1;
        if (try self.compareEntries(self.order[root], self.order[child], budget) != .lt) return;
        std.mem.swap(u32, &self.order[root], &self.order[child]);
        root = child;
    }
}
