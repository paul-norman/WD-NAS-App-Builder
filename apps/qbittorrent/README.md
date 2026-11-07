# qBittorrent App

[qBittorrent](https://www.qbittorrent.org/) is a popular BitTorrent client. The app runs its headless version *(qbittorrent-nox)* natively on the NAS *(no Docker)*, with its web interface on port 8092, downloading straight into the NAS's shares.

For the Intel and ARM models *(the ARM ones' package is checked under emulation when it's built, but hasn't yet been tried on an ARM NAS)*.

- **It asks for a login**: user name `admin` and a generated password, which the management page shows, copies or replaces. The same login works for remote apps *(e.g. phone apps, or Sonarr / Radarr)* on port 8092. qBittorrent bans an address for a while after repeated wrong passwords.
- Downloads go to a **Downloads** share if the NAS has one, else to `Public/Downloads` *(created on first start)* - any folder in the shares can be chosen on the management page. qBittorrent runs as its own `qbittorrent` user *(created by the app, ID 84)* in the NAS's share group, keeping its files group-writable, so the NAS's users can move, rename or delete them over SMB.
- Other computers reach it on its **peer port** *(6882 by default, TCP and UDP)*: qBittorrent asks the router to forward it *(UPnP / NAT-PMP)*; if the router doesn't, forward it by hand for faster downloads.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_qbittorrent`, and survives reinstalls and removal: qBittorrent's own settings, torrents and their progress *(`profile/`)*, its log *(`logs/`, kept under 1MB)*, the page's settings and the password *(root only)*. The downloads stay where they are.
- The page's settings are written into qBittorrent's own `qBittorrent.conf` at every start; anything else changed in its web interface *(e.g. seeding limits, queue sizes, RSS, categories)* is kept.
- **With the Arr stack recipe**: that recipe brings its own qBittorrent *(port 8090)*, wired to its apps. This app is for downloading without it - they can run side by side, but the Arr apps only use their own.
- Its programs come from [qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static): qBittorrent built fully static, with Qt 6, libtorrent 2, Boost, OpenSSL and zlib inside - one file per architecture, checked against its published digest. The app adds a small helper that switches to its user, and its own list of certificate authorities *(for HTTPS trackers, RSS feeds and searches)*. qBittorrent doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

qBittorrent's page in the NAS dashboard *(Apps → qBittorrent)* shows whether it's running, its version, the number of torrents and the current speeds, its addresses and the login *(with the password)*. It sets the downloads folder, the peer port, download and upload limits, and whether it's only reachable through the Nginx app, restarts qBittorrent and shows its latest log lines. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the qBittorrent app

From the project root directory:

```bash
./build.sh qbittorrent
```

This first runs `static/qbittorrent` *(once per version)*. The WD bin files will be created in `packages/qbittorrent/`. To update, change the version in `apkg.rc` and `static/qbittorrent/build.sh` *(with the new release's libtorrent version, checksums and Qt version)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
