const std = @import("std");
const shulvyr = @import("shulvyr");

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const status = try execute(init.io, arguments[1..], &stdout_file.interface, &stderr_file.interface);
    try stdout_file.interface.flush();
    try stderr_file.interface.flush();
    return status;
}

fn execute(io: std.Io, arguments: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const command = shulvyr.cli.parse(arguments) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        return 2;
    };
    switch (command) {
        .help => try stdout.writeAll(shulvyr.cli.usage),
        .version => try stdout.print("Shulvyr {s}\n", .{shulvyr.version}),
        .identity => |operation| shulvyr.identity_cli.execute(io, operation, stdout) catch |err| {
            try stderr.print("error: {s}\n", .{@errorName(err)});
            return 1;
        },
        .run => |config| {
            try stdout.print("Shulvyr {s} foundation runtime\n", .{shulvyr.version});
            try stdout.flush();
            const ticks = shulvyr.Runtime.run(io, config) catch |err| {
                try stderr.print("error: {s}\n", .{@errorName(err)});
                return 1;
            };
            try stdout.print("Stopped after {d} ticks\n", .{ticks});
        },
    }
    return 0;
}
