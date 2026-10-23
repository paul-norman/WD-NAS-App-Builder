# WireGuard App

[WireGuard](https://www.wireguard.com/) is a fast, modern VPN: phones and laptops connect to the NAS from anywhere, and reach the NAS - and, if you choose, the rest of your home network or the internet through your home connection - as if they were at home. It runs natively on the NAS *(no Docker)*.

- **wireguard-go**: WD's 4.14 kernel predates WireGuard in the kernel *(5.6)*, so the app runs WireGuard's official userspace implementation. It needs only the kernel's TUN device *(WD ships it as a module, which the app loads - as the Tailscale app does)*. It's slower than the kernel's WireGuard, but well beyond a home internet connection's upload speed.
- **Devices** are added on the management page, each with its own keys *(and a preshared key)* and address: the page shows its configuration as a QR code *(for the WireGuard app on a phone: Add a tunnel → Scan from QR code)* and as a file to download *(for a laptop's WireGuard app)*. Devices can be switched off or removed, which cuts them off straight away. The page shows when each last connected, from where, and how much it sent and received.
- **What devices can reach**: the NAS only; the NAS and the home network *(the default)*; or everything - all their internet traffic goes through home *(e.g. on public Wi-Fi; IPv6 too, so nothing goes around the VPN)*. The home network sees the NAS's address *(the app masquerades the devices' traffic)*, so nothing needs a route back. Devices use the NAS's own DNS server by default *(e.g. your router or Pi-hole)*.
- **Your router** must pass the UDP port *(51820 by default)* on to the NAS, and devices need your home's address on the internet: a domain name that points to it *(e.g. your router's dynamic DNS)* or its IP address - set on the management page before adding devices.
- **On the NAS**, it runs as root *(making network interfaces and routing needs it)*. WireGuard doesn't answer anything without a device's key, so the open port reveals nothing. Its routing rules are in their own iptables chains *(`WIREGUARD`, in the filter and nat tables)*, removed when it stops, and IP forwarding is turned back off then unless Docker *(which needs it)* is running. The address range *(10.8.0.0/24 by default)* can be changed if it clashes with another network.
- The `wg` command is linked into the NAS's path *(e.g. `wg show` over SSH)*.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_wireguard` *(root only)*, and survives reinstalls and removal: the NAS's private key, the settings and each device's keys *(so its configuration can be shown again)*, and `wireguard.log` *(errors only)*.
- Built from source, fully static: wireguard-go, `wg` *(wireguard-tools)* and `qrencode` *(for the QR codes)*. The NAS shows an alert when a new wireguard-go release is out, checked weekly.

## Management page

WireGuard's page in the NAS dashboard *(Apps → WireGuard)* shows whether it's running, its version, the address devices connect to and the NAS's addresses in the VPN; adds devices *(showing their QR code and configuration)*, shows their configuration again, switches them off or on, removes them, and shows each one's last connection; sets the address and port devices connect to, what they can reach, their DNS servers and the address range *(checked not to overlap the home network)*; restarts WireGuard; and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the WireGuard app

From the project root directory:

```bash
./build.sh wireguard
```

This first runs `static/wireguard` *(once per version)*, which builds wireguard-go, `wg` and `qrencode` from their source. The WD bin files will be created in `packages/wireguard/`. To update, change the version in `apkg.rc` and `static/wireguard/build.sh` *(with the new source's checksum)*. Tests: [`tests/wireguard`](../../tests/wireguard/README.md).

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
