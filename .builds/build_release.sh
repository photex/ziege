#!/usr/bin/bash

set -e

# Build all release targets

zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux -Dcpu=x86_64+avx -p _release/linux/x86_64
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos -Dcpu=x86_64+avx -p _release/macos/x86_64
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux -p _release/linux/aarch64
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos -p _release/macos/aarch64

zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows -Dcpu=x86_64+avx -p _release/windows/x86_64
cp scripts/*.bat _release/windows/x86_64/bin/.
