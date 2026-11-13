# Valkey Exporter App

[redis_exporter](https://github.com/oliver006/redis_exporter) gives Prometheus the [Valkey app](../valkey/README.md)'s metrics - memory, clients, commands, keys and expiries - with a Grafana dashboard. It's for the [Prometheus](../prometheus/README.md) and [Grafana](../grafana/README.md) apps: once they're installed *(in any order)*, Prometheus collects its metrics every 30 seconds, and its dashboard *(Valkey (Redis))* is in Grafana's **NAS** folder. It runs natively on the NAS *(no Docker)*.

- **It needs the [Valkey app](../valkey/README.md)** *(installed first)*. It uses Valkey's password *(Valkey has one, in `Nas_Prog/_valkey/valkey.conf`)*, read again every time it starts - restart it after changing that password.
- It listens on the NAS itself only *(`127.0.0.1:9121`)* and runs as its own user *(`redis_exporter`, ID 91)*. Its files are kept in `Nas_Prog/_redis_exporter`, across reinstalls and removal.
- **Its page** shows whether it reaches Valkey, whether Prometheus collects its metrics, and links to its dashboard. **Read Valkey's password again** picks up a changed one.
- Its scrape job is `prometheus/redis.yml` and its dashboard `dashboards/valkey.json`: the Prometheus and Grafana apps pick up every app's *(see their READMEs)*, and drop them when the app is removed.
- The dashboard is redis_exporter's own dashboard (contrib/grafana_prometheus_redis_dashboard.json, MIT, Copyright (c) 2016 Oliver), unchanged apart from its title, a `nas` tag and its `namespace` filter (a Kubernetes label, which the NAS hasn't).
- It's the official static program, checked against the SHA256s its release publishes *(pinned in `static/redis_exporter/build.sh`)*. For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)*.

## Building the Valkey Exporter app

From the project root directory:

```bash
./build.sh redis_exporter
```

The WD bin files will be created in `packages/redis_exporter/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
