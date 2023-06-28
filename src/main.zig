const std = @import("std");
const log = std.log;
const path = std.fs.path;
const hash = std.hash;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;


const Mode = enum {
    Zig,
    Zls,
    Ziege
};

const Args = [][:0]u8;

const App = struct {
    allocator: Allocator,
    args: Args,
    mode: Mode,

    pub fn init(allocator: Allocator) !App {
        log.debug("Initializing...", .{});
        var args = try std.process.argsAlloc(allocator);

        const zigBinNameHash = comptime hash.Crc32.hash("zig");
        const zlsBinNameHash = comptime hash.Crc32.hash("zls");

        const binName = path.basename(args[0]);
        const binNameHash = hash.Crc32.hash(binName);

        return App {
            .allocator = allocator,
            .args = args,
            .mode = switch (binNameHash) {
                zigBinNameHash => .Zig,
                zlsBinNameHash => .Zls,
                else => .Ziege,
            },
        };
    }

    pub fn deinit(self: *App) !void {
        log.debug("Cleaning up...", .{});
        std.process.argsFree(self.allocator, self.args);
    }
};

// For args that start with '+' we interpret as arguments
// for us rather than the tools we proxy.
fn parse_args(app: App) !void {
    for (app.args[1..]) |arg| {
        if (arg[0] == '+') {
            log.info("Found an arg for ziege: {s}", .{arg});
        }
    }
}

fn zig_mode(app: App) !void {
    log.debug("We are running in zig mode!", .{});
    try parse_args(app);
}

fn zls_mode(app: App) !void {
    log.debug("We are running in zls mode!", .{});
    try parse_args(app);
}

fn ziege_mode(app: App) !void {
    log.debug("We are running in goat mode.", .{});
    try parse_args(app);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const stat = gpa.deinit();
        assert(stat != .leak);
    }

    var app = try App.init(gpa.allocator());
    defer app.deinit() catch @panic("Unrecoverable error during shutdown!");

    switch (app.mode) {
        .Zig => try zig_mode(app),
        .Zls => try zls_mode(app),
        .Ziege => try ziege_mode(app),
    }
}
