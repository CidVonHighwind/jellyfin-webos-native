# Getting pixels on screen

## The framebuffer route is closed

`/dev/fb0` exists, is openable, and reports a plausible mode — and is
nonetheless useless. From `fbflash.zig`:

```
fb: osd0_fb
  1920x1080 (virtual 1920x2160, offset 0,0) 32bpp stride 7680
  R off=16 len=8  G off=8 len=8  B off=0 len=8  A off=24 len=8   → ARGB8888
  smem_start=0x8c328000 smem_len=4096 visual=2 type=0
mmap(16588800) failed: errno 5 (EIO)
mmap(4096)     failed: errno 5 (EIO)
```

Both ioctls (`FBIOGET_VSCREENINFO`, `FBIOGET_FSCREENINFO`) succeed, but:

- `smem_len` is **4096**, not the ~16 MB the geometry implies.
- `mmap` returns **`EIO` even for a single page**.

`dmesg` gives the reason:

```
hal-gal  HAL_GAL_CaptureFrameBuffer: framebuffer 0x87d94000 7680 1920 1080 afbc 32x8 abgr
hal-gal  HAL_GAL_CaptureFrameBuffer: rsvd flag=0x12 (ABGR,AFBC32x8)
```

The real scanout buffer is **AFBC-compressed** (ARM Frame Buffer Compression,
32x8 blocks). `/dev/fb0` (`osd0_fb`) is a stub control node backed by no linear
memory. This is not a permissions problem — writing bytes into a compressed
tiled surface would not produce an image even if it mapped.

`/dev/dri/card0` is `0600 root` and held by `surface-manager` as DRM master.
`/dev/mali0` is `0666`, so GPU access itself is unprivileged.

**Conclusion: Wayland is the only route to the display plane.** This is not
overhead — going through the compositor is what keeps AFBC intact, and
`VK_EXT_image_drm_format_modifier` exists precisely to negotiate it.

## The compositor

`surface-manager` (LSM), a Qt5-Wayland compositor. `wlinfo.zig` lists 23 globals:

```
wl_compositor v3              wl_subcompositor v1        wl_shm v1
wl_seat v4 (x3)               wl_output v2               wl_data_device_manager v1
wl_shell v1                   wl_webos_shell v1          wl_drm v2
zwp_linux_dmabuf_v1 v3        mali_buffer_sharing v5     qt_hardware_integration v1
wl_webos_foreign v1           wl_webos_surface_group_compositor v1
wl_webos_input_manager v1     wl_webos_xinput_extension v1
wl_starfish_output v1         wl_starfish_pointer v1
text_model_factory v1         input_method v2            input_panel v1
```

Notable:

- **No `xdg_wm_base`.** No xdg-shell at all. Use `wl_webos_shell` (or legacy
  `wl_shell`). This is why a stock SDL/GLFW Wayland backend will not work
  unpatched.
- **`zwp_linux_dmabuf_v1` v3 is present** — this is the Vulkan present path.
- `wl_shm` v1 is present — enough for CPU-drawn pixels, no GPU needed.

## Making a surface visible

Verified working in `wlbox.zig`, and simpler than expected:

1. Bind `wl_compositor`, `wl_shm`, `wl_webos_shell`.
2. `wl_compositor.create_surface`.
3. `wl_webos_shell.get_shell_surface(surface)`.
4. **`wl_webos_shell_surface.set_property("appId", "<some.app.id>")`** — LSM only
   composites surfaces it can attribute to an app.
5. `set_state(1)` for fullscreen.
6. Attach a buffer, `damage`, `commit`.

**The `appId` does not need to correspond to an installed app.** A bare binary
run over SSH with a self-declared `appId` renders fullscreen. No `appinfo.json`,
no SAM launch, no dev-mode packaging needed for development.

### Look up opcodes by name, do not hardcode them

`libwayland`'s `wl_interface` structs carry their own method tables at runtime
(`name`, `signature`, index = opcode). Read them instead of transcribing opcodes
from protocol XML. This immediately caught a trap:

```
wl_webos_shell v1:
  [0] get_system_pip()
  [1] get_shell_surface(no)      ← opcode 1, NOT 0
wl_webos_shell_surface v1:
  [0] set_location_hint(u)  [1] set_state(u)  [2] set_property(ss)
  [3] set_key_mask(u)       [4] set_size(ii)
```

`get_shell_surface` being opcode 1 is the kind of thing a from-memory guess gets
wrong silently. See `opcode()` in `wlbox.zig`.

## Where the webOS protocol interfaces live

`wl_webos_shell_interface` is not in `libwayland-client`. It is exported by
several device libraries; **`/usr/lib/libwayland-webos-client.so.1`** is the one
to `dlopen`. (Also present in `libSDL2`, `libWebOSCoreCompositor`,
`liblsm-connector`, `libwayland-webos-server`, `libuwac0`, `libgm-wayland`.)

