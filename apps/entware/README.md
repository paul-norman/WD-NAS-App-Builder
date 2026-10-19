# Entware App

[Entware](https://entware.net/) adds the `opkg` package manager to the NAS, with thousands of extra command line tools *(e.g. `git`, `htop`, `rsync`, `tmux`, `python3`)*. It is used over SSH:

```sh
opkg update               # refresh the package list
opkg find '*name*'        # search for a package
opkg install <package>    # install a package
opkg list-installed       # show installed packages
opkg upgrade              # update installed packages
```

- Entware's root is kept in `Nas_Prog/_entware/opt` and mounted on `/opt`. WD's own `/opt/wd` *(used by WD's services)* is linked back in.
- Root's home folder *(SSH keys, shell history...)* is kept in `Nas_Prog/_entware/home` and linked from `/home/root`, so it survives reboots.
- `/opt/bin` and `/opt/sbin` are put first in the `PATH` *(via `/etc/profile`)*, so Entware's versions of commands are used over the NAS's own.
- `/opt/sbin/reboot` stops Entware's services and unmounts `/opt` before rebooting the NAS.
- Services installed with packages *(`/opt/etc/init.d`)* are started and stopped with the app.
- The NAS shows an alert *(and sends an email, if set up)* when package updates are available, checked weekly.
- Removing the app keeps `Nas_Prog/_entware`, so reinstalling it brings everything back.

## Management page

Entware's page in the NAS dashboard *(Apps → Entware)* can:

- check for package updates and install them all
- search for packages, and install or remove them
- start, stop and restart the services installed with packages *(`/opt/etc/init.d`)*
- switch package downloads to HTTPS, if they still use HTTP

Installs, removals and updates run in the background, and the page shows their progress. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Moving from the WDCommunity Entware app

This app replaces the older Entware app from [WDCommunity](https://github.com/WDCommunity/wdpksrc) *(version 20.11.17, which uses the same package name)*, and can be installed directly over it: it moves the existing Entware root *(`/shares/Volume_1/entware`, or the `entware.bak` that the older app's upgrade scripts rename it to)* and root's home folder *(`Nas_Prog/entware/home`)* into `Nas_Prog/_entware`, so installed packages and SSH keys carry on as they are.

Back up root's home folder first anyway *(e.g. `cp -a /mnt/HD/HD_a2/Nas_Prog/entware/home /mnt/HD/HD_a2/root-home-backup`)*, and don't *uninstall* the older app before installing this one: its removal script deletes the Entware root.

## Fresh installs and HTTPS

A fresh install runs Entware's official installer *(bundled when the app is built)*. The installer bootstraps over plain HTTP, as there are no CA certificates yet, so the app then installs `wget-ssl` and `ca-bundle` and switches Entware's package downloads to HTTPS *(`use_https.sh`, which first updates the installed packages - `wget-ssl` can't start with older libraries - and switches back if HTTPS downloads don't work)*. Installs taken over from the WDCommunity app are switched too, and if the switch fails, the management page can retry it.

## Building the Entware app

From the project root directory:

```bash
./build.sh entware
```

The WD bin files will be created in `packages/entware/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
