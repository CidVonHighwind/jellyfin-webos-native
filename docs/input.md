# Input

## Devices on the TV

`/dev/input/event0`–`event31`, all `0660 root:composit`, plus `js0`–`js5`
(`0664 root:input`). Named devices:

```
event0   LGE RCU                      standard IR remote
event1   CHECK INPUT
event2   LGE M-RCU - Builtin [0]       Magic Remote
event3   LGE M-RCU - Builtin [1]
event4   LGE M-RCU - Builtin [2]
event5   LGE TONE+ - Builtin [3]       Bluetooth audio
event6   LGE Simple Premium
event7   Bluetooth-audio-source
event8   ClickableMouse                <-- pointer device
event9   Smart Remote RCU Input
event10  LGE Network Input             <-- network-injected input
event11  LGE Smart Remote - TouchPad   <-- Magic Remote pointer
event12  IoT keypad
```

Two are interesting: **`ClickableMouse`** proves LSM already consumes a
relative-pointer evdev device, and **`LGE Network Input`** shows LG themselves
inject input over the network.

`/dev/uinput` exists (`0600 root`, `uinput` misc device registered), so we can
**create our own input device** and have the whole webOS stack — LSM, the TV UI,
and any app — treat it as real hardware.

## Options for an application

Roughly in order of how much the system does for you:

1. **Wayland `wl_seat`** (3 seats advertised). Normal keyboard/pointer/touch
   events delivered to your focused surface. This is what an app should use for
   its own input. Requires no privilege.
2. **`wl_webos_input_manager` / `wl_webos_xinput_extension` / `wl_starfish_pointer`**
   — webOS extensions for cursor visibility and remote-specific behaviour.
   Needed for Magic Remote pointer semantics. **Protocol details unverified.**
3. **Read `/dev/input/event*` directly** — group `composit`, so root or group
   membership. Bypasses focus entirely; you see everything. Useful for a
   background service, rude for an app.
4. **`/dev/uinput` injection** — synthesise input system-wide. Root only. This is
   the basis of the cursor-forwarding plan below.
5. **`libStarfishInput.so.0`** — LG's own input abstraction. **Unverified.**

## Forwarding the PC cursor — dropped

A plan to inject the PC's mouse into the TV via `/dev/uinput` was sketched and
then **dropped at the user's request**: development happens on the PC and the
cursor is not wanted on the TV. Recorded only so it is not re-proposed.

If it is ever revived, the one non-obvious detail: `struct input_event` is
**24 bytes on x86-64 but 16 on the 32-bit TV** (`timeval` differs), so a
forwarder must translate rather than pipe raw bytes.

## Measured: what `wl_seat` actually delivers

`inputlog` (`zig build run -Dapp=inputlog`) draws every event it receives and
prints the same lines to the terminal. Findings on this device:

- **Three seats are advertised and all three are live.** They are not labelled,
  so the app binds every one and tags events with the seat index. On the test
  set, remote key presses arrive on **seat 1**; seats 0 and 2 mirror the
  modifier traffic. Bind all of them — picking "the" seat loses input.
- **A `modifiers` event is sent on all three seats for every key**, essentially
  always all-zero. `inputlog` suppresses unchanged ones or the log is unreadable.
- Key codes are plain **evdev keycodes** (`KEY_LEFT` = 105, `KEY_UP` = 103,
  `KEY_ENTER` = 28, …) delivered by `wl_keyboard.key`. No xkb is needed to map
  the remote: read the number, name it.
- Seats are bound at **version 1** deliberately, so only the original event set
  can arrive and the listener tables stay small.

To map a button: run `inputlog`, press it, read the code off the screen, and add
it to `key_names` in `src/inputlog.zig`.

## The shim

`src/wl.zig` is the shared Wayland layer: connect, bind globals, create one
window with one `wl_shm` buffer, and deliver input as a tagged union. It chooses
`wl_webos_shell` on the TV and `xdg_wm_base` on a desktop, so the same source
runs in both places (`zig build run` vs `zig build run-host`).

xdg-shell is the one place where wire order is taken on trust: unlike every
other protocol here it lives in generated code rather than a shared library, so
its three interfaces are spelled out in `wl.zig`. Everything else looks its
opcodes up by name in the `wl_interface` tables libwayland already carries.

Two details worth keeping:

- `wl_registry.bind` is signature `usun` — the new_id placeholder comes **last**,
  unlike every other request, where it comes first. Getting this wrong segfaults
  inside libffi with no useful message.
- `wl_pointer`/`wl_keyboard`/`wl_touch` listener structs must have as many
  entries as the *library's* interface declares events, not as many as the bound
  version can send; libwayland indexes the struct by event opcode.
