# rclone App

[rclone](https://rclone.org/) copies and syncs files with cloud storage - Google Drive, OneDrive, Dropbox, S3 and its many look-alikes *(Backblaze B2, Wasabi, Cloudflare R2...)*, SFTP, WebDAV and over 70 others. The app runs it natively on the NAS *(no Docker)*: its web interface to set up remotes and browse them, jobs on the management page that copy or sync the NAS's shares on a schedule, and the `rclone` command for SSH.

For the Intel and ARM models *(the ARM ones' package is checked under emulation when it's built, but hasn't yet been tried on an ARM NAS)*.

- **Its web interface** is on port 5572 *(or `https://rclone.<domain>` through the Nginx app)*. It asks for a login: user name `admin` and a generated password, which the management page shows, copies or replaces. The browser asks for it first, then rclone's own login page *(the page's Open rclone button fills in its address and user name)*.
- **Remotes** - each cloud storage account - are set up in the web interface *(Remotes → New)*, or with `rclone config` over SSH. For services that log in through a browser *(Google Drive, OneDrive, Dropbox...)*, rclone asks for a token made on a computer with a browser: install rclone there and run the `rclone authorize ...` command it shows. Remotes can be encrypted *(the `crypt` type, wrapping another remote)*.
- **Jobs**, on the management page, copy or sync a folder in the shares to a remote *(or the other way round, or between two remotes)* - daily at a chosen hour, or only when run from the page. **Copy** adds and updates files and never deletes; **Sync** makes the destination the same as the source, deleting what isn't in it. The page shows each job's last run and its log. A job that's still running isn't started again.
- rclone runs as its own `rclone` user *(created by the app, ID 68)* in the NAS's share group: it can use the shares, and what it writes there stays writable by the NAS's users. It can't read the apps' own data *(`Nas_Prog`)*.
- **The `rclone` command** *(over SSH)* uses the app's remotes. Run as root, it runs as the `rclone` user, as the jobs do.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_rclone`, and survives reinstalls and removal: its remotes *(`config/rclone.conf` - their keys and tokens, readable by its user only)*, the jobs, their last runs' logs, the page's settings, the password *(root only)* and `rclone.log` *(kept under 1MB)*.
- **Not yet tried on the NAS**: mounting remotes as folders *(the interface's Mounts page)* - it needs the kernel's FUSE, and rclone runs as its own user. Reloading the page while looking at one remote shows "404 page not found" - go back to the interface's start page *(rclone serves the interface's other pages directly)*.
- rclone and its web interface are rclone's official program *(its interface is built into it: the build saves it as files, so that the interface and the API it calls share one address)*. rclone doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

rclone's page in the NAS dashboard *(Apps → rclone)* shows whether its web interface is running, its version, its addresses, the login *(with the password)* and the remotes set up. It adds, runs and removes jobs, shows their last runs and logs, sets whether the interface is only reachable through the Nginx app, restarts it and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the rclone app

From the project root directory:

```bash
./build.sh rclone
```

This first runs `static/rclone` *(once per version)*. The WD bin files will be created in `packages/rclone/`. To update, change the version in `apkg.rc` and `static/rclone/build.sh` *(with the new release's checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
