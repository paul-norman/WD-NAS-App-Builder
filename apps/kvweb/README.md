# kvweb App

[kvweb](https://github.com/natrimmer/kvweb) is a web interface for Valkey and Redis: browse and search the keys, see and edit their values, and see the server's information. It runs natively on the NAS *(no Docker)*, for the [Valkey app](../valkey/README.md).

- Its address is `https://kvweb.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically - it's needed: kvweb only listens on the NAS itself, `127.0.0.1:8082`)*.
- kvweb has no login of its own, so its address asks for a user name and password first: `admin` and the password the app generates *(shown on the management page, which can also change it)*. Nginx checks it.
- It logs in to Valkey by itself, with the password from the Valkey app's configuration *(given to it in its environment, never on a command line)*. Changing Valkey's password on its page restarts kvweb with the new one.
- A **read only** setting on the page stops changes and deletions. Emptying a whole database *(FLUSHDB / FLUSHALL)* is always blocked.
- At boot it waits for Valkey to answer *(in the background, for up to 10 minutes)*, and once running it reconnects by itself if Valkey restarts.
- It runs as its own user *(`kvweb`, ID 87)*. Its settings and password are kept in `Nas_Prog/_kvweb`, across reinstalls and removal.
- On the Intel models it's the official static program *(checked against the SHA256 its release publishes, pinned in `static/kvweb/build.sh`)*. The NAS shows an alert when a new release is out *(checked weekly)*. kvweb is a young project from one developer, under the AGPL-3.0.
- For the Intel and ARM models, as the Valkey app. kvweb has no release for the ARM ones' 32-bit processors, so there it's built from the same release's source *(its web app, then kvweb with Go - prepared by `static/kvweb`)*. The ARM packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS.

## Building the kvweb app

From the project root directory:

```bash
./build.sh kvweb
```

The WD bin files will be created in `packages/kvweb/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
