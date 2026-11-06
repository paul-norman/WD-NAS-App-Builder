# pgweb App

[pgweb](https://github.com/sosedoff/pgweb) is a web interface for PostgreSQL: browse the tables and their rows, run queries, see the structure and export results *(CSV, JSON, XML)*. It runs natively on the NAS *(no Docker)*, for the [PostgreSQL app](../postgresql/README.md)'s databases.

- Its address is `https://pgweb.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, pgweb is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8081`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8081` on the local network, over plain HTTP.
- It asks for a user name and password first: `admin` and the password the app generates *(shown on the management page, which can also change it)*. Through Nginx, Nginx checks it. On the network, pgweb's own login checks it too - its password is then on pgweb's command line, which other programs on the NAS can read, so HTTPS through the Nginx app is safer.
- That first password can be switched off on the page *("Ask for this password first")*, leaving only PostgreSQL's own login. Keep it on if pgweb's address can be reached from the internet: without it, anyone who reaches pgweb gets its connection form, which can connect to any server *(e.g. to probe the local network)*, not just the NAS's PostgreSQL.
- Then pgweb asks which database to open: host `127.0.0.1`, port `5432`, and a database user with its password *(e.g. one made on the PostgreSQL app's page, or `postgres`)*. Each visitor logs in to PostgreSQL separately.
- A **read only** setting on the page stops queries changing anything.
- It runs as its own user *(`pgweb`, ID 86)*, with no SSH tunnels to other machines. Its settings, password and saved queries are kept in `Nas_Prog/_pgweb`, across reinstalls and removal.
- It's the official static program. Its release publishes no checksums, so the build checks it against the SHA256 pinned in `static/pgweb/build.sh`. The NAS shows an alert when a new release is out *(checked weekly)*.
- For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)*. The PostgreSQL app is for the Intel models only, so on an ARM NAS pgweb is for PostgreSQL servers elsewhere on the network.

## Building the pgweb app

From the project root directory:

```bash
./build.sh pgweb
```

The WD bin files will be created in `packages/pgweb/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
