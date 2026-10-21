# Uptime Kuma App

[Uptime Kuma](https://github.com/louislam/uptime-kuma) watches websites, services and devices *(HTTP(S) and keywords, TCP ports, ping, DNS, certificates' expiry, databases, Docker containers and more)*, shows their history and status pages, and sends alerts through dozens of services *(email, Telegram, Discord, Slack, ntfy, Pushover, webhooks…)* when something goes down. It runs natively on the NAS *(no Docker)*, using about 100–150MB of memory.

- It's at `http://<nas-ip>:3001` on the local network, and also served over HTTPS by the [Nginx app](../nginx/README.md), if installed, at `https://uptime-kuma.<its domain>` *(added automatically; the site can be renamed or switched off there)*. The management page can limit it to the Nginx app only.
- It runs as its own `uptimekuma` user *(created by the app, ID 72)*, not as root.
- It has its own Node.js *(24.22.0)*: its SQLite module is compiled for one Node.js version, so it doesn't use the Node.js app's, which can be updated separately.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_uptime-kuma`, and survives reinstalls and removal:
  - `data/` - Uptime Kuma's own data: the SQLite database `kuma.db` *(monitors, history, settings)* and uploaded images, readable only by its user
  - `settings` - the management page's settings
  - `backups/` - the daily backups *(unless another folder is chosen)*
  - `uptime-kuma.log` - its log, kept under 1MB
- **Ping monitors** use the app's own `ping` *(iputils, static)*: the NAS's BusyBox `ping` only works for root, while iputils' can ping through the kernel's ICMP sockets. The NAS doesn't allow those by default *(`net.ipv4.ping_group_range` is "1 0")*, so the app allows them for Uptime Kuma's group only while it runs, as Docker does for containers - and turns them off again when it stops.
- Not available natively: the "real browser" monitor *(it needs Chromium)* and the embedded MariaDB database option *(only in Uptime Kuma's Docker image)* - the database is SQLite.
- It's built from Uptime Kuma's release *(source and prebuilt web interface)* by `static/uptime-kuma`, which installs its packages on Debian Bullseye *(the NAS's version, so its compiled modules suit the NAS - checked during the build)* and builds the tools used alongside it: `ping`, `sqlite3` *(for backups)* and `kuma_runas` *(to switch to its user - the NAS has no `su`)*.
- Uptime Kuma doesn't update itself: updates come with new versions of the app, and the NAS shows an alert *(and sends an email, if set up)* when a new release is out, checked weekly.

## Management page

Uptime Kuma's page in the NAS dashboard *(Apps → Uptime Kuma)* shows whether it's running, its version and addresses, with a link to it. It can:

- limit access to the Nginx app *(HTTPS)* only, or also allow port 3001 on the local network
- reset the admin account's password *(to a new random one, shown once - every session is logged out)*
- set the backup folder and how many backups to keep, back up straight away, and list the backups
- restart Uptime Kuma, and show its latest log

Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## First steps

1. Open Uptime Kuma *(the management page links to it)* and create the admin account.
2. Add monitors, and the notifications that should alert you *(Settings → Notifications)*.
3. Behind the Nginx app, turn on **Trust Proxy** in Settings → Reverse Proxy, so that Uptime Kuma sees its visitors' real addresses.

Uptime Kuma runs on the NAS, so it can't tell you when the NAS itself is down - for that, monitor the NAS from somewhere else too *(e.g. a free external service, or Uptime Kuma's "Push" monitors fed by another machine)*.

## Backups

Every day at 02:30, and on the page's **Back up now**, the app writes `uptime-kuma-<date>-<time>.tar.gz` to the backup folder, holding `kuma.db` *(a consistent copy made with SQLite's online backup while Uptime Kuma runs, and checked)*, `db-config.json` and the `upload/` folder. The newest backups are kept *(7 by default - the database grows with the monitors' history, kept for 180 days unless changed in Settings → Monitor History)*. They're readable by root only.

To restore one over SSH *(the app's folder may be on another volume)*:

```sh
sh /mnt/HD/HD_a2/Nas_Prog/uptime-kuma/kuma_ctl.sh stop
cd /mnt/HD/HD_a2/Nas_Prog/_uptime-kuma
mv data data.old
mkdir data && tar -xzf backups/uptime-kuma-<date>-<time>.tar.gz -C data
chown -R uptimekuma:uptimekuma data && chmod 700 data
sh /mnt/HD/HD_a2/Nas_Prog/uptime-kuma/kuma_ctl.sh start
```

## Building the Uptime Kuma app

From the project root directory:

```bash
./build.sh uptime-kuma
```

This first runs `static/uptime-kuma` *(once per version)*. The WD bin files will be created in `packages/uptime-kuma/`. To update, change the version in `apkg.rc` and `static/uptime-kuma/build.sh` *(with the new release's checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
