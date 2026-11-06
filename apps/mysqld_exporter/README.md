# MariaDB Exporter App

[mysqld_exporter](https://github.com/prometheus/mysqld_exporter) gives Prometheus the NAS's MariaDB *(WD's own, or the [MariaDB app](../mariadb/README.md)'s)* metrics - queries, connections, InnoDB's buffer pool, locks and table caches - with a Grafana dashboard. It's for the [Prometheus](../prometheus/README.md) and [Grafana](../grafana/README.md) apps: once they're installed *(in any order)*, Prometheus collects its metrics every 30 seconds, and its dashboard *(MariaDB / MySQL)* is in Grafana's **NAS** folder. It runs natively on the NAS *(no Docker)*.

- **For the NAS's MariaDB**: WD's own, or the [MariaDB app](../mariadb/README.md)'s *(the same socket, `/var/lib/mysql/mysql.sock`)*. It logs in as `mysqld_exporter@localhost`, a login the app creates *(as root, over the socket)* with a password only it keeps, which can read MariaDB's status *(`PROCESS`, `REPLICATION CLIENT` and `performance_schema`)*, not your data. If MariaDB isn't running when it starts, the login is set up as soon as it answers.
- It listens on the NAS itself only *(`127.0.0.1:9104`)* and runs as its own user *(`mysqld_exporter`, ID 90)*. Its files are kept in `Nas_Prog/_mysqld_exporter`, across reinstalls and removal.
- **Its page** shows whether it reaches MariaDB, whether Prometheus collects its metrics, and links to its dashboard. **Set up its login again** makes a new password *(e.g. after switching between WD's MariaDB and the MariaDB app's)*.
- Its scrape job is `prometheus/mysql.yml` and its dashboard `dashboards/mariadb.json`: the Prometheus and Grafana apps pick up every app's *(see their READMEs)*, and drop them when the app is removed.
- The dashboard is mysqld_exporter's own dashboard (mysqld-mixin/dashboards/mysql-overview.json, Apache-2.0), unchanged apart from its title, a `nas` tag, and two settings MariaDB no longer has taken out of its memory panel *(InnoDB's additional memory pool, TokuDB's cache)*. Its process states panels use the process list collector, which the app turns on.
- It's the official static program, checked against the SHA256 its release publishes *(pinned in `static/mysqld_exporter/build.sh`)*. For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)* - on an ARM NAS it watches WD's own MariaDB, if it has one (the MariaDB app is for the Intel models only).

## Building the MariaDB Exporter app

From the project root directory:

```bash
./build.sh mysqld_exporter
```

The WD bin files will be created in `packages/mysqld_exporter/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
