# WireGuard tests

Tests for the [WireGuard app](../../apps/wireguard/README.md) with a real tunnel: three containers stand in for the NAS *(the PHP test image with legacy iptables, as WD's NAS has, and BusyBox's `ip`)*, a phone on "the internet", and a device on the home network behind the NAS:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh wireguard    # first: the app's binaries and its package
tests/wireguard/run_tests.sh                         # everything, on PHP 7.4 - WD's version
tests/wireguard/run_tests.sh app --php 8.5           # the tunnel and the page, on PHP 8.5 (the PHP app's)
```

| Group | What it checks |
|---|---|
| `app` | The interface started by wireguard-go; the management page's API *(refused without a NAS admin's login or with a wrong CSRF token; no devices before their address is set; a low port, a range overlapping the home network, a bad address or DNS server refused)*; a device added: its configuration *(address, the NAS, routes, DNS, preshared key)* and QR code; the phone, brought up from that configuration, reaching the NAS *(in the VPN and at its home address)* and a device at home *(which sees the NAS's address)*; the page seeing it connected; the NAS only *(the home network unreachable)*; everything *(all traffic, IPv6 included, forwarding on)*; switching a device off *(cut off at once)* and on *(reconnects by itself)*; a new address range *(devices move with it)*; removing a device; stopping *(the interface, its iptables rules and forwarding all undone)* |
| `package` | The built package's life as WD's installer runs it *(BusyBox `sh`)*: install, initialise and start *(wg0 up)*, its data's permissions, the update check and `wg` command, the page, then removal - keeping its keys |

## How it works

- The containers are privileged *(only then can they change IP forwarding)*, on two Docker networks: `192.168.77.0/24` *(home: the NAS and a device that answers with the address it sees requests come from)* and `172.31.77.0/24` *(the internet: the NAS and the phone)*.
- The phone runs the app's own wireguard-go and `wg` with the configuration the page gives it *(as the WireGuard app would)*.
- Not covered here *(tested on the NAS)*: WD's 4.14 kernel and its modules *(tun, NAT)*, port forwarding on a real router, and the WireGuard apps on real phones.

Needs Docker and Python 3. Work files go in `$WG_TEST_WORK`, by default `/tmp/wireguard-tests`; `WG_TEST_KEEP=1` leaves the containers running to look into a failure.
