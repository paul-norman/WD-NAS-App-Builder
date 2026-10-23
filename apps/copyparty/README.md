# copyparty App

[copyparty](https://github.com/9001/copyparty) puts the NAS's shares in a web browser: upload files of any size *(resumable - an interrupted upload carries on where it stopped, and several upload at once)*, download whole folders as a zip, search, see thumbnails of photos *(iPhones' HEIC included)* and videos, play music and videos in the browser, and let people without a login view or upload to chosen folders. The same users and folders also work over **WebDAV** *(e.g. Windows' "Map network drive", macOS's "Connect to Server", phones' file managers)* and, if turned on, **SFTP**. It runs natively on the NAS *(no Docker)*.

- It's at `https://files.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically, with no upload size limit)*, and at `http://<nas-ip>:3923` on the local network unless limited to the Nginx app on the management page.
- **Users** are created on the management page, each with a generated password *(shown, copied or replaced there)*. Logins need the user name as well as the password. The first start creates an `admin` user.
- **Shared folders** are chosen on the management page: any folder on the NAS's volumes *(or a USB drive)*, each with its own address *(e.g. `/photos/`)* and, for each user, what they may do: **View** *(browse and download)*, **Upload only** *(a drop box)*, **View and upload**, **Full** *(also move, rename and delete)* or **Admin**. Everyone without a login can be given View or Upload only. By default, only the `Public` share is shared, with `admin`. `Nas_Prog` *(the apps' own files, with their passwords)* and the volumes' system folders can't be shared.
- **On the NAS**, copyparty runs as its own `copyparty` user *(created by the app, ID 81)* in the NAS's `share` group. WD's shares are open to that group, so copyparty can use any of them, and what it creates is writable by the group *(files 664, folders 775)* - so it can be changed over SMB too, as files copied over SMB can be changed in copyparty.
- **Passwords** are stored hashed *(argon2)* in copyparty's own configuration, which the app writes at every start from the management page's settings. The settings themselves *(with the passwords, so the page can show them)* are readable by root only.
- **Search** finds every file by name, also files copied in by other means *(found at start, then every 6 hours)*, without reading whole files to hash them *(which would take hours on a large share)*. **Music tags** *(artist, album, title: searchable, and shown in its player)* can be turned on, at the cost of reading every music file once.
- **Thumbnails and playback**: Pillow *(with HEIC and AVIF)* for photos, and a static ffmpeg built for the app *(thumbnails of videos, audio spectrograms, and Opus transcoding for its music player)*. AV1 videos get no thumbnail.
- Left out: FTP *(it sends passwords unencrypted)* and SMB *(which copyparty itself advises against - the NAS has its own)*.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_copyparty`, and survives reinstalls and removal: the settings *(users, passwords, folders - root only)* and the password salt, `config/` *(the generated `copyparty.conf`, its sessions and the SFTP server's keys)*, `hist/` *(its database and thumbnails - nothing is written into the shares themselves)*, and `copyparty.log` *(kept under 5MB)*. The shared files stay where they are.
- copyparty doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

copyparty's page in the NAS dashboard *(Apps → copyparty)* shows whether it's running, its version and addresses; adds and removes users, and shows, copies or replaces their passwords; shares folders *(checking that they're on the NAS's volumes and that copyparty can write to them)*, changes who may do what in each, and stops sharing them; limits access to the Nginx app; turns SFTP and music tags on or off; restarts copyparty; and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the copyparty app

From the project root directory:

```bash
./build.sh copyparty
```

This first runs `static/copyparty` *(once per version)*, which installs copyparty and its packages into a portable Python *(each package's checksum locked in `static/copyparty/requirements.txt`)* and builds ffmpeg. The WD bin files will be created in `packages/copyparty/`. To update, change the version in `apkg.rc` and `static/copyparty/build.sh` *(with the new wheel's checksum from PyPI)*, and delete `requirements.txt` so that it's made again. Tests: [`tests/copyparty`](../../tests/copyparty/README.md).

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
