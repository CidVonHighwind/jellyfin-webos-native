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

### The real trap: Zig's gnueabi disables FP codegen

Zig's `gnueabi` target sets LLVM `float-abi=soft`, which not only uses core
registers for arguments but **stops emitting FPU instructions entirely**, turning
every operation into an `__aeabi_dmul` / `__aeabi_dadd` library call. That is a
genuine, large penalty — and it is a toolchain artefact, not a device limit.

Measured on the TV with `fptest.zig` (20M iterations, 2 flops each):

| | throughput |
|---|---|
| f64, Zig `gnueabi` (software float) | **24.2 Mflop/s** |
| f32, Zig `gnueabi` (software float) | 23.5 Mflop/s |
| f64, same loop via inline VFP asm | **254.9 Mflop/s** |
| u64 integer reference | (11.1x faster than soft f64) |

**10.5x** — and the VFP figure even carries a load/store per iteration, so real
hardware FP is better still. Setting `-mcpu=cortex_a55` does *not* fix it, and
neither does subtracting the `soft_float` CPU feature; the triple's ABI decides.

### Working around it

1. **Ignore it** for FP-light code. Wayland uses fixed-point integers; the Vulkan
   plumbing passes floats inside structs (memory, not registers). Our current
   apps do no meaningful FP.
2. **Inline VFP asm** for a hot kernel — see `vfpChain` in `fptest.zig`. Argument
   passing stays base-ABI, so this is safe to mix.
3. **Write the kernel in C and compile with `zig cc -mfloat-abi=softfp`.** Clang
   *can* express softfp even though the Zig target triple cannot. Verified:

   ```
   zig cc -target arm-linux-gnueabi -mcpu=cortex_a55 -mfloat-abi=softfp -O2 -c k.c
     → vmul.f64 emitted, Tag_ABI_VFP_args absent (base registers)
   ```

   Hardware FP *and* device-compatible argument passing. This is the clean
   escape hatch for anything FP-heavy.
4. **Isolate a Zig hard-float kernel behind a pointer/integer-only boundary.**
   `uidemo` does this for MSDF generation: the final process remains `gnueabi`,
   while a private `gnueabihf` static object uses VFP internally. No float may
   cross that boundary by value, and the kernel must not call a base-ABI function
   with float arguments. This brought on-TV renderer initialization to about
   250 ms.
5. **Put it on the GPU** — for genuinely heavy math, Vulkan compute beats any of
   the above.

## Building

Zig cross-compiles this with no toolchain installed. See `../build.sh`:

```sh
zig build-exe fbflash.zig -target arm-linux-gnueabi          -O ReleaseSmall  # static, no libc
zig build-exe wlbox.zig   -target arm-linux-gnueabi.2.31 -lc -O ReleaseSmall
```

- Pin glibc **2.31** (`-target …gnueabi.2.31`). Older than the TV's 2.35, so
  forward-compatible; building against 2.35+ risks symbol versions the TV lacks.
- `-lc` is only needed for `dlopen`. `fbflash` needs no libc and links fully static.
- **All device libraries are `dlopen`'d at runtime**, never linked. So the build
  needs no headers, no sysroot and no `.so` copied from the TV. This is
  deliberate — keep it that way.

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
