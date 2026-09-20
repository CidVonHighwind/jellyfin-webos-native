# NDL: hardware video

NDL is LG's native media API — the way a native app reaches the **video plane**
and the hardware decoder. It is the only path to 4K or 120 fps on this device;
the graphics plane a Wayland client draws into is a fixed 1080p60
([display.md](display.md)).

`src/ndlplay.zig` is a working player: Annex-B elementary stream in, hardware
decode out, from a file on the TV or a TCP stream published by the PC.

```sh
zig build videos                      # encode demo clips and push them to the TV
zig build play -Dapp=ndlplay -Dsrc=/media/developer/videos/demo_1920x1080p120.h265
zig build stream -Dapp=ndlplay -Dgeom=1920x1080p60   # live from this machine
```

`ndlplay` also verifies graphics-over-video composition. Its transparent ARGB
surface draws a translucent bottom control strip, a moving progress indicator,
and a settings glyph above the NDL video plane. This is enabled by default;
set `NDL_OVERLAY=0` to return to the bare punch-through test. The raw stream
has no duration, so the indicator loops deliberately: it verifies redraws,
not playback position.

Measured on device, all three decoding in real time:

| clip | result |
|---|---|
| 1920x1080p60 H.264 | 480 frames in 7 s |
| 1920x1080p120 H.265 | 960 frames in 7 s |
| 3840x2160p30 H.265 | 240 frames in 7 s |
| live H.264 1080p60 over TCP | 480 frames in 7 s, sustained |

## The four libraries

All are ~9 KB stubs that `dlopen` a matching `_impl` library on first use.
**`NDL_*_DL_Initialize()` must be called before anything else** or every entry
point traps.

| library | what it is |
|---|---|
| `libNDL_directmedia.so.1` | elementary-stream player: you feed it H.264/H.265/VP9/AV1 access units. What `ndlplay` and Moonlight-style clients use. |
| `libNDL_media.so.1` | URI player: `NDL_MediaLoad`, seek, playback rate, subtitles, track selection, DRM. Built on uMediaServer. |
| `libNDL_vt.so.1` | "video texture": decoded video into a **GL texture** (`NDL_VT_GenerateTexture`, `NDL_VT_GetMaxTextureResolution`). The bridge between the video plane and an OpenGL app. |
| `libNDL.so.1` | Luna service calls and launch parameters (`NDL_ServiceCall`, `NDL_GetParamString`, `NDL_GetAppID`). |

Full symbol lists are in [ndl-symbols.txt](ndl-symbols.txt).

## The DirectMedia interface

Signatures are from webos-userland's `NDL_directmedia` v2 headers; this device
implements v2.

```c
bool NDL_DirectMedia_DL_Initialize(void);          /* first, always */
int  NDL_DirectMediaSetWindowId(const char *id);   /* see below: before Init */
int  NDL_DirectMediaInit(const char *app_id);
int  NDL_DirectMediaLoad(NDL_DIRECTMEDIA_DATA_INFO_T *info, NDLMediaLoadCallback cb);
int  NDL_DirectMediaSetAppState(NDL_DIRECTMEDIA_APP_STATE state);
int  NDL_DirectVideoSetArea(int left, int top, int width, int height);
int  NDL_DirectVideoPlay(void *buffer, unsigned size, long long pts);
int  NDL_DirectVideoGetRenderBufferLength(int *length);
int  NDL_DirectVideoFlushRenderBuffer(void);
int  NDL_DirectVideoSetHDRInfo(NDL_DIRECTVIDEO_HDR_INFO_T info);
int  NDL_DirectAudioPlay(void *buffer, unsigned size, long long pts);
int  NDL_DirectMediaUnload(void);
int  NDL_DirectMediaQuit(void);
const char *NDL_DirectMediaGetError(void);
```

`NDL_DIRECTMEDIA_DATA_INFO_T` is `{ int width; int height; NDL_VIDEO_TYPE type;
int unknown1; }` followed by a 32-byte audio union. Video types are
`H264 = 1, H265 = 2, VP9 = 3, AV1 = 4`. Zeroing the audio union means "no
audio", which this implementation accepts.

The full struct is in webosbrew/webos-userland,
`include/libndl-media/NDL_directmedia_types.h`, and this device's
`DMPlayer::createLoadParameter` matches it exactly. Audio types are
**`PCM = 1, MP3 = 2, OPUS = 3`** and nothing else; the union starts at byte 16,
with the PCM arm `{ type, unknown1, const char *format, *layout,
*channelMode, sampleRate }` — strings validated against `isSupportedPCMFormat`
/ `isSupportedPCMLayout`, defaults `S16LE` / `interleaved` / `stereo`. The
sample-rate enum is **not** ordered by frequency (`48K = 1, 44.1K = 2, 32K = 3,
24K = 4, 16K = 5, 12K = 6, 8K = 7, 22.05K = 8`) and `0` means bypass, which
takes the pipeline down. Video and audio are emitted in one pass — the video
branch rejoins the audio switch — so `{video, audio}` together is fine.

### The ES player has no clock

