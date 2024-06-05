
<p align="center">
  <img width="256" height="256" src="logo.png">
</p>

Ziege manages zig toolchains and zls releases on your system (automatically configured by a `.zigversion` in your repo root). When used as an alias (either by renaming it, or by symlink) to Zig it will seamlessly dispatch all command line arguments to the correct Zig binary for a project.

Using Ziege should be totally transparent and should be the only tool you need to setup for working with Zig.

This tool was inspired by [Bazelisk](https://github.com/bazelbuild/bazelisk)

## Feature Checklist

Ziege is still in it's very early stagess but can hopefully be as useful for you as it is for me. Bug reports, feature requests, or any other sort of contribution are all greatly appreciated.

- [x] Download Zig toolchain indicated by a project `.zigversion`
- [ ] Work on major desktop platforms.
  - [x] Windows
  - [x] Linux
  - [ ] MacOS (*not yet tested*)
- [x] Simple proxy for Zig
  - [x] Allow zig version override with launcher args (ex: `+version=0.12.0`)
- [ ] Simple proxy for Zls
- [ ] Manage pinned Zig version
- [x] List installed Zig versions
- [x] Add Zig toolchains
- [x] Remove Zig toolchains
- [ ] Gracefully fail in the face of edge cases, network failures, and other problems
- [ ] Configure a default Zig toolchain version for when a repo doesn't specify one
- [ ] Allow configuration of alternate Zig and Zls indexes.
- [ ] Allow configuration of the location of Zig toolchains.
- [ ] Add symlinks in a repo (ex: `<repo>/tools/zig`) for folks that do not wish to use Ziege as a proxy
- [ ] Be your one stop shop for all your Zig tool needs!

## Modes

### Zig mode

In this mode, ziege is a proxy for a specific zig release. When ziege is named 'zig' or if run using a symlink named 'zig' this mode is activated.

```sh
ln -s ziege zig
./zig help
```

Ziege will try and determine the zig version to proxy by reading a file named `.zigversion` in the current working directory. If that is not found *ziege will create this file and use the current nightly version of zig*.

You can override this version by using a "launcher arg":

```sh
zig +version=0.12.0 build run
```

In all cases, if the resolved version isn't found then it will be downloaded first.

### Zls mode

> **This mode is not yet implemented**

### Ziege mode

In this mode ziege offers some basic toolchain management commands.

```sh
ziege list
ziege add 0.12.0
ziege remove 0.11.0
```

## How it works

It isn't magic, and the Zig standard library provides essentially everything needed!

When you run Ziege, it searches for a `.zigversion` file in the current working directory. If that is found the contents are read and used to locate an appropriate toolchain. In the event that no version file is present in the repo yet, Ziege will resolve the latest nightly and create a `.zigversion` for you.

If a toolchain matching the specified version isn't present on your system already, then it will be downloaded and unpacked into a standard location.

Once a toolchain is located, run Zig and forward any command line arguments to it.

### Where do we store toolchains?

At the moment we create a `ziege` folder under the AppData path for your system.

On Linux this is `$HOME/.local/share/ziege`, and on Windows this is `%USERPROFILE%\AppData\Local\ziege`

### From where do we download Zig?

We cache the Zig release index and use this to resolve the current nightly version or get the url for a tagged release.

Because this index doesn't contain information for every nightly build, if a repo is pinned to a nightly build we have to derive the url for that toolchain.

## Why is it called "Ziege"?

Ziege is the German word for Goat, it starts with the letter 'Z', and I once overheard someone talking about Zig on the train who pronounced Zig with an accent which sounded to me like *tsee-guh*. This coincidentally is how you pronouce the German word.

Ziege looks similar to the English word 'siege' and so perhaps you pronounce it *zeej*.

However you like to pronounce it is fine.
