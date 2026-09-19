# Codec support

Three sources agree on the broad picture but answer different questions:

| source | what it tells you | trust |
|---|---|---|
| `/etc/umediaserver/device_codec_capability_config.json` | **hardware limits** per codec (resolution, fps, bitrate, channels) | authoritative |
| `gst-inspect-1.0` element caps | what is *plumbed* in GStreamer | advertised, not guaranteed |
| `libNDL_*` strings | what each native API path accepts | indicative |

Raw copies: [device-codec-capability.json](device-codec-capability.json) and
[gstreamer-codec-elements.txt](gstreamer-codec-elements.txt) (219 codec elements).

---

## Video — hardware decode limits

From the device capability config. `bitrate` is Mbit/s.

### 4K-class

| codec | max res | max fps | max bitrate |
|---|---|---|---|
| **H.265** | 4096x2304 | **120** | 50 |
| **H.264** | 4096x2304 | 60 | 50 |
| **VP9** | 4096x2304 | 60 | 50 |
| **AV1** | 4096x2304 | 60 | **60** |
| **H.266 / VVC** | 4096x2304 | 60 | **60** |
| HEVC *(separate entry)* | 4096x2176 | 60 | 50 |

AV1 **and** H.266/VVC in hardware is unusually modern — worth designing around.

### 1080p-class (all 1920x1088, 30 fps, 40 Mbit/s)

```
MPEG1  MPEG2  MPEG4  MP4S  MPS2  MP43
DivX   XviD   H.263  WMV   MJPEG
VP8    AVS    RV30   RV40  (RealVideo)
```

Note **VP8 is 1080p30 only**, while VP9 is 4K60 — do not assume the VP8 path
scales.

### Multiview restriction

H.264, H.265, HEVC, VP9 and AV1 each carry a `multiview_sub` restriction:
when used as the secondary stream in multiview, they drop to
**1920x1088 @ 30 fps**. Relevant only if you use PiP/multiview.

---

## Audio — hardware decode

Name and max channels:

| codec | ch | | codec | ch |
|---|---|---|---|---|
| AAC | 6 | | DTS | 6 |
| MPEG (MP1/2/3) | 2 | | DTSH (DTS-HD) | 6 |
| AC3 | 6 | | DTSE (DTS Express) | 6 |
| EAC3 | **8** | | DRA | 6 |
| WMA | 6 | | Vorbis | 6 |
| WMAP (WMA Pro) | **8** | | FLAC | 6 |
| WMAL (WMA Lossless) | **8** | | OPUS | 6 |
| PCM / LPCM | 2 | | RA6 / RA8 (RealAudio) | 2 / 6 |
| AMR | 1 | | | |

### Discrepancy worth knowing

GStreamer ships `ac4_audiodec` (Dolby AC-4) and `mpegh_audiodec` (MPEG-H 3D
Audio), and `decproxy` advertises `audio/x-ac4` and `audio/mpeg-h` — but
**neither appears in the device capability config**. Most likely those paths are
reserved for broadcast/ATSC 3.0 rather than app playback. **Treat AC-4 and
MPEG-H as unavailable to an app until proven otherwise.**

Also present in GStreamer but *not* in the hardware config, so presumably
software-only: ALAC, WavPack, Speex, ADPCM, A-law/µ-law, MIDI.

---

## Which API to use

### `NDL_directmedia` — low-latency, narrow

Codec strings found in the library: **H264, H265, OPUS, PCM** only.

This is the game-streaming / low-latency path: you push compressed frames
yourself with `NDL_DirectVideoPlay` / `NDL_DirectAudioPlay`. Right choice for
remote play or a custom streaming client; wrong choice for general playback.

### `NDL_media` — full playback

```
NDL_MediaLoad / NDL_MediaLoadWithOption / NDL_MediaPreload
NDL_MediaPlay / Pause / SeekTo / SetPlaybackRate / GetCurrentPosition
NDL_MediaSelectTrack / NDL_MediaSetDisplayWindow / NDL_MediaMuteDisplay
NDL_MediaSetSubtitle{Source,Enable,Color,FontSize,Position,Sync,Encoding}
NDL_MediaDRM{Init,Load,SendMessage,SendMessageAsync,Unload,IsLoaded,GetError}
NDL_MediaSubscribeEvents
```

URI-based playback with track selection, subtitles and DRM. **This is the one to
use for wide format support** — it sits on umediaserver and therefore gets the
full codec table above, container demuxing and adaptive streaming for free.

### GStreamer — maximum control

`decproxy` is the hardware decode entry point; `lxvideodec` / `omx_lxvideodec`
are the LG hardware decoders (they advertise the full list including AV1, AVS2,
H.266); `lxmjpegdec` for MJPEG; `lxvideoenc` / `v4l2h264enc` / `v4l2vp8enc` for
encode. Software fallbacks exist via libav (`avdec_h264`, `avdec_vp8`,
`avdec_vp9`, `avdec_mjpeg`, and most audio codecs).

There is also a standard **`v4l2h264dec`** stateful V4L2 decoder, which is the
most portable route if you want to avoid LG-specific elements.

---

## Containers and streaming

Demuxers available:

```
MP4 / MOV / 3GP  qtdemux, dvrqtdemux      Matroska / WebM  matroskademux
MPEG-TS          tsdemux, dvrtsdemux      MPEG-PS          mpegpsdemux
AVI              avidemux                 ASF / WMV        asfdemux
FLV              flvdemux                 Ogg              oggdemux
WAV / RF64       wavparse                 AIFF             aiffparse
MXF              mxfdemux                 MIDI             midiparse
IVF              ivfparse                 AU               auparse
```

Adaptive streaming: **DASH** (`dashdemux`, `dashdemux2`), **HLS** (`hlsdemux`,
`hlsdemux2`), **Smooth Streaming** (`mssdemux`), plus `sdpdemux` for RTSP/SDP.

DRM plugins present: PlayReady (`cencdrmplayready`), Widevine-style CENC
(`adaptivedecryptor`, `ckdrm`), `uhdcp`, DTCP-IP.

Subtitles: SSA/ASS, DVB and DVD subpictures, XSUB, teletext, WebVTT, SRT.

---

## Encode

Much narrower than decode:

| | |
|---|---|
| Video | `lxvideoenc` (LG HW), `v4l2h264enc` (H.264 HW), `v4l2vp8enc` (VP8 HW) |
| Audio | FLAC, Vorbis, Speex, WavPack, A-law, µ-law, AC3/EAC3 (`avenc_*`) |

`/dev/venc` is group `composit`, unlike `/dev/vdec` which is world-accessible —
so encoding may need privileges that decoding does not.

---

## Caveats

- The capability config is the **decoder** table; it does not promise every codec
  is reachable through every API.
- GStreamer element caps are what the element *advertises*. `lxvideodec` lists
  AVS2 and `video/x-fd`, which do not appear in the capability config.
- Concurrent decode sessions are limited by
  `/etc/umediaserver/umediaserver_resource_config.txt` — **not examined.**
- The runtime authority is `luna://com.webos.media/getCapability`, which could
  not be called from an SSH session (see [device.md](device.md) — `luna-send` is
  mute there). Everything above is from on-device config and binaries.
