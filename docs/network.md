# Network

## Interfaces

```
wlan0   10.10.8.63/24    UP    connected, 5 GHz
eth0    169.254.120.76/16  UP  link-local only -- cable present, no DHCP lease
p2p0    (Wi-Fi Direct)   NO-CARRIER
lo      127.0.0.1/8
```

The TV is reachable over **Wi-Fi**; `eth0` has only a link-local address, so
either nothing is plugged in or there is no DHCP on that segment. `eth0` reports
`speed = 100` (100 Mbit PHY), so wired would cap at 100 Mbit — **slower than the
current Wi-Fi link** if you were considering switching for throughput.

Wi-Fi link quality at time of survey:

```
SSID "Mount Doom"  BSSID 24:4b:fe:27:61:94
freq 5220 MHz (5 GHz)   signal -59 dBm   tx bitrate 780.0 MBit/s
```

-59 dBm is a solid link; 780 Mbit/s PHY rate suggests Wi-Fi 6 / 80–160 MHz.
Expect real TCP throughput well above the 100 Mbit the Ethernet port could give.

## Listening services

```
0.0.0.0:22      SSH (our access path)
0.0.0.0:1418    0.0.0.0:1551    0.0.0.0:1624    0.0.0.0:1792
0.0.0.0:1852    0.0.0.0:1866    0.0.0.0:9998    0.0.0.0:18888
:::3000  :::3001  :::8443  :::18181            (IPv6)
:::8008  :::8009                                (Chromecast/DIAL)
:::7000                                         (AirPlay)
127.0.0.1:53                                    (local DNS)
```

Also listening on Unix sockets: `/var/run/unified_service_server`,
`/tmp/airplay/AirPlayController`, `@/var/run/mDNSResponder-lpm`.

Port **9998** is the webOS SSAP websocket (the usual remote-control API), and
`3000`/`3001` are the developer-mode/inspector ports. AirPlay (7000) and
Chromecast/DIAL (8008/8009) are live.

**Pick a high port well away from these for your own services.** Nothing is
listening on 9999, which is what the input-forwarding plan uses.

## Tools on device

`curl`, `wget`, `nc` are present. **No** `socat`, `iperf`, `iperf3`, `tcpdump`.

`nc` is significant: it means one direction of a forwarding pipe needs no code
on the device at all.

## Notes

- There is no firewall rule blocking new listeners observed, but this was not
  explicitly tested. **Unverified.**
- Throughput was not benchmarked (no `iperf` on device). If it matters, push a
  static `iperf3` — it cross-compiles for `arm-linux-gnueabi` the same way our
  apps do.
