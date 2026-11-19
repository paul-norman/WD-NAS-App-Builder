# changedetection.io App

[changedetection.io](https://changedetection.io/) watches web pages for changes and alerts you: a price dropping, something back in stock, a new document on a council's site, a changed timetable. Each watch can look at the whole page or just part of it *(a CSS or XPath selector, a price, JSON from an API)*, every few minutes or once a day, and alerts can go to the [ntfy app](../ntfy/README.md), email, Discord, Telegram and many more. It runs natively on the NAS *(no Docker)*, with its own Python.

- Its address is `https://changes.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, changedetection.io is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:5000`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:5000` on the local network, over plain HTTP.
- **It asks for a password** from the start: the app makes one at installation. The management page *(Apps → changedetection.io)* shows it and sets a new one *(typed, or generated)*. It's set there, not in changedetection.io's own settings.
- **Pages that need a browser** *(built by JavaScript, or behind a login or a click)*: install the **[Browser for changedetection.io](../../recipes/changedetection-browser/README.md)** recipe *(Store → Recipes; it needs the [Docker app](../docker/README.md))* - Google Chrome in a container, which the app then uses by itself. A watch set to *Chrome/Javascript* *(in its Request tab)* loads its page there, and browser steps, screenshots and the visual selector work. Or set a browser on another machine on the page *(its Chrome DevTools address)*. Without one, every page is fetched with plain HTTP requests - enough for most.
- **Patchright** drives the browser, in place of the Playwright changedetection.io normally uses: the same API, but it hides what usually gives an automated browser away *(it doesn't switch on Chrome DevTools' Runtime and Console domains, which sites can detect)* - so fewer sites refuse it.
- **ntfy alerts**: with an ntfy topic set on the page *(and the ntfy app installed)*, every change is also sent there - alongside the alert addresses set in changedetection.io itself.
- **Local network pages** *(a router's, a printer's)* are refused unless allowed on the page: anyone who can add a watch could otherwise look at devices on your network.
- It runs as its own user *(`changedetection`, ID 51)*. Its data is kept in `Nas_Prog/_changedetection`, across reinstalls and removal: `datastore/` is changedetection.io's own *(its settings, the watches and every version of their pages)*; `settings` and `password` are the app's.
- It's changedetection.io's PyPI release with its packages *(each pinned by its checksums in `static/changedetection/requirements.txt`)*, plus Patchright, in a portable build of Python 3.14 *(python-build-standalone, trimmed: no IDLE, Tk, tests or pip)*. It's large *(about 600MB, much of it changedetection.io's AI features - LiteLLM - and Patchright's own Node.js)*.
- For the Intel models only: several of its packages, and Patchright, have no 32-bit ARM builds.

## Building the changedetection.io app

From the project root directory:

```bash
./build.sh changedetection
```

This first runs `static/changedetection` *(once per version)*. The WD bin files will be created in `packages/changedetection/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
