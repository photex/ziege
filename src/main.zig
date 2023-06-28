const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;


const Mode = enum {
    Zig,
    Ziege
};

const Args = [][:0]u8;

const App = struct {
    allocator: Allocator,
    args: Args,
    mode: Mode,

    pub fn init(allocator: Allocator) !App {
        std.debug.print("Initializing.\n", .{});

        var args = try std.process.argsAlloc(allocator);

        const zigBinNameHash = hash.Crc32.hash("zig");

        const binName = path.basename(args[0]);
        const binNameHash = hash.Crc32.hash(binName);

        return App {
            .allocator = allocator,
            .args = args,
            .mode = if (binNameHash == zigBinNameHash) .Zig else .Ziege,
        };
    }

    pub fn deinit(self: *App) !void {
        std.debug.print("Shutting down.\n", .{});
        std.process.argsFree(self.allocator, self.args);
    }
};

fn parse_args(app: App) !void {
    for (app.args[1..], 1..) |arg, index| {
        std.debug.print("{d}: {s}\n", .{ index, arg });
    }
}

fn zig_mode(app: App) !void {
    std.debug.print("We are running in zig mode!\n", .{});
    try parse_args(app);
}

fn ziege_mode(app: App) !void {
    std.debug.print("We are running in goat mode.\n", .{});
    try parse_args(app);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const stat = gpa.deinit();
        assert(stat != .leak);
    }

    var app = try App.init(gpa.allocator());
    defer app.deinit() catch @panic("WTF");

    switch (app.mode) {
        .Zig => try zig_mode(app),
        .Ziege => try ziege_mode(app),
    }
}
