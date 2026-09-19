# webos-native

Native (non-JavaScript) applications for LG webOS TVs, written in Zig.

Cross-compiles from any Linux machine with **only Zig installed** — no webOS SDK,
no sysroot, no cross-toolchain, no headers copied off the TV. Every device
library is `dlopen`'d at runtime.

## What works

| | |
|---|---|
| `gltri` | 1000 instanced rotating triangles via GL ES 3.2, CPU/GPU frame times on screen — **verified on device** |
| `glinfo` | EGL + OpenGL ES capabilities, limits and extensions |
| `inputlog` | on-screen log of every input event — maps the remote and the cursor, **verified on device** |
| `wlbox` | fullscreen red box via Wayland `wl_shm` + `wl_webos_shell` — **verified on device** |
| `wlinfo` | lists the compositor's Wayland globals |
| `vkinfo` | enumerates the Mali Vulkan ICD (1.3.260, 102 device extensions) |
| `fbflash` | `/dev/fb0` prober — documents why direct framebuffer access is impossible |
| `fptest` | float throughput benchmark (soft-float ABI vs hardware VFP) |

Full findings are in **[docs/](docs/README.md)** — ABI, display pipeline, OpenGL
ES, Vulkan, codecs, input, network, packaging.

## Requirements

- **Zig 0.16** (developed against `0.16.0`; the `std` API moves fast, so other
  versions may need small edits)
- `openssh` — `ssh`/`scp` for deploy
- `tar`, `sed`, `coreutils` — used by the `.ipk` packager
- **`slangc`** ([Slang](https://shader-slang.org/)) — only for the GL apps, which
  compile their shaders from `src/shaders/*.slang` at build time
- `glslangValidator` — optional; if present, every generated shader is validated
  against GLSL ES 3.20 before it is embedded
- An LG webOS TV with **root SSH access** (e.g. via
  [Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel)) and
  your key installed

Nothing else. In particular you do **not** need `ares-cli`, the webOS SDK, or an
ARM cross-compiler.

## Setup

```sh
cp .env.example .env     # then set WEBOS_HOST to your TV's address
```

`.env` is git-ignored and sourced by every step that touches the TV; no address
is hardcoded.

## Build commands

```sh
zig build                          # build every app into zig-out/bin
zig build info                     # show the resolved .env settings

zig build run   -Dapp=wlbox        # scp one app to /tmp and run it on the TV
zig build run-host -Dapp=inputlog  # build for this PC and run it in a local window
zig build deploy                   # scp every app to the TV's temp dir

zig build shot                     # screenshot the TV over VNC -> zig-out/shot.png

zig build package     -Dapp=wlbox  # build zig-out/<id>_<version>_arm.ipk
zig build install-app -Dapp=wlbox  # package, push and install via luna
zig build launch                   # start the installed app through SAM
```

`-Dapp=` selects the app for `run` / `run-host` / `package` / `install-app`
(default `wlbox`).
`zig build run` is the fast development loop: a bare binary renders fullscreen
without being installed at all, so packaging is only needed to get an entry in
the TV's app list.

Cross-compilation target is set in `build.zig`: **`arm-linux-gnueabi`**,
armv7-a soft-float ABI, glibc 2.31. Override with `-Dtarget=` to build for the
host instead.

## Seeing what the TV actually drew

webOS exposes no screenshot service a native app can reach, but the TV runs a
VNC server on 5900. `zig build shot` grabs one frame into `zig-out/shot.png`
(`tools/vncshot.py`, needs `python3` + `pycryptodome`, password from
`WEBOS_VNC_PASS` in `.env`). This is the only honest check of on-device
rendering; the `*_DUMP=1` ASCII readbacks below are the offline fallback.

## Layout

```
src/wl.zig  Wayland shim: one window, one shm buffer, all input.
            Picks wl_webos_shell on the TV and xdg_wm_base on a PC, so the
            same binary source runs in both places.
src/        application sources
src/shaders/ Slang shaders, compiled to GLSL ES at build time
assets/     icon.png, font8x16.bin and other packaged files
tools/      dev-machine helpers (VNC screenshot)
docs/       findings from investigating the device
appinfo.json  webOS app manifest (`main` is rewritten per -Dapp at package time)
build.zig     build, package, deploy, install, launch
```

## Gotchas that cost real time

- `uname -m` says `aarch64`; **userland is 32-bit ARM, soft-float ABI**. A
  `gnueabihf` build fails with a confusing `not found`.
- App ids may **not** start with `com.webos.` — developer-mode installs of that
  reserved namespace are refused with a generic `errorCode: -15`.
- `/dev/fb0` cannot be mapped — scanout is AFBC-compressed. Wayland is the only
  route to the screen.
- Vulkan works but has **no `VK_KHR_wayland_surface`**, so a swapchain cannot
  present; use `zwp_linux_dmabuf_v1`.
- Zig 0.16's self-hosted x86_64 backend miscompiles `@memset` over a large
  global slice, so `run-host` pins `use_llvm`. The ARM build is unaffected.
- `GL_EXT_disjoint_timer_query` is advertised but returns nothing on this
  driver, and Slang cannot emit GLSL ES directly — both are worked around and
  explained in [docs/opengl.md](docs/opengl.md).
- The panel is 120 Hz FreeSync but **the graphics plane is a fixed 1080p60**
  (DRM CRTC mode, `wl_output`, and no 120 Hz mode on the connector). Apps here
  take their size and rate from `wl_output` and never assume one.

Each is explained in [docs/](docs/README.md).

## Developing on the PC

`zig build run-host -Dapp=<app>` builds the same source for this machine and
runs it as an ordinary window, so the edit/run loop does not need the TV. The
shim binds `xdg_wm_base` when `wl_webos_shell` is absent; the app code does not
know the difference.

`inputlog` additionally renders one frame into a buffer and prints it as ASCII
when `INPUTLOG_DUMP=1` is set, which checks the log formatting and the font
without a compositor at all:

```sh
INPUTLOG_DUMP=1 zig build run-host -Dapp=inputlog
GLTRI_DUMP=1    zig build run-host -Dapp=gltri     # glReadPixels -> ASCII
```

`assets/font8x16.bin` is the ASCII range of
[Terminus](https://terminus-font.sourceforge.net/) (OFL-1.1), extracted from
`Lat2-Terminus16.psfu` as 95 glyphs of 16 bytes.
