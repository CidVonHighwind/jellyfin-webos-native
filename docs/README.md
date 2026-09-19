# Native applications on webOS TV (LG, `10.10.8.63`)

Findings from investigating how to run native code — and specifically Vulkan —
on an LG webOS TV. Everything here was verified on the device unless explicitly
marked as unverified.

| doc | contents |
|---|---|
| [device.md](device.md) | ABI, toolchain, build and deploy |
| [display.md](display.md) | How to get pixels on screen; why the framebuffer route is closed |
| [opengl.md](opengl.md) | OpenGL ES 3.2 capabilities, GPU timing, and the Slang -> GLSL ES pipeline |
| [vulkan.md](vulkan.md) | The Mali ICD, the missing loader, the missing WSI, and how to initialise anyway |
| [multimedia.md](multimedia.md) | Hardware video decode: NDL_directmedia, GStreamer, device nodes |
| [codecs.md](codecs.md) | Full codec support: hardware limits, containers, which API to use |
| [packaging.md](packaging.md) | .ipk format, installing, and the reserved-namespace trap |
| [input.md](input.md) | Input devices and options; forwarding the PC cursor as a remote |
| [network.md](network.md) | Interfaces, link speeds, listening services |
| [device-codec-capability.json](device-codec-capability.json) | Raw LG codec capability table pulled from the TV |
| [gstreamer-codec-elements.txt](gstreamer-codec-elements.txt) | Raw inventory: 219 GStreamer codec elements + caps |
| [vulkan-extensions.txt](vulkan-extensions.txt) | Raw `vkinfo` dump: 9 instance + 102 device extensions |
| [opengl-capabilities.txt](opengl-capabilities.txt) | Raw `glinfo` dump: limits + 28 EGL and 101 GL extensions |

## The three facts that shape everything

1. **Userland is 32-bit ARM** (`arm-linux-gnueabi`), on a 64-bit kernel.
   `uname -m` says `aarch64` and is misleading. The float ABI is soft *for
   argument passing only* — the FPU is real and fast, but Zig's `gnueabi` target
   disables FP codegen and costs 10.5x. See [device.md](device.md).
2. **The framebuffer cannot be written directly.** Scanout is AFBC-compressed and
   owned by `surface-manager`. Wayland is the only route to the screen.
3. **Vulkan works but cannot present.** The driver is a complete Vulkan 1.3.260
   ICD, but ships no `VK_KHR_wayland_surface` — so a normal swapchain cannot
   reach the display. Present via `zwp_linux_dmabuf_v1` instead, or use
   **OpenGL ES 3.2**, which has a working EGL/Wayland binding — see
   [opengl.md](opengl.md).

## Status

Working and verified on-device:

- `fbflash.zig` — framebuffer prober; documents the dead end
- `wlinfo.zig` — lists the compositor's Wayland globals
- `wlbox.zig` — **fullscreen red box via `wl_shm` + `wl_webos_shell`** (confirmed visible)
- `vkinfo.zig` — enumerates the Vulkan ICD
- `fptest.zig` — float throughput benchmark (settles the soft-float question)
- `inputlog.zig` — on-screen log of every input event; maps the remote and cursor
- `glinfo.zig` — EGL/GL ES capabilities
- `gltri.zig` — **1000 instanced rotating triangles at 60 fps** with CPU/GPU frame times

Build and deploy with `build.zig`; SSH target comes from `.env`:

```sh
zig build                     # all apps -> zig-out/bin
zig build run -Dapp=wlbox     # deploy one app and run it on the TV
zig build package -Dapp=wlbox # build an .ipk
zig build info                # show resolved .env
```

Not yet built:

- **the Vulkan triangle** — design in [vulkan.md](vulkan.md#getting-a-triangle-on-screen)
(The PC-cursor-as-remote idea was dropped — see [input.md](input.md).)
