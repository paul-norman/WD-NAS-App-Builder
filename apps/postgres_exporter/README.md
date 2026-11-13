# Postgres Exporter App

[postgres_exporter](https://github.com/prometheus-community/postgres_exporter) gives Prometheus the [PostgreSQL app](../postgresql/README.md)'s metrics - its activity, transactions, cache hits, locks and database sizes - with a Grafana dashboard. It's for the [Prometheus](../prometheus/README.md) and [Grafana](../grafana/README.md) apps: once they're installed *(in any order)*, Prometheus collects its metrics every 30 seconds, and its dashboard *(PostgreSQL)* is in Grafana's **NAS** folder. It runs natively on the NAS *(no Docker)*.

- **It needs the PostgreSQL app** *(installed first)*. It logs in as `postgres_exporter`, a login the app creates with a password only it keeps *(in `Nas_Prog/_postgres_exporter`, root's)*, as a member of `pg_monitor`: it can read PostgreSQL's statistics, not your data. At boot PostgreSQL may start after it: the login is then set up as soon as PostgreSQL answers.
- It listens on the NAS itself only *(`127.0.0.1:9187`)* and runs as its own user *(`postgres_exporter`, ID 89)*. Its files are kept in `Nas_Prog/_postgres_exporter`, across reinstalls and removal.
- **Its page** shows whether it reaches PostgreSQL, whether Prometheus collects its metrics, and links to its dashboard. **Set up its login again** makes a new password *(e.g. after PostgreSQL's data was started afresh)*.
- Its scrape job is `prometheus/postgres.yml` and its dashboard `dashboards/postgresql.json`: the Prometheus and Grafana apps pick up every app's *(see their READMEs)*, and drop them when the app is removed.
- The dashboard is postgres_exporter's own dashboard (postgres_mixin/dashboards/postgres-overview.json, Apache-2.0), unchanged apart from its title, a `nas` tag, and its Buffers panel brought up to PostgreSQL 17 and later *(checkpoints' buffers from `pg_stat_checkpointer`, which the app collects - backends' writes are no longer counted there)*.
- It's the official static program, checked against the SHA256s its release publishes *(pinned in `static/postgres_exporter/build.sh`)*. For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)*.

## Building the Postgres Exporter app

From the project root directory:

```bash
./build.sh postgres_exporter
```

The WD bin files will be created in `packages/postgres_exporter/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
