# Prometheus App

[Prometheus](https://prometheus.io/) collects metrics: every 30 seconds it fetches ("scrapes") the numbers that exporters publish - such as the [Node Exporter app](../node_exporter/README.md)'s, for the NAS's hardware, system and WD storage - and stores them with their history. The [Grafana app](../grafana/README.md) draws dashboards from it, and its own rules can raise alerts.

- It's on port `9090`, reachable **on the NAS itself only** by default: Prometheus has no login, and Grafana reaches it there. The management page can open it to the local network.
- Its configuration is written by the app *(at every start, and by the page's **Reload**)*: it scrapes itself and the Node Exporter app, if installed - following that app's port and password, so changing them on Node Exporter's page updates Prometheus too.
- **Other apps' metrics are collected by themselves**: an app can ship a scrape job *(`prometheus/*.yml` in its folder - e.g. the [Postgres](../postgres_exporter/README.md), [MariaDB](../mysqld_exporter/README.md) and [Valkey](../redis_exporter/README.md) exporters)*. Prometheus copies each installed app's into `apps.d/` *(with the NAS's name as its `instance`)* and reloads when such an app is installed or removed - in either order.
- Your own scrape jobs go in `scrape.d/*.yml`, and alerting / recording rules in `rules.d/*.yml` *(see `scrape.d/README.txt`)*. A file with an error doesn't stop Prometheus: it keeps its previous configuration, and the page shows that the reload failed.
- History is kept for 30 days by default *(adjustable on the page)*. For one NAS that's typically a few hundred MB.
- It runs as its own `prometheus` user *(created by the app, ID 73)*, not as root.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_prometheus` *(the database in `data/`, its settings, your own files, and `prometheus.log` - warnings only, kept under 1MB)*, and survives reinstalls and removal.
- Prometheus writes to its database continuously, so the NAS's disks won't sleep while it runs.
- The official static program is used *(prepared by `static/prometheus`, without `promtool`)*. Prometheus doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.
- For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)* - and it's heavy for them: workable with 1-2GB of memory *(e.g. an EX4100)*, too much for the 512MB single-drive My Cloud.

## Management page

Prometheus' page in the NAS dashboard *(Apps → Prometheus)* shows whether it's running, its version, address, how much it stores, whether its configuration loaded, and its targets with their state *(and the error, for any that are down)*. It reloads the configuration, restarts Prometheus, sets how many days of history to keep and whether it's reachable from the network, and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Prometheus app

From the project root directory:

```bash
./build.sh prometheus
```

This first runs `static/prometheus` *(once per version)*. The WD bin files will be created in `packages/prometheus/`. To update, change the version in `apkg.rc` and `static/prometheus/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
