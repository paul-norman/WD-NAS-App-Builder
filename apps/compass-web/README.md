# Compass Web App

[Compass Web](https://github.com/haohanyang/compass-web) is MongoDB Compass - MongoDB's own desktop tool - running in the browser: browse databases and collections, query, edit, insert and delete documents, import and export JSON / CSV, see a collection's schema, build aggregations and indexes, and explain queries. It's an unofficial port, built from Compass's own web components. It runs natively on the NAS *(no Docker)*, with its own Node.js, and works on the [MongoDB app](../mongodb/README.md)'s server *(which it needs: install that first)*.

- Its address is `https://compass.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, Compass Web is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8087`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8087` on the local network, over plain HTTP.
- **It asks for a login first**: user `admin`, with a password the app generates *(shown on the management page, which can also change it)*. Once in, it works on MongoDB **as the MongoDB app's administrator** *(all rights, on every database - it reads that password when it starts, and is restarted when it changes)*. Anyone with its login can see and change all of MongoDB's data.
- Not switched on: adding other connections in the browser, its MongoDB shell *(it would run JavaScript on the NAS)* and its AI features *(they'd send queries - or documents - to OpenAI)*.
- It runs as its own user *(`compassweb`, ID 66)*. Its data is kept in `Nas_Prog/_compass-web`, across reinstalls and removal *(its settings and password, root's)*.
- The app checks weekly for a new release *(a NAS alert)*.
- It's the `compass-web` package from npm, with its packages *(each version with its checksum, in `static/compass-web/package-lock.json` - delete it to take newer ones; `@fastify/secure-session` is held at 8.2.0, whose compiled part runs on the NAS's glibc)*, and Node.js 24. Compass Web is licensed under the SSPL *(Server Side Public License - its licence comes with the package)*. Intel models only.

## Building the Compass Web app

From the project root directory:

```bash
./build.sh compass-web
```

This first runs `static/compass-web` *(once per version)*. The WD bin files will be created in `packages/compass-web/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
