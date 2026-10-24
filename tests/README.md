# Tests

Tests that run without a NAS: each suite starts containers standing in for it *(the NAS's PHP and glibc versions, BusyBox's `sh`)*, installs what it tests as the NAS does, and checks it. Each prints `PASS` / `FAIL` lines and a summary per group, keeps a log of everything, and exits non-zero if anything failed.

| Suite | Tests | Run |
|---|---|---|
| [`apps`](apps/README.md) | **Every app**'s package through its life as WD's installer runs it: install, start and its port or command, file permissions, its page, stop, clean, remove keeping its data | `tests/apps/run_tests.sh [app ...]` |
| [`store`](store/README.md) | The [Store app](../apps/store/README.md): repositories and signatures, installing apps and recipes, the page | `tests/store/run_tests.sh [group] [--php 7.4\|8.5\|both]` |
| [`copyparty`](copyparty/README.md) | The [copyparty app](../apps/copyparty/README.md): logins, uploads into WD's shares, thumbnails and transcoding, search, access levels, SFTP, the page, the package | `tests/copyparty/run_tests.sh [group] [--php 7.4\|8.5\|both]` |
| [`wireguard`](wireguard/README.md) | The [WireGuard app](../apps/wireguard/README.md): a real tunnel from a stand-in phone to the NAS and a device at home, access levels, the page, the package | `tests/wireguard/run_tests.sh [group] [--php 7.4\|8.5]` |
| [`icecast`](icecast/README.md) | The [Icecast app](../apps/icecast/README.md): the server, the station from a folder (ezstream and ffmpeg), live broadcasts, the page, the package | `tests/icecast/run_tests.sh [group] [--php 7.4\|8.5\|both]` |
| [`audiobookshelf`](audiobookshelf/README.md) | The [Audiobookshelf app](../apps/audiobookshelf/README.md): the root user claimed, libraries and scans, streaming, M4B merging, podcast downloads, the page, the package | `tests/audiobookshelf/run_tests.sh [group] [--php 7.4\|8.5\|both]` |
| [`calibre-web`](calibre-web/README.md) | The [Calibre-Web app](../apps/calibre-web/README.md): its bundled runtime, the ingest folder, conversions, the page, the package | `tests/calibre-web/run_tests.sh [group] [--php 7.4\|8.5\|both]` |

- [`images`](images): the PHP 7.4 *(WD's own version - Debian 11, the NAS's glibc)* and 8.5 *(the [PHP app](../apps/php/README.md)'s)* images the suites run in, built the first time they're needed *(`nas-test-php74`, `nas-test-php85`)*.
- What's tested here is what doesn't need the NAS's hardware or firmware; each suite's README says what's left for the NAS.

Needs Docker on Linux *(e.g. WSL)*, Python 3 and the apps built for the PR4100 *(each suite says which)*.
