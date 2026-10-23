# Calibre-Web tests

Tests for the [Calibre-Web app](../../apps/calibre-web/README.md), run in containers standing in for the NAS - with the NAS's glibc *(2.31)* and the restrictions WD's firmware has that matter here *(`/dev/random` and `/dev/urandom` readable by root only, no writable `/dev/shm`)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh calibre-web    # first: the app's binaries and its package
tests/calibre-web/run_tests.sh                         # everything, on PHP 7.4 - WD's version
tests/calibre-web/run_tests.sh page --php both         # one group, on PHP 7.4 and 8.5 (the PHP app's)
```

| Group | What it checks |
|---|---|
| `app` | Every library the app's programs need resolves with its own runtime *(only Calibre's desktop-only parts missing)*; the first start *(a library created, a generated admin password, Calibre-Web's default one refused, `/dev/urandom` made readable)*; the ingest folder *(books added, an EPUB made from a text file, other files and duplicates set aside with a note, a file still being copied left for later, the books seen by Calibre-Web)*; Calibre-Web finding the converter, kepubify and ImageMagick; a conversion through Calibre-Web *(EPUB → AZW3)*; PDF output *(Calibre's Chromium, as Calibre-Web's user)*; a cover from a PDF's first page *(ImageMagick + Ghostscript)* and libmagic; a new password; the backups; stopping |
| `page` | The management page's API as the dashboard calls it: refused without a NAS admin's login or with a wrong CSRF token; status and versions; the password; the ingest folder's settings and the folder checks *(not in the library, not in `Nas_Prog`)*; switching to a new library; a new password |
| `package` | The built package's life as WD's installer runs it *(BusyBox `sh`)*: install, initialise and start, its cron jobs and page, then removal - keeping its data and the library |

## How it works

- **The NAS**: the PHP 7.4 test image *([`tests/images`](../images), shared with the other suites - Debian 11, the NAS's glibc)*, with the app's files where the NAS installs them *(`/mnt/HD/HD_a2/Nas_Prog/calibre-web`, the only place its programs run from)* and its prepared binaries *(`packages/static/calibre-web`)* mounted in. A static BusyBox gives it the NAS's `adduser` and `addgroup`. The `page` group runs on PHP 7.4 or 8.5; the others always on 7.4's image.
- **The book**: `bin/make_book.py` makes a small EPUB *(with a cover image and three chapters)* the same every time, rather than downloading one.
- Not covered here *(tested on the NAS)*: WD's 4.14 kernel and the N3710's CPU *(Calibre's converter on a CPU without AVX was checked with an emulator when the app was made)*, the dashboard itself, the Nginx site, and Kobo sync.

Needs Docker and Python 3. Work files *(the app's files, BusyBox, the book, the logs)* go in `$CW_TEST_WORK`, by default `/tmp/calibre-web-tests`.
