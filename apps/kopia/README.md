# Kopia App

[Kopia](https://kopia.io/) backs up the NAS's shares: encrypted *(before anything leaves the NAS)*, deduplicated and compressed, with as many versions ("snapshots") as you choose to keep, to the cloud *(Backblaze B2, Amazon S3 and S3-compatible services, Google Cloud Storage, Azure, Google Drive and more, via rclone)*, another server *(SFTP, WebDAV)* or a USB drive. RAID protects against a failed disk, not against files being deleted or encrypted by ransomware, or the NAS being lost - a copy elsewhere does. It runs natively on the NAS *(no Docker)*.

- Its web interface is at `https://kopia.<domain>` through the [Nginx app](../nginx/README.md) *(added automatically)*. When the Nginx app is installed, Kopia is **only reachable through it** by default - it can read and restore any file on the NAS, so HTTPS is safer. Without the Nginx app *(or with that setting off)* it's also at `http://<nas-ip>:51515` on the local network.
- Log in as `admin`, with the password the app generates *(shown on the management page, which can also replace it)*. It's given to Kopia in its environment, never on a command line.
- Kopia runs as root: it needs to read every share, and to restore files with their owners and permissions.
- Its configuration is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_kopia` *(root only)*, and survives reinstalls and removal: `repository.config` *(where the repository is, and its saved password)*, a cache *(for speed - it can be deleted)*, Kopia's own logs in `logs/`, the server's output `kopia.log`, the web interface's password and the page's settings.
- Kopia schedules the snapshots itself, from the policies set in its interface. Its own update checks are off: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.
- It's the official static program *(downloaded and checked against the release's checksums by the app's build)*.
- For the Intel and ARM models *(the ARM ones' packages haven't yet been tried on an ARM NAS)*.

## First steps

1. Open Kopia *(the management page links to it)* and create a **repository** - where the backups go. You choose the repository's own **password** here: it encrypts everything, and **without it the backups can't be restored**, so keep a copy away from the NAS *(e.g. in a password manager - the Vaultwarden app, but also somewhere that doesn't depend on the NAS)*. Keep a note of the storage's details too *(e.g. the B2 bucket and its key)*.
2. Under **Snapshots → New Snapshot**, add the folders to back up - the shares are under `/mnt/HD/HD_a2` *(e.g. `/mnt/HD/HD_a2/Public`)*.
3. Under **Policies**, set when snapshots are taken and how many to keep *(e.g. hourly, daily, weekly and monthly ones)*, and anything to leave out *(e.g. caches)*.
4. Try a restore: browse a snapshot and restore a file somewhere else, to be sure it works.

To restore after losing the NAS: install Kopia on any computer, connect it to the same repository *(with its password and the storage's details)*, and restore from there.

## Management page

Kopia's page in the NAS dashboard *(Apps → Kopia)* shows whether it's running, its version, addresses and repository, and each folder backed up *(its last snapshot, size, next snapshot, and any file errors last time)*. It shows, copies or replaces the web interface's password, sets whether Kopia is only reachable through the Nginx app, restarts it, and shows its latest output. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Kopia app

From the project root directory:

```bash
./build.sh kopia
```

The WD bin files will be created in `packages/kopia/`. The Kopia version is taken from `apkg.rc`, and the download is checked against the release's published checksums.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
