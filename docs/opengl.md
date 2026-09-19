# OpenGL ES

**This is the working path to the screen for rendered graphics.** Unlike Vulkan
(a complete ICD that [cannot present](vulkan.md)), GL ES has a full EGL/Wayland
window-system binding on this device, so a normal `eglSwapBuffers` loop works.

Verified with `zig build run -Dapp=glinfo`; the raw dump is
[opengl-capabilities.txt](opengl-capabilities.txt).

## What the device is

```
EGL_VERSION     1.5 Bifrost-"r46p0-01eac1"
EGL_VENDOR      ARM
EGL_CLIENT_APIS OpenGL_ES              <-- ES only, no desktop GL
GL_VENDOR       ARM
GL_RENDERER     Mali-G52
GL_VERSION      OpenGL ES 3.2 v1.r46p0-01eac1...
GL_SL_VERSION   OpenGL ES GLSL ES 3.20
```

Libraries present: `libEGL.so.1`, `libGLESv2.so.2`, `libGLESv1_CM.so.1`,
`libwayland-egl.so.1`. All are `dlopen`'d at runtime (see `src/gl.zig`), so the
build still needs no headers and no sysroot.

**ES 3.2 is the full feature set**, not a cut-down profile: compute shaders,
geometry and tessellation shaders, `GL_ANDROID_extension_pack_es31a`, texture
buffers, shader storage blocks, ASTC (LDR + HDR), `GL_KHR_debug`, multiview.
101 GL extensions and 28 EGL extensions.

## Limits worth knowing

| | |
|---|---|
| `MAX_TEXTURE_SIZE` | 16383 (also 3D and cube) |
| `MAX_ARRAY_TEXTURE_LAYERS` | 4096 |
| `MAX_VERTEX_ATTRIBS` | 32 |
| `MAX_VERTEX_UNIFORM_VECTORS` | 4096 |
| `MAX_FRAGMENT_UNIFORM_VECTORS` | 4096 |
| `MAX_VARYING_VECTORS` | 31 |
| `MAX_TEXTURE_IMAGE_UNITS` | 16 (96 combined) |
| `MAX_UNIFORM_BLOCK_SIZE` | 65536 |
| `MAX_UNIFORM_BUFFER_BINDINGS` | 216 |
| `MAX_SHADER_STORAGE_BLOCK_SIZE` | 2 GiB |
| `MAX_DRAW_BUFFERS` / `MAX_COLOR_ATTACHMENTS` | 4 |
| `MAX_SAMPLES` | 4 |
| `MAX_COMPUTE_WORK_GROUP_INVOCATIONS` | 36 |

`MAX_VERTEX_ATTRIB_BINDINGS` reads 0 — `glVertexAttribBinding` (the separate
attribute format API) is not usable; use plain `glVertexAttribPointer`.

## Zero-copy and interop

The extensions that matter for sharing buffers with the rest of the system:

- `EGL_EXT_image_dma_buf_import` + `EGL_EXT_image_dma_buf_import_modifiers` —
  import a dma-buf (a decoded video frame, a Vulkan image) as an `EGLImage`.
- `EGL_WL_bind_wayland_display` — import a client's `wl_buffer` directly.
- `GL_OES_EGL_image_external` / `_essl3`, `GL_EXT_YUV_target` — sample those
  images, including YUV, in a shader.
- `GL_EXT_EGL_image_storage`, `EGL_ANDROID_native_fence_sync`,
  `EGL_KHR_fence_sync`, `EGL_KHR_wait_sync` — storage and cross-API sync.
- `GL_EXT_shader_framebuffer_fetch`, `GL_EXT_shader_pixel_local_storage`,
  `GL_ARM_shader_framebuffer_fetch` — tile-local reads, the cheap way to do
  post-processing on a Mali.

So **Vulkan can still render and GL can present it**, via a dma-buf and
`EGL_EXT_image_dma_buf_import`, without going through the compositor protocol
by hand.

## GPU timing: the extension lies

`GL_EXT_disjoint_timer_query` is advertised. It is not implemented: a
`GL_TIME_ELAPSED_EXT` query never becomes available and a blocking
`glGetQueryObjectui64vEXT` returns 0, with no GL error, on r46p0.

`gltri` therefore starts with the query, and after ~120 frames with no result
falls back to a `glFinish()` stopwatch, marked with a `*` on screen. The same
binary on a desktop Mesa driver uses the real query path. Measured with 1000
instanced triangles at 1920x1080:

```
cpu 0.40 ms   gpu* 0.90 ms   frame 16.67 ms      (TV, vsync-locked 60 Hz)
cpu 0.07 ms   gpu  0.04 ms   frame  6.94 ms      (desktop, 144 Hz)
```

