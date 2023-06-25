const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const assert = std.debug.assert;

const zigBinHash = hash.Crc32.hash("zig");

fn zig_mode() !void {}

fn ziege_mode() !void {}

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

    if (hash.Crc32.hash(binName) == zigBinHash) {
        std.debug.print("We are running in zig mode!\n", .{});
    } else {
        std.debug.print("We are running in goat mode.\n", .{});
    }

    for (args[1..], 1..) |arg, index| {
        std.debug.print("{d}: {s}\n", .{ index, arg });
    }
}
