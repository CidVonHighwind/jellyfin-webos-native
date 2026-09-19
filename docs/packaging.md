# Packaging and installing

For day-to-day development you do **not** need any of this — `zig build run`
pushes a binary to `/tmp` and executes it, and LSM renders it fullscreen
(see [display.md](display.md)). Packaging matters when you want the app to
appear in the TV's own app list and survive reboots.

## The rule that actually blocks installs

```
"reason": "Cannnot install privileged app on developer mode"
```
*(LG's typo, not ours.)*

**`com.webos.*` is a reserved system namespace.** Developer-mode installs of an
app whose id starts with it are rejected outright, no matter how correct the
package is. The failure surfaces only as `"errorCode": -15` with
`"state": "install failed"` — the useful `reason` field is easy to miss because
it appears in a later subscription message than the error itself.

Use your own namespace. What the community ships:

```
org.webosbrew.hbchannel     org.mariotaku.ihsplay     com.limelight.webos
org.jellyfin.webos          org.webosbrew.inputhook   twitch.adamffdev.v1
```

`com.` is fine; it is specifically `com.webos.*` (and by extension the other LG
system prefixes) that is privileged. This repo uses `dev.hookedbehemoth.wlbox`.

> **Always read the `reason` field.** `errorCode: -15` is a generic
> "install failed" and tells you nothing on its own. `zig build install-app`
> prints `state` and `reason` for this purpose.

## .ipk format

An .ipk is an `ar` archive of exactly three members, in order:

```
debian-binary      contains "2.0\n"
control.tar.gz     contains  control
data.tar.gz        contains  usr/palm/applications/<id>/...
```

Our builder (`ipk_script` in `build.zig`) writes the `ar` header by hand rather
than calling `ar`, matching a real webosbrew .ipk byte-for-byte in structure:

| detail | reference (`org.webosbrew.hbchannel_0.7.3_all.ipk`) | GNU `ar` default |
|---|---|---|
| ar member names | `debian-binary` | `debian-binary/` (trailing slash) |
| ar mode field | `100644` | `644` |
| data.tar.gz paths | `usr/palm/...` | `./usr/palm/...` if you tar `.` |
| control.tar.gz path | `control` | `./control` |

> **Honest caveat:** these format differences were found by diffing against the
> reference *while* the privileged-namespace problem was still in play. Once the
> id was fixed the install succeeded immediately, and a follow-up attempt to
> prove whether the GNU-`ar` layout *also* works was inconclusive (the install
> service stopped answering repeat subscriptions for an already-installed id).
> So it is **not confirmed** that the `ar`/tar changes were required. They match
> known-good output, which is why they were kept.

The control file follows the reference exactly:

```
Package: <id>
Version: <version>
Section: misc
Priority: optional
Architecture: arm
Installed-Size: <KiB>
Maintainer: N/A <nobody@example.com>
Description: This is a webOS application.
webOS-Package-Format-Version: 2
webOS-Packager-Version: x.y.x
```

## appinfo.json for a native app

Minimum that works, cross-checked against installed native apps
(`org.mariotaku.ihsplay`, `com.limelight.webos`):

```json
{
  "id": "dev.hookedbehemoth.wlbox",
  "version": "0.0.1",
  "type": "native",
  "main": "wlbox",
  "title": "wlbox",
  "icon": "icon.png",
  "vendor": "webos-native"
}
```

`icon.png` must actually exist in the package. `main` is the binary path
relative to the app directory (Moonlight uses `bin/moonlight`, so subdirectories
are fine). `build.zig` rewrites `main` to match `-Dapp`, so one `appinfo.json`
serves every app in the repo.

## Commands

```sh
zig build package -Dapp=wlbox       # -> zig-out/<id>_<version>_arm.ipk
zig build install-app -Dapp=wlbox   # package, scp, install, print state+reason
zig build launch                    # start it through SAM
```

Install goes through
`luna://com.webos.appInstallService/dev/install` with
`{"id":…,"ipkUrl":…,"subscribe":true}`. **Subscribe** — without it you get an
immediate `returnValue: true` and never learn whether the install succeeded.

Installed apps land in `/media/developer/apps/usr/palm/applications/<id>/`,
owned by uid 1000, and appear in
`luna://com.webos.applicationManager/listApps`.

Launch with `luna://com.webos.applicationManager/launch {"id":…}`.

## Removing

```sh
luna-send -n 1 -f luna://com.webos.appInstallService/dev/remove '{"id":"<id>"}'
```
**Untested.**
