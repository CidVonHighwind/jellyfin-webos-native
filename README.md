# webos-native

Native Zig applications for LG webOS TVs. The project contains two programs:

- `jellyfin` — a native Jellyfin client.
- `gltri` — an OpenGL ES triangle renderer and timing probe.

Both use the same SDL2 platform layer for webOS windowing, input, and OpenGL
context creation. Device libraries are loaded at runtime, so cross-compiling
requires neither the webOS SDK nor a target sysroot.

## Requirements

- Zig 0.16.0
- `ssh`, `scp`, `tar`, `sed`, and coreutils for device operations
- `slangc` to compile the embedded OpenGL ES shaders
- `glslangValidator` is optional shader validation

The pure-Zig TrueType reader and skyline atlas packer required by Jellyfin are
vendored under `src/vendor`; no sibling checkout is required.

## Setup

```sh
cp .env.example .env
```

Set `WEBOS_HOST` in `.env` to the TV's address.

## Commands

```sh
zig build                              # build both applications
zig build run -Dapp=jellyfin           # deploy and run on the TV
zig build run-host -Dapp=gltri         # run locally through SDL
zig build deploy                       # copy both binaries to the TV
zig build package -Dapp=jellyfin       # create an .ipk
zig build install-app -Dapp=jellyfin   # package, copy, and install
zig build launch -Dapp=jellyfin        # launch the installed app
zig build test                         # Jellyfin host tests
```

`GLTRI_DUMP=1 zig build run-host -Dapp=gltri` reads the rendered frame back as
ASCII for a headless smoke test.
