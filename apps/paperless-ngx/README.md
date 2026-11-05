# Paperless-ngx App

[Paperless-ngx](https://docs.paperless-ngx.com/) turns paper into a searchable archive: documents dropped into a folder *(from a scanner, over SMB, or uploaded in its web interface)* are read with OCR, made into searchable PDFs, tagged, dated and filed - then found again by searching their text. The app runs it natively on the NAS *(no Docker)*. **It needs the [Valkey app](../valkey/README.md)** *(its task queue)* - install that first.

- Its web interface is at `https://paperless.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically)*, and at `http://<nas-ip>:8040/` on the local network unless limited to the Nginx app on the management page. Its own phone apps and other clients use the same address.
- **Logging in**: user name `admin` and a generated password, which the management page shows, copies or replaces. Add more users *(and give them permissions)* in Paperless itself.
- **Adding documents**: drop them in its **consume folder** - `Public/Paperless` by default *(created on first start; any folder in the shares can be chosen on the management page)*. Paperless imports each file, reads it *(OCR, in English by default - German, or both, can be chosen)*, and removes it from the folder *(so the folder chosen is made writable by the NAS's share group, if it isn't already)*. Scanners with "scan to network folder" can save straight into it. Uploading in the web interface works too.
- Your documents are kept in its data folder, next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_paperless-ngx`, and survive reinstalls and removal: the originals and their searchable copies *(`media/`)*, its database *(SQLite)* and search index *(`data/`)*, the page's settings, the secret key and admin password *(root only)*, and `paperless.log`. Back it up *(e.g. with the [Kopia app](../kopia/README.md))*; Paperless's own exporter also works over SSH: `.../paperless-ngx/pl_ctl.sh manage document_exporter /mnt/HD/HD_a2/Public/paperless-export`.
- It runs as its own `paperless` user *(created by the app, ID 96)* in the NAS's share group, as four processes: its web server *(Granian)*, the consumer *(watching the consume folder)*, a task worker *(OCR and the rest, one document at a time)* and a scheduler *(Celery)*. When the NAS starts, it waits for Valkey, then updates its database if a new version needs it.
- **Memory and speed**: it uses about 600MB-1GB, more while reading a document. OCR on the NAS's processor takes from a few seconds to a minute a page.

## What's left out

- **Office documents and e-mails** *(Word, Excel, `.eml`)*: Paperless reads them through two separate services *(Apache Tika and Gotenberg)*, which aren't included. PDFs, images *(scans, photos)* and plain text all work. To add them, run Tika and Gotenberg *(e.g. in the Docker app)* and point Paperless at them with its `PAPERLESS_TIKA_*` settings.
- **Local AI models**: Paperless's AI features *(suggestions, chat)* work with OpenAI-compatible servers or Ollama, set in its own settings - not with models run by Paperless itself *(its "HuggingFace" embedding option needs PyTorch, over 1GB, which isn't included)*.
- Other OCR languages than English and German *(Tesseract's language data isn't included)*.

## How it's built

`static/paperless-ngx` prepares everything, from Paperless's own release *(its ready-made web interface, and the exact package versions it pins, with their checksums)*:

- Paperless in its own Python 3.14 *(a portable build)*, with the document tools its OCR uses: Tesseract *(English, German)*, Ghostscript, pngquant, qpdf, poppler and libmagic from Debian, and unpaper *(page cleaning)* built against a small ffmpeg.
- They need a newer glibc than the NAS's, so the app brings its own *(Debian Trixie's, in `binaries/runtime`)*: every program in it is patched to use it - the NAS's own programs are unaffected *(as for the [Calibre-Web app](../calibre-web/README.md))*. So the app must be installed on the first volume *(`HD_a2`)*.
- Paperless doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Paperless's page in the NAS dashboard *(Apps → Paperless-ngx)* shows whether it's running *(each of its processes, or what it's waiting for while starting)*, its version, its addresses and the admin login *(with the password)*. It sets the consume folder, the documents' language and whether it's only reachable through the Nginx app, gives the admin a new password, restarts Paperless and shows its latest log lines. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Paperless-ngx app

From the project root directory:

```bash
./build.sh paperless-ngx
```

This first runs `static/paperless-ngx` *(once per version)*. The WD bin files will be created in `packages/paperless-ngx/`. To update, change the version in `apkg.rc` and `static/paperless-ngx/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