CPU time is measured with `CLOCK_THREAD_CPUTIME_ID`, not wall clock. With
vsync on, the wait for a free swapchain buffer happens inside the *next*
frame's first GL call, so a wall-clock "CPU time" just reports the refresh
interval back at you — the first version of this did exactly that and read
16.5 ms.

## Refresh rate: the graphics plane is 60 Hz, whatever the panel does

The TV panel is 120 Hz with FreeSync. **The LSM graphics plane is not.** Nothing
in the app assumes a rate, but the rate that comes back is 60:

- `wl_output.mode` reports `1920x1080` at **60000 mHz**.
- The DRM CRTC agrees — `/sys/kernel/debug/dri/0/state`:
  `mode: "1920x1080": 60 148500 1920 2008 2052 2200 1080 1084 1089 1125` — a
  stock 148.5 MHz 1080p60 timing, with no `mode_changed` pending.
- `/sys/class/drm/card0-TV-1/modes` lists only `1920x1080`, `3840x2160`,
  `1280x720` — one entry each, so no 120 Hz variant is exposed to DRM at all.
- There is no Wayland protocol on this device to ask for one:
  `wl_starfish_output` sounds promising but its only requests are
  `set_stereoscope` / `stereoscope_hint`, and no `wp_tearing_control_manager_v1`
  or presentation-timing global is advertised.

