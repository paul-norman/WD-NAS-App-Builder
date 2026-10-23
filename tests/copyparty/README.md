# copyparty tests

Tests for the [copyparty app](../../apps/copyparty/README.md), run in containers standing in for the NAS - with the NAS's glibc *(2.31)* and WD's shares as they are on the NAS *(root's, open to all - 0777 - and the `share` group every NAS user is in)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh copyparty    # first: the app's binaries and its package
tests/copyparty/run_tests.sh                         # everything, on PHP 7.4 - WD's version
tests/copyparty/run_tests.sh page --php both         # one group, on PHP 7.4 and 8.5 (the PHP app's)
```

| Group | What it checks |
|---|---|
| `app` | The first start *(its own user in the share group, an admin user with a generated password, only its hash in copyparty's configuration)*; logins *(a wrong password, none, or a password without its user name refused)*; uploads into a share *(owned by copyparty, writable by the share group, nothing of its own left in the share)*; thumbnails of JPEG, HEIC, video and audio, and FLAC transcoded to Opus; search *(files copied in by other means, with their music tags when turned on)*; access levels *(view, upload only)*, everyone without a login, symbolic links out of a folder; SFTP with the same users; nothing shared *(an empty folder, not copyparty's own working folder)*; stopping |
| `page` | The management page's API as the dashboard calls it: refused without a NAS admin's login or with a wrong CSRF token; status; passwords *(shown, new)*; users *(added, checked names, removed - also from every folder - but never the last)*; shared folders *(shared, changed, renamed; refused: `Nas_Prog`, outside the volumes, `..`, missing, a link to `Nas_Prog`, full access for everyone, names in use or invalid; a folder copyparty can only read flagged)*; listening only for the Nginx app *(SFTP too)*; restarting |
| `package` | The built package's life as WD's installer runs it *(BusyBox `sh`)*: install, initialise and start, its cron jobs, page and file permissions, then removal - keeping its settings |

## How it works

- **The NAS**: the PHP 7.4 test image *([`tests/images`](../images), shared with the other suites - Debian 11, the NAS's glibc)*, with the app's files where the NAS installs them *(`/mnt/HD/HD_a2/Nas_Prog/copyparty`)* and its prepared binaries *(`packages/static/copyparty`)* mounted in. A static BusyBox gives it the NAS's `adduser` and `addgroup`. The `page` group runs on PHP 7.4 or 8.5; the others always on 7.4's image.
- **The media**: a picture *(JPEG and HEIC)*, a video and a FLAC file are made by the test with the app's own Pillow and ffmpeg, rather than downloaded.
- Not covered here *(tested on the NAS)*: the dashboard itself, the Nginx site *(HTTPS, large uploads through it)*, WebDAV clients, and speed on the NAS's CPU.

Needs Docker and Python 3. Work files *(the app's files, BusyBox, the logs)* go in `$CPP_TEST_WORK`, by default `/tmp/copyparty-tests`.
