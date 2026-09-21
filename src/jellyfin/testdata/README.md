`opus-preskip.mka` is a 60 ms synthetic sine wave with Opus encoder pre-skip.
Its first packet starts at -7 ms in Matroska's timebase; after decoding and
removing 312 padding samples, its first audible sample starts at 0 ms.

Generated with:

```sh
ffmpeg -f lavfi -i sine=frequency=1000:sample_rate=48000:duration=0.06 \
  -c:a libopus opus-preskip.mka
```
