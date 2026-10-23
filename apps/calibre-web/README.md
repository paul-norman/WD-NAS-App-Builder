# Calibre-Web App

[Calibre-Web](https://github.com/janeczku/calibre-web) is an e-book library in the browser: browse and search your books, read them in the browser, download them, and manage them *(edit their details, fetch details and covers from Google Books, Amazon and others, upload new books)*. It has users *(each with their own shelves, reading progress and permissions)*, an **OPDS catalogue** for e-reader apps *(e.g. KOReader, Moon+ Reader, Marvin)*, **Kobo sync** *(Kobo e-readers sync with it as they would with Kobo's store, in Kobo's own format through kepubify)*, sending books to e-readers by email *(e.g. a Kindle's address)*, and comics *(CBZ, CB7)*. It runs natively on the NAS *(no Docker)*.

**Conversion between formats** *(e.g. EPUB → AZW3, MOBI, KEPUB, PDF, DOCX)* uses **Calibre 9**'s own converter, included in the app. Calibre 9 needs a newer system library *(glibc 2.34)* than the NAS has *(2.31)*, so the app brings its own copy of the newer one, which only Calibre's programs use - see [How it runs](#how-it-runs).

- It's at `https://books.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically, with large uploads allowed)*, and at `http://<nas-ip>:8083` on the local network unless limited to the Nginx app on the management page. The OPDS catalogue is at `/opds` on the same address.
- **The library** is a Calibre library *(a folder with `metadata.db` and a folder per author)*, on a share: by default `Public/Books/Calibre Library`, created on the first start. The management page can point it at another folder - an existing Calibre library *(e.g. copied from Calibre on a computer)*, or an empty or new folder for a new one. Calibre-Web runs as its own `calibreweb` user *(created by the app, ID 80)*, which owns the library: change it through Calibre-Web, not with Calibre on a computer at the same time *(both would write to the same database)*. Everyone can read the books over the network.
- **The ingest folder** *(off by default, turned on on the management page)*: copy books into it *(by default `Public/Books/Add to library`)*, e.g. over the network, and within a couple of minutes they're added to the library and moved into its `Added` folder - or into `Not added`, with a note next to each saying why *(e.g. already in the library, or not an e-book)*. Optionally, books in other formats also get an EPUB made from them. Files changed in the last minute are left for the next round, in case they're still being copied.
- **Users**: the app sets a generated password for Calibre-Web's `admin` user *(replacing Calibre-Web's well-known default; the management page shows, copies or replaces it)*. Create a user for each person in Calibre-Web *(Admin → Add new user)*. Uploads are on *(for users allowed to upload)*.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_calibre-web`, and survives reinstalls and removal: Calibre-Web's settings and users *(`data/app.db`)*, its log, Calibre's settings, the backups *(every night: `app.db` and the library's `metadata.db` - the books' details, not the book files - keeping 7 days)*, the ingest log, the page's settings and the admin password *(root only)*. The library itself stays on its share.
- Calibre-Web doesn't update itself: updates come with new versions of the app *(which also bring newer Calibre versions)*, and the NAS shows an alert when a new Calibre-Web release is out, checked weekly.
- Left out: Google Scholar as a source of book details *(it brings a browser automation framework along)*, Google Drive and Gmail *(normal email settings work)*, LDAP and OAuth logins, Goodreads *(its API is closed)*, CBR comics *(needs an unrar program)* and DRM removal.

## Management page

Calibre-Web's page in the NAS dashboard *(Apps → Calibre-Web)* shows whether it's running, its versions *(Calibre-Web, Calibre, kepubify)*, its addresses and the OPDS catalogue's, and the library's folder and number of books. It changes the library's folder, turns the ingest folder on or off *(its folder, and whether to make EPUBs)* with its latest results, shows, copies or replaces the admin user's password, limits access to the Nginx app, restarts Calibre-Web, and lists the backups and Calibre-Web's latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## How it runs

- `binaries/python`: a portable Python 3.14 with Calibre-Web and its packages *(installed from a list with each package's checksum, `static/calibre-web/requirements.txt`)*.
- `binaries/calibre`: Calibre 9's Linux release, unchanged except that its programs are patched *(below)*. Calibre-Web is set to use its `ebook-convert` and `calibredb`. PDF output uses Calibre's built-in Chromium, without a GPU.
- `binaries/runtime`: Debian Bookworm's glibc 2.36 and the libraries these programs expect from a system *(about 85MB)*. Every program in the app is patched *(with `patchelf`)* to start with this runtime's loader, and every program and library to look in it first. The loader is found by its full path, so the app only runs where the NAS installs it *(`Nas_Prog` on the first volume)*. Nothing else on the NAS uses the runtime: WD's own programs keep the NAS's glibc.
- Also: kepubify *(Kobo's format)*, ImageMagick *(covers)*, Ghostscript *(covers of PDFs)* and libmagic.
- PDF output needs two things WD's firmware restricts to root: the app makes `/dev/random` and `/dev/urandom` readable by all users *(as on any other Linux system - Chromium won't start without them)*, and Chromium keeps its shared memory in the app's temporary folder *(WD has no `/dev/shm`)*.
- `cw_ctl.sh run <program> [arguments]` runs any of these as Calibre-Web's user, with its environment - e.g. `cw_ctl.sh run /mnt/HD/HD_a2/Nas_Prog/calibre-web/binaries/calibre/ebook-convert book.epub book.azw3` to try a conversion by hand.

## Building the Calibre-Web app

From the project root directory:

```bash
./build.sh calibre-web
```

This first runs `static/calibre-web` *(once per version)*, which downloads Calibre, Python, Calibre-Web's packages and kepubify *(each checked against its checksum)*, collects the runtime and patches everything. The WD bin files will be created in `packages/calibre-web/` *(about 400MB)*. To update Calibre-Web, change the version in `apkg.rc` and `static/calibre-web/build.sh` *(with the new release's checksum)*, and delete `static/calibre-web/requirements.txt` so that it's made again with the new packages. To update Calibre, change its version and checksum in `static/calibre-web/build.sh`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
