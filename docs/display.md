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
