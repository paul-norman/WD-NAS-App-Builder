# Tailscale App

[Tailscale](https://tailscale.com/) connects the NAS to your private Tailscale network *(tailnet)* over WireGuard, so you can reach it securely from anywhere, without opening any ports on your router.

## Setting up

Open Tailscale's page in the NAS dashboard *(Apps → Tailscale)*, click **Log in**, then open the link it shows and sign in. The page also shows the NAS's Tailscale addresses and your other devices, can share your home network with the tailnet *(subnet router)* or offer the NAS as an exit node, and can log the NAS out. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

The NAS stays logged in and reconnects by itself after restarts and app updates. Shared networks and exit nodes must also be approved in the [Tailscale admin console](https://login.tailscale.com/admin/machines).

It can all be done over SSH too:

```sh
tailscale up                                            # log in - open the link it shows
tailscale status                                        # the NAS's Tailscale address and connected devices
tailscale set --advertise-routes=192.168.1.0/24         # share the home network
tailscale set --advertise-exit-node                     # offer the NAS as an exit node
```

## Privacy

The app is set up to share as little as possible with Tailscale *(the company)*:

- **No log uploads:** `tailscaled` runs with `--no-logs-no-support`, so it doesn't send its logs and diagnostics to Tailscale. Tailscale's support needs them, so they can be turned on from the management page when asking for help.
- **The NAS keeps its own DNS:** logging in uses `--accept-dns=false`, so the NAS doesn't switch to Tailscale's MagicDNS *(its DNS lookups keep going to your own DNS server, e.g. a Pi-hole)*. Other devices are still reachable by their Tailscale addresses.
- **Your own coordination server:** the login form accepts the address of a self-hosted [Headscale](https://headscale.net/) server, an open-source replacement for Tailscale's coordination server. With it, no company knows about your devices *(to switch an existing NAS to it, log out, then log in with the new server)*.

Traffic between your devices is always end-to-end encrypted with WireGuard *(Tailscale's relay servers, used when two devices can't connect directly, only see encrypted packets)*. What Tailscale's own coordination server does know is your devices, their names and IP addresses, when they're online, and the account *(Google, Microsoft, GitHub...)* you logged in with. It also hands out your devices' keys - if you use it, consider turning on [Tailnet Lock](https://tailscale.com/kb/1226/tailnet-lock), so that new devices must also be signed by one of your own.

## How it works

- `tailscaled` runs as `root`, using the kernel's TUN device *(WD ships `tun.ko`, which the app loads if needed)*, on UDP port `41641`.
- Its state *(the node's identity, login and settings)* is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_tailscale`, and survives reinstalls. Its output is in `tailscale.log` in the app's install directory.
- The `tailscale` command is linked into `/usr/bin`.
- Stopping the app runs `tailscaled --cleanup`, removing its routes, firewall rules and network interface *(as Tailscale's own service does)*.
- The NAS shows an alert *(and sends an email, if set up)* when a new Tailscale release is out, checked weekly.

Tailscale needs to reach `*.tailscale.com` and `*.tailscale.io` - DNS blocklists for VPNs *(e.g. in Pi-hole)* often block these, so allow them if needed.

## Building the Tailscale app

From the project root directory:

```bash
./build.sh tailscale
```

The WD bin files will be created in `packages/tailscale/`. The Tailscale version is taken from `apkg.rc`, and each download is checked against its published checksum.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
