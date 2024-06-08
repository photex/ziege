//-----------------------------------------------------------------------------
// Copyright (c) 2024 - Chip Collier, All Rights Reserved.
//-----------------------------------------------------------------------------

const builtin = @import("builtin");
const std = @import("std");

pub const INDEX_FILENAME = "index.json";
pub const ZIGVERSION_FILENAME = ".zigversion";

/// <URL_PLATFORM>-<VERSION>.<ARCHIVE_EXT>
pub const ZIG_NIGHTLY_URL_FMT = "https://ziglang.org/builds/zig-{s}-{s}.{s}";
pub const ZIG_ARCHIVE_FMT = "zig-{s}-{s}.{s}";

pub const DEFAULT_ZIG_INDEX_URL = "https://ziglang.org/download/index.json";
pub const ZIG_BIN_NAME = switch (builtin.os.tag) {
    .windows => "zig.exe",
    else => "zig",
};
pub const ZIG_BIN_NAME_HASH = std.hash.Crc32.hash(ZIG_BIN_NAME);

pub const ZLS_BUILDS_URL_FMT = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/{s}/{s}/{s}";
pub const DEFAULT_ZLS_INDEX_URL = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";
pub const ZLS_BIN_NAME = switch (builtin.os.tag) {
    .windows => "zls.exe",
    else => "zls",
};
pub const ZLS_BIN_NAME_HASH = std.hash.Crc32.hash(ZLS_BIN_NAME);

pub const ARCH = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    else => @compileError("Unsupported CPU Architecture"),
};

pub const OS = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};

pub const URL_PLATFORM = OS ++ "-" ++ ARCH;
pub const JSON_PLATFORM = ARCH ++ "-" ++ OS;
pub const ARCHIVE_EXT = if (builtin.os.tag == .windows) "zip" else "tar.xz";

pub const log = std.log.scoped(.ziege);
