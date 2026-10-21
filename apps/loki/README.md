# Loki (logs) App

Collects the NAS's logs in one place, searchable in [Grafana](../grafana/README.md):

- **[Grafana Loki](https://grafana.com/oss/loki/)** stores the log lines - like Prometheus does for metrics, it indexes only their labels, which keeps it light.
- **[Vector](https://vector.dev/)** reads the log files *(and Docker containers' output)* as they're written, labels each line and sends it to Loki. It's used instead of Grafana Alloy *(Grafana's own collector, which replaced the retired Promtail)*: it does the same job here at a third of the size *(a 57MB download, against 170MB)* and a fraction of the memory.

What's collected *(each source can be turned off on the management page)*:

| Source | Logs | Labelled |
|---|---|---|
| The NAS itself | `/var/log/*.log` *(the system log `user.log`, `kern.log`, `daemon.log`, `sshd.log`, WD's `nasAdmin.log`, `wdlog.log`, `wdhwlib.log`, `event.log`, `otaclient.log`…)* and Samba's logs - not WD's private or analytics logs | `source="system"`, `app="user"`, `"kern"`, `"sshd"`… |
| The apps | `Nas_Prog/_<app>/*.log` *(e.g. Vaultwarden, Uptime Kuma, Prometheus, Grafana, Docker, PHP)*, the Nginx app's logs, Node Exporter's, and the app scripts' `/tmp/debug_apkg` | `source="app"`, `app="vaultwarden"`, `"nginx"`, `"app-scripts"`… |
| Docker | every container's output, while Docker runs *(restart this app after starting Docker)* | `source="docker"`, `app=<container name>` |

Every line also has a `host` label *(the NAS's name)*. When it first starts, Vector reads back up to a day of each log.

- With the Grafana app installed, Loki becomes a data source and a **NAS logs** dashboard appears in the **NAS** folder: lines and errors / warnings over time by app, and the log lines themselves, filtered by source, app and search text. **Explore** *(with the Loki data source)* allows any LogQL query, e.g. `{app="sshd"} |= "Failed password"`.
- Logs are kept for 30 days by default *(adjustable on the page)*.
- Loki is reachable **on the NAS itself only** *(`127.0.0.1:3100` - it has no login)*. It runs as its own `loki` user *(created by the app, ID 75)*. Vector runs as root, as many logs are readable by root only - it only reads them, and sends them to Loki.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_loki`, and survives reinstalls and removal: Loki's database `data/`, Vector's place in each file `vector/`, the generated `loki.yaml` and `vector.yaml`, the page's `settings`, and the two programs' own logs *(warnings only, kept under 1MB - not collected, so that the app never reads what it writes about itself)*.
- Both are official static programs *(prepared by `static/loki`)*. Neither updates itself: updates come with new versions of the app, and the NAS shows an alert when a new Loki release is out, checked weekly.

## Management page

The app's page in the NAS dashboard *(Apps → Loki (logs))* shows whether Loki and Vector are running, their versions, how much is stored, and what has been collected in the last 24 hours *(lines per log)*. It sets how many days to keep and which sources to collect, restarts both, and shows their latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Loki app

From the project root directory:

```bash
./build.sh loki
```

This first runs `static/loki` *(once per version)*. The WD bin files will be created in `packages/loki/`. To update, change the versions in `apkg.rc` and `static/loki/build.sh` *(with the new releases' checksums)*. The NAS logs dashboard is `dashboards/nas-logs.json`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
