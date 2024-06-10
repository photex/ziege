#!/usr/bin/bash

set -e

# Build all release targets

zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux -Dcpu=x86_64+avx -p _release/build/linux/x86_64
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos -Dcpu=x86_64+avx -p _release/build/macos/x86_64
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux -p _release/build/linux/aarch64
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos -p _release/build/macos/aarch64

zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows -Dcpu=x86_64+avx -p _release/build/windows/x86_64

zip -j _release/ziege-windows-x86_64.zip _release/build/windows/x86_64/bin/ziege.exe scripts/zig.bat scripts/zls.bat
cp _release/build/linux/x86_64/bin/ziege _release/ziege-linux-x86_64
cp _release/build/macos/x86_64/bin/ziege _release/ziege-macos-x86_64
cp _release/build/linux/aarch64/bin/ziege _release/ziege-linux-aarch64
cp _release/build/macos/aarch64/bin/ziege _release/ziege-macos-aarch64

rm -rf _release/build
