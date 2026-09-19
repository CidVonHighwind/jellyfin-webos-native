# Jellyfin client

`src/jellyfin.zig` is a real client for a Jellyfin server: UDP discovery,
sign-in (password or Quick Connect), a stored token, home rows, a virtual
library grid, and the path down to a single episode. It reuses `uidemo`'s
renderer unchanged — one instanced batch, rasterised glyphs, the same remote
and pointer handling.

Verified against **Jellyfin 10.11.8**, and on the TV at 1920x1080.

## Shape

```
src/jellyfin.zig          screens, navigation, poster cache
src/jellyfin/api.zig      endpoints, JSON, credentials, the worker pool
src/jellyfin/image.zig    PNG decode through the TV's libpng
src/jellyfin/store.zig    where files go on disk, and the artwork cache
```

Requests never touch the render thread. `api.Fetcher` owns a fixed pool of 32
task slots and four worker threads; the UI submits a task, polls it once a
frame, copies what it needs into fixed-size screen state and hands the slot
back. A task's results live in that task's arena, so "copy what you need" is
the rule that keeps a draw command from holding a pointer into memory a worker
is about to reuse.

Two bugs that cost time and are easy to reintroduce:

- A draw command holds a **slice**, not a string. Passing a card *by value* to a
  draw function makes its text point into that function's stack frame, which is
  gone by the time the renderer runs. Cards are passed by pointer for that
  reason, and the pointer must be to storage that outlives the frame.
- `fetcher.pending()` counts tasks that are **finished but not yet consumed**,
  not just in-flight ones. "Nothing in flight" is not "the screen is up to
  date": there is a frame between a worker finishing and the UI draining it.

## Navigation is a stack, not a rule

Back pops a stack of entries (`Entry` in `jellyfin.zig`). The rule-based version
— "from details, go back to the grid if a grid is loaded" — is wrong in the
ordinary case: reaching a show from a *home row* and pressing Back returned to
whichever library grid happened to still be loaded, so
`home → shows → korra → back` landed in `shows`.

An entry stores enough to **re-enter** a screen, not a snapshot of it.
Re-entering refetches, which is also what keeps a details screen current.

## Storage

Two roots, chosen without any environment, because SAM provides none:

| | |
|---|---|
| installed | the app's own directory, `<appdir>/conf/` and `<appdir>/cache/` |
| development | `/tmp/jellyfin-native/{conf,cache}` |
| override | `$JELLYFIN_STORE` |

An installed app runs with its own directory as the working directory, so
`/proc/self/cwd` answers both "where do I write" and "am I installed" -- the
same trick `ndlplay` uses to find its app id. The marker is the path containing
`/usr/palm/applications/`, since a developer-mode install lives under
`/media/developer/apps` and a retail one under `/media/cryptofs/apps`.

Writing into the app's own directory is what the native apps on this TV do:

```
com.limelight.webos/conf/{moonlight.ini,hosts.ini,key/key.pem}
com.limelight.webos/cache/<uuid>_<id>          (box art)
org.mariotaku.ihsplay/.cache/fontconfig/...
```

### The permission that makes it work

**An installed app cannot write to its own directory unless the package ships
it world-writable.** The app runs as a jail uid (6350 here) that owns none of
its files, which are installed owned by uid 1000. Both reference apps ship
`777`; a package built with a default `mkdir` gets `755` and every write fails
silently.

`ipk_script` in `build.zig` therefore ships `conf/` and `cache/` at `777`. The
proof that this is the real mechanism is the ownership of what gets written:

```
drwxrwxrwx 1000:1000  cache/
-rw-r--r-- 6350:5000  cache/<item>-<tag>-240x360.img     <- written by the jail uid
```

`store.init` also probes writability and falls back to `/tmp` with a log line
rather than failing every write silently, which is what an older package
installed before this change would otherwise do.

Because SAM gives no terminal either, stderr is redirected to
`<root>/conf/jellyfin.log` (`/tmp/jellyfin.log` if even that is not writable).
Without it an installed app is undebuggable.

## Credentials

Five lines -- server, token, user id, user name, password -- written `0600`.

**The password is stored, not just the token.** Jellyfin invalidates a device's
previous token whenever that device signs in again, so a token-only store goes
stale on its own and strands the user at a sign-in screen with a remote in
their hand. On a 401 the client re-authenticates in the background, saves the
new token and reloads the screen that failed; the user sees a status line, not
a login form. Two consecutive failures stop the retry and sign out properly.

That does mean a plaintext password on disk in a world-writable directory. The
file mode is what protects it, and root on this TV can read it regardless.
Quick Connect stores no password and simply signs out when its token dies.

