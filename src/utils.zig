//-----------------------------------------------------------------------------
// Copyright (c) 2024 - Chip Collier, All Rights Reserved.
//-----------------------------------------------------------------------------

// This is where we define miscellaneous functions that don't have another obvious location yet.
// Feel free to factor things into more sensible arrangements.

const std = @import("std");

pub fn dirExists(abs_path: []const u8) !bool {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    dir.close();
    return true;
}

pub fn ensureDirectoryExists(abs_path: []const u8) !void {
    std.fs.makeDirAbsolute(abs_path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}
