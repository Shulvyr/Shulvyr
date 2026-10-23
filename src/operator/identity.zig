const std = @import("std");
const Io = std.Io;
const Command = @import("cli.zig").Identity;
const Store = @import("../transport/identity/KeyStore.zig");
const Private = @import("../transport/identity/private_file.zig");

/// Administrative entry point. Paths are borrowed for this synchronous call.
/// Output contains only generation, public fingerprint and recovery byte count.
pub fn execute(io: Io, command: Command, output: *Io.Writer) !void {
    const source = try location(io, command.directory);
    defer source.parent.close(io);
    var store = if (command.action == .init) try Store.initialize(io, source.parent, source.name, .{}) else try Store.open(io, source.parent, source.name, .{});
    defer store.close(io);
    switch (command.action) {
        .init, .show => {
            var loaded = try store.load(io);
            defer loaded.deinit();
            try show(output, loaded.metadata);
        },
        .inspect => {
            const inspected = try store.inspect(io);
            try show(output, inspected.metadata);
            try output.print("Uncommitted bytes {d}\n", .{inspected.uncommitted_bytes});
        },
        .rotate => {
            var loaded = try store.rotate(io, command.expected orelse return error.MissingExpectedFingerprint);
            defer loaded.deinit();
            try show(output, loaded.metadata);
        },
        .recover => {
            var recovered = try store.recover(io, command.expected orelse return error.MissingExpectedFingerprint);
            defer recovered.loaded.deinit();
            try show(output, recovered.loaded.metadata);
            try output.print("Discarded uncommitted bytes {d}\n", .{recovered.discarded_bytes});
        },
        .backup => {
            const destination = try location(io, command.destination orelse return error.MissingDestination);
            defer destination.parent.close(io);
            const metadata = try store.backup(io, destination.parent, destination.name);
            try output.writeAll("Backup complete\n");
            try show(output, metadata);
        },
    }
}

fn show(output: *Io.Writer, metadata: Store.Metadata) !void {
    try output.print("Operator identity generation {d}\nFingerprint {s}\n", .{ metadata.generation, std.fmt.bytesToHex(metadata.fingerprint, .lower) });
}

fn location(io: Io, path: []const u8) !struct { parent: Io.Dir, name: []const u8 } {
    const name = std.fs.path.basename(path);
    try Private.validName(name);
    return .{ .parent = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{}), .name = name };
}
