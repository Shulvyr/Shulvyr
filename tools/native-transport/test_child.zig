const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidTestChild;
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    if (std.mem.eql(u8, args[1], "private-failure")) {
        try output.interface.writeAll("a=ice-pwd:synthetic\nnative probe failed: ProbeTimeout\nnative probe leaked 2 Zig allocations a=ice-pwd:synthetic\n");
        try output.interface.flush();
        return 1;
    }
    if (std.mem.eql(u8, args[1], "closed-stall")) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "closed-pipes", .data = "reached" });
        std.Io.File.stdout().close(init.io);
        std.Io.File.stderr().close(init.io);
    } else if (std.mem.eql(u8, args[1], "flood")) {
        for (0..4096) |_| try output.interface.writeAll("synthetic child output\n");
        try output.interface.flush();
        return 0;
    } else if (!std.mem.eql(u8, args[1], "stall")) return error.InvalidTestChild;
    try std.Io.sleep(init.io, .fromSeconds(10), .awake);
    return 0;
}
