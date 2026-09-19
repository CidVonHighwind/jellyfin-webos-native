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
