const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const assert = std.debug.assert;

const Args = [][:0]u8;

const zigBinHash = hash.Crc32.hash("zig");

fn parse_args(args: Args) !void {
    for (args[1..], 1..) |arg, index| {
        std.debug.print("{d}: {s}\n", .{ index, arg });
    }
}

fn zig_mode(args: Args) !void {
    std.debug.print("We are running in zig mode!\n", .{});
    try parse_args(args);
}

fn ziege_mode(args: Args) !void {
    std.debug.print("We are running in goat mode.\n", .{});
    try parse_args(args);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const stat = gpa.deinit();
        assert(stat != .leak);
    }

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.debug.print("CMD: {s}\n", .{args[0]});

    const binName = path.basename(args[0]);

    switch (hash.Crc32.hash(binName)) {
        zigBinHash => try zig_mode(args),
        else => try ziege_mode(args),
    }
}
