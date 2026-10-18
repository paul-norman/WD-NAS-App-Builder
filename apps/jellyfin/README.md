# Jellyfin App

Jellyfin is the volunteer-built media solution that puts you in control of your media. Stream to any device from your own server, with no strings attached. Your media, your server, your way.

This app runs Jellyfin natively on the NAS *(no Docker)*, with **VA-API hardware transcoding** on the Intel models' built-in GPU.

- Jellyfin's web interface is on port `8096` *(the **Open** button in the NAS web UI redirects to it)*.
- Its data, configuration, cache and logs are kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_jellyfin`, and survive reinstalls.
- Jellyfin's own output is in `jellyfin.log` in the app's install directory, and its logs *(incl. one per transcode)* in `_jellyfin/log`.
- Like Plex on the NAS, it runs as `root`.

## How it works

The app combines Jellyfin's portable release *(with its own .NET runtime and web client)* and the portable [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg). Both are built for newer Linux systems than the NAS *(Debian Bullseye, glibc 2.31)*, so a few libraries are replaced with copies built on Bullseye by `static/jellyfin`:

- `libe_sqlite3.so` *(Jellyfin's database engine)* - the same SQLite version and build options as Jellyfin's own copy, which needs a newer glibc.
- `libva`, `libva-drm`, `libdrm` - newer than the NAS's, which jellyfin-ffmpeg needs for VA-API. `bin/ffmpeg` and `bin/ffprobe` are small wrappers that run jellyfin-ffmpeg with them. They still use the NAS's own Intel `i965` driver.

`libe_sqlite3.so` must match the SQLite version bundled with each Jellyfin release, so when updating Jellyfin, also update `VERSION` *(and `SQLITE_VERSION` if it changed)* in `static/jellyfin/build.sh`.

Only the Intel models are supported: Jellyfin 12+ and jellyfin-ffmpeg have no 32-bit ARM builds.

## Hardware transcoding

In Jellyfin's dashboard, under **Playback → Transcoding**:

- **Hardware acceleration:** VA-API, with the device `/dev/dri/renderD128`.
- **Hardware decoding:** H264, HEVC, MPEG2, VC1 and VP8 *(the PR4100 / PR2100's Pentium N3710 decodes 8-bit HEVC only)*.
- **Hardware encoding:** on, with **Allow encoding in HEVC format** off *(this GPU only encodes H.264)*.

Leave **HEVC 10bit** *(and VP9 / AV1)* unticked: this GPU can't decode them, and Jellyfin fails to transcode such files if it's told otherwise. 10-bit HEVC is then decoded in software and encoded on the GPU - about 1.3x real time for a 1080p file on a PR4100, so starts and seeks take a few seconds. 8-bit files are decoded on the GPU too, and clients that can play a file as-is *(e.g. Jellyfin's TV / mobile apps for HEVC)* avoid transcoding entirely.

## Building the Jellyfin app

From the project root directory:

```bash
./build.sh jellyfin
```

The WD bin files will be created in `packages/jellyfin/`. The jellyfin-ffmpeg version is set in `build.sh` and the Jellyfin version in `apkg.rc`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