Using it means no hand-written protocol tables anywhere in our code.

## Two planes: graphics is 1080p60, video is 4K120

The single most useful thing to understand about this platform: **rendering and
video playback do not share a path.** "The TV does 4K120" is true of one of them
and not the other.

`/sys/kernel/debug/dri/0/state` shows three planes on one CRTC:

```
plane[32]: plane-0    fb allocated by = surface-manager
                      format=AB24  modifier=0x800000000000062 (AFBC)
                      size=1920x1080
plane[34]: plane-1    crtc=(null)   color-encoding=ITU-R BT.601 YCbCr
plane[36]: plane-2    crtc=(null)   color-encoding=ITU-R BT.601 YCbCr
crtc[38]: mode: "1920x1080": 60 148500 1920 2008 2052 2200 1080 1084 1089 1125
```

Plane 0 is the **graphics plane** — the one every Wayland client, including
everything in this repo, ends up in. The two idle YCbCr planes are **video
planes**, fed by the hardware decoder, and they are where 4K120 lives.

### Why the graphics plane is 1080p, and where that is decided

It is a per-model configd value, not a negotiation. `surface-manager` reads it
at startup (`/etc/surface-manager.d/eglfs_starfish.env`) and hands it straight
to Qt's KMS backend as the DRM connector mode:

```sh
primary_geometry="$(luna-send ... '{"configNames":["com.webos.surfacemanager.compositorGeometry"]}' \
                    || printf "1920x1080+0+0r0s1")"
primary_resolution="${primary_geometry%[-+]?*[-+]?*r?*s?*}"
WEBOS_COMPOSITOR_DISPLAY_CONFIG='[{"device":"/dev/dri/card0", ... "connector":{"mode":"1920x1080"} ...'
```

The value comes from a configd layer picked by device name. This set reports
`o22n2`, which has no layer of its own, so it falls back to
`/etc/configd/layers/base/com.webos.surfacemanager.json`:

| layer | `compositorGeometry` |
|---|---|
| `base` (this TV) | `1920x1080+0+0r0s1` |
| `e60n`, `o228k`, `o22n28k`, `o22n8k` | `3840x2160+0+0r0s1` |

So a 4K graphics plane is a real configuration that LG ships — on other models.
It matches their published guidance that app graphics are 1080p on 4K sets and
720p on FHD sets; the display engine scales the plane to the panel.

Two things follow:

- **No client-side lever exists.** Only the DRM master (`surface-manager`) sets
  the mode, there is no Wayland protocol to request one, and
  `com.webos.service.config` refuses the query without the
  `com.webos.surfacemanager` role. `wl_output` just reports the result.
- **The only lever at all** is editing that configd layer (or adding a
  `devicename/o22n2` one) and restarting `surface-manager`. Untested here, and
  worth being careful with: a geometry the display engine rejects means no UI
  until it is fixed over SSH. GPU cost would not be the problem — 1000
  triangles take 0.9 ms at 1080p, so 4x the pixels still fits in a frame.

**120 Hz is not reachable this way regardless.** The geometry string carries
offset, rotation and scale (`+0+0r0s1`) but no refresh field, the connector
advertises only three resolutions with no refresh variants, and its EDID reads
0 bytes — `TV-1` is an internal connector into the SoC's display engine, not a
link to the panel. See [opengl.md](opengl.md) for the measurements.

### How 4K120 homebrew actually does it

Moonlight-style clients — [moonlight-tv](https://github.com/mariotaku/moonlight-tv)
and its 4K120-focused fork Aurora — never rasterise 4K120. They receive a
compressed stream and hand it to the hardware decoder through **NDL
DirectMedia**, which outputs on a video plane. The GL plane stays 1080p60 and
carries only the overlay and UI.

The device's own codec table ([device-codec-capability.json](device-codec-capability.json))
agrees precisely:

| codec | max | fps |
|---|---|---|
| H.265 | 4096x2304 | **120** |
| H.264 | 4096x2304 | 60 |
| HEVC entry | 4096x2176 | 60 |

H.265 at 120 fps is the only 120 in the whole file. That is why those projects
insist on HEVC rather than AV1 — and reportedly why AV1 is avoided for
interactive streaming, at ~8-12 ms of decode latency against ~1 ms for H.265.

So the honest summary for a native app here:

- **Rendering your own frames**: 1080p60. Not negotiable from the client.
- **Playing a video stream**: up to 4K120 HDR, via NDL DirectMedia on the video
  plane — see [multimedia.md](multimedia.md) and [codecs.md](codecs.md).
- Mixing the two is the normal design: video on its plane, your GL overlay on
  the graphics plane, composited by the display engine.
