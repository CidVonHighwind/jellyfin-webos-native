# Vulkan on webOS TV

## Summary

Vulkan **works**, and is a fairly complete 1.3 implementation. Two things are
missing, and only one of them matters:

| | |
|---|---|
| ICD | `/usr/lib/libmali.so` — full Vulkan **1.3.260** driver, Mali-G52 |
| ICD registration | `/usr/share/vulkan/icd.d/mali.json` (already present) |
| Loader (`libvulkan.so.1`) | **absent** — but we don't need it (see below) |
| Platform WSI (`VK_KHR_wayland_surface`) | **absent** — this is the real constraint |
| `/dev/mali0` | `0666`, unprivileged access |

This is why Vulkan appears missing on the device: there is no loader, so anything
that `dlopen`s `libvulkan.so.1` (including SDL2's `SDL_Vulkan_LoadLibrary`)
fails. The driver itself is fine.

## Initialising without the loader

The ICD exports exactly the three entrypoints a modern driver should:

```
vk_icdGetInstanceProcAddr
vk_icdGetPhysicalDeviceProcAddr
vk_icdNegotiateLoaderICDInterfaceVersion
```

Because we use **no WSI surface extension**, the Khronos loader buys us nothing:
its jobs are ICD discovery (one known ICD here), layers (none on device), and
surface object ownership (we create no `VkSurfaceKHR`). So skip it:

```zig
const lib = dlopen("libmali.so");
const negotiate = dlsym(lib, "vk_icdNegotiateLoaderICDInterfaceVersion");
const gipa      = dlsym(lib, "vk_icdGetInstanceProcAddr");  // use as vkGetInstanceProcAddr
var v: u32 = 5; negotiate(&v);                               // → 5, rc 0
```

Then `gipa(null, "vkCreateInstance")` etc. Verified working in `vkinfo.zig`.
Nothing needs to be shipped alongside the binary.

If you ever *do* need WSI, you would build the Khronos loader for
`arm-linux-gnueabi` and ship it as `libvulkan.so.1` — but it still could not
give you a Wayland surface the driver doesn't implement.

## The presentation problem

Instance extensions — all 9:

```
VK_EXT_debug_utils            VK_EXT_headless_surface
VK_KHR_surface                VK_KHR_get_surface_capabilities2
VK_KHR_get_physical_device_properties2
VK_KHR_device_group_creation  VK_KHR_external_fence_capabilities
VK_KHR_external_memory_capabilities   VK_KHR_external_semaphore_capabilities
```

`VK_KHR_swapchain` **is** supported as a device extension (rev 70), but the only
platform surface extension is `VK_EXT_headless_surface`. There is no
`VK_KHR_wayland_surface`, no `VK_KHR_display`, no xlib/xcb. Every Wayland
reference inside `libmali.so` is EGL-side (`eglBindWaylandDisplayWL`,
`egl_winsys_get_implementation_wayland`) — Mali's Wayland WSI on this build is
wired into EGL only.

> **A Vulkan swapchain cannot present to the screen on this device.**
> You must render to an exportable image and hand the dma-buf to the compositor.

This also rules out the SDL2 shortcut: `libSDL2-2.0.so.0.14.0` is on the device,
webOS-patched with `wl_webos_shell` and exposing `SDL_Vulkan_*`, but
`SDL_Vulkan_CreateSurface` needs `VK_KHR_wayland_surface` and will fail
regardless of the loader.

## Interop extensions — the ones that matter

All confirmed present as device extensions:

```
VK_EXT_external_memory_dma_buf (rev 1)     VK_KHR_external_memory_fd (rev 1)
VK_EXT_image_drm_format_modifier (rev 2)   VK_EXT_queue_family_foreign (rev 1)
VK_KHR_external_semaphore_fd (rev 1)       VK_KHR_external_fence_fd (rev 1)
VK_KHR_dynamic_rendering (rev 1)           VK_KHR_synchronization2 (rev 1)
VK_EXT_image_compression_control_swapchain (rev 1)
```

`VK_EXT_image_drm_format_modifier` is the key one: it lets the driver allocate an
**AFBC** image and report the modifier, which is exactly what the compositor
wants (see [display.md](display.md)). `VK_KHR_dynamic_rendering` removes all
renderpass/framebuffer boilerplate.

## What is NOT available — correcting an earlier claim

`strings libmali.so` lists many extension names that the driver **does not
advertise at runtime**. The blob is a generic Mali DDK build; only the
enumerated list is real. Confirmed absent from
[vulkan-extensions.txt](vulkan-extensions.txt):

```
VK_KHR_ray_query                 VK_KHR_acceleration_structure
VK_KHR_ray_tracing_pipeline      VK_EXT_descriptor_indexing
VK_KHR_push_descriptor           VK_KHR_cooperative_matrix
VK_EXT_fragment_density_map      VK_KHR_wayland_surface / VK_KHR_display
```

> Earlier in this investigation I said ray query was available, based on
> `strings`. **That was wrong** — there is no ray tracing on this device. Trust
> `vkinfo` (runtime enumeration), never `strings`, for capability decisions.

Note also **zero instance layers** — no validation layer on device. Validate on
the PC against desktop Vulkan, or cross-check with `VK_EXT_debug_utils`, which
*is* available.

## Getting a triangle on screen

Design, not yet implemented. Render into dma-buf-backed images and hand them to
the compositor directly — no `VkSurfaceKHR` anywhere:

1. **Wayland**: bind `wl_compositor`, `wl_webos_shell`, `zwp_linux_dmabuf_v1`;
   create surface, set `appId`, fullscreen.
2. **Vulkan**: `dlopen` the ICD as above. Create instance (no extensions needed).
   Create device with `VK_KHR_external_memory_fd`,
   `VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`,
   `VK_EXT_queue_family_foreign`, `VK_KHR_dynamic_rendering`.
3. Query supported DRM format modifiers for `R8G8B8A8`; create 2 exportable
   `VkImage`s with `VkImageDrmFormatModifierListCreateInfoEXT`.
4. `vkGetMemoryFdKHR` → dma-buf fd per image. Query the chosen modifier and
   per-plane offsets/strides with `vkGetImageDrmFormatModifierPropertiesEXT`
   and `vkGetImageSubresourceLayout`.
5. Wrap each fd as a `wl_buffer` via `zwp_linux_dmabuf_v1` params, passing that
   modifier.
6. Draw with `VK_KHR_dynamic_rendering`; release the image to
   `VK_QUEUE_FAMILY_FOREIGN_EXT` before handing it over.
7. `attach` / `damage` / `commit`; drive the loop from `wl_buffer.release` and
   `wl_surface.frame` callbacks.

Steps 1 and the buffer/commit half of 7 are already proven by `wlbox.zig`; the
Vulkan half is what remains. Expect ~600–800 lines, most of it the hand-rolled
swapchain — not because a triangle is hard, but because the driver will not
present for us.

### Cheaper alternative

EGL + GLES2 on `wayland-egl` needs ~200 lines and is the path RetroArch's webOS
port already uses on this exact stack (`libEGL.so.1.4.0`, `libGLESv2.so.2.1.0`,
`libwayland-egl.so.1.20.0` are all on the device, backed by the same
`libmali.so`). Choose Vulkan only if something actually requires it.

## Reproducing

```sh
zig build-exe vkinfo.zig -target arm-linux-gnueabi.2.31 -lc -O ReleaseSmall
scp vkinfo root@10.10.8.63:/tmp/ && ssh root@10.10.8.63 /tmp/vkinfo
```

`vkinfo` needs no Wayland environment. Beware piping its output through `head` —
SIGPIPE truncates the dump.