`DIRECTMEDIA-ES-PLAYER` presents each buffer as it arrives. The PTS you pass
is used for A/V alignment and the render-queue bookkeeping, not as a
presentation deadline — **the application holds the clock**. Three things were
tried against the real pipeline, by interposing
`StarfishMediaAPIs::Load` with `LD_PRELOAD` and rewriting its payload:

| lever | result |
|---|---|
| `"lowDelayMode": false` | still arrival-paced |
| `"videoInfo":{"isGameMode": false}` | still arrival-paced |
| `StarfishMediaAPIs::Play()` (returns 1) | still arrival-paced |

That last one is worth knowing on its own: `NDL_Media::DMPlayer::Play()` is
exported, calls `StarfishMediaAPIs::Play()`, and **nothing in the library ever
calls it** — there is no `NDL_DirectMediaPlay` in v2, and `SetAppState` only
reaches `DVPlayer::SetVisible`. Calling it by hand changes nothing.

The load payload NDL actually sends, for reference:

```json
{"args":[{"mediaTransportType":"DIRECTMEDIA-ES-PLAYER","option":{
  "appId":"...","lowDelayMode":true,
  "externalStreamingInfo":{"contents":{
    "codec":{"video":"H265","audio":"PCM"},
    "esInfo":{"videoHeight":1080,"videoWidth":1920,
              "pauseAtDecodeTime":true,"ptsToDecode":0},
    "pcmInfo":{"sampleRate":1,"channelMode":"stereo",
               "format":"S16LE","layout":"interleaved"}}},
  "adaptiveStreaming":{"maxHeight":1080,"maxFrameRate":120,"maxWidth":1920},
  "windowId":"_Window_Id_66","videoInfo":{"isGameMode":true}}}]}
```

So a player on this API needs its own clock and its own read-ahead: pace the
feed against the PTS, and demux on another thread so a stall in the source
never lands on a frame deadline. The untried lever, if presentation timing
ever becomes worth it, is `setMasterClock`/`setSlaveClock` plus
`setMediaSynchronizerOptions` — the media-synchronizer path, which is a
different project. `libNDL_media` (URI player) is the other way out: it clocks
playback itself, at the cost of owning demux and everything else.

**MP3 is in the enum but does not work.** NDL emits `"audio":{"codec":"MP3"}`
with no rate or channel count, SMP fails to build caps for it, and Load prints
the pair

```
g_object_set: assertion 'G_IS_OBJECT (object)' failed
gst_mini_object_unref: assertion 'mini_object != NULL' failed
```

— `g_object_set(appsrc, "caps", …)` plus `gst_caps_unref` with both null. The
audio source is never created; feeding it then dies in
`StarfishMediaAPIs::Feed`, whose first instruction is `ldr r3, [r1, #0x4c]`
(hence a fault at address `0x4c`, not a mutex bug). **Decode to PCM and feed
that instead** — which is what the Jellyfin client does.

## Four things that cost time

**1. It needs a Luna role, so it must be an installed app.** Without one you get
`std::runtime_error: LSRegisterPubPriv FAILED` and `terminate`. The role file
generated at install time is keyed on the binary's **exact path**:

```json
{ "role": { "exeName": "/media/developer/apps/usr/palm/applications/<id>/<main>",
            "allowedNames": ["com.webos.media.client.*", "com.webos.rm.client.*", ...] } }
```

So running the *installed* binary over SSH works exactly like being launched by
SAM, and keeps stderr on your terminal. That is what `zig build play` does. The
app id passed to `NDL_DirectMediaInit` must match the installed app — `ndlplay`
takes it from its own working directory, since SAM provides no environment. One
app id per app, which is why packaging rewrites `appinfo.json` per `-Dapp`.

**2. Set the window id BEFORE `NDL_DirectMediaInit`.** `libNDL_directmedia_impl`
links against `libSDL2` and, if it has not been given a window id by the time it
initialises, calls `SDL_webOSCreateExportedWindow` itself — which fails with
`fail creating exported window : no video device` unless you have an SDL video
subsystem. Hand it an id from `wl_webos_foreign` first and it takes its
"external windowid" path instead. **SDL is not required.** It still calls
`SDL_webOSExportedSetProperty` and `SDL_webOSSetExportedWindow` afterwards, both
fail harmlessly, and playback is unaffected.

**3. Call `NDL_DirectMediaSetAppState(FOREGROUND)`.** Nothing else does. Without
it the decoder accepts every frame, reports no error, and shows nothing — the
implementation logs "Video feed in the background state" and drops them. This
was the difference between a working player and a black screen.

**4. Split into access units, not chunks.** `NDL_DirectVideoPlay` takes one
access unit with its PTS. Feeding fixed-size chunks "works" (no error) but the
timing is meaningless. Annex-B splitting is a start-code scan plus one bit:

- a VCL NAL is type 1..5 (H.264, low 5 bits) or type < 32 (H.265, bits 1..6);
- it begins a new picture if the top bit of the byte after the NAL header is
  set — H.264's `first_mb_in_slice` is exp-Golomb, whose zero is the single bit
  `1`, and H.265's `first_slice_segment_in_pic_flag` is that bit directly.

