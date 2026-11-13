# Adminer App

[Adminer](https://www.adminer.org/) manages databases in a web browser: tables and their rows, queries, structure, users and permissions, imports and exports. One interface for the NAS's MariaDB *(WD's own, or the [MariaDB app](../mariadb/README.md)'s)*, the [PostgreSQL app](../postgresql/README.md) and the [Valkey app](../valkey/README.md) *(with Adminer's own Redis driver plugin, included)* - an alternative to the [phpMyAdmin app](../phpMyAdmin/README.md) for MariaDB, and to the [kvweb app](../kvweb/README.md) for Valkey. It runs natively on the NAS *(no Docker)*.

- Its address is `https://adminer.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, Adminer is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8084`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8084` on the local network, over plain HTTP.
- Through Nginx, it asks for a user name and password first: `admin` and the password the app generates *(shown on the management page, which can also change it)* - a second lock in front of Adminer's own login, as Adminer pages exposed to the internet are often probed. On the network, there's only Adminer's own database login *(which limits failed attempts)*.
- That first password can be switched off on the page *("Ask for this password first")*, leaving only the databases' own logins. Keep it on if Adminer's address can be reached from the internet: without it, anyone who reaches Adminer gets its login form, which can connect to any server *(e.g. to probe the local network)*, not just the NAS's databases.
- Then Adminer asks for a database login: server `127.0.0.1`, with a MariaDB user *(e.g. phpMyAdmin's `admin`)*, a PostgreSQL user *(e.g. one made on the PostgreSQL app's page, or `postgres`)*, or for Valkey *(System: Redis)* the username `default` and the password on the Valkey app's page.
- Its Redis driver is the plugin as released on adminer.org *(the repository's own copy only works with Adminer's development version - also checked against a pinned SHA256)*, in `www/adminer-plugins/` next to Adminer. It talks to Valkey over a plain socket, so it needs no PHP extension: it works on either PHP.
- It's the official single PHP file *(every driver and language - its release publishes no checksums, so the build checks it against the SHA256 pinned in `static/adminer/build.sh`)*, run by PHP's own web server, with 4 workers, as its own user *(`adminer`, ID 88)*, never as root. Imports of up to 512MB go through.
- Its PHP: the [PHP app](../php/README.md)'s PHP 8.5 if it's installed *(MariaDB, PostgreSQL and SQLite)*, else the NAS's own PHP 7.4 *(MariaDB and SQLite only - it has no PostgreSQL driver)*. After installing the PHP app, restart Adminer *(its page)* to move to it.
- Its password and sessions are kept in `Nas_Prog/_adminer`, across reinstalls and removal. The NAS shows an alert when a new release is out *(checked weekly)*.
- For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)*.

## Building the Adminer app

From the project root directory:

```bash
./build.sh adminer
```

The WD bin files will be created in `packages/adminer/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
