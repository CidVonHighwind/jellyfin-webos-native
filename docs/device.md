# Device, ABI and toolchain

## Platform

```
Linux LGwebOSTV 5.4.268-320 #1 SMP PREEMPT Mon Jun 17 01:25:25 UTC 2024 aarch64
glibc 2.35
GPU: ARM Mali-G52 (vendorID 0x13b5, deviceID 0x74021000), driver 46.0.0
```

## The float ABI: what it does and does not mean

`uname -m` reports `aarch64` — that is the **kernel**. Userland is 32-bit ARM:

```
$ file /usr/lib/libmali.so.0
ELF 32-bit LSB shared object, ARM, EABI5 version 1 (SYSV)
$ readelf -h libmali.so.0 | grep Flags
Flags: 0x5000200, Version5 EABI, soft-float ABI
$ readelf -A libmali.so.0
Tag_CPU_name: "7-A"   Tag_CPU_arch: v7
Tag_FP_arch: FP for ARMv8          Tag_Advanced_SIMD_arch: NEON for ARMv8
```

**"soft-float ABI" here means the calling convention, not software emulation.**
The device is `softfp`:

- `Tag_FP_arch: FP for ARMv8` and NEON — the driver *does* use FPU instructions.
- `Tag_ABI_VFP_args` is absent (= 0, base standard) — float/double arguments are
  passed in **core registers**, not VFP registers.

So the hardware FPU runs at full speed; only argument passing at function
boundaries uses integer registers, which costs close to nothing. This is exactly
why the JS-heavy webOS UI performs fine — doubles are hardware doubles.

The ABI still matters, but only for **compatibility**:

- Target **`arm-linux-gnueabi`** — not `gnueabihf`.
- The dynamic linker is `/lib/ld-linux.so.3`; a `gnueabihf` build requests
  `/lib/ld-linux-armhf.so.3` and fails with `not found`, which misleadingly looks
  like a missing binary rather than a wrong ABI.
- Mixing ABIs silently corrupts float arguments across library calls, so
  `gnueabihf` is not an option even if you patch the interpreter path.

### The float trap, and why this project is C

Soft-float here is an *argument-passing* convention. The FPU is real and fast;
what matters is whether the compiler will emit instructions for it.

GCC's `-mfloat-abi=softfp` does exactly the right thing: base-ABI argument
passing, VFP/NEON for the arithmetic. That is what `CMakeLists.txt` sets,
alongside `-mcpu=cortex-a55 -mfpu=neon-vfpv4`, and there is nothing further to
arrange.

Zig's `gnueabi` target cannot express that. It sets LLVM `float-abi=soft`, which
not only uses core registers for arguments but **stops emitting FPU instructions
entirely**, turning every operation into an `__aeabi_dmul` / `__aeabi_dadd`
library call. Measured on the TV (20M iterations, 2 flops each):

| | throughput |
|---|---|
| f64, Zig `gnueabi` (software float) | **24.2 Mflop/s** |
| f32, Zig `gnueabi` (software float) | 23.5 Mflop/s |
| f64, same loop via inline VFP asm | **254.9 Mflop/s** |
| u64 integer reference | (11.1x faster than soft f64) |

**10.5x** — and the VFP figure even carries a load/store per iteration, so real
hardware FP is better still. Setting `-mcpu=cortex_a55` does *not* fix it, and
neither does subtracting the `soft_float` CPU feature; the triple's ABI decides.

The Zig version of this project worked around that by compiling its glyph
rasteriser as a separate `gnueabihf` module behind a pointer-and-integer-only
boundary — a second build target, a vendored TrueType reader, and a rule that no
float may cross the ABI seam by value. With GCC, none of it is needed: the
rasteriser is FreeType and the boundary is gone.

## Building

The [openlgtv buildroot NDK](https://github.com/openlgtv/buildroot-nc4) ships
the cross toolchain, a sysroot with the TV's own libraries, and the CMake
toolchain file this project defers to:

```sh
cmake --preset webos     # WEBOS_SDK=/path/to/ndk to move it off /opt
cmake --build build
```

Its glibc is older than the TV's 2.35, so
  forward-compatible; building against 2.35+ risks symbol versions the TV lacks.
- The NDK's sysroot carries the TV's own libraries and headers, so SDL2, EGL,
  GLESv2, libpng, FreeType, ALSA, libcurl, libhelpers and libplayerAPIs are all
  linked normally rather than `dlopen`'d by hand.
- FFmpeg is the exception on the other side: no webOS release ships one a native
  app may link, so Jellyfin links one known build and ships it in the app's
  `lib/` directory, avoiding an ABI shim per firmware.
- json-c comes from the NDK's static `libjson-c.a`, so nothing has to be bundled
  or assumed present for it either.

## Deploy and run

SSH as root works with a key (port 22). Wayland clients need the compositor's
environment, which is **not** set in an SSH session:

```sh
scp wlbox root@10.10.8.63:/tmp/
ssh root@10.10.8.63 'XDG_RUNTIME_DIR=/tmp/xdg WAYLAND_DISPLAY=wayland-0 /tmp/wlbox'
```

Compositor environment, read from `surface-manager`'s `/proc/<pid>/environ`:

```
XDG_RUNTIME_DIR=/tmp/xdg          WAYLAND_DISPLAY=wayland-0 (socket /tmp/xdg/wayland-0)
QT_QPA_PLATFORM=wayland           QT_WAYLAND_SHELL_INTEGRATION=webos
SDL_VIDEODRIVER=wayland           QT_WAYLAND_HARDWARE_INTEGRATION=linux-dmabuf-unstable-v1
WEBOS_COMPOSITOR_EXTENSIONS=webos-wayland-extension,webos-window-extension,starfish-extension
```

**No app packaging is required.** A bare binary run over SSH renders fullscreen,
as long as it declares an `appId` (see [display.md](display.md)). `appinfo.json`
/ SAM packaging is only needed for launching from the TV's own UI.

### Gotchas

- The device shell mangles double quotes in SSH command strings (`"` arrives as
  `"/bsppart`). Put anything quote-heavy in a script file and `scp` it over.
- `luna-send` **works fine** over SSH — an earlier note here claimed it was mute,
  which was wrong. It returns full JSON for e.g.
  `luna://com.webos.applicationManager/listApps`. What actually happens is that
  *some specific methods* return nothing: `com.webos.service.capture/executeOneShot`
  and `com.webos.surfacemanager/captureCompositorOutput` both exit 0 and write no
  file, so scripted screenshots remain unavailable and visual checks still need
  eyes on the TV. Do not generalise that to luna-send as a whole.
- For install//status calls, pass `subscribe:true` and use `luna-send -i`;
  one-shot calls report `returnValue: true` long before the operation finishes.
- Available on-device tools: `strings`, `busybox`. **No** `readelf`, `nm`,
  `objdump`, `file`. Copy binaries to the PC to inspect them.
