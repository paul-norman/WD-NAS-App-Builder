# Tests

Tests that run without a NAS: each suite starts containers standing in for it *(the NAS's PHP and glibc versions, BusyBox's `sh`)*, installs what it tests as the NAS does, and checks it. Each prints `PASS` / `FAIL` lines and a summary per group, keeps a log of everything, and exits non-zero if anything failed.

| Suite | Tests | Run |
|---|---|---|
| [`store`](store/README.md) | The [Store app](../apps/store/README.md): repositories and signatures, installing apps and recipes, the page | `tests/store/run_tests.sh [group] [--php 7.4\|8.5\|both]` |
| [`copyparty`](copyparty/README.md) | The [copyparty app](../apps/copyparty/README.md): logins, uploads into WD's shares, thumbnails and transcoding, search, access levels, SFTP, the page, the package | `tests/copyparty/run_tests.sh [group] [--php 7.4\|8.5\|both]` |
| [`calibre-web`](calibre-web/README.md) | The [Calibre-Web app](../apps/calibre-web/README.md): its bundled runtime, the ingest folder, conversions, the page, the package | `tests/calibre-web/run_tests.sh [group] [--php 7.4\|8.5\|both]` |

- [`images`](images): the PHP 7.4 *(WD's own version - Debian 11, the NAS's glibc)* and 8.5 *(the [PHP app](../apps/php/README.md)'s)* images the suites run in, built the first time they're needed *(`nas-test-php74`, `nas-test-php85`)*.
- What's tested here is what doesn't need the NAS's hardware or firmware; each suite's README says what's left for the NAS.

Needs Docker on Linux *(e.g. WSL)*, Python 3 and the apps built for the PR4100 *(each suite says which)*.
