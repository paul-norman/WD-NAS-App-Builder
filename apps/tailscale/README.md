# Tailscale App

[Tailscale](https://tailscale.com/) connects the NAS to your private Tailscale network *(tailnet)* over WireGuard, so you can reach it securely from anywhere, without opening any ports on your router.

## Setting up

Log in over SSH, then open the link it shows to add the NAS to your tailnet:

```sh
tailscale up
tailscale status          # the NAS's Tailscale address and connected devices
```

The NAS stays logged in and reconnects by itself after restarts and app updates. Options such as sharing your home network *(`--advertise-routes=192.168.1.0/24`)* or acting as an exit node *(`--advertise-exit-node`)* are added to `tailscale up`, or changed later with `tailscale set`.

The app's page in the NAS web UI only explains this - logging in is deliberately done over SSH, as app pages can be reached without logging in to the NAS *(anyone who opened the login link could add the NAS to their own tailnet)*.

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
