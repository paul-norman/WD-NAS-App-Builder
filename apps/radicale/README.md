# Radicale App

[Radicale](https://radicale.org/) keeps your calendars, reminders and contacts on the NAS and syncs them with phones and computers *(CalDAV and CardDAV: the iPhone's own Calendar, Reminders and Contacts apps, DAVx⁵ on Android, Thunderbird, macOS)*. Everything is plain files *(`.ics` and `.vcf`)*, with no database: easy to back up *(e.g. with the [Kopia app](../kopia/README.md))*. It runs natively on the NAS *(no Docker)*, with its own Python.

- Its address is `https://calendar.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, Radicale is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:5232`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:5232` on the local network, over plain HTTP.
- **Its users are added on the management page** *(Apps → Radicale)*, each with a password *(given, or generated; shown once - only its SHA-512 hash is kept)*. There are none at first, so nobody can log in until one is added. Adding or removing a user needs no restart *(Radicale remembers a successful login for 15 seconds: a removed user or an old password still works that long)*.
- **Each user** gets their own calendar and address book, which nobody else sees, and **every user shares the Family calendar and Family contacts** *(both can be changed by any user)*. Phones find all of them from the address and the user's name. Removing the Family calendar on a phone only removes it from that user: the app puts it back the next night.
- Radicale's own web page *(`https://calendar.<domain>/.web/`, logging in as a user)* creates more calendars and address books, and imports and exports them.
- **Setting up an iPhone**: Settings → Apps → Calendar → Calendar Accounts → Add Account → Other → Add CalDAV Account, with the server `calendar.<domain>`, the user's name and password; then the same in Contacts *(Add CardDAV Account)*. The page shows the exact server to type.
- Removing a user keeps their calendars and contacts *(adding them again with the same name gets them back)*.
- It runs as its own user *(`radicale`, ID 53)*. Its data is kept in `Nas_Prog/_radicale`, across reinstalls and removal: `collections/` is Radicale's storage *(`collection-root/<user>/<collection>/`, the Family ones in `collection-root/family/`)*; the users file, access rules and settings are the app's *(rewritten at every start)*.
- It's Radicale's PyPI release with its packages *(each pinned by its checksums in `static/radicale/requirements.txt`, all pure Python)*, in a portable build of Python 3.14 *(python-build-standalone, trimmed: no IDLE, Tk, tests or pip)*.
- For the Intel models and the ARM ones. The ARM models' kernels use large memory pages, which Python's own ARM build isn't laid out for: there, Python starts through a small launcher of the app's own *(as in the [Python app](../python/README.md))* - checked under emulation, not yet tried on an ARM NAS.

## Building the Radicale app

From the project root directory:

```bash
./build.sh radicale
```

This first runs `static/radicale` *(once per version)*. The WD bin files will be created in `packages/radicale/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
