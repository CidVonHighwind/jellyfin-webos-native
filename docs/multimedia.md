# Hardware multimedia

## Decoder device nodes

```
crw-rw-rw-  161,0   /dev/vdec        video decoder   (world read/write)
crw-rw----  1820,0  /dev/venc        video encoder   (group `composit`)
crw-rw-rw-  /dev/fwload_vdec         decoder firmware loader
```

`/dev/vdec` being **0666** is notable — decoder access needs no privilege.

There are also ~23 V4L2 nodes (`/dev/video2`, `10`–`13`, `20`, `21`, `24`, `27`–`33`,
`40`, `50`, `60`, `70`, `240`, `241`). Most are `0600 root`; the ones in group
`composit` (`video20`, `27`, `28`, `31`, `60`, `70`) are the ones the compositor
and media stack use. These are LG's own pipeline plumbing, **not** a generic
`V4L2_M2M` decoder interface — do not expect `v4l2-ctl`-style stateful decoding
to work here.

## The supported native API: NDL_directmedia

LG ships a native media library, `libNDL_directmedia.so.1` ("NDL" = Native
Development Library). This is the documented path for native apps and what
ports like RetroArch/moonlight use. Exported entry points:

```
NDL_DirectMediaInit            NDL_DirectMediaQuit
NDL_DirectMediaLoad            NDL_DirectMediaUnload
NDL_DirectMediaSetWindowId     NDL_DirectMediaSetAppState
NDL_DirectMediaGetError

NDL_DirectVideoPlay                   NDL_DirectVideoSetArea
NDL_DirectVideoGetRenderBufferLength  NDL_DirectVideoFlushRenderBuffer
NDL_DirectVideoSetFrameDropThreshold  NDL_DirectVideoSetHDRInfo

NDL_DirectAudioPlay                   NDL_DirectAudioRegisterCallback
NDL_DirectAudioGetAvailableBufferSize NDL_DirectAudioGetTotalBufferSize
NDL_DirectAudioSupportMultiChannel

NDL_DirectEffectLoad / Play / Unload / GetAvailableBufferSize
```

Shape of the API: you `Init`, `Load` with a codec description, bind the output to
a window id (`SetWindowId` — ties into `wl_webos_foreign`, which is in the
Wayland global list), then feed compressed frames with `NDL_DirectVideoPlay` /
`NDL_DirectAudioPlay`. It is a **push-buffer** API — decode and presentation are
handled below you, including HDR metadata.

`NDL_DirectVideoSetArea` positions video, which means video is composited on its
own plane, not into your surface. Relevant if you plan to overlay graphics.

Companion libraries: `libNDL_media.so.1`, `libStarfishCameraPlayer.so.1`,
`libStarfishServiceIntegration.so.0`, `libStarfishInput.so.0`.

> Codec support is documented separately in **[codecs.md](codecs.md)**, sourced
> from `/etc/umediaserver/device_codec_capability_config.json`. Note that
> `NDL_directmedia` itself only references **H264, H265, OPUS, PCM** — for wide
> format support use `NDL_media` (URI playback, DRM, subtitles) instead.

## GStreamer

131 plugins in `/usr/lib/gstreamer-1.0/`. The hardware path is LG-specific:

- `libgstdecproxy.so` — LG's hardware decode proxy element
- `libgstlxvideosink.so` — LG hardware video sink
- `libgstlgaudiosink.so` — LG audio sink
- `libgstwaylandsink.so` — standard Wayland sink
- plus DRM/CENC plugins (`cencdrmplayready`, `ckdrm`, `dtcpip`), adaptive
  streaming (`dash`, `adaptiveng`), and container/parser plugins

So GStreamer is a viable route and `decproxy` is where hardware decode enters.
For a native app, NDL_directmedia is lower friction.

## Recommendation

For playback in a native app, use **NDL_directmedia** via `dlopen` (consistent
with the no-sysroot approach used everywhere else in this repo). Reach for
GStreamer only if you need container demuxing or adaptive streaming that you
would otherwise reimplement.
