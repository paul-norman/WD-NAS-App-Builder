# Icecast tests

Tests for the [Icecast app](../../apps/icecast/README.md), run in containers standing in for the NAS - with the NAS's glibc *(2.31)*, BusyBox's `ip`, and WD's `/dev/urandom` *(readable by root only)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh icecast    # first: the app's binaries and its package
tests/icecast/run_tests.sh                         # everything, on PHP 7.4 - WD's version
tests/icecast/run_tests.sh page --php both         # one group, on PHP 7.4 and 8.5 (the PHP app's)
```

| Group | What it checks |
|---|---|
| `app` | The first start *(its own user, generated passwords, its configuration, no warnings, its admin pages)*; the station from a folder *(its playlist - hidden folders and other files left out - an MP3 stream, each track's title, the station's description with awkward characters, skipping tracks - one with quotes and an ampersand in its name - new music found without stopping)*; a live broadcast alongside it, and a wrong broadcasting password refused; listening only on the NAS itself; stopping |
| `page` | The management page's API as the dashboard calls it: refused without a NAS admin's login or with a wrong CSRF token; status; the admin password; the station *(turned on, skipping, new music, a new address, name and quality, turned off; refused: a bad address, an unknown bitrate, no name, no listeners, `Nas_Prog`, a missing or unreadable folder)*; a new broadcasting password *(the old one refused, the station carrying on)*; listening only for the Nginx app; restarting |
| `package` | The built package's life as WD's installer runs it *(BusyBox `sh`)*: install, initialise and start, its cron jobs, page and file permissions, then removal - keeping its settings |

## How it works

- **The NAS**: the PHP 7.4 test image *([`tests/images`](../images))*, with the app's files where the NAS installs them *(`/mnt/HD/HD_a2/Nas_Prog/icecast`)* and its prepared binaries *(`packages/static/icecast`)* mounted in. A static BusyBox gives it the NAS's `adduser`, `addgroup` and `ip`.
- **The music**: tagged MP3s and a WAV with an awkward name, made by the test with Python and the app's own ffmpeg.
- **A live broadcast**: curl sends an MP3 to Icecast as broadcasting software does *(a chunked `PUT`)*.
- Not covered here *(tested on the NAS)*: the dashboard itself, the Nginx site, real players and broadcasting software, and the NAS's CPU with a large music folder.

Needs Docker and Python 3. Work files go in `$ICE_TEST_WORK`, by default `/tmp/icecast-tests`.
