# Bugsink App

[Bugsink](https://www.bugsink.com/) tracks the errors of your own programs and websites: they report them with [Sentry](https://sentry.io/)'s SDKs *(for Python, JavaScript, PHP, Go, Java... - Bugsink speaks Sentry's protocol)*, and Bugsink groups them into issues, with their stack traces, and the requests and releases they came with. It runs natively on the NAS *(no Docker)*, with its own Python, and keeps everything in SQLite *(no database app needed)*.

- Its address is `https://bugsink.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically)*. With the Nginx app installed, Bugsink is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8000`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8000` on the local network, over plain HTTP.
- **Its admin user** is `admin`, with a password the app generates on its first start *(shown on the management page, which can also change it)*. Other people get an **invitation link** from the admin *(Users, in Bugsink)*: the NAS sends no email, and only admins can invite.
- **Reporting errors to it**: make a team and a project in Bugsink, then give the project's DSN to your program's Sentry SDK. Its DSNs use Bugsink's address - the Nginx app's site when there is one, else the NAS's own address on port 8000 *(the page shows it)* - so programs elsewhere must be able to reach it there. Its address is set at every start: restart Bugsink after setting the Nginx app's domain.
- It runs as its own user *(`bugsink`, ID 92)*: its web server *(gunicorn, two workers)* and its background worker *(which turns the events it takes in into issues)*. Its data is kept in `Nas_Prog/_bugsink`, across reinstalls and removal: `data/` is Bugsink's own *(its databases and the events being taken in)*; its settings *(`conf/bugsink_conf.py`, written by the app at every start)*, password and secret key are root's.
- Its databases are brought up to date at every start *(after an update too)*.
- It's Bugsink as published on PyPI, with its packages *(each version with its checksums, in `static/bugsink/requirements.txt` - delete it to take newer ones)*, in a portable build of Python 3.14. Bugsink's licence is the [PolyForm Shield 1.0.0](https://polyformproject.org/licenses/shield/1.0.0) *(free to use, and to pass on with the licence - but not to make a product competing with Bugsink's)*: it comes with the package. Intel models only.

## Building the Bugsink app

From the project root directory:

```bash
./build.sh bugsink
```

This first runs `static/bugsink` *(once per version)*. The WD bin files will be created in `packages/bugsink/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
