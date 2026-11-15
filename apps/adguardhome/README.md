# AdGuard Home App

[AdGuard Home](https://adguard.com/adguard-home/overview.html) blocks ads and trackers for every device on the network - phones, TVs, consoles, computers - as their DNS server, with no software on any of them. Its web interface shows what each device looks up and what was blocked, and sets its block lists, your own rules, per-device settings, safe search and parental controls, rewrites *(names for your own devices)*, and encrypted upstream DNS. The app runs AdGuard Home's official program natively on the NAS *(no Docker)*, for the Intel models and the ARM ones *(its ARMv7 program - checked for the ARM models' large memory pages, and under emulation; not yet tried on an ARM NAS)*. An alternative to the [Pi-hole recipe](../../recipes/README.md) - not alongside it: both answer DNS on port 53.

- **Using it**: set the NAS's address *(shown on the page)* as the DNS server in your router's DHCP settings, so that every device gets it when it next reconnects - or on one device first, to try it. Its DNS server is always on the network, on port 53.
- **Never as root**: only root may open port 53, so AdGuard Home runs as its own `adguardhome` user *(created by the app, ID 57)* and answers on port 5335, and the NAS's firewall forwards port 53 to it - its own NAT chain *(`ADGUARDHOME`)*, with a rule for each of the NAS's addresses, kept up to date every 5 minutes *(e.g. a new address from the router)*. AdGuard Home sees each device's own address. Stopping it removes the rules. It won't start if something else already answers on port 53 *(e.g. the Pi-hole recipe)*: the page says so. IPv4 only *(as the NAS's network is)*.
- **Its web interface** is at `https://adguard.<domain>` through the [Nginx app](../nginx/README.md) *(added automatically)* - by default, with the Nginx app installed, only through it *(on the NAS itself only, `127.0.0.1:8094`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8094` on the local network, over plain HTTP.
- **Nobody else can claim it.** A new AdGuard Home starts with a setup wizard that lets whoever opens it first in. The app writes its settings before its first start instead - its admin account `admin` *(with a generated password the page shows, copies or resets)*, DNS on port 5335, and the upstream servers AdGuard Home's own setup suggests *([Quad9](https://quad9.net/), over HTTPS)* - so the wizard never runs. Everything else is AdGuard Home's own defaults *(its own block list on)*, changed in its web interface.
- **Backups** every night at 02:50, and from the page: AdGuard Home's settings file *(block lists, your rules, clients, rewrites, upstream servers - not its statistics or query log)*, as a `.tar.gz` in `Nas_Prog/_adguardhome/backups` *(root's only; the newest 14 kept, set on the page)*. To restore one: stop AdGuard Home *(the dashboard's switch)*, unpack it into `Nas_Prog/_adguardhome/work`, start it again.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_adguardhome`, and survives reinstalls and removal: `work/` *(AdGuard Home's settings file, statistics, query log and block lists - its user's only)*, the admin password, backups, the page's settings and `adguardhome.log` *(kept under 1MB)*.
- Left out: its DHCP server *(your router keeps doing that)*. AdGuard Home's own updater is off: updates come with new versions of the app, and the NAS shows an alert when a new release is out *(checked weekly)*.

## Management page

AdGuard Home's page in the NAS dashboard *(Apps → AdGuard Home)* shows whether it's running, its version, the address to give your router *(while the firewall forwards DNS to it)*, its web interface's addresses, the admin login *(with the password)* and the latest backup - and why it isn't running, if it refused to start. It resets the admin password, backs up now, sets whether its web interface is only reachable through the Nginx app and how many backups are kept, restarts it and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the AdGuard Home app

From the project root directory:

```bash
./build.sh adguardhome
```

This first runs `static/adguardhome` *(once per version: AdGuard Home's release for each architecture, checked against its SHA256, and the run-as helper)*. The WD bin files will be created in `packages/adguardhome/`. To update, change the version in `apkg.rc` and `static/adguardhome/build.sh` *(with the new releases' checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
