# Grafana App

[Grafana](https://grafana.com/oss/grafana/) draws dashboards from metrics and other data, and sends alerts. With the [Prometheus app](../prometheus/README.md) *(which stores the metrics of the [Node Exporter app](../node_exporter/README.md))* it shows the NAS's health and activity. It runs natively on the NAS *(no Docker)*, using about 300–400MB of memory.

- It's at `http://<nas-ip>:3000` on the local network, and also served over HTTPS by the [Nginx app](../nginx/README.md), if installed, at `https://grafana.<its domain>` *(added automatically; the site can be renamed or switched off there)*. The management page can limit it to the Nginx app only.
- Log in as `admin`, with the password the app generates on first start *(shown on the management page, which can also reset it)*.
- Set up by the app:
  - the Prometheus app as the default data source, and the [logs app](../loki/README.md)'s Loki *(each when installed)*, with its **NAS logs** dashboard
  - two dashboards in a **NAS** folder: **WD NAS** *(made for the app: storage health and RAID state from WD's own records, disk temperatures, a table of the disks, volume space, CPU, memory and disk throughput)* and **[Node Exporter Full](https://grafana.com/grafana/dashboards/1860)** *(the standard, very detailed system dashboard - by rfmoz, Apache-2.0)*. They're read-only *(copy one in Grafana, with "Save as", to change it)*.
  - no telemetry, news feed, or plugins downloaded at start-up
- It runs as its own `grafana` user *(created by the app, ID 74)*, not as root.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_grafana`, and survives reinstalls and removal:
  - `data/` - Grafana's own data: its database `grafana.db` *(dashboards, users, data sources, alerts, settings)* and installed plugins, readable only by its user
  - `admin_password` - the first admin password *(root only)*
  - `grafana.ini` and `provisioning/` - written by the app at every start
  - `settings` - the management page's settings
  - `backups/` - the daily backups *(unless another folder is chosen)*
  - `grafana.log` - its warnings and errors, kept under 1MB
- It's Grafana's official static release, trimmed by `static/grafana` to what the NAS needs *(about 650MB instead of 1.4GB)*: without its documentation, API browser and the web interface's debugging files, and with only the data source plugins for **Prometheus**, **Loki** *(the logs app)*, **MySQL / MariaDB** and **PostgreSQL** *(the project's database apps)*. Other data sources *(e.g. InfluxDB, Tempo)* can be installed from Grafana's plugin catalogue *(Administration → Plugins)*.
- Grafana doesn't update itself: updates come with new versions of the app, and the NAS shows an alert *(and sends an email, if set up)* when a new release is out, checked weekly.

## Management page

Grafana's page in the NAS dashboard *(Apps → Grafana)* shows whether it's running, its version, addresses and data source, with a link to it. It can:

- limit access to the Nginx app *(HTTPS)* only, or also allow port 3000 on the local network
- show and copy the admin password, or reset it to a new random one
- set the backup folder and how many backups to keep, back up straight away, and list the backups
- restart Grafana, and show its latest warnings

Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Backups

Every day at 02:45, and on the page's **Back up now**, the app writes `grafana-<date>-<time>.tar.gz` to the backup folder, holding `grafana.db` *(a consistent copy made with SQLite's online backup while Grafana runs, and checked)*. The newest backups are kept *(7 by default)*, readable by root only.

To restore one over SSH *(the app's folder may be on another volume)*:

```sh
sh /mnt/HD/HD_a2/Nas_Prog/grafana/graf_ctl.sh stop
cd /mnt/HD/HD_a2/Nas_Prog/_grafana
tar -xzf backups/grafana-<date>-<time>.tar.gz -C data
chown grafana:grafana data/grafana.db && chmod 600 data/grafana.db
sh /mnt/HD/HD_a2/Nas_Prog/grafana/graf_ctl.sh start
```

## Building the Grafana app

From the project root directory:

```bash
./build.sh grafana
```

This first runs `static/grafana` *(once per version - it downloads Grafana's 460MB release)*. The WD bin files will be created in `packages/grafana/`. To update, change the version in `apkg.rc` and `static/grafana/build.sh` *(with the new release's checksum)*. The WD NAS dashboard is `dashboards/wd-nas.json`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
