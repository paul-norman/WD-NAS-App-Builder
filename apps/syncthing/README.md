# Syncthing App

[Syncthing](https://syncthing.net/) continuously synchronises files between your devices, privately and peer-to-peer *(no cloud service in between)*.

- Syncthing's web GUI is on port `8384`.
- Its configuration, keys and database are kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_syncthing`, and survive reinstalls.
- Its log is `syncthing.log` in the app's install directory *(rotated at 1MB)*.
- Devices connect on port `22000` *(TCP and UDP)* and find each other on the local network on UDP port `21027`.
- Like Jellyfin and Plex on the NAS, it runs as `root`. Files it creates are writable by everyone *(like the NAS's shares themselves)*, so the NAS's users can still change them over SMB.
- Anonymous usage reporting is declined on a fresh install, rather than Syncthing asking when its GUI is first opened.
- Syncthing doesn't update itself: updates come with new versions of the app, and the NAS shows an alert *(and sends an email, if set up)* when a new Syncthing release is out, checked weekly.

## Management page

Syncthing's page in the NAS dashboard *(Apps → Syncthing)* shows whether it's running, its version, the NAS's device ID *(which other devices add it with)*, its folders and their sync state, and the other devices and whether they're connected. It links to Syncthing, can restart it, can turn anonymous usage reporting off, and shows and changes the GUI password *(see below)*. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Logging in

Log in as `admin`. A random password is generated on first install and saved, readable by root only, in `Nas_Prog/_syncthing/gui_password` on the install volume. The management page shows it, and can change it to one you choose or a generated one *(e.g. `cat /mnt/HD/HD_a2/Nas_Prog/_syncthing/gui_password` over SSH works too)*.

The GUI is reachable from the whole network and Syncthing can read and write anywhere on the NAS, so it always has a password. It can also be changed in Syncthing's own settings *(Actions → Settings → GUI)*, but Syncthing only stores it hashed, so the management page can't show a password changed there.

## Adding folders

The app doesn't create Syncthing's usual default folder: add the folders you want to share in the GUI, using their full path on the NAS, e.g. `/mnt/HD/HD_a2/<share>/<folder>`.

## Building the Syncthing app

From the project root directory:

```bash
./build.sh syncthing
```

The WD bin files will be created in `packages/syncthing/`. The Syncthing version is taken from `apkg.rc`, and each download is checked against the release's published checksums.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