So 120 Hz and VRR belong to the TV's video/HDMI path, not to the plane a native
Wayland client draws into. The plane's 1920x1080 comes from a per-model configd
value and 4K120 is a property of the *video* planes, not this one — the whole
picture is in [display.md](display.md#two-planes-graphics-is-1080p60-video-is-4k120). Nothing here is hardcoded to 60, and if that plane
ever changes the app follows it automatically:

- the window size comes from `wl_output` (`wl.open(..., 0, 0, ...)`), never from
  a literal;
- the refresh rate comes from `wl_output.mode` and is re-read whenever the
  compositor sends a new one;
- animation is driven by elapsed seconds, so it looks identical at any rate;
- the overlay shows **measured Hz / reported Hz** side by side, so a mismatch or
  a mode change is visible on screen.

`SWAP_INTERVAL` in the environment sets the EGL swap interval (default 1).
`SWAP_INTERVAL=0` presents unthrottled, which is what a variable-refresh output
wants and also shows the headroom:

```
SWAP_INTERVAL=1   frame 16.66 ms    60 Hz    (compositor-throttled)
SWAP_INTERVAL=0   frame  2.68 ms   373 Hz    (same scene, no throttle)
```

1000 triangles cost 0.4 ms of CPU and ~0.9 ms of GPU, so the 60 Hz cap is the
compositor's, not the app's — a 120 Hz plane would need no code change.

## Shaders: Slang to GLSL ES

Shaders are written in [Slang](https://shader-slang.org/) (`src/shaders/*.slang`)
and compiled at build time. **`slangc` must be on `PATH`** — see the README.

Slang has no ESSL target: `-target glsl` emits *desktop* GLSL 450 in the Vulkan
flavour, and `-profile` accepts only `glsl_{150..460}`. SPIR-V is not an option
either, since this driver exposes no SPIR-V ingestion extension. The build
therefore compiles to GLSL and rewrites the header (`build.zig`, `slang_script`):

- `#version 450` becomes `#version 320 es` plus explicit
  `precision highp float; precision highp int;` (ES requires a default precision;
  desktop GLSL does not).
- `layout(row_major) uniform;` and `layout(row_major) buffer;` are dropped —
  layout-qualifier defaults are a GLSL 4.2 feature.

The shader *body* needs no rewriting, with one rule: **avoid constructs Slang
lowers to Vulkan-only GLSL.** `SV_VertexID` is the one that bites — it becomes
`gl_VertexIndex - gl_BaseVertex` and `#extension GL_ARB_shader_draw_parameters`,
neither of which exists in GLSL ES. `text.slang` takes its quad corners from a
4-vertex buffer instead.

Two more things to know about Slang's GLSL output:

- Global `uniform` declarations become a `std140` uniform *block* named
  `block_GlobalParams_0` at `binding = 0`. So uniforms are set with
  `glBufferSubData` + `glBindBufferBase`, never `glUniform*`. Pad to 16 bytes.
- Binding points are handed out in declaration order across *all* resources, so
  a sampler declared after that uniform block lands on `binding = 1` and its
  texture must be bound to texture unit **1**. This silently draws nothing if
  you assume 0.

If `glslangValidator` is installed the build validates every generated shader
against ES 3.20 before embedding it, which catches all of the above on the
host instead of on the TV.

## The app

`src/gltri.zig` — 1000 triangles, one `glDrawArraysInstanced` call:

| attribute | divisor | contents |
|---|---|---|
| 0 `position` | 0 | the one shared triangle, 3 vertices |
| 1 `offset` | 1 | where the instance sits, NDC |
| 2 `direction` | 1 | starting angle, also the hue |
| 3 `speed` | 1 | rotation rate |
| 4 `phase` | 1 | time offset, so instances peak at different moments |
| 5 `size` | 1 | scale amplitude, so they peak at different sizes |

`scale = sin(time + phase) * size`, `angle = direction + time * speed`, with
`time` and `aspect` as the only uniforms. Aspect correction is applied to the
triangle's own vertices, not to its offset — scaling the offset too would
squeeze the whole field into the middle third of a 16:9 screen.

The frame-time overlay is an R8 coverage texture rasterised on the CPU by
`src/text.zig` and drawn as one blended triangle strip, which is also how any
other HUD in this repo should work: no glyph atlas, no text shaping, ~60 lines.

`GLTRI_DUMP=1` reads the frame back with `glReadPixels` and prints it as ASCII,
so the render can be checked over SSH. For a real picture, `zig build shot`
grabs a frame from the TV's VNC server on 5900 (`tools/vncshot.py`) -- that is
what caught the overlay being white-on-nothing and unreadable over the scene;
it now draws its glyphs on a dim plate.

## What the UI renderer costs, and why

`uidemo` at 1080p on the TV, library screen, 3.14x overdraw, measured with the
`glFinish` stopwatch (`GL_EXT_disjoint_timer_query` is dead here, see above).
Each row is a single change from the row above:

| variant | GPU |
|---|---|
| MSDF glyphs, `discard` clipping, one branchy shader | 9.74 ms |
| clip by shrinking the quad in the vertex shader instead of `discard` | 8.28 ms |
| rasterised glyphs instead of MSDF | 8.13 ms |
| **one fragment program per instance kind + skip corner math in interiors** | **3.85 ms** |

Two reference points for where that can go, same scene and geometry:

| probe | GPU |
|---|---|
| fragment shader replaced by `return i.color` | 2.80 ms |
| real shaders with `glDisable(GL_BLEND)` | 2.29 ms |
| real shaders, rounded-corner math stubbed out | 3.94 ms |

So the final version is *at* the no-rounded-math figure while still drawing
rounded corners: the remaining time is rasterisation and blending, not shading.

### Where the time actually went

**`roundedDistance` over large areas, not branching.** It was 4.2 ms of the
8.1 ms. Every panel, card and the full-screen background ran a `length()` and a
`smoothstep` per fragment for corners that occupy a few hundred pixels of a
half-megapixel rect. Two changes fix it, and together they account for almost
the whole win:

- **an interior test**: `min(local, size - local) >= radius` is four
  instructions and skips the corner math for everything that no corner can
  reach;
- **one program per kind** (fill, round, border, glyph, image) so a square fill
  runs `return i.color` and nothing else. Branching itself was only worth about
  1 ms; the value is that specialised programs *have no other code to run*.

This is cheap precisely because the renderer already batches on binding
changes, so the program is just another part of the batch state. It took the
frame from 17 draw calls to 32, which cost nothing measurable.

**`discard` is expensive on Mali.** Clipping by discarding fragments outside a
clip rect disables early-ZS and Forward Pixel Kill, so every overdrawn fragment
runs the shader to completion. Clipping by shrinking the quad to its clip
rectangle in the vertex shader was worth 1.5 ms, and fully clipped instances --
most rows of a virtual list -- now cost nothing at all.

### Overdraw, and why depth testing does not help

Overdraw was measured directly, and it is not the problem:

- Removing the full-screen background fill, a whole **1.0x of overdraw**, made
  the frame **slower**: 3.83 -> 4.57 ms. An opaque full-screen write lets the
  driver skip loading the framebuffer into each tile; without it every tile has
  to be read back before blending. On a tile-based GPU that fill is closer to a
  clear than to overdraw.
- Of the remaining 2.14x, essentially all of it is *visible* UI with soft edges:
  rounded panels (1.21x) and border rings (0.80x). Blending it costs 1.6 ms.

A depth test removes fragments hidden behind opaque geometry that was drawn
**earlier**. A UI is painter-ordered, so occluders come later, and at the moment
an occluded fragment is shaded there is nothing in front of it yet. Getting any
benefit would mean splitting every rounded rect into an opaque interior and
translucent edges, sorting the opaque set front-to-back into its own pass, then
drawing the translucent set back-to-front against a depth buffer. The prize is
whatever opaque area is covered by later opaque area -- which this measurement
says is nearly all the background fill, and that is already free.

Marking genuinely opaque square fills as non-blended is in the renderer anyway
(it is the correct state, and blending is part of the batch key), but it
measured flat: 3.88 -> 3.85 ms.
