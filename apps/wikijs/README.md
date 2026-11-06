# Wiki.js App

[Wiki.js](https://js.wiki/) 3 is a modern wiki: pages written in Markdown, AsciiDoc or a visual editor - by several people at once, live - with content blocks *(diagrams, Draw.io, galleries, page includes...)*, drawings *(Excalidraw)*, page history, comments, approvals, and its own search. It runs natively on the NAS *(no Docker)*, with its own Node.js, and keeps everything in the [PostgreSQL app](../postgresql/README.md) *(which it needs: install that first)*.

- Its address is `https://wikijs.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically - rename it there, e.g. to `wiki`)*. With the Nginx app installed, Wiki.js is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:3010`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:3010` on the local network, over plain HTTP.
- **Its administrator** logs in as `admin@nas.local`, with a password the app generates on its first start *(shown on the management page, which can also change it - even after the email address has been changed in Wiki.js)*. Other people's accounts are added in Wiki.js *(Administration, Users)*: the NAS sends no email unless you set up a mail server in Wiki.js.
- **Its database**: the app makes a login and a database of its own in PostgreSQL *(both `wikijs`; the login owns the database and nothing else)*, and Wiki.js adds what it needs to it *(the `ltree` and `pg_trgm` extensions, its tables in a `wiki` schema)* on its first start - which takes a minute or two. At boot, if PostgreSQL isn't answering yet, Wiki.js waits for it *(up to 5 minutes, in the background)*.
- **Backups**: every day at 03:25, its whole database *(pages and their history, uploaded files, users and settings - Wiki.js keeps them all in it)* with PostgreSQL's `pg_dump`, while it runs, into `Nas_Prog/_wikijs/backups` *(or a folder chosen on the page)*, keeping the newest 7. To restore one: stop Wiki.js, then, as the PostgreSQL app's `postgres` user *(password on its page)*:

  ```sh
  /mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql/bin/pg_restore -h /var/run/postgresql -U postgres \
      -d wikijs --clean --if-exists --no-owner --role=wikijs /path/to/wikijs-<date>.dump
  ```

- It runs as its own user *(`wikijs`, ID 99)*. Its other data is kept in `Nas_Prog/_wikijs`, across reinstalls and removal: `data/` is Wiki.js's own *(its cache)*; its configuration *(`conf/config.yml`, written by the app at every start)*, passwords, settings and backups are root's. Its database stays in PostgreSQL when the app is removed *(drop it there to start afresh: `DROP DATABASE wikijs; DROP ROLE wikijs;`, and delete `Nas_Prog/_wikijs`)*.
- Wiki.js fetches the icons it's asked for from Iconify's service *(once - then kept in its database)* and checks for new versions; the app also checks weekly for a new release *(a NAS alert)*.
- Not included: PDF export and page images through a browser *(Puppeteer - Wiki.js would download Chromium)*, and Pandoc. Git storage *(Administration, Storage)* needs a `git` program: the [Forgejo app](../forgejo/README.md) provides one.
- It's the official release *(its server with its packages, and its web interface - checked by its SHA256)* with Node.js 26. Wiki.js is AGPL-3.0 licensed. Intel models only.
- Moving from Wiki.js 2: export from 2.x *(Administration, Utilities, Export for Wiki.js 3.x)*, then import here *(Administration, Utilities, Import from Wiki.js 2.x)* - see [Wiki.js's guide](https://docs.js.wiki/).

## Building the Wiki.js app

From the project root directory:

```bash
./build.sh wikijs
```

This first runs `static/wikijs` *(once per version)*. The WD bin files will be created in `packages/wikijs/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
