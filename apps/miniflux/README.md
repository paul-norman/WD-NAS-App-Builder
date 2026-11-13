# Miniflux App

[Miniflux](https://miniflux.app/) is a minimalist feed reader: RSS, Atom and JSON Feed subscriptions, read in a fast, plain web interface *(also on phones - it installs as a web app)*, with categories, search, starred articles, full-content fetching for feeds that only give a summary, and integrations *(e.g. Wallabag, Pocket-style "read later" services, or the [ntfy app](../ntfy/README.md) through its webhooks)*. Phone and desktop apps that speak the Fever or Google Reader APIs *(e.g. Reeder, NetNewsWire, FeedMe)* can use it too - turn them on in its Settings, Integrations. It runs natively on the NAS *(no Docker)* and keeps everything in the [PostgreSQL app](../postgresql/README.md) *(which it needs: install that first)*.

- Its address is `https://miniflux.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically - rename it there, e.g. to `news`)*. With the Nginx app installed, Miniflux is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8099`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8099` on the local network, over plain HTTP.
- **Its administrator** logs in as `admin`, with a password the app generates on its first start *(shown on the management page, which can also change it)*. Other people's accounts are added in Miniflux *(Settings, Users)*.
- **Feeds on the local network** *(e.g. another app's RSS on the NAS)* are refused by default, so that a feed's address can't be used to reach into the network - turn them on with the page's setting.
- **Its database**: the app makes a login and a database of its own in PostgreSQL *(both `miniflux`; the login owns the database and nothing else)*, and Miniflux makes its tables on its first start. At boot, if PostgreSQL isn't answering yet, Miniflux waits for it *(up to 5 minutes, in the background)*.
- It checks its feeds every hour *(4 at a time, a lighter load than its defaults)*, and keeps read articles for 60 days, unread ones for 180 *(Miniflux's defaults; starred ones are kept)*.
- **Backups**: every day at 03:35, its whole database *(feeds, articles, users and settings)* with PostgreSQL's `pg_dump`, while it runs, into `Nas_Prog/_miniflux/backups` *(or a folder chosen on the page)*, keeping the newest 7. To restore one: stop Miniflux, then, as the PostgreSQL app's `postgres` user *(password on its page)*:

  ```sh
  /mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql/bin/pg_restore -h /var/run/postgresql -U postgres \
      -d miniflux --clean --if-exists --no-owner --role=miniflux /path/to/miniflux-<date>.dump
  ```

- It runs as its own user *(`miniflux`, ID 63)*. Its other data is kept in `Nas_Prog/_miniflux`, across reinstalls and removal: its configuration *(`conf/miniflux.conf`, written by the app at every start - readable by its user's group only)*, passwords, settings, backups and `miniflux.log` *(kept under 1MB)* are root's. Its database stays in PostgreSQL when the app is removed *(drop it there to start afresh: `DROP DATABASE miniflux; DROP ROLE miniflux;`, and delete `Nas_Prog/_miniflux`)*.
- It's Miniflux's official static program *(checked by its published SHA256)*. Miniflux doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly. For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)*.

## Management page

Miniflux's page in the NAS dashboard *(Apps → Miniflux)* shows whether it's running, its version, its addresses and its database, and the administrator's password *(show, copy, or a new one)*. It sets whether it's only reachable through the Nginx app and whether feeds on the local network are allowed, sets the backups' folder and how many to keep, backs up now and lists the backups, restarts Miniflux and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Miniflux app

From the project root directory:

```bash
./build.sh miniflux
```

This first runs `static/miniflux` *(once per version)*. The WD bin files will be created in `packages/miniflux/`. To update, change the version in `apkg.rc` and `static/miniflux/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