Only a **401/403** triggers any of this. An earlier version signed out on any
non-200, so a restarting server cost you a password typed on a remote.

A file written by a root development run over SSH is `0600 root`, which the
jailed app cannot read. That is a development artefact, not a bug: the app
writes it as its own uid in normal use.

## Artwork cache

Keyed `<item>-<tag>-<width>x<height>.img` under `cache/`, holding the encoded
PNG as received.

The tag is Jellyfin's own image tag, which is **a hash of the image content**,
so a changed image is a different filename and a stale one can never be served.
That is what makes the cache need no revalidation request at all: a hit costs
no network. Episodes carry `SeriesPrimaryImageTag`, which is exactly the tag
for the series poster the episode falls back to.

What the server actually offers, measured:

| | |
|---|---|
| `ETag` on images | **absent**; `If-None-Match` is ignored and returns 200 with the full body |
| `If-Modified-Since` | **honoured**, returns 304 with 0 bytes |
| `tag=` in the URL | accepted but *not* validated -- a wrong tag still serves the image |

So `tag=` is purely a cache-busting URL component, which is how Jellyfin's own
clients use it, and this client sends it for the same reason: it makes the URL
change when the image does. An image with no tag is simply not cached;
`If-Modified-Since` is the documented fallback if that ever needs to change.

Writes go through a temporary plus rename, because four workers share the
directory and a half-written file must never be readable as a whole one. The
cache is swept back under 48 MB at startup, oldest first -- a disposable cache
does not justify an index to keep consistent across four writer threads.

In memory, on top of that, sits an LRU of 48 GL textures keyed by item **and**
tag, so re-tagged artwork is not served from the old texture for the rest of a
session.

## Artwork: why `libpng`, and why not the JPEG

Both libraries are on the TV:

```
/usr/lib/libjpeg.so.62   -> libjpeg.so.62.3.0
/usr/lib/libpng16.so.16  -> libpng16.so.16.39.0
/usr/lib/libwebp.so.7    /usr/lib/liblxjpeg.so.2    /lib/libz.so.1
```

The client `dlopen`s `libpng16.so.16` like every other device library here, and
asks Jellyfin for `format=Png`. **JPEG was rejected on ABI grounds, not
preference:** the TV ships `libjpeg.so.62` and a current development machine
ships `libjpeg.so.8`. Those are different ABIs behind the same name, and
libjpeg's entry points take a `struct jpeg_decompress_struct` whose layout *is*
the ABI — so a `dlopen`'d JPEG path needs one transcribed struct per version
and is silently wrong on whichever machine it was not written for.
`libpng16.so.16` is on both (1.6.39 on the TV, 1.6.58 here).

Within libpng, this uses the **simplified API** (`png_image_begin_read_from_memory`
/ `png_image_finish_read`), which is why the binding is about forty lines:

- `png_image` is a small struct with an explicit `version` field, which the
  library checks — so it is safe to declare without libpng's headers.
- It does not use `setjmp`. The classic `png_create_read_struct` path signals
  errors by longjmp'ing out of the error callback, and a callback that returns
  instead makes libpng call `abort()`. Zig has no `setjmp`, so that path is not
  available at all.

### `fillWidth`/`fillHeight` is a hint, not a contract

The same request comes back at different sizes depending on the source art:

```
fillWidth=200&fillHeight=300  ->  200x300, 204x300, 212x300, 200x301, 534x300
```

That killed the first design, which packed posters into one atlas of fixed
tiles: an image wider than its tile overwrites its neighbours. **Posters get one
texture each.** The cost is a draw call per distinct texture on screen, which is
what the batcher already does for a binding change; the alternative is cropping
every image to a tile and re-uploading over tiles a scrolling grid may still be
drawing from. The cache is 48 textures, evicted least-recently-drawn, and
`coverUv` crops the long axis so a 534x300 library banner and a 200x300 poster
look right in the same card.

## Playback: resolved, not decoded

The details and episode screens resolve

```
{server}/Videos/{id}/stream?static=true&api_key={token}
```

and show it. Nothing decodes it yet — that is the NDL work below.

## Audio, for later

Noted now because the decision belongs with the video work, not after it.

**What the library actually contains** (600 items sampled of 3026, movies and
episodes):

| | |
|---|---|
| containers | `mkv` 98%, `mp4`, `mpeg` |
| video | `hevc` 339, `h264` 154, `av1` 103, `mpeg2video` 4 |
| audio | `aac` 292, `eac3` 249, `flac` 168, `opus` 141, `ac3` 103, `dts` 32, `truehd` 14, `mp2` 4 |
| channels | 2ch 621, 6ch 361, 8ch 15 |

