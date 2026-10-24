# Audiobookshelf tests

Tests for the [Audiobookshelf app](../../apps/audiobookshelf/README.md), run in containers standing in for the NAS - with the NAS's glibc *(2.31)* and WD's shares as they are on the NAS *(root's, open to all - 0777 - and the `share` group every NAS user is in)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh audiobookshelf    # first: the app's binaries and its package
tests/audiobookshelf/run_tests.sh                         # everything, on PHP 7.4 - WD's version
tests/audiobookshelf/run_tests.sh page --php both         # one group, on PHP 7.4 and 8.5 (the PHP app's)
```

| Group | What it checks |
|---|---|
| `app` | The first start *(its own user in the share group; the root user claimed by the app while Audiobookshelf answers on the NAS itself only; a generated password, root's only)*; a library scanned *(title, author, chapters, duration - ffprobe - its cover from the files' embedded art, resized to WebP; accent-insensitive search - nunicode)*; playing, transcoded to HLS for a player; merging an audiobook into M4B; a podcast feed read and an episode downloaded by ffmpeg *(from a feed on the NAS itself, allowed as the page's setting does)*, changeable over SMB; a backup; a new password; stopping, and starting again with the same root user |
| `page` | The management page's API as the dashboard calls it: refused without a NAS admin's login or with a wrong CSRF token; status; the root password; its libraries *(items, a folder it can't open flagged)*; its login to Audiobookshelf kept and reused *(root only)*; a new password; podcast feeds on the home network *(a bad host name refused)*; listening only for the Nginx app; restarting |
| `package` | The built package's life as WD's installer runs it *(BusyBox `sh`)*: install, initialise and start, its cron jobs, page and file permissions, then removal - keeping its database and root password |

## How it works

- **The NAS**: the PHP 7.4 test image *([`tests/images`](../images))*, with the app's files where the NAS installs them *(`/mnt/HD/HD_a2/Nas_Prog/audiobookshelf`)* and its prepared binaries *(`packages/static/audiobookshelf`)* mounted in. A static BusyBox gives it the NAS's `adduser` and `addgroup`.
- **Something to listen to**: an audiobook *(two tagged MP3 chapters with a cover)*, another with an accented title, and a podcast feed with one episode served on port 8099 - made by the test with Python and the app's own ffmpeg.
- Not covered here *(tested on the NAS)*: the dashboard itself, the Nginx site, its phone apps, and the NAS's CPU with a large library.

Needs Docker and Python 3. Work files go in `$ABS_TEST_WORK`, by default `/tmp/audiobookshelf-tests`.
