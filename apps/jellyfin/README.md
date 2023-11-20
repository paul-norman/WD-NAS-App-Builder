# Jellyfin App

Jellyfin is the volunteer-built media solution that puts you in control of your media. Stream to any device from your own server, with no strings attached. Your media, your server, your way.

Running Jellyfin is currently only possible from a Docker container which not only requires an old Docker install, but also sacrifices any possibility of hardware transcoding. It would be much easier to have a dedicated application for WD NAS devices that will install everything natively.

## Building the Jellyfin app

From the project root directory:

```bash
./build.sh jellyfin
```

The WD bin files will be created in `packages/jellyfin/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.