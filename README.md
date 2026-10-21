# Building WD NAS apps

This is a repository for me to learn how to build apps for the WD NAS machines running OS5 *(FW > 5.27.157 - Debian Bullseye)*.

The goal is to build a [Jellyfin server for WD devices](https://features.jellyfin.org/posts/220/port-to-wd-nas-western-digital-pr4100) without the need for Docker / external packages so that hardware transcoding is possible. Dozens of us are itching to ditch Plex, dozens...

## Building an existing app

To build an existing app, there is a build script in the root directory that will run the process through a Debian 11 (Bullseye) docker container. For example:

```bash
./build.sh <app_name>
```

The WD bin files will be created in `/packages/<app_name>/<version>/*`.

To build for a single model only *(much quicker while developing)*, set `MODEL_OVERRIDE` to its model name, e.g. `MODEL_OVERRIDE=MyCloudPR4100 ./build.sh <app_name>`. Each build replaces that version's release directory, so run a normal build again before publishing all models. A file containing the most recently built version number will also be created in `/packages/<app_name>/latest`.

If you don't have docker installed, see the [guide](docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](docker/WINDOWS.md) for WSL / docker installation.

# Creating a new app

- Copy the `apps/template` app directory and create a new app directory from it in the same parent directory.
  - e.g. `cp -R apps/template apps/new_app`
- Edit the `apps/<new_app>/apkg.rc` file to have a `Package` value which exactly matches the new directory name.
  - e.g. `sed -i 's/Package:.*/Package:\t\t\tnew_app/' apps/new_app/apkg.rc`
  - Other options `apkg.rc` are explained in the [guide](guides/README.md).
- Edit `web/desc.xml` with the app's description in each language *(shown in the NAS web UI; the template has English, French, Spanish and German)*, and use the English text for `Description` in `apkg.rc` too.
- The `apps/<new_app>/build.sh` script runs locally from Docker to package your app. Customise it to your app's needs *(e.g. if you need to package downloaded binaries)* - see [guide](apps/README.md).
  - If you're downloading the application files on the WD NAS device itself, you can leave this file alone.
- All other shell scripts (`apps/<new_app>/*.sh`) run on the WD NAS device itself to perform the actions that are required. See [overview](guides/README.md) and [guide](apps/README.md).

## Building statically linked apps

WD NAS devices run a heavily stripped down Debian Bullseye without a package manager, outdated / missing linked libraries and only offer ancient versions of many programs. It's therefore not possible to simply expect many applications to work when built *from* a full Debian machine.

For this reason it's possible to build "statically linked" versions of applications that you want the WD NAS device to run and then include that binary in the app package. These versions have all dependencies bundled with them and require nothing extra.

Creation of these binaries will require an extra build step *(which `./build.sh <app_name>` runs automatically when a matching `static/<app_name>` directory exists, or which can be called manually)*

```bash
./build_static.sh <static_app_name>
```

The statically linked files will be created in `/packages/static/<static_app_name>/<version>/<arch>/*`. A file containing the most recently built version number will also be created in `/packages/static/<static_app_name>/latest`.

Where a program can't work as a fully static binary *(e.g. ValKey 9+, which loads its built-in Lua engine with `dlopen`)*, it is instead built on Debian Bullseye, linked only against glibc. The NAS runs Bullseye's glibc 2.31, so those shared libraries are always present.

`static/docker` is different again: it builds kernel modules that WD's kernel lacks *(`overlay`, `iptable_raw`)* from WD's own GPL source, for one specific firmware version *(see the [Docker app](apps/docker/README.md))*.

Each `static/<static_app_name>/build.sh` must declare the version it builds on its own line as `VERSION=<version>`. A version that has already been built for an architecture is skipped, so bumping `VERSION` is all that's needed to trigger a rebuild *(delete the matching `/packages/static/...` directory to force one)*.

## Project structure

- `/`
  - `/apps`     - files that build the WD apps
  - `/docker`   - Dockerfiles used to run builds
  - `/guides`   - information that I have found / written
  - `/static`   - build instructions / required files for statically linked programs
  - ---
  - `/packages` - the built apps (static and for devices)

## Current progress report

- [x] Understand the WD app basics
  - [x] Create a template to expedite future app creation
- [x] Create something new, but simple (`nodejs` app)
- [x] Run Jellyfin natively (`jellyfin` app - Jellyfin 12.2 portable release, with libraries rebuilt for the NAS's glibc)
  - [x] Installs
  - [x] Runs
  - [x] Loads Jellyfin-Web
  - [x] Uses Jellyfin-Ffmpeg, with VA-API hardware encoding on the Intel GPU *(verified with ffmpeg on a PR4100)*
  - [x] Hardware transcoding while streaming from Jellyfin *(GPU encoding; 10-bit HEVC is decoded in software, ~1.3x real time for 1080p on a PR4100 - 8-bit H.264 / HEVC are decoded on the GPU too)*
- [ ] Learn about building / statically linking
  - [x] Attempt a statically linked build for AMD64 (`nano` app)
  - [ ] Attempt a statically linked build for ARM
    - [Guide](https://jensd.be/1126/linux/cross-compiling-for-arm-or-aarch64-on-debian-or-ubuntu)
    - Create a docker container using `arm-linux-gnueabi-gcc` / `gcc-aarch64-linux-gnu`
- [ ] Complete and test the automatic SSH installation of apps via the `build.sh` script
  - [ ] SSH config to the WD NAS device
  - [ ] Create test file format / helpers
- [ ] Find others willing to help / test *(preferably someone with an ARM based NAS device)*
- [ ] Create some new, really simple, potentially useful, stand-alone apps. *(No need to be novel, perhaps directly out of Entware ipk files to begin with?)*. Some ideas:
  - [x] [Node 24.22.0 LTS](https://nodejs.org/dist/v24.22.0/node-v24.22.0-linux-x64.tar.xz)
  - [x] [Go 1.27.2](https://go.dev/dl/go1.27.2.linux-amd64.tar.gz)
  - [x] [phpMyAdmin 5.2.3](https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz)
  - [x] [Mailpit 1.31.6](https://github.com/axllent/mailpit/releases/download/v1.31.6/mailpit-linux-amd64.tar.gz)
  - [x] [ValKey 9.1.2](https://github.com/valkey-io/valkey/archive/refs/tags/9.1.2.tar.gz)
  - [x] [Docker 29.9.1](https://download.docker.com/linux/static/stable/x86_64/docker-29.9.1.tgz) / [Docker-Compose 5.6.0](https://github.com/docker/compose/releases/download/v5.6.0/docker-compose-linux-x86_64) / [Portainer 2.45.2 LTS](https://github.com/portainer/portainer/releases/tag/2.45.2)
  - [x] [PHP 8.5.12](https://www.php.net/releases/8.5/) *(`php` app: replaces the NAS's own PHP 7.4, static build with static-php-cli)*
  - [x] [Nginx 1.30.6](https://nginx.org/) *(`nginx` app: HTTPS reverse proxy for the apps, with certificates from Let's Encrypt via lego - static build with Brotli)*
  - [x] [MariaDB 11.8.9 LTS](https://mariadb.org/) *(`mariadb` app: replaces the NAS's own MariaDB 10.5, on a copy of its data)*
  - [x] [PostgreSQL 18.6](https://www.postgresql.org/) *(`postgresql` app: built on Bullseye with bundled libraries, runs as its own user - with PostGIS, pgvector, pg_cron, pg_partman and pgaudit)*
  - [x] [Node Exporter 1.12.1](https://github.com/prometheus/node_exporter) *(`node_exporter` app: system metrics for Prometheus / Grafana, plus WD's disk, RAID and volume health as `wd_` metrics)*
  - [x] [Vaultwarden 1.37.4](https://github.com/dani-garcia/vaultwarden) *(`vaultwarden` app: native Bitwarden-compatible server with SQLite, served over HTTPS by the Nginx app, runs as its own user - daily backups)*
  - [x] [Uptime Kuma 2.5.6](https://github.com/louislam/uptime-kuma) *(`uptime-kuma` app: native, with its own Node.js and an unprivileged ping, runs as its own user - optional HTTPS via the Nginx app, daily backups)*
  - [x] [Prometheus 3.15.0](https://prometheus.io/) *(`prometheus` app: stores the metrics, scraping the Node Exporter app automatically - NAS-only by default, own user)*
  - [x] [Grafana 13.2.4](https://grafana.com/oss/grafana/) *(`grafana` app: dashboards and alerts, with the Prometheus app as its data source and WD NAS + Node Exporter Full dashboards - trimmed official release, own user, daily backups)*
  - [x] [Loki 3.7.9](https://grafana.com/oss/loki/) + [Vector 0.60.0](https://vector.dev/) *(`loki` app: collects the NAS's, apps' and Docker containers' logs, searchable in the Grafana app with a NAS logs dashboard)*
  - [x] [Kopia 0.23.1](https://kopia.io/) *(`kopia` app: encrypted, deduplicated, versioned backups to the cloud, another server or a USB drive - HTTPS-only through the Nginx app by default)*
  - [x] [ntfy 2.32.0](https://ntfy.sh/) *(`ntfy` app: push notifications to phones and browsers from the NAS's apps and scripts - login required, optional iPhone relay)*
  - [ ] [Git 2.47.1](https://bin.entware.net/x64-k3.2/git_2.39.2-1_x64-3.2.ipk)

## Where to find other apps?

There's a list of compiled apps:

- [First Party](https://community.wd.com/t/apps-my-cloud-os5-apps-matrix/286467)
- [Third Party](https://community.wd.com/t/apps-my-cloud-os5-apps-matrix-third-party/286505)

## Inspiration / acknowledgements

This project is building principally upon work done by [Stefan (aka TFL)](https://github.com/stefaang) in the [WDCommunity](https://github.com/WDCommunity/wdpksrc/) Github Repo, but the `helper.sh` script was heavily influenced by Cerberus's [App Template](https://drive.google.com/uc?export=download&id=1Qds0Nh2o4DPlGG6WfIlXLkcChsZlqrp7) from the [WD Community Support forums](https://community.wd.com/t/my-cloud-os5-app-template/286542).
