# Scrutiny App

[Scrutiny](https://github.com/AnalogJ/scrutiny) watches the health of the NAS's disks: their SMART data, kept over time *(temperatures, reallocated and pending sectors, power-on hours...)*, judged both by each disk's own verdict and by Scrutiny's, from real-world failure rates of each attribute's values - so a disk that's likely to fail shows before it does. It alerts the [ntfy app](../ntfy/README.md) when one fails. The app runs it natively on the NAS *(no Docker)*.

For the Intel models only: Scrutiny keeps its history in InfluxDB 2, which has no build for the ARM models' 32-bit processors.

- **It's reached through the [Nginx app](../nginx/README.md)** *(which it needs)*, at `https://scrutiny.<domain>`: Scrutiny has no login of its own, so it only listens on the NAS itself, and Nginx asks for the app's login first - user name `admin` and a generated password, which the management page shows, copies or replaces.
- **The disks are read hourly** *(and when it starts, and on request from the page)*. A disk that's asleep is left asleep - not read at all that time - so the disks still spin down; its last reading stays until it next wakes. Each disk is read as a SATA disk, with the program's own `smartctl` *(7.5 - newer than the NAS's)*.
- **Alerts**: set an ntfy topic on the page *(e.g. `nas`, the one your phone subscribes to)* and Scrutiny sends it an alert when a disk fails its SMART check or Scrutiny's own - with the ntfy app's token for the apps, so nothing else needs setting up. The page can send a test alert. Scrutiny's own notification settings *(in its interface)* add to these.
- Scrutiny and InfluxDB run as their own `scrutiny` user *(created by the app, ID 65)*, on the NAS itself only *(ports 8091 and 8093)*; reading the disks runs as root, as SMART needs. InfluxDB uses about 100-200MB of memory.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_scrutiny`, and survives reinstalls and removal: the disks' history *(`db/` - Scrutiny's database - and `influxdb/`)*, the page's settings, the password *(root only)* and the logs *(each kept under 1MB)*.
- Its programs are Scrutiny's official ones *(its web interface, its front end and its collector)*, InfluxDB's official ones and smartctl built from source, all fully static *(prepared by `static/scrutiny`, which checks them on the NAS's kind of processor, without AVX)*. Scrutiny doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Scrutiny's page in the NAS dashboard *(Apps → Scrutiny)* shows whether it's running, its version, its address, the disks *(each one's model, size and serial number, health, temperature and when it was last read)* and when they were last read. It reads them now, restarts Scrutiny, shows the login *(with the password)*, sets the ntfy topic for alerts and sends a test alert, and shows the disk reader's latest log lines. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Scrutiny app

From the project root directory:

```bash
./build.sh scrutiny
```

This first runs `static/scrutiny` *(once per version)*. The WD bin files will be created in `packages/scrutiny/`. To update, change the version in `apkg.rc` and `static/scrutiny/build.sh` *(with the new release's checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
