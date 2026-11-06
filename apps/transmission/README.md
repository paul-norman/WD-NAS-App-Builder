# Transmission App

[Transmission](https://transmissionbt.com/) is a lightweight BitTorrent client. The app runs its daemon natively on the NAS *(no Docker)*, with its web interface, downloading straight into the NAS's shares.

- Its web interface is at `https://transmission.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically)*, and at `http://<nas-ip>:9091/transmission/web/` on the local network unless limited to the Nginx app on the management page.
- **It asks for a login**: user name `admin` and a generated password, which the management page shows, copies or replaces. The same login works for remote apps *(e.g. Transmission Remote GUI, phone apps, or Sonarr / Radarr)* on port 9091. Through the Nginx app, Nginx asks for the same login first *(its own copy, `htpasswd`, kept in step with the page)*, so visits without it stop there.
- Downloads go to a **Downloads** share if the NAS has one, else to `Public/Downloads` *(created on first start)* - any folder in the shares can be chosen on the management page. Transmission runs as its own `transmission` user *(created by the app, ID 97)* in the NAS's share group, keeping its files group-writable, so the NAS's users can move, rename or delete them over SMB.
- Other computers reach it on its **peer port** *(51413 by default, TCP and UDP)*: Transmission asks the router to forward it *(UPnP / NAT-PMP)*; if the router doesn't, forward it by hand for faster downloads.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_transmission`, and survives reinstalls and removal: Transmission's own settings, torrents and their progress *(`config/`)*, the page's settings, the password *(root only)* and `transmission.log` *(warnings only, kept under 1MB)*. The downloads stay where they are.
- **Its log**: Transmission notes every request without its login (`Rejected request from ... (failed authentication)`) - e.g. a browser's first visit to port 9091, before it asks for the password; through the Nginx app those stop at Nginx. `Couldn't initialize IPv6 LPD: No such device` at each start is harmless: WD's kernel has no IPv6 multicast, and finding peers on the local network still works over IPv4.
- The page's settings are written into Transmission's own `settings.json` at every start; anything else changed in its web interface *(e.g. seeding limits, queue sizes, blocklists)* is kept.
- It's built from source by `static/transmission`, fully static *(with its own OpenSSL and curl)*. `transmission-remote`, `-create`, `-edit` and `-show` come with it, in the app's `binaries/bin`. Transmission doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Transmission's page in the NAS dashboard *(Apps → Transmission)* shows whether it's running, its version, the number of torrents and the current speeds, its addresses and the login *(with the password)*. It sets the downloads folder, the peer port, download and upload limits, and whether it's only reachable through the Nginx app, restarts Transmission and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Transmission app

From the project root directory:

```bash
./build.sh transmission
```

This first runs `static/transmission` *(once per version)*. The WD bin files will be created in `packages/transmission/`. To update, change the version in `apkg.rc` and `static/transmission/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
