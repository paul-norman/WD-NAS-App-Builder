# Tautulli App

[Tautulli](https://tautulli.com/) watches a Plex Media Server: who's watching what and how *(direct play or transcoding)*, the history of everything played, statistics and graphs, newsletters, and notifications *(e.g. to the [ntfy app](../ntfy/README.md), or when a stream starts)*. It runs natively on the NAS *(no Docker)*, with its own Python.

- Its address is `https://tautulli.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, Tautulli is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8181`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8181` on the local network, over plain HTTP.
- **It asks for a login from the start**: `admin` and a password the app generates before Tautulli first starts *(shown on the management page, which can also change it)* - Tautulli has none by default, and it shows who watches what. Its own settings can add more *(e.g. logging in with Plex accounts)*.
- **The first time**, Tautulli's setup asks for the Plex server to follow. With [Plex Media Server](https://www.plex.tv/) on the NAS *(the Store lists Plex's own package)*, that's `127.0.0.1`, port `32400`; signing in with your Plex account there gives Tautulli Plex's token.
- Tautulli's own update checks are turned off *(at every start)*: they'd offer an update it can't install itself. The Store updates it.
- It runs as its own user *(`tautulli`, ID 93)*. Its data is kept in `Nas_Prog/_tautulli`, across reinstalls and removal: `data/` is Tautulli's own *(its settings `config.ini`, its database, logs, daily database backups and cache)*; the app's settings and the password it set are root's.
- It's Tautulli's source as released *(GitHub's archive of its tag, pinned by SHA256 in `static/tautulli/build.sh`)*, with a portable build of Python 3.14 *(python-build-standalone, trimmed: no IDLE, Tk, tests or pip)* - Tautulli brings its own packages. Intel models only.

## Building the Tautulli app

From the project root directory:

```bash
./build.sh tautulli
```

This first runs `static/tautulli` *(once per version)*. The WD bin files will be created in `packages/tautulli/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
