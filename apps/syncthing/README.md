# Syncthing App

[Syncthing](https://syncthing.net/) continuously synchronises files between your devices, privately and peer-to-peer *(no cloud service in between)*.

- Syncthing's web GUI is on port `8384` *(the **Open** button in the NAS web UI redirects to it)*.
- Its configuration, keys and database are kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_syncthing`, and survive reinstalls.
- Its log is `syncthing.log` in the app's install directory *(rotated at 1MB)*.
- Devices connect on port `22000` *(TCP and UDP)* and find each other on the local network on UDP port `21027`.
- Like Jellyfin and Plex on the NAS, it runs as `root`. Files it creates are writable by everyone *(like the NAS's shares themselves)*, so the NAS's users can still change them over SMB.
- Syncthing doesn't update itself: updates come with new versions of the app, and the NAS shows an alert *(and sends an email, if set up)* when a new Syncthing release is out, checked weekly.

## Logging in

Log in as `admin`. A random password is generated on first install and saved, readable by root only, in `Nas_Prog/_syncthing/gui_password` on the install volume *(e.g. `cat /mnt/HD/HD_a2/Nas_Prog/_syncthing/gui_password` over SSH)*.

The GUI is reachable from the whole network and Syncthing can read and write anywhere on the NAS, so it always has a password. You can change it in Syncthing's settings *(Actions → Settings → GUI)*; the file is only used for the first install, so update it too if you want to keep it as a reminder.

## Adding folders

The app doesn't create Syncthing's usual default folder: add the folders you want to share in the GUI, using their full path on the NAS, e.g. `/mnt/HD/HD_a2/<share>/<folder>`.

## Building the Syncthing app

From the project root directory:

```bash
./build.sh syncthing
```

The WD bin files will be created in `packages/syncthing/`. The Syncthing version is taken from `apkg.rc`, and each download is checked against the release's published checksums.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
