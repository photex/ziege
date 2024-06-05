//-----------------------------------------------------------------------------
// Copyright (c) 2024 - Chip Collier, All Rights Reserved.
//-----------------------------------------------------------------------------

const std = @import("std");
const globals = @import("./globals.zig");
const utils = @import("./utils.zig");

const Allocator = std.mem.Allocator;

const log = globals.log;

/// A simple struct with paths to our configured/standard locations on the system.
const Locations = struct {
    const Self = @This();

    allocator: Allocator,
    app_data: []u8,
    config_file: []u8,
    pkg_root: []u8,
    zig_pkgs: []u8,
    zls_pkgs: []u8,

    /// Build our paths to standard locations, and creates any missing directories if needed.
    pub fn init(allocator: Allocator) !Self {
        const app_data = try std.fs.getAppDataDir(allocator, "ziege");
        const config_file = try std.fs.path.join(allocator, &.{ app_data, "settings.json" });
        const pkg_root = try std.fs.path.join(allocator, &.{ app_data, "pkg" });
        const zig_pkgs = try std.fs.path.join(allocator, &.{ pkg_root, "zig" });
        const zls_pkgs = try std.fs.path.join(allocator, &.{ pkg_root, "zls" });

        log.debug("ZIEGE ROOT: {s}", .{app_data});
        log.debug("ZIG PACKAGES: {s}", .{zig_pkgs});
        log.debug("ZLS PACKAGES: {s}", .{zls_pkgs});

        // I'm assuming here that we can "make" a dirt that already exists without errors.
        try utils.ensureDirectoryExists(app_data);
        try utils.ensureDirectoryExists(pkg_root);
        try utils.ensureDirectoryExists(zig_pkgs);
        try utils.ensureDirectoryExists(zls_pkgs);

        return Self{
            .allocator = allocator,
            .app_data = app_data,
            .config_file = config_file,
            .pkg_root = pkg_root,
            .zig_pkgs = zig_pkgs,
            .zls_pkgs = zls_pkgs,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.app_data);
        self.allocator.free(self.config_file);
        self.allocator.free(self.pkg_root);
        self.allocator.free(self.zig_pkgs);
        self.allocator.free(self.zls_pkgs);
        self.* = undefined;
    }

    pub fn getZigRootPath(self: *const Self, version: []const u8) ![]u8 {
        return try std.fs.path.join(self.allocator, &.{ self.zig_pkgs, version });
    }
};

// NOTE: This is intended to eventually load settings from our app data directory.
pub const Configuration = struct {
    const Self = @This();

    allocator: Allocator,

    locations: Locations,

    zig_index_url: []const u8,
    zls_index_url: []const u8,

    pub fn load(allocator: Allocator) !Self {
        const locations = try Locations.init(allocator);

        return Self{
            .allocator = allocator,
            .locations = locations,
            .zig_index_url = globals.DEFAULT_ZIG_INDEX_URL,
            .zls_index_url = globals.DEFAULT_ZLS_INDEX_URL,
        };
    }

    pub fn unload(self: *Self) void {
        self.locations.deinit();
        self.* = undefined;
    }
};