Both codecs, one test. Without it, x264's `-tune zerolatency` (sliced threads)
reads as ~1000 "frames" a second because every slice looks like a picture.

## Punch-through, without SDL

The window id comes from `wl_webos_foreign`, whose protocol has no published
XML — `zig build run -Dapp=wlinfo` dumps it off the library's own tables:

```
wl_webos_foreign v1
  -> [1] export_element(nou)          new_id, wl_surface, type
wl_webos_exported v1
  -> [1] set_exported_window(oo)      source region, destination region
  -> [3] set_property(ss)
  <- [0] window_id_assigned(su)       "_Window_Id_39", type
```

Export type 0 is video — the event echoes the type back, so the guess is
checkable. `src/wl.zig`'s `exportVideoWindow` does this and returns the id.

The surface must be committed and **transparent** where the video should show.
If it is opaque you see your own pixels; `NDL_BG=opaque` in `ndlplay` paints it
red on purpose, which is how to tell "surface not composited" from
"punch-through not working".

Note that **`zig build shot` cannot see video**: the VNC server captures the
graphics plane, and the video plane is composited downstream of it. A screenshot
of a working player is a black rectangle. Trust the frame counter in the log,
and your eyes.

## Events

The load callback is `void (*)(int type, long long value, const char *text)`,
and the types are `PF_EVENT_T` from webos-userland's `StarfishMediaAPIs.h`.
The ones a Jellyfin session actually produces, in the order they arrive:

| type | name | carries |
|---|---|---|
| 13 | `INT_NUM_PROGRAM` | program count |
| 14 / 15 | `INT_NUM_VIDEO_TRACK` / `_AUDIO_TRACK` | track counts |
| 5 / 8 | `STR_VIDEO_TRACK_INFO` / `STR_AUDIO_TRACK_INFO` | caps, as text |
| 17 | `STR_RESOURCE_INFO` | `{"context":…,"resourceList":[VDEC,PCMMC]}` |
| 22 | `STATE_UPDATE__LOADCOMPLETED` | `"true"` |
| 7 | `STR_AUDIO_INFO` | `{"track":1,"immersive":"none"}` |
| 4 | `STR_VIDEO_INFO` | frame rate, scan type, HDR, SEI, VUI |
| 26 | `STATE_UPDATE__PLAYING` | `"true"` |
| 44 / 46 | `INT_BUFFERLOW` / `STR_BUFFERLOW` | backpressure, downward |
| 45 | `STR_BUFFERFULL` | backpressure, upward |
| 25 | `STATE_UPDATE__SEEKDONE` | a seek landed |
| 23 | `STATE_UPDATE__UNLOADCOMPLETED` | `"true"` — **not** end of stream |

**There is no pull side.** `INT_NEED_DATA` (38) and `INT_ENOUGH_DATA` (39) are
in the enum, but `onEnoughData` is wired only in `mediapipeline::DvrPipeline`
and there is no `onNeedData` symbol in `libpf` at all. Load a stream and feed
it nothing and the pipeline says nothing after 22/7: it never asks. The
application pushes, and the only flow control is reactive — `Feed`'s own
`BufferFull` reply plus 44/45/46.

## Seeking

`StarfishMediaAPIs::flush(const char *)` parses exactly two keys — `audioFlush`
(bool) and `offset` (int64) — and hands them to `player->flush(int, long long)`
at vtable +0xa8, which is `CustomPipeline::flush(int, long long)`. **That
overload pushes a real FLUSH_START/FLUSH_STOP pair to both appsrcs**; the
no-argument `flush()` is a degenerate `gst_element_seek` to
`GST_CLOCK_TIME_NONE` that sends neither, so the sink stays anchored to the
pre-seek segment and eventually stops draining. Anyone who concluded that
in-place seek is impossible here was calling the wrong overload.

```
Pause()
flush({"audioFlush":true,"offset":<pos>})
setTimeToDecode({"position":<pos>})     -- refused unless paused
av_seek_frame + refeed from the keyframe
Play()                                  -- event 25 confirms
```

Units are assumed to be milliseconds, matching `Seek(const char *millis)`.
Nothing in `flush` says so; the unit is decided downstream in
`CustomPipeline::flush`.

The disassembly also confirms the header's layout: `flush` reaches the player
through `[this, #0x4c]`, which is `char unknown[76]` followed by the public
`boost::shared_ptr<mediapipeline::Player> player`. No private offsets needed.

## What else is reachable

- **`NDL_MediaLoad`** takes a URI (`file://`, and the strings in
  `libNDL_media_impl` show http/uri handling) with seeking, playback rate,
  subtitles and track selection — the better fit for playing a *container*
  rather than an elementary stream, since it demuxes for you.
- **`NDL_VT_*`** puts decoded video into a GL texture, so a GL app can
  composite video into a 3D scene rather than punching it through. It reports
  `NDL_VT_GetMaxTextureResolution` and `NDL_VT_GetRequireGlEsVersion`.
- Below all of it is **uMediaServer** (`libumedia_api.so.1`), which both NDL
  libraries link. `StarfishMediaAPIs` is the same pipeline with a different
  face, and takes the same exported window id.
