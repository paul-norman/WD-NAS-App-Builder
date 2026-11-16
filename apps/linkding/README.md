# linkding App

[linkding](https://linkding.link/) is a bookmark manager that's fast and simple: save links with tags and notes, find them again with its search, read them later, share them with the household *(or publicly)*, and import or export them in the browsers' own format. Its [browser extensions](https://linkding.link/browser-extension/) *(Firefox, Chrome)* and its REST API add links from anywhere. It runs natively on the NAS *(no Docker)*, with its own Python, and keeps everything in SQLite. For the Intel models only.

- **Its address** is `https://linkding.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, linkding is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:9099`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:9099` on the local network, over plain HTTP.
- **Its admin user** is `admin`, with a password the app generates on its first start *(shown on the management page, which can also change it)*. linkding has no sign-ups, so nobody else can claim it: add the rest of the household in linkding's admin pages *(Settings → Admin → Users)*, each with bookmarks of their own.
- **Its background worker** fetches each bookmark's favicon and preview image, and can ask the [Wayback Machine](https://web.archive.org/) to archive the pages you save *(linkding's settings)*. Left out: linkding's own page snapshots *(they need a Chromium browser, which its larger Docker image brings)*.
- **Backups** every night at 03:20, and from the page: linkding's own full backup *(its bookmarks, tags, notes, uploaded files, favicons and previews - a `.zip`, with a safe copy of its database while it runs)*, in `Nas_Prog/_linkding/backups` *(root's only; the newest 14 kept, set on the page)*. To restore one: stop linkding *(the dashboard's switch)*, unpack it into `Nas_Prog/_linkding/data`, start it again.
- It runs as its own user *(`linkding`, ID 56)*: its web server *(uWSGI)* and its background worker. Its data is kept in `Nas_Prog/_linkding`, across reinstalls and removal: `data/` is linkding's own *(its database, secret key, uploaded files, favicons and previews - linkding's folder links to it)*; its password, settings and backups are root's.
- Its database is brought up to date at every start *(after an update too)*.
- It's linkding's source as tagged *(GitHub's archive of its tag, pinned by SHA256 in `static/linkding/build.sh`)*, with its packages from its own lock file *(each checked against the lock's checksums)* in a portable build of Python 3.13 - its web interface built once, with Node.js. Its web server, uWSGI, is compiled for the NAS's libraries. The NAS shows an alert when a new release is out *(checked weekly)*.

## Management page

linkding's page in the NAS dashboard *(Apps → linkding)* shows whether it's running *(and its worker)*, its version and its addresses, the admin's password *(and changes it - to one you give, or a new random one)*, and the latest backup. It backs up now, sets whether it's only reachable through the Nginx app and how many backups are kept, restarts it and shows its latest warnings and errors. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the linkding app

From the project root directory:

```bash
./build.sh linkding
```

This first runs `static/linkding` *(once per version: linkding's source, checked against its SHA256, its packages, its web interface, and the run-as helper)*. The WD bin files will be created in `packages/linkding/`. To update, change the version in `apkg.rc` and `static/linkding/build.sh` *(with the new tag archive's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