**What the TV decodes in hardware** — full table in [codecs.md](codecs.md):
AAC 6ch, EAC3 **8ch**, AC3 6ch, DTS/DTS-HD/DTS Express 6ch, FLAC 6ch, OPUS 6ch,
MP1/2/3 2ch, PCM 2ch.

Lining those up:

- Every codec in this library is decodable **except `truehd`** (14 items), which
  appears nowhere in the LG capability table. Those need transcoding or a
  fallback to the file's second audio track — most TrueHD tracks ship with an
  AC3/EAC3 companion.
- The 8-channel tracks (15 items) are only in range if they are EAC3; 8ch AAC or
  FLAC exceeds the 6ch hardware limit and needs a downmix.
- `mp2` only exists in the four `mpeg` files, alongside `mpeg2video` — the one
  combination worth just transcoding rather than supporting.

**What the decode path needs.** `NDL_directmedia` takes **elementary streams**,
not containers, so 98% of this library being Matroska means a demuxer either
way — the container carries the audio/video split, the codec ids and the
timestamps that `NDL_DirectAudioPlay`'s `pts` argument wants.

`NDL_DIRECTMEDIA_DATA_INFO_T` is `{ int width, height; VideoType type; int
unknown1; }` followed by a **32-byte audio union that this client currently
zeroes**, which the implementation accepts as "no audio" (see [ndl.md](ndl.md)).
The layout of that union is *not* documented here and is the first thing to work
out. The audio side is then a second push API —
`NDL_DirectAudioPlay(buffer, size, pts)` with
`NDL_DirectAudioGetAvailableBufferSize` for flow control, and
`NDL_DirectAudioSupportMultiChannel` for the 6ch and 8ch tracks above.

Note also that `NDL_directmedia` itself only references **H264, H265, OPUS,
PCM** internally ([multimedia.md](multimedia.md)). If that is a real limit
rather than an artefact of the symbol scan, then AAC and EAC3 — 541 of the 600
sampled tracks — do not go through `NDL_directmedia` at all, and the audio path
is `NDL_media` or GStreamer instead. **Unverified; test before designing around
either answer.**

## Testing without a remote in your hand

There is no way to click through this app headlessly, so it replays one:

```sh
set -a; . ./.env; set +a
UI_SCRIPT=oddo UI_CAPTURE=/tmp/home.ppm zig build run-host -Dapp=jellyfin
```

`UI_SCRIPT` letters are `u`/`d`/`l`/`r` for the arrows, `o` for OK, `b` for
Back, `.` to wait a beat. A press is held until nothing is outstanding in the
fetcher, so a script does not race a request. `UI_CAPTURE` saves the screen it
ends on — this application's own OpenGL backbuffer, the same path as `uidemo`'s
F12 — and exits.

The same works on the TV, which is how the grid above was confirmed on device:

```sh
ssh $T "cd /tmp && XDG_RUNTIME_DIR=/tmp/xdg WAYLAND_DISPLAY=wayland-0 \
  JELLYFIN_USER=... JELLYFIN_PASSWORD=... UI_SCRIPT=oddoddrro \
  UI_CAPTURE=/tmp/jf.ppm /tmp/jellyfin"
```

`JELLYFIN_ADDRESS`, `JELLYFIN_USER` and `JELLYFIN_PASSWORD` prefill the sign-in
fields when no token is stored; they are ignored once one is.

To exercise the *installed* path, run the installed binary from its own
directory -- that is what makes `/proc/self/cwd` say "installed":

```sh
ssh $T "cd /media/developer/apps/usr/palm/applications/dev.hookedbehemoth.jellyfin \
  && XDG_RUNTIME_DIR=/tmp/xdg WAYLAND_DISPLAY=wayland-0 ./jellyfin"
```

With no tty its output goes to `conf/jellyfin.log`, not the terminal.

The endpoint layer has its own live test, skipped unless the environment names
a server:

```sh
set -a; . ./.env; set +a; zig test -lc src/jellyfin/api.zig
```

## Credentials

Four lines — server, token, user id, user name — written `0600` to
`$JELLYFIN_STORE`, else `$HOME/.jellyfin-native`. The **password is never
stored**; the access token is. The device id is derived from the hostname so the
server's device list does not grow an entry per launch and Quick Connect
approvals stick.

Only a **401/403** clears them. An earlier version signed out on any non-200,
which meant a restarting server or a dropped Wi-Fi association cost you a
password typed back in on a TV remote.
