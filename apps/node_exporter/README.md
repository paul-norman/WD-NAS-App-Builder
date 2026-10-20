# Node Exporter App

[Node Exporter](https://github.com/prometheus/node_exporter) is Prometheus's official exporter for a machine's hardware and system metrics *(CPU, memory, load, disk I/O, filesystems, network, temperatures, software RAID…)*. Prometheus collects them from it, and Grafana shows them.

- The metrics are at `http://<nas-ip>:9100/metrics` *(the port can be changed on the management page)*.
- The app adds **WD's own view of the storage**, which Linux alone doesn't show, as metrics starting with `wd_` *(see below)*.
- Nothing is written to the disks while it runs: its files and log are kept in RAM *(`/tmp`)*, and WD's records are read rather than the disks themselves, so sleeping disks stay asleep.
- Its settings *(port, password)* are kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_node_exporter`, and survive reinstalls.
- Node Exporter doesn't update itself: updates come with new versions of the app, and the NAS shows an alert *(and sends an email, if set up)* when a new release is out, checked weekly.

## WD storage metrics

A small script reads WD's records of the disks, RAID arrays and volumes every 30 seconds *(the same ones the dashboard's Storage pages use, via WD's `xmldbc`)*, and Node Exporter serves them with its own metrics *(through its textfile collector)*:

| Metric | Labels | Value |
|---|---|---|
| `wd_health` | | Overall storage health: `0` healthy, `1` degraded *(e.g. a disk too hot, a RAID rebuilding)*, `2` critical *(e.g. a failed disk, a degraded RAID, a volume not mounted)* |
| `wd_info` | `model`, `firmware` | Always `1` |
| `wd_disk_info` | `disk`, `bay`, `vendor`, `model`, `firmware` | Always `1` |
| `wd_disk_temperature_celsius` | `disk`, `bay` | The temperature WD last read |
| `wd_disk_healthy`, `wd_disk_failed`, `wd_disk_over_temperature`, `wd_disk_sleeping` | `disk`, `bay` | `1` or `0` |
| `wd_disk_smart_passed` | `disk`, `bay` | Whether the last SMART test WD ran passed *(only once one has run)* |
| `wd_disk_size_bytes` | `disk`, `bay` | |
| `wd_raid_info` | `raid`, `level`, `system` | Always `1` *(`system="1"` is WD's own small system array, `md0`)* |
| `wd_raid_state` | `raid`, `state` | Always `1`: the state is the label *(e.g. `clean`, `degraded`, `recovering`)* |
| `wd_raid_disks` | `raid`, `state` | Disk counts: `total`, `active`, `working`, `spare`, `failed`, `rebuilding` |
| `wd_raid_dirty` | `raid` | `1` or `0` |
| `wd_raid_size_bytes` | `raid` | |
| `wd_volume_info` | `volume`, `label`, `mountpoint`, `raid`, `raid_level` | Always `1` |
| `wd_volume_mounted`, `wd_volume_encrypted`, `wd_volume_unlocked` | `volume` | `1` or `0` |
| `wd_volume_size_bytes`, `wd_volume_used_bytes` | `volume` | |
| `wd_collector_success` | | Whether WD's records could all be read |

Disk serial numbers are left out. For alerts, e.g. `wd_health > 0`, `wd_disk_temperature_celsius > 55` or `wd_raid_disks{state="failed"} > 0`.

## Management page

Node Exporter's page in the NAS dashboard *(Apps → Node Exporter)* shows whether it's running, its version and metrics address, and the storage as WD sees it *(disks with temperatures, RAID arrays, volumes and overall health)*. It changes the port, can require a password *(see below)*, gives a `prometheus.yml` snippet to copy, and shows Node Exporter's latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Password

Like Node Exporter on other machines, the metrics can be read by anyone on the local network by default *(they show the NAS's activity, not its files or settings)*. The management page can require a password: tick the box, enter a password *(or leave it empty to generate one)* and save. The user name is `prometheus`, and the password can be shown, copied or changed on the page afterwards. It's saved, readable by root only, in `Nas_Prog/_node_exporter/password`, and Node Exporter is given only its hash *(in `web-config.yml`)*. Add the `basic_auth` lines from the page's snippet to Prometheus.

## Building the Node Exporter app

From the project root directory:

```bash
./build.sh node_exporter
```

The WD bin files will be created in `packages/node_exporter/`. The Node Exporter version is taken from `apkg.rc`, and each download is checked against the release's published checksums.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
