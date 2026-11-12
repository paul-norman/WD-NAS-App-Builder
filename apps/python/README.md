# Python App

Makes **Python 3.14** the NAS's `python3`, in place of WD's own Python 3.9, with `pip`, virtual environments (`venv`) and [uv](https://docs.astral.sh/uv/). It's a portable build of Python *([python-build-standalone](https://github.com/astral-sh/python-build-standalone), the builds uv uses)*, depending only on the NAS's system library. For the Intel models and the ARM ones *(python-build-standalone's own ARMv7 build, which needs glibc 2.17 or newer)*.

- When the app starts *(at every boot)* it points `/usr/bin/python3` at Python 3.14, and adds `python3.14`, `pip3`, `pydoc3`, `uv` and `uvx`. Stopping or removing the app puts WD's `python3` back *(wherever it was on that NAS: the app notes where `python3` led before its first switch of each boot)*. WD's own files are never changed - only those links, which are in RAM anyway.
- **WD's scripts were checked before making this app**: WD's Python has no extra packages, only the standard library, and the scripts that use it - `wsdd` *(Windows network discovery)*, `mysql_reset.py` and a couple of one-line JSON reads - use nothing that's been removed since Python 3.9. Both compile with every warning treated as an error, and `wsdd` was run on 3.14. WD's boot scripts and `wsdd` start before the apps, so they always run on WD's own Python 3.9 anyway; only what WD runs later uses Python 3.14.
- There's no plain `python` command: a few of WD's scripts ask for it, but they're Python 2 code that has never been able to run on OS5 - with a `python` they'd start and crash instead.
- The management page can switch `python3` back to WD's Python 3.9 *(and back again)* as a safety net - the choice is kept across reboots and reinstalls.

## Packages

Install packages into a **virtual environment**, kept wherever you like - e.g. under `/home/root` *(persistent with the [Entware app](../entware/README.md))* or on a share. Packages installed into the app's Python itself would be lost with its next update, so `pip` refuses that *(add `--break-system-packages` to do it anyway)*:

```sh
python3 -m venv /home/root/venvs/myproject
/home/root/venvs/myproject/bin/pip install requests
/home/root/venvs/myproject/bin/python myscript.py
```

Or with uv, which also runs tools and single scripts with their own packages:

```sh
uv venv /home/root/venvs/myproject
uvx ruff check myscript.py
uv run --with requests myscript.py
```

- Virtual environments use the app's Python, so they keep working across the app's updates within 3.14; a new line *(e.g. 3.15)* needs them made again.
- The NAS has no compiler, so packages come from ready-built wheels - almost all popular packages have them *(the Intel models' glibc is 2.31, which `manylinux_2_28` wheels suit)*. On the ARM models, packages need wheels for 32-bit ARM (`armv7l`), which fewer packages publish.
- Programs using `curses` *(full-screen terminal programs)* need a terminal database, which the NAS doesn't have: install Entware's `ncurses-terminfo` and set `TERMINFO_DIRS=/opt/share/terminfo`. Python's own interactive prompt doesn't need it.

## Management page

The Python app's page in the NAS dashboard *(Apps → Python)* shows which Python `python3` is, the app's and WD's versions, pip and uv, the commands the app has added, and which Python `wsdd` is running on. It switches `python3` between the app's Python and WD's. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

Updates come with new versions of the app *(the NAS shows an alert when a new 3.14 release is out, checked weekly)*.

## Building the Python app

From the project root directory:

```bash
./build.sh python
```

The WD bin files will be created in `packages/python/`. To update, change the version in `apkg.rc` and the python-build-standalone release and checksum in `build.sh`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
