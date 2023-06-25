const std = @import("std");
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const stat = gpa.deinit();
        assert(stat != .leak);
    }

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args, 0..) |arg, index| {
        std.debug.print("{d}: {s}\n", .{ index, arg });
    }
}
