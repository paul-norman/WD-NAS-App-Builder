"""
Connects the arr stack's apps to each other, as a person would in their
settings pages - run by hooks/wire.sh after an install, an update or a change
of settings (the Store's post_install, post_update and post_change hooks), with
.env's values in the environment. Everything it does can be done again: it only
adds what's missing and updates what changed.

 - the data folder's layout (torrents/, usenet/, media/ - one file system, so
   downloads are hard-linked into the library), or library folders of your own
   elsewhere (finished downloads copied into them)
 - one user name and password for every web interface (qBittorrent, Prowlarr,
   Sonarr, Radarr, Lidarr, Bookshelf, Bazarr, SABnzbd), and - at install -
   their anonymous usage data (sent to their developers by default) switched
   off
 - qBittorrent: its save folder, a category per app, its listening port, how
   long it seeds (AFTER_IMPORT)
 - Sonarr, Radarr (and Lidarr, Bookshelf): their library folders, qBittorrent
   (and SABnzbd) as download clients - each removing a finished download once
   qBittorrent stops seeding it - and renaming (RENAME)
 - Prowlarr: Sonarr, Radarr (and Lidarr, Bookshelf) as applications - indexers
   added in Prowlarr reach them all - and FlareSolverr as a proxy for indexers
   tagged "flaresolverr"
 - SABnzbd: its folders, a category per app, the address the other apps reach
   it at
 - Bazarr: Sonarr and Radarr, a subtitle language, subtitle sources that need
   no account
 - Seerr: Sonarr and Radarr (its own setup page then only asks for the media
   server - Jellyfin or Plex)
 - searching (SEARCH): automatic - for what's added or requested, and new
   releases (RSS) - or only by hand (Prowlarr's sync profile for the indexers
   it gives the apps, and Seerr's requests added without a search)
 - Radarr, with FLAT_FILMS: a script it runs after each import, filing films
   without a folder of their own
 - Sonarr, Radarr (and Lidarr): the media server (MEDIA_SERVER - Plex, Jellyfin
   or Emby), told about each new file
 - ntfy (NTFY_TOPIC, with the ntfy app on the NAS): Sonarr, Radarr, Lidarr,
   Bookshelf, Prowlarr and Seerr send their notifications to a topic -
   imports, failures, health problems, requests
 - Recyclarr (RECYCLARR): the TRaSH Guides' quality profiles in Sonarr and
   Radarr (1080p and 4K) - synced at once, then daily - and the chosen one
   (QUALITY) for Seerr's requests
 - optional apps switched off: their container removed, and their links in
   Prowlarr

Written for Python 3.9 (the NAS's own) and its standard library only.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ENV = os.environ
USER = ENV.get("ADMIN_USER", "admin")
PASSWORD = ENV.get("ADMIN_PASSWORD", "")
PUID = int(ENV.get("PUID", "84"))
PGID = int(ENV.get("PGID", "1000"))
DATA_ROOT = ENV.get("DATA_ROOT", "")
# The first volume: folders there appear in the containers at /media/<their
# path relative to it> (else relative to /mnt), as the Store mounts them
VOLUME = ENV.get("VOLUME", "/mnt/HD/HD_a2")
# What happens to a torrent once its download is filed: seed (keep seeding),
# limit (seed to SEED_RATIO or SEED_DAYS, then remove it), remove (stop and
# remove it straight away)
AFTER_IMPORT = ENV.get("AFTER_IMPORT", "seed")
SEED_RATIO = ENV.get("SEED_RATIO", "2")
SEED_DAYS = int(ENV.get("SEED_DAYS", "14") or 0)
RENAME = ENV.get("RENAME", "on") == "on"
# Searching: auto (what's added or requested is searched for, and new releases
# are picked up - RSS) or manual (only the apps' Interactive Search)
SEARCH_BY_HAND = ENV.get("SEARCH", "auto") == "manual"
# Films without a folder of their own (FLAT_FILMS): once filed, moved up into
# the library folder and taken off Radarr's list - by a script Radarr runs
# after each import (Settings -> Connect)
FLAT_FILMS = ENV.get("FLAT_FILMS", "off") == "on"
# Installing (the Store's STORE_ACTION - setup.sh is always an install):
# settings only set the first time, which may then be changed in the apps (e.g.
# their anonymous usage data, sent by default - switched off)
INSTALLING = ENV.get("STORE_ACTION", "install") == "install"
# The media server told about new files: none, plex, jellyfin or emby - at
# MEDIA_SERVER_URL (empty: on the NAS, at its usual port), with its key (Plex:
# its token - empty, read from Plex on the NAS)
MEDIA_SERVER = ENV.get("MEDIA_SERVER", "none")
MEDIA_SERVER_URL = ENV.get("MEDIA_SERVER_URL", "").strip()
MEDIA_SERVER_KEY = ENV.get("MEDIA_SERVER_KEY", "").strip()
# The ntfy topic the apps send notifications to (empty: none) - through the
# ntfy app on the NAS, with its apps' token
NTFY_TOPIC = ENV.get("NTFY_TOPIC", "").strip()
# Recyclarr's quality profiles (the TRaSH Guides'), and the one Seerr requests
# with: 1080p or 2160p
RECYCLARR = ENV.get("RECYCLARR", "off") == "on"
QUALITY = ENV.get("QUALITY", "1080p")
TORRENT_PORT = int(ENV.get("TORRENT_PORT", "6881"))
LANGUAGE = ENV.get("SUBTITLE_LANGUAGE", "en")
# How long to wait for an app to answer: the first start of some takes
# minutes on the NAS
READY_TIMEOUT = int(ENV.get("WIRE_READY_TIMEOUT", "600"))
# The recipe's folder (where the Store runs its hooks)
DATA = ENV.get("STORE_DATA") or os.getcwd()
# The ntfy app (in Nas_Prog, next to the recipe's folder), and its data folder:
# its apps' token and settings (kept when the app is removed - so only used
# while the app is installed)
NTFY_APP = os.path.join(os.path.dirname(DATA.rstrip("/")), "ntfy")
NTFY_DATA = os.path.join(os.path.dirname(DATA.rstrip("/")), "_ntfy")
# Where the apps' settings are (Radarr's at radarr/ - /config in its container)
CONFIG_ROOT = ENV.get("CONFIG_ROOT") or DATA
# The password last given to qBittorrent: it only takes a new one from someone
# logged in with the old one (root only, next to .env - which holds the
# password too)
QBIT_PASSWORD_FILE = os.path.join(DATA, ".qbittorrent-password")


def on(name):
    """
    Whether one of the recipe's on / off options is on.

    :param str name: The option (e.g. LIDARR)

    :return: Whether it's on
    """
    return ENV.get(name, "off") == "on"


# The library apps: name, port, API version, its key's setting, the option
# switching it on (None: always), its folder in media/ (unless its folders
# option - a list - names folders of your own), and its category's setting
# name in download clients
LIBRARY_APPS = [
    {
        "name": "sonarr", "title": "Sonarr", "port": 8989, "api": "v3",
        "key": "SONARR_API_KEY", "option": None, "folder": "tv",
        "folders": "TV_FOLDERS", "category": "tvCategory",
        "rename": "renameEpisodes", "prowlarr": "Sonarr", "items": "/series",
        "ntfy_tag": "tv",
    },
    {
        "name": "radarr", "title": "Radarr", "port": 7878, "api": "v3",
        "key": "RADARR_API_KEY", "option": None, "folder": "movies",
        "folders": "MOVIES_FOLDERS", "category": "movieCategory",
        "rename": "renameMovies", "prowlarr": "Radarr", "items": "/movie",
        "ntfy_tag": "movie_camera",
    },
    {
        "name": "lidarr", "title": "Lidarr", "port": 8686, "api": "v1",
        "key": "LIDARR_API_KEY", "option": "LIDARR", "folder": "music",
        "folders": "MUSIC_FOLDERS", "category": "musicCategory",
        "rename": "renameTracks", "prowlarr": "Lidarr", "items": "/artist",
        "ntfy_tag": "musical_note",
    },
    {
        "name": "bookshelf", "title": "Bookshelf", "port": 8787, "api": "v1",
        "key": "BOOKSHELF_API_KEY", "option": "BOOKS", "folder": "books",
        "folders": "BOOKS_FOLDERS",
        # eadarr - which Bookshelf continues - kept Lidarr's name for its download clients' category
        "category": "musicCategory",
        "rename": "renameBooks", "prowlarr": "Readarr", "items": "/author",
        "ntfy_tag": "books",
    },
]
# Optional containers, by their option
OPTIONAL = {
    "LIDARR": "lidarr",
    "BOOKS": "bookshelf",
    "SABNZBD": "sabnzbd",
    "FLARESOLVERR": "flaresolverr",
    "RECYCLARR": "recyclarr",
}

problems = []


def log(text):
    """
    Prints a line of the hook's output (shown in the Store's log).

    :param str text: The line
    """
    print(text, flush=True)


def problem(text):
    """
    Notes a problem (the hook finishes with an error), and prints it.

    :param str text: What went wrong
    """
    problems.append(text)
    log("Problem: " + text)


class HttpError(Exception):
    """An app's error answer (HTTP 400 or more)."""

    def __init__(self, status, body):
        """
        The error, with the start of the app's answer as its message.

        :param int status: The HTTP status
        :param str body:   The app's answer
        """
        super().__init__("HTTP %s: %s" % (status, body[:300]))
        self.status = status
        self.body = body


def http(method, url, headers=None, body=None, form=None, timeout=30):
    """
    Makes an HTTP request.

    :param str method:   The method (e.g. GET)
    :param str url:      The address
    :param dict headers: Headers to send
    :param body:         Sent as JSON (None: nothing)
    :param form:         Sent as a URL-encoded form (a dict or pairs)
    :param int timeout:  How long to wait, in seconds

    :return: (status, body as text, response)
    """
    headers = dict(headers or {})
    data = None

    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form, doseq=True).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    request = urllib.request.Request(
        url, data=data, headers=headers, method=method
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return (
                response.status,
                response.read().decode("utf-8", "replace"),
                response,
            )
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace"), error


def wait_for(title, check):
    """
    Waits for check() to be true, up to READY_TIMEOUT seconds.

    :param str title:       What's waited for, for the problem if it never is
    :param callable check:  Whether it's ready

    :return: Whether it was
    """
    start = time.time()

    while time.time() - start < READY_TIMEOUT:
        try:
            if check():
                return True
        except (OSError, ValueError):
            pass

        time.sleep(3)

    problem("%s didn't answer within %d seconds" % (title, READY_TIMEOUT))

    return False


def docker(*args, stdin=None):
    """
    Runs docker.

    :param str args:    Its arguments
    :param bytes stdin: What to give it as its input

    :return: (exit code, output - stdout and stderr)
    """
    result = subprocess.run(
        ["docker"] + list(args),
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    return result.returncode, result.stdout.decode("utf-8", "replace")


def container_running(name):
    """
    Whether a container is running.

    :param str name: The container

    :return: Whether it is
    """
    code, output = docker("inspect", "-f", "{{.State.Running}}", name)

    return code == 0 and output.strip() == "true"


# -----------------------------------------------------------------------------
# The data folder

def library_folders(app):
    """
    The app's library folders on the NAS: those chosen (TV_FOLDERS...), else
    media/<its folder> in DATA_ROOT.

    :param dict app: The library app (LIBRARY_APPS)

    :return: The folders
    """
    chosen = [
        f.rstrip("/")
        for f in ENV.get(app["folders"], "").split("|")
        if f.strip()
    ]

    return chosen or [os.path.join(DATA_ROOT, "media", app["folder"])]


def in_container(folder):
    """
    Where a folder on the NAS appears in the containers: under /data if it's
    in DATA_ROOT (so that downloads are hard-linked into it - one mount), else
    where the Store mounts it: /media/<its path relative to the first volume>.

    :param str folder: The folder on the NAS

    :return: Its path in the containers
    """
    root = DATA_ROOT.rstrip("/")

    if folder == root or folder.startswith(root + "/"):
        return "/data" + folder[len(root):]

    volume = VOLUME.rstrip("/") + "/"

    return "/media/" + (
        folder[len(volume):]
        if folder.startswith(volume)
        else re.sub(r"^/mnt/", "", folder)
    )


def writable_by_apps(folder):
    """
    Whether the apps (PUID, in the group PGID) can write into a folder of the
    user's - which is never changed.

    :param str folder: The folder

    :return: Whether they can
    """
    try:
        info = os.stat(folder)
    except OSError:
        return False

    return bool(
        (info.st_uid == PUID and info.st_mode & 0o200)
        or (info.st_gid == PGID and info.st_mode & 0o020)
        or info.st_mode & 0o002
    )


def folders():
    """
    Makes the data folder's layout (torrents/, usenet/, media/), owned by the
    apps' user and the share group, and checks library folders of the user's
    own can be written by the apps.
    """
    if not DATA_ROOT:
        return

    # Library folders of the user's own, outside DATA_ROOT: left as they are -
    # only checked
    for app in LIBRARY_APPS:
        if app["option"] is not None and not on(app["option"]):
            continue

        for folder in library_folders(app):
            if (
                in_container(folder).startswith("/media/")
                and not writable_by_apps(folder)
            ):
                problem(
                    "%s can't write into %s: it needs to be writable by the "
                    "share users' group (the apps run as user %d, group %d)"
                    % (app["title"], folder, PUID, PGID)
                )

    names = ["torrents", "usenet/incomplete"]

    for app in LIBRARY_APPS:
        names += [
            "torrents/" + app["folder"],
            "usenet/complete/" + app["folder"],
        ]

        # media/<its folder> only where it's the app's library - not with
        # folders of your own
        if not ENV.get(app["folders"], "").strip():
            names += ["media", "media/" + app["folder"]]

    for name in names:
        path = os.path.join(DATA_ROOT, name)

        if not os.path.isdir(path):
            os.makedirs(path)
            log("Created " + path)

        # The apps' user and the share group; new files and folders inside
        # keep the group - setgid
        try:
            os.chown(path, PUID, PGID)
            os.chmod(path, 0o2775)
        except PermissionError:
            problem("Couldn't set the owner of " + path)

    for parent in ("usenet/complete", "usenet"):
        path = os.path.join(DATA_ROOT, parent)

        try:
            os.chown(path, PUID, PGID)
            os.chmod(path, 0o2775)
        except PermissionError:
            pass


# -----------------------------------------------------------------------------
# qBittorrent

QBIT = "http://127.0.0.1:8090"


def qbit_login(password, previous=False):
    """
    Logs in to qBittorrent's API.

    :param str password:  The password to try
    :param bool previous: Whether it's the previous one (tried with the user
                          name and admin)

    :return: Its session cookie (name=value), or None
    """
    # The temporary password is admin's; the others are the user name's -
    # which may have changed too, so the previous password is tried with both
    users = (
        [USER]
        if password == PASSWORD
        else (["admin"] if not previous else [USER, "admin"])
    )

    for user in users:
        sid = qbit_login_as(user, password)

        if sid:
            return sid

    return None


def qbit_login_as(user, password):
    """
    Logs in to qBittorrent's API as a user.

    :param str user:     The user name
    :param str password: Their password

    :return: Its session cookie (name=value), or None
    """
    status, text, response = http(
        "POST",
        QBIT + "/api/v2/auth/login",
        headers={"Referer": QBIT},
        form={"username": user, "password": password},
    )

    # qBittorrent 5 answers 204 with no text; earlier versions 200 "Ok."
    if status == 204 or (status == 200 and text.strip() == "Ok."):
        cookie = response.headers.get("Set-Cookie", "")
        match = re.search(r"(SID|QBT_SID_\d+)=([^;]+)", cookie)

        return match.group(0) if match else None

    return None


def qbittorrent():
    """
    Sets up qBittorrent: its login, save folder, a category per app, its
    listening port and how long it seeds (AFTER_IMPORT).
    """
    if not wait_for(
        "qBittorrent",
        lambda: http("GET", QBIT + "/api/v2/app/version")[0]
        in (200, 401, 403),
    ):
        return

    sid = qbit_login(PASSWORD)

    if not sid and os.path.isfile(QBIT_PASSWORD_FILE):
        # The password was changed: the previous one
        with open(QBIT_PASSWORD_FILE) as f:
            sid = qbit_login(f.read().strip(), previous=True)

    if not sid:
        # The first time: the temporary password it logs (as user admin)
        code, logs = docker("logs", "qbittorrent")
        found = re.findall(
            r"temporary password is provided for this session: (\S+)", logs
        )
        sid = qbit_login(found[-1]) if found else None

    if not sid:
        problem(
            "Couldn't log in to qBittorrent (its password was changed in "
            "qBittorrent?)"
        )

        return

    headers = {"Cookie": sid, "Referer": QBIT}
    preferences = {
        "web_ui_username": USER,
        "web_ui_password": PASSWORD,
        "save_path": "/data/torrents",
        "temp_path_enabled": False,
        "listen_port": TORRENT_PORT,
        "upnp": False,
        # Reached through the Nginx app's address too, and by the other apps by its container's name
        "web_ui_host_header_validation_enabled": False,
        # Torrents of the apps' categories go in their folder (automatic
        # torrent management)
        "auto_tmm_enabled": True,
        "torrent_changed_tmm_enabled": True,
        "save_path_changed_tmm_enabled": True,
        "category_changed_tmm_enabled": True,
    }
    # How long finished torrents seed: stopped at the limit (never removed by
    # qBittorrent itself - the library apps remove each once it's filed and
    # stopped, with its files). "remove": a ratio of 0 - stopped as soon as
    # it's complete
    ratio = (
        None
        if AFTER_IMPORT == "seed"
        else (
            0
            if AFTER_IMPORT == "remove"
            else (None if SEED_RATIO == "none" else float(SEED_RATIO))
        )
    )
    days = SEED_DAYS if AFTER_IMPORT == "limit" else 0

    if AFTER_IMPORT == "limit" and ratio is None and not days:
        # No limit chosen: as "remove"
        ratio = 0

    preferences.update({
        "max_ratio_enabled": ratio is not None,
        "max_ratio": ratio if ratio is not None else -1,
        "max_seeding_time_enabled": bool(days),
        "max_seeding_time": days * 1440 if days else -1,
        "max_ratio_act": 0,
    })
    status, text, _ = http(
        "POST",
        QBIT + "/api/v2/app/setPreferences",
        headers=headers,
        form={"json": json.dumps(preferences)},
    )

    if status != 200:
        problem(
            "qBittorrent's settings weren't saved: %s %s"
            % (status, text[:200])
        )
    else:
        fd = os.open(
            QBIT_PASSWORD_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
        )

        with os.fdopen(fd, "w") as f:
            f.write(PASSWORD)

    status, text, _ = http(
        "GET", QBIT + "/api/v2/torrents/categories", headers=headers
    )
    existing = json.loads(text) if status == 200 else {}

    for app in LIBRARY_APPS:
        category = app["folder"]
        path = "/data/torrents/" + category

        if category not in existing:
            http(
                "POST",
                QBIT + "/api/v2/torrents/createCategory",
                headers=headers,
                form={"category": category, "savePath": path},
            )
        elif existing[category].get("savePath") != path:
            http(
                "POST",
                QBIT + "/api/v2/torrents/editCategory",
                headers=headers,
                form={"category": category, "savePath": path},
            )

    seeding = {
        "seed": "seeding without limit",
        "remove": "not seeding (removed once filed)",
    }.get(
        AFTER_IMPORT,
        "seeding to %s" % " or ".join(filter(None, [
            "ratio %g" % ratio if ratio else "",
            "%d days" % days if days else "",
        ])),
    )
    log(
        "qBittorrent: user %s, saving to /data/torrents (a category per app), "
        "listening on port %d, %s" % (USER, TORRENT_PORT, seeding)
    )


# -----------------------------------------------------------------------------
# SABnzbd

SAB = "http://127.0.0.1:8085"


def sab_key():
    """
    SABnzbd's API key, from its settings.

    :return: The key, or None
    """
    code, ini = docker("exec", "sabnzbd", "cat", "/config/sabnzbd.ini")
    match = re.search(r"^api_key\s*=\s*(\S+)", ini, re.M)

    return match.group(1) if code == 0 and match else None


def sabnzbd():
    """
    Sets up SABnzbd (if it's switched on): its folders, login, a category per
    app and the address the other apps reach it at.

    :return: Its API key, or None
    """
    if not on("SABNZBD"):
        return None

    if not wait_for(
        "SABnzbd",
        lambda: sab_key() is not None
        and http("GET", SAB + "/api?mode=version&output=json")[0] == 200,
    ):
        return None

    key = sab_key()

    def setting(section, keyword, value):
        """
        Saves one of SABnzbd's settings.

        :param str section: Its section (e.g. misc)
        :param str keyword: Its name
        :param str value:   Its value
        """
        status, text, _ = http(
            "GET",
            SAB + "/api?" + urllib.parse.urlencode({
                "mode": "set_config",
                "section": section,
                "keyword": keyword,
                "value": value,
                "apikey": key,
                "output": "json",
            }),
        )

        if status != 200:
            problem(
                "SABnzbd's %s %s wasn't saved: %s"
                % (section, keyword, text[:200])
            )

    # It only answers addresses it knows: the other apps reach it as "sabnzbd"
    status, text, _ = http(
        "GET",
        SAB + "/api?" + urllib.parse.urlencode({
            "mode": "get_config",
            "section": "misc",
            "keyword": "host_whitelist",
            "apikey": key,
            "output": "json",
        }),
    )
    hosts = []

    try:
        value = json.loads(text)["config"]["misc"]["host_whitelist"]
        hosts = [
            h
            for h in (value if isinstance(value, list) else value.split(","))
            if h.strip()
        ]
    except (ValueError, KeyError, TypeError):
        pass

    if "sabnzbd" not in hosts:
        setting("misc", "host_whitelist", ",".join(hosts + ["sabnzbd"]))

    setting("misc", "download_dir", "/data/usenet/incomplete")
    setting("misc", "complete_dir", "/data/usenet/complete")
    setting("misc", "username", USER)
    setting("misc", "password", PASSWORD)

    for app in LIBRARY_APPS:
        http(
            "GET",
            SAB + "/api?" + urllib.parse.urlencode({
                "mode": "set_config",
                "section": "categories",
                "name": app["folder"],
                "dir": app["folder"],
                "apikey": key,
                "output": "json",
            }),
        )

    log(
        "SABnzbd: user %s, downloading to /data/usenet (a category per app) - "
        "add your Usenet provider in its settings" % USER
    )

    return key


# -----------------------------------------------------------------------------
# Sonarr, Radarr, Lidarr, Bookshelf and Prowlarr (the same API, by version)

class Arr:
    """One of the apps sharing the *arr API: Sonarr, Radarr, Prowlarr..."""

    def __init__(self, title, port, api, key):
        """
        The app, on the NAS.

        :param str title: Its name, for messages
        :param int port:  Its port
        :param str api:   Its API version (e.g. v3)
        :param str key:   Its API key
        """
        self.title = title
        self.base = "http://127.0.0.1:%d/api/%s" % (port, api)
        self.key = key

    def call(self, method, path, body=None):
        """
        Calls its API.

        :param str method: The method (e.g. GET)
        :param str path:   The path, after the API's (e.g. /rootfolder)
        :param body:       Sent as JSON (None: nothing)

        :return: Its answer, decoded (None if it's empty)

        :raises HttpError: When it answers with an error
        """
        # Some take a while: e.g. Prowlarr syncing its indexers to the apps, a connection test
        status, text, _ = http(
            method,
            self.base + path,
            headers={"X-Api-Key": self.key},
            body=body,
            timeout=120,
        )

        if status >= 400:
            raise HttpError(status, text)

        return json.loads(text) if text.strip() else None

    def ready(self):
        """
        Waits for it to answer.

        :return: Whether it did
        """
        return wait_for(
            self.title,
            lambda: http(
                "GET",
                self.base + "/system/status",
                headers={"X-Api-Key": self.key},
            )[0] == 200,
        )

    def login(self):
        """Its web interface: a login page, with the user name and password."""
        host = self.call("GET", "/config/host")
        host.update({
            "authenticationMethod": "forms",
            "authenticationRequired": "enabled",
            "username": USER,
            "password": PASSWORD,
            "passwordConfirmation": PASSWORD,
        })

        # No anonymous usage data sent to its developers - on by default; only at install, so it can be switched on again
        if INSTALLING:
            host["analyticsEnabled"] = False

        self.call("PUT", "/config/host/%s" % host["id"], host)

    def ensure(self, path, match, item, schema_path=None, force=True):
        """
        Adds (or updates) a thing - a download client, an application... -
        from its schema.

        :param str path:          Where the things are (e.g. /downloadclient)
        :param callable match:    Whether a thing (or schema) is the one
        :param callable item:     Fills in a thing's fields (given its schema)
        :param str schema_path:   Where the schemas are (default: path/schema)
        :param bool force:        Saved even if its connection test fails

        :raises HttpError: When it's refused (e.g. its test failed, not forced)
        """
        save = "?forceSave=true" if force else ""
        existing = [x for x in self.call("GET", path) if match(x)]
        schema = (
            existing[0]
            if existing
            else [
                x
                for x in self.call("GET", schema_path or path + "/schema")
                if match(x)
            ][0]
        )
        wanted = item(json.loads(json.dumps(schema)))

        if existing:
            if wanted != existing[0]:
                self.call(
                    "PUT", "%s/%s%s" % (path, existing[0]["id"], save), wanted
                )
        else:
            self.call("POST", path + save, wanted)

    def remove(self, path, match):
        """
        Removes things.

        :param str path:       Where the things are (e.g. /notification)
        :param callable match: Whether a thing is to go
        """
        for thing in self.call("GET", path):
            if match(thing):
                self.call("DELETE", "%s/%s" % (path, thing["id"]))


def set_fields(item, values):
    """
    Sets a thing's fields (those it has).

    :param dict item:   The thing (its "fields" list)
    :param dict values: The fields' values, by name

    :return: The thing
    """
    for field in item.get("fields", []):
        if field["name"] in values:
            field["value"] = values[field["name"]]

    return item


def library_app(app, sab_api_key):
    """
    Sets up a library app: its login, library folders, download clients,
    renaming, media server and notifications.

    :param dict app:        The library app (LIBRARY_APPS)
    :param str sab_api_key: SABnzbd's API key (None: SABnzbd's off)
    """
    arr = Arr(app["title"], app["port"], app["api"], ENV.get(app["key"], ""))

    if not arr.ready():
        return

    try:
        arr.login()
        # Its library folders (as the containers see them), added where
        # missing - any others added in the app are kept
        roots = [in_container(folder) for folder in library_folders(app)]
        existing = [
            r["path"].rstrip("/") for r in arr.call("GET", "/rootfolder")
        ]

        for folder in roots:
            if folder in existing:
                continue

            root = {"path": folder}

            if app["api"] == "v1":
                # Lidarr and Bookshelf: a name, and the profiles new artists or authors get
                root.update({
                    "name": os.path.basename(folder) or app["title"],
                    "defaultQualityProfileId": arr.call(
                        "GET", "/qualityprofile"
                    )[0]["id"],
                    "defaultMetadataProfileId": arr.call(
                        "GET", "/metadataprofile"
                    )[0]["id"],
                    "defaultMonitorOption": "all",
                    "defaultNewItemMonitorOption": "all",
                    "defaultTags": [],
                    "isCalibreLibrary": False,
                })

            arr.call("POST", "/rootfolder", root)

        # Library folders the recipe gave it before (in the data folder, or
        # mounted at /media) and no longer chosen: taken off, if nothing in
        # the app is in them - else kept, and said
        items = None

        for root in arr.call("GET", "/rootfolder"):
            path = root["path"].rstrip("/")

            if path in roots or not (
                path.startswith("/data/media/") or path.startswith("/media/")
            ):
                continue

            if items is None:
                items = [
                    i.get("path", "") for i in arr.call("GET", app["items"])
                ]

            if any(i == path or i.startswith(path + "/") for i in items):
                log(
                    "%s: %s is no longer one of its library folders, but has "
                    "things in it - kept (move them in %s)"
                    % (app["title"], path, app["title"])
                )
            else:
                arr.call("DELETE", "/rootfolder/%s" % root["id"])
                log(
                    "%s: %s taken off its library folders (no longer chosen)"
                    % (app["title"], path)
                )

        folder = ", ".join(roots)

        def client(implementation, values):
            """
            Adds (or updates) a download client.

            :param str implementation: Its kind (e.g. QBittorrent)
            :param dict values:        Its fields' values
            """
            def fill(item):
                """
                Fills in the download client.

                :param dict item: Its schema (or itself)

                :return: The download client
                """
                item.update({
                    "enable": True,
                    "name": (
                        implementation
                        if implementation != "QBittorrent"
                        else "qBittorrent"
                    ),
                    "priority": 1,
                    "removeCompletedDownloads": True,
                    "removeFailedDownloads": True,
                })

                return set_fields(item, values)

            arr.ensure(
                "/downloadclient",
                lambda x: x["implementation"] == implementation,
                fill,
            )

        client("QBittorrent", {
            "host": "qbittorrent",
            "port": 8090,
            "username": USER,
            "password": PASSWORD,
            app["category"]: app["folder"],
        })

        if sab_api_key:
            client("Sabnzbd", {
                "host": "sabnzbd",
                "port": 8080,
                "apiKey": sab_api_key,
                "username": USER,
                "password": PASSWORD,
                app["category"]: app["folder"],
            })
        else:
            arr.remove(
                "/downloadclient", lambda x: x["implementation"] == "Sabnzbd"
            )

        # Files renamed as they're imported (tidy names for Jellyfin and Plex)
        # - or kept as downloaded (RENAME off)
        naming = arr.call("GET", "/config/naming")

        if app["rename"] in naming and naming[app["rename"]] != RENAME:
            naming[app["rename"]] = RENAME
            arr.call("PUT", "/config/naming/%s" % naming["id"], naming)

        log(
            "%s: user %s, library %s, downloads through qBittorrent%s, %s"
            % (
                app["title"],
                USER,
                folder,
                " and SABnzbd" if sab_api_key else "",
                "renamed as filed" if RENAME else "names kept",
            )
        )
    except (HttpError, KeyError, IndexError, ValueError, OSError) as error:
        problem("%s: %s" % (app["title"], error))

        return

    try:
        media_server(arr, app)
    except (HttpError, KeyError, IndexError, ValueError, OSError) as error:
        problem("%s: the media server: %s" % (app["title"], error))

    ntfy(arr, app["ntfy_tag"])


# The media servers: name, the apps' connection for it (Settings -> Connect),
# its usual port
MEDIA_SERVERS = {
    "plex": ("Plex", "PlexServer", 32400),
    "jellyfin": ("Jellyfin", "MediaBrowser", 8096),
    "emby": ("Emby", "MediaBrowser", 8096),
}
# The recipe's connections are named "<server> (library updates)" - any others the user added are left alone
MEDIA_SERVER_SUFFIX = " (library updates)"
# The events changing what's in the library - the media server is told of these (not of grabs, health issues...)
LIBRARY_EVENTS = (
    "Download",
    "ImportComplete",
    "Upgrade",
    "Rename",
    "Delete",
    "ReleaseImport",
    "TrackRetag",
)


def plex_token():
    """
    The token of Plex on the NAS (the WD app, or one installed by hand in
    Nas_Prog): from its Preferences.xml.

    :return: The token ("" if it wasn't found)
    """
    for top in glob.glob(
        os.path.join(
            os.path.dirname(VOLUME.rstrip("/")), "HD_*", "Nas_Prog", "*"
        )
    ):
        if "plex" not in os.path.basename(top).lower():
            continue

        for depth in range(5):
            for path in glob.glob(
                os.path.join(
                    glob.escape(top),
                    *(["*"] * depth),
                    "Plex Media Server",
                    "Preferences.xml",
                )
            ):
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        match = re.search(
                            r'\bPlexOnlineToken="([^"]+)"', f.read()
                        )
                except OSError:
                    continue

                if match:
                    return match.group(1)

    return ""


def media_server(arr, app):
    """
    Tells the media server about each new (or renamed, or deleted) file - so
    it shows at once, not at its next scan.

    :param Arr arr:  The library app
    :param dict app: Its LIBRARY_APPS entry

    :raises HttpError: When the app refuses a change (other than the
                       connection's test)
    """
    ours = lambda x: (
        x["implementation"] in ("PlexServer", "MediaBrowser")
        and x.get("name", "").endswith(MEDIA_SERVER_SUFFIX)
    )

    if MEDIA_SERVER not in MEDIA_SERVERS:
        arr.remove("/notification", ours)

        return

    title, implementation, default_port = MEDIA_SERVERS[MEDIA_SERVER]
    name = title + MEDIA_SERVER_SUFFIX
    arr.remove("/notification", lambda x: ours(x) and x.get("name") != name)

    if not [
        x
        for x in arr.call("GET", "/notification/schema")
        if x["implementation"] == implementation
    ]:
        # Not one it can tell: Bookshelf
        return

    key = MEDIA_SERVER_KEY or (plex_token() if MEDIA_SERVER == "plex" else "")

    if not key:
        problem(
            "%s: not connected to %s - it needs %s (the recipe's settings)"
            % (
                app["title"],
                title,
                "Plex's token: it wasn't found on the NAS"
                if MEDIA_SERVER == "plex"
                else "an API key from its dashboard",
            )
        )

        return

    # On the NAS - host.docker.internal, as the apps see it - at the server's usual port, unless set
    address = urllib.parse.urlsplit(
        MEDIA_SERVER_URL or "http://host.docker.internal:%d" % default_port
    )
    ssl = address.scheme == "https"
    values = {
        "host": address.hostname,
        "port": address.port or (443 if ssl else default_port),
        "useSsl": ssl,
        "updateLibrary": True,
    }

    if MEDIA_SERVER == "plex":
        # Plex is told to scan the series' or film's folder in each library of that kind: no paths needed
        values["authToken"] = key
    else:
        # Jellyfin and Emby are told of the file by its path: theirs (on the NAS), not the containers'
        inside = in_container(library_folders(app)[0])
        prefix = "/data" if inside.startswith("/data") else "/media"
        values.update({
            "apiKey": key,
            "notify": False,
            "mapFrom": prefix,
            "mapTo": (DATA_ROOT if prefix == "/data" else VOLUME).rstrip("/"),
        })

    def fill(item):
        """
        Fills in the connection: told of the library's events only.

        :param dict item: Its schema (or itself)

        :return: The connection
        """
        item.update({"name": name, "tags": []})

        for event in [
            k for k in item if k.startswith("on") and isinstance(item[k], bool)
        ]:
            item[event] = any(e in event for e in LIBRARY_EVENTS) and item.get(
                "supports" + event[0].upper() + event[1:], True
            )

        return set_fields(item, values)

    # The app tests the connection as it's saved - and refuses it if the server doesn't answer
    try:
        arr.ensure(
            "/notification",
            lambda x: x["implementation"] == implementation
            and x.get("name", "") in ("", name),
            fill,
            force=False,
        )
    except HttpError as error:
        try:
            body = json.loads(error.body)
            reason = "; ".join(
                "%s (%s)"
                % (e.get("errorMessage", ""), e.get("detailedDescription", ""))
                for e in body
            )
        except (ValueError, AttributeError, TypeError):
            reason = str(error)

        problem(
            "%s: not connected to %s at %s:%s - %s. Tried again at the next "
            "update or change of settings"
            % (app["title"], title, values["host"], values["port"], reason)
        )

        return

    log(
        "%s: tells %s (%s:%s) about new files"
        % (app["title"], title, values["host"], values["port"])
    )


# The script Radarr runs after each import (in its container - its paths) with
# FLAT_FILMS. Radarr keeps each film in a folder of its own: the film's files
# are moved up into the library folder, the folder removed, and the film taken
# off Radarr's list (its files kept) - or Radarr would see it missing and fetch
# it again. Nothing is moved if a file of the same name is already there: the
# film keeps its folder (and its place in Radarr)
FLAT_FILMS_SCRIPT = r"""#!/bin/sh
# Written by the Arr stack recipe ("Films without their own folder") - run by Radarr after it files a film (Settings ->
# Connect): rewritten by the recipe's setup, edits here are lost
[ "${radarr_eventtype}" = Download ] || exit 0
folder="${radarr_movie_path%/}"
library="$(dirname "${folder}")"
[ -n "${folder}" ] && [ -d "${folder}" ] && [ -f "${radarr_moviefile_path}" ] || exit 0
for f in "${folder}"/*; do
	if [ -f "${f}" ] && [ -e "${library}/$(basename "${f}")" ]; then
		echo "Not moved: ${library}/$(basename "${f}") already exists - ${radarr_movie_title} keeps its folder"
		exit 0
	fi
done
for f in "${folder}"/*; do
	if [ -f "${f}" ] && ! mv "${f}" "${library}/"; then
		echo "Couldn't move ${f} into ${library}"
		exit 1
	fi
done
rmdir "${folder}" 2>/dev/null
# Off Radarr's list (its files kept), once Radarr has finished with this import
key="${RADARR__AUTH__APIKEY:-$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)}"
nohup sh -c "sleep 15; curl -s -o /dev/null -X DELETE -H 'X-Api-Key: ${key}' 'http://localhost:7878/api/v3/movie/${radarr_movie_id}?deleteFiles=false&addImportExclusion=false'" > /dev/null 2>&1 &
echo "Filed ${radarr_movie_title} in ${library}, without a folder of its own"
"""
FLAT_FILMS_NAME = "Films without their own folder"


def radarr_flat_films():
    """
    Radarr's script for films without a folder of their own (FLAT_FILMS):
    written and run after each import - or taken off if it's switched off.
    """
    radarr = [app for app in LIBRARY_APPS if app["name"] == "radarr"][0]
    arr = Arr(
        radarr["title"],
        radarr["port"],
        radarr["api"],
        ENV.get(radarr["key"], ""),
    )

    if not arr.ready():
        return

    # Only the recipe's own script - any other the user added is left alone
    match = lambda x: (
        x["implementation"] == "CustomScript"
        and x.get("name", "") in ("", FLAT_FILMS_NAME)
    )

    try:
        if not FLAT_FILMS:
            arr.remove(
                "/notification",
                lambda x: x["implementation"] == "CustomScript"
                and x.get("name") == FLAT_FILMS_NAME,
            )

            return

        folder = os.path.join(CONFIG_ROOT, "radarr", "scripts")
        os.makedirs(folder, exist_ok=True)
        script = os.path.join(folder, "films-without-folders.sh")

        with open(script, "w") as f:
            f.write(FLAT_FILMS_SCRIPT)

        for path in (folder, script):
            os.chown(path, PUID, PGID)
            os.chmod(path, 0o755)

        def fill(item):
            """
            Fills in the script's connection: run after each import only.

            :param dict item: Its schema (or itself)

            :return: The connection
            """
            item.update({
                "name": FLAT_FILMS_NAME,
                "onDownload": True,
                "onUpgrade": False,
                "onRename": False,
                "onMovieAdded": False,
                "onMovieDelete": False,
                "onMovieFileDelete": False,
                "onMovieFileDeleteForUpgrade": False,
                "onHealthIssue": False,
                "onApplicationUpdate": False,
                "onManualInteractionRequired": False,
                "tags": [],
            })

            return set_fields(item, {
                "path": "/config/scripts/films-without-folders.sh",
                "arguments": "",
            })

        arr.ensure("/notification", match, fill)
        log(
            "Radarr: films filed without a folder of their own (then taken "
            "off its list)"
        )
    except (HttpError, KeyError, IndexError, ValueError, OSError) as error:
        problem("Radarr: films without folders: %s" % error)


def prowlarr(enabled_apps):
    """
    Sets up Prowlarr: its login, the library apps as applications, searching
    (SEARCH), FlareSolverr as a proxy, and its notifications.

    :param list enabled_apps: The library apps switched on (LIBRARY_APPS)
    """
    arr = Arr("Prowlarr", 9696, "v1", ENV.get("PROWLARR_API_KEY", ""))

    if not arr.ready():
        return

    try:
        arr.login()

        for app in LIBRARY_APPS:
            match = lambda x, app=app: x["implementation"] == app["prowlarr"]

            if app in enabled_apps:
                def fill(item, app=app):
                    """
                    Fills in the application.

                    :param dict item: Its schema (or itself)
                    :param dict app:  The library app

                    :return: The application
                    """
                    item.update(
                        {"name": app["title"], "syncLevel": "fullSync"}
                    )

                    return set_fields(item, {
                        "prowlarrUrl": "http://prowlarr:9696",
                        "baseUrl": "http://%s:%d" % (app["name"], app["port"]),
                        "apiKey": ENV.get(app["key"], ""),
                    })

                arr.ensure("/applications", match, fill)
            else:
                arr.remove("/applications", match)

        # Searching: automatic, or only by hand - for the indexers it gives
        # the apps (its sync profiles), synced to them now
        changed = False

        for profile in arr.call("GET", "/appprofile"):
            if (
                profile.get("enableRss") == SEARCH_BY_HAND
                or profile.get("enableAutomaticSearch") == SEARCH_BY_HAND
            ):
                profile.update({
                    "enableRss": not SEARCH_BY_HAND,
                    "enableAutomaticSearch": not SEARCH_BY_HAND,
                    "enableInteractiveSearch": True,
                })
                arr.call("PUT", "/appprofile/%s" % profile["id"], profile)
                changed = True

        if changed:
            arr.call("POST", "/command", {"name": "ApplicationIndexerSync"})

        tags = arr.call("GET", "/tag")
        tag = [t for t in tags if t["label"] == "flaresolverr"]

        if on("FLARESOLVERR"):
            tag_id = (
                tag[0]["id"]
                if tag
                else arr.call("POST", "/tag", {"label": "flaresolverr"})["id"]
            )
            # Prowlarr tests a proxy as it's saved: FlareSolverr - just started, if it was switched on - must answer
            # first. It has no port on the NAS, so it's asked from Prowlarr's container, as Prowlarr reaches it
            wait_for(
                "FlareSolverr",
                lambda: docker(
                    "exec", "prowlarr", "curl", "-s", "-m", "5",
                    "-o", "/dev/null", "-w", "%{http_code}",
                    "http://flaresolverr:8191/",
                )[1].strip() == "200",
            )

            def proxy(item):
                """
                Fills in the proxy: for indexers tagged flaresolverr.

                :param dict item: Its schema (or itself)

                :return: The proxy
                """
                item.update({"name": "FlareSolverr", "tags": [tag_id]})

                return set_fields(item, {
                    "host": "http://flaresolverr:8191/",
                    "requestTimeout": 60,
                })

            arr.ensure(
                "/indexerproxy",
                lambda x: x["implementation"] == "FlareSolverr",
                proxy,
            )
        else:
            arr.remove(
                "/indexerproxy",
                lambda x: x["implementation"] == "FlareSolverr",
            )

        log(
            "Prowlarr: user %s, linked to %s%s, %s - add indexers in Prowlarr"
            % (
                USER,
                ", ".join(a["title"] for a in enabled_apps),
                " (FlareSolverr for indexers tagged flaresolverr)"
                if on("FLARESOLVERR")
                else "",
                "searching only by hand (Interactive Search)"
                if SEARCH_BY_HAND
                else "searching automatically",
            )
        )
    except (HttpError, KeyError, IndexError, ValueError, OSError) as error:
        problem("Prowlarr: %s" % error)

    ntfy(arr, "mag")


# -----------------------------------------------------------------------------
# ntfy

# The ntfy app, as the containers reach it (the NAS: host.docker.internal), and
# the name of the apps' connection to it (Settings -> Connect - any other the
# user added is left alone)
NTFY_URL = "http://host.docker.internal:2586"
NTFY_NAME = "ntfy (Arr stack)"
# What's sent: a release filed (once for it all - else per file), an upgrade, a
# download or import that failed, one that needs a person, health problems
# (and their end) - not grabs, renames, additions...
NTFY_EVENTS = (
    "onUpgrade",
    "onDownloadFailure",
    "onImportFailure",
    "onManualInteractionRequired",
    "onHealthIssue",
    "onHealthRestored",
)
NTFY_IMPORT_EVENTS = ("onImportComplete", "onReleaseImport", "onDownload")
# Seerr's notifications: a request awaiting approval, or approved by itself;
# available; failed; an issue reported
SEERR_NTFY_TYPES = 2 | 128 | 8 | 16 | 256
ntfy_token = None


def ntfy_setup():
    """
    The ntfy app's token for the NAS's apps (ntfy_token), if notifications are
    on and it's installed (and reachable from the apps).
    """
    global ntfy_token

    if not NTFY_TOPIC:
        return

    try:
        if not os.path.isfile(os.path.join(NTFY_APP, "apkg.rc")):
            raise OSError("not installed")

        with open(os.path.join(NTFY_DATA, "token")) as f:
            token = f.read().strip()
    except OSError:
        log(
            "ntfy: the ntfy app isn't installed - no notifications (install "
            "it, then save the recipe's settings again)"
        )

        return

    try:
        with open(os.path.join(NTFY_DATA, "settings")) as f:
            local = re.search(r"^LISTEN=local$", f.read(), re.M)
    except OSError:
        local = None

    if local:
        problem(
            "ntfy only listens on the NAS itself (its page: \"Listen on\") - "
            "the apps reach it from Docker: no notifications"
        )

        return

    ntfy_token = token


def ntfy(arr, tag):
    """
    The app's notifications, sent to the ntfy topic (or taken off, without
    ntfy).

    :param Arr arr: The app
    :param str tag: The notifications' tag (an emoji's name, e.g. tv)
    """
    ours = lambda x: (
        x["implementation"] == "Ntfy" and x.get("name") == NTFY_NAME
    )

    try:
        if not ntfy_token:
            arr.remove("/notification", ours)

            return

        def fill(item):
            """
            Fills in the connection: the events sent, the topic and token.

            :param dict item: Its schema (or itself)

            :return: The connection
            """
            item.update(
                {"name": NTFY_NAME, "tags": [], "includeHealthWarnings": False}
            )
            supported = lambda event: event in item and item.get(
                "supports" + event[0].upper() + event[1:], True
            )
            imported = (
                [e for e in NTFY_IMPORT_EVENTS if supported(e)] or [None]
            )[0]

            for event in [
                k
                for k in item
                if k.startswith("on") and isinstance(item[k], bool)
            ]:
                item[event] = bool(
                    supported(event)
                    and (event in NTFY_EVENTS or event == imported)
                )

            return set_fields(item, {
                "serverUrl": NTFY_URL,
                "accessToken": ntfy_token,
                "userName": "",
                "password": "",
                "priority": 3,
                "topics": [NTFY_TOPIC],
                "tags": [tag],
                "clickUrl": "",
            })

        # It sends a test notification as it's first saved - refused if ntfy doesn't answer
        arr.ensure(
            "/notification",
            lambda x: x["implementation"] == "Ntfy"
            and x.get("name", "") in ("", NTFY_NAME),
            fill,
        )
        log("%s: notifications to ntfy (topic %s)" % (arr.title, NTFY_TOPIC))
    except (HttpError, KeyError, IndexError, ValueError, OSError) as error:
        problem("%s: notifications to ntfy: %s" % (arr.title, error))


# -----------------------------------------------------------------------------
# Bazarr

BAZARR = "http://127.0.0.1:6767"


def bazarr_key():
    """
    Bazarr's API key, from its settings.

    :return: The key, or None
    """
    code, config = docker(
        "exec", "bazarr", "cat", "/config/config/config.yaml"
    )
    match = re.search(
        r"^auth:\s*\n(?:[ \t]+.*\n)*?[ \t]+apikey:\s*'?([0-9a-f]+)'?",
        config,
        re.M,
    )

    return match.group(1) if code == 0 and match else None


def bazarr():
    """
    Sets up Bazarr: its login, Sonarr and Radarr, and - the first time - a
    subtitle language and sources that need no account.
    """
    if not wait_for(
        "Bazarr",
        lambda: bazarr_key() is not None
        and http(
            "GET",
            BAZARR + "/api/system/status",
            headers={"X-API-KEY": bazarr_key()},
        )[0] == 200,
    ):
        return

    key = bazarr_key()
    status, text, _ = http(
        "GET",
        BAZARR + "/api/system/languages/profiles",
        headers={"X-API-KEY": key},
    )
    profiles = json.loads(text) if status == 200 else []
    form = [
        ("settings-auth-type", "form"),
        ("settings-auth-username", USER),
        ("settings-auth-password", PASSWORD),
        ("settings-general-use_sonarr", "true"),
        ("settings-sonarr-ip", "sonarr"),
        ("settings-sonarr-port", "8989"),
        ("settings-sonarr-apikey", ENV.get("SONARR_API_KEY", "")),
        ("settings-sonarr-base_url", "/"),
        ("settings-sonarr-ssl", "false"),
        ("settings-general-use_radarr", "true"),
        ("settings-radarr-ip", "radarr"),
        ("settings-radarr-port", "7878"),
        ("settings-radarr-apikey", ENV.get("RADARR_API_KEY", "")),
        ("settings-radarr-base_url", "/"),
        ("settings-radarr-ssl", "false"),
    ]

    if not profiles:
        # The first time: the chosen language, a profile with it for every
        # series and film, and sources needing no account
        form += [
            ("languages-enabled", LANGUAGE),
            ("languages-profiles", json.dumps([{
                "profileId": 1,
                "name": LANGUAGE,
                "cutoff": None,
                "mustContain": [],
                "mustNotContain": [],
                "originalFormat": False,
                "tag": None,
                "items": [{
                    "id": 1,
                    "language": LANGUAGE,
                    "audio_exclude": "False",
                    "audio_only_include": "False",
                    "hi": "False",
                    "forced": "False",
                }],
            }])),
            ("settings-general-serie_default_enabled", "true"),
            ("settings-general-serie_default_profile", "1"),
            ("settings-general-movie_default_enabled", "true"),
            ("settings-general-movie_default_profile", "1"),
            ("settings-general-enabled_providers", "podnapisi"),
            ("settings-general-enabled_providers", "embeddedsubtitles"),
        ]

    if INSTALLING:
        # No anonymous usage data sent to its developers - on by default
        form.append(("settings-analytics-enabled", "false"))

    status, text, _ = http(
        "POST",
        BAZARR + "/api/system/settings",
        headers={"X-API-KEY": key},
        form=form,
    )

    if status not in (200, 204):
        problem(
            "Bazarr's settings weren't saved: %s %s" % (status, text[:200])
        )
    else:
        log(
            "Bazarr: user %s, linked to Sonarr and Radarr%s"
            % (USER, ", subtitles in %s" % LANGUAGE if not profiles else "")
        )


# -----------------------------------------------------------------------------
# Recyclarr

# The TRaSH Guides' quality profiles it makes (their ids in the guides, and
# names): 1080p, then 4K
QUALITY_PROFILES = {
    "sonarr": [
        ("72dae194fc92bf828f32cde7744e51a1", "WEB-1080p"),
        ("d1498e7d189fbe6c7110ceaabb7473e6", "WEB-2160p"),
    ],
    "radarr": [
        ("d1d67249d3890e49bc12e275d989a7e9", "HD Bluray + WEB"),
        ("64fb5f9858489bdac2af690e27c8f42f", "UHD Bluray + WEB"),
    ],
}
# The profiles Sonarr and Radarr start with
STOCK_PROFILES = (
    "Any",
    "SD",
    "HD-720p",
    "HD-1080p",
    "Ultra-HD",
    "HD - 720p/1080p",
)
RECYCLARR_HEADER = (
    "# Written by the Arr stack recipe (its quality rules): rewritten by its "
    "setup while this line is here\n"
)


def recyclarr_config():
    """
    Recyclarr's settings: the TRaSH Guides' quality profiles, in Sonarr and
    Radarr.

    :return: Its recyclarr.yml
    """
    lines = [
        RECYCLARR_HEADER.rstrip("\n"),
        "# - remove it to make this file your own (https://recyclarr.dev/). "
        "The API keys come from the container's environment",
    ]

    for kind, port, definition in (
        ("sonarr", 8989, "series"),
        ("radarr", 7878, "movie"),
    ):
        lines += [
            "%s:" % kind,
            "  %s:" % kind,
            "    base_url: http://%s:%d" % (kind, port),
            "    api_key: !env_var %s_API_KEY" % kind.upper(),
            "    quality_definition:",
            "      type: %s" % definition,
            "    quality_profiles:",
        ]

        for trash_id, name in QUALITY_PROFILES[kind]:
            lines += [
                "      - trash_id: %s  # %s" % (trash_id, name),
                "        reset_unmatched_scores:",
                "          enabled: true",
            ]

    return "\n".join(lines) + "\n"


def recyclarr():
    """
    The quality profiles, synced now (Recyclarr then syncs them daily).

    :return: Whether they're there
    """
    if not RECYCLARR:
        return False

    folder = os.path.join(CONFIG_ROOT, "recyclarr")
    path = os.path.join(folder, "recyclarr.yml")

    try:
        os.makedirs(folder, exist_ok=True)
        os.chown(folder, PUID, PGID)
        mine = os.path.isfile(path) and not open(path).read().startswith(
            RECYCLARR_HEADER
        )

        if mine:
            log(
                "Recyclarr: its settings (recyclarr/recyclarr.yml) are your "
                "own - left as they are"
            )
        else:
            with open(path, "w") as f:
                f.write(recyclarr_config())

            os.chown(path, PUID, PGID)
    except OSError as error:
        problem("Recyclarr's settings couldn't be written: %s" % error)

        return False

    if not wait_for("Recyclarr", lambda: container_running("recyclarr")):
        return False

    # The first time, it downloads the guides: a minute or two
    code, output = docker("exec", "recyclarr", "recyclarr", "sync")

    if code != 0:
        problem(
            "Recyclarr's sync failed (it tries again daily): %s"
            % output.strip()[-400:]
        )

        return False

    if not mine:
        log(
            "Recyclarr: the TRaSH Guides' profiles in Sonarr (%s) and Radarr "
            "(%s), kept up to date daily"
            % (
                ", ".join(n for _, n in QUALITY_PROFILES["sonarr"]),
                ", ".join(n for _, n in QUALITY_PROFILES["radarr"]),
            )
        )

    return True


# -----------------------------------------------------------------------------
# Seerr

def seerr(quality_rules):
    """
    Sets up Seerr: Sonarr and Radarr (with the profile requests are made
    with), searching (SEARCH), and its notifications to ntfy.

    :param bool quality_rules: Whether Recyclarr's quality profiles are there
    """
    if not wait_for(
        "Seerr",
        lambda: http("GET", "http://127.0.0.1:5055/api/v1/status")[0] == 200
        and docker(
            "exec", "seerr", "test", "-f", "/app/config/settings.json"
        )[0] == 0,
    ):
        return

    code, text = docker("exec", "seerr", "cat", "/app/config/settings.json")

    try:
        settings = json.loads(text)
    except ValueError:
        problem("Seerr's settings couldn't be read")

        return

    changed = False

    for app, kind in (
        (LIBRARY_APPS[0], "sonarr"),
        (LIBRARY_APPS[1], "radarr"),
    ):
        try:
            arr = Arr(
                app["title"], app["port"], app["api"], ENV.get(app["key"], "")
            )
            profiles = arr.call("GET", "/qualityprofile")
            # The quality rules' profile chosen (QUALITY), else a 1080p one if
            # there is one: the usual choice for a home library
            names = (
                [QUALITY_PROFILES[kind][1 if QUALITY == "2160p" else 0][1]]
                if quality_rules
                else []
            )
            profile = (
                [p for p in profiles if p["name"] in names]
                or [
                    p
                    for p in profiles
                    if p["name"] in ("HD-1080p", "HD - 720p/1080p")
                ]
                or profiles
            )[0]
        except (HttpError, IndexError, ValueError) as error:
            problem("Seerr: %s's profiles: %s" % (app["title"], error))

            continue

        if settings.get(kind):
            # Already set: only its profile changes - to the quality rules'
            # chosen one, from one Sonarr or Radarr started with (or the
            # quality rules' other): one chosen in Seerr is kept
            entry = settings[kind][0]

            # Requests searched for, or not (SEARCH)
            if entry.get("preventSearch") != SEARCH_BY_HAND:
                entry["preventSearch"] = SEARCH_BY_HAND
                changed = True

            # Its folder for new requests: the first library folder, if the
            # one it has was the recipe's and is no longer chosen
            roots = [in_container(folder) for folder in library_folders(app)]

            for field in ("activeDirectory", "activeAnimeDirectory"):
                current = (entry.get(field) or "").rstrip("/")

                if (
                    field in entry
                    and current not in roots
                    and (
                        current.startswith("/data/media/")
                        or current.startswith("/media/")
                    )
                ):
                    entry[field] = roots[0]
                    changed = True

            ruled = STOCK_PROFILES + tuple(
                n for _, n in QUALITY_PROFILES[kind]
            )

            if quality_rules and profile["name"] in names:
                for field in ("activeProfile", "activeAnimeProfile"):
                    if (
                        entry.get(field + "Name") in ruled
                        and entry.get(field + "Id") != profile["id"]
                    ):
                        entry.update({
                            field + "Id": profile["id"],
                            field + "Name": profile["name"],
                        })
                        changed = True

            continue

        entry = {
            "id": 0,
            "name": app["title"],
            "hostname": app["name"],
            "port": app["port"],
            "apiKey": ENV.get(app["key"], ""),
            "useSsl": False,
            "baseUrl": "",
            "activeProfileId": profile["id"],
            "activeProfileName": profile["name"],
            "activeDirectory": in_container(library_folders(app)[0]),
            "tags": [],
            "is4k": False,
            "isDefault": True,
            "externalUrl": "",
            "syncEnabled": True,
            "preventSearch": SEARCH_BY_HAND,
            "tagRequests": False,
            "overrideRule": [],
        }

        if kind == "sonarr":
            entry.update({
                "seriesType": "standard",
                "animeSeriesType": "anime",
                "activeAnimeProfileId": profile["id"],
                "activeAnimeProfileName": profile["name"],
                "activeAnimeDirectory": entry["activeDirectory"],
                "animeTags": [],
                "enableSeasonFolders": True,
                "monitorNewItems": "all",
            })
        else:
            entry["minimumAvailability"] = "released"

        settings[kind] = [entry]
        changed = True

    # Its notifications to ntfy: set the first time (what's sent may then be
    # changed in Seerr), and kept pointing at the ntfy app - one set up by
    # hand (another address) is left alone
    agent = (
        settings.setdefault("notifications", {})
        .setdefault("agents", {})
        .setdefault("ntfy", {})
    )
    options = agent.setdefault("options", {})

    if options.get("url", "") in ("", NTFY_URL):
        before = json.dumps(agent, sort_keys=True)

        if ntfy_token:
            if not options.get("url"):
                agent.update({
                    "enabled": True,
                    "types": SEERR_NTFY_TYPES,
                    "embedPoster": agent.get("embedPoster", True),
                })

            options.update({
                "url": NTFY_URL,
                "topic": NTFY_TOPIC,
                "authMethodToken": True,
                "token": ntfy_token,
                "authMethodUsernamePassword": False,
                "priority": options.get("priority", 3),
                "tags": options.get("tags", ""),
            })
        elif options.get("url"):
            agent["enabled"] = False

        changed = changed or json.dumps(agent, sort_keys=True) != before

    if changed:
        # Written through its own container, then read again as it restarts
        code, output = docker(
            "exec", "-i", "seerr", "sh", "-c",
            "cat > /app/config/settings.json.new && mv "
            "/app/config/settings.json.new /app/config/settings.json",
            stdin=json.dumps(settings, indent=1).encode(),
        )

        if code != 0:
            problem("Seerr's settings couldn't be written: " + output)

        docker("restart", "seerr")
        log(
            "Seerr: linked to Sonarr and Radarr, requesting with their "
            "profiles %s - open it to choose your media server (Jellyfin or "
            "Plex)"
            % " and ".join(
                str((settings.get(k) or [{}])[0].get("activeProfileName"))
                for k in ("sonarr", "radarr")
            )
        )


# -----------------------------------------------------------------------------

def main():
    """
    Connects everything, in order: the folders, then each app.

    :return: The exit code: 0, or 1 if there were problems
    """
    folders()

    # Optional apps switched off: their containers go (Docker Compose leaves
    # them running otherwise)
    for option, container in OPTIONAL.items():
        if not on(option) and docker("inspect", container)[0] == 0:
            docker("rm", "-f", container)
            log("Removed %s (switched off)" % container)

    enabled = [
        app
        for app in LIBRARY_APPS
        if app["option"] is None or on(app["option"])
    ]
    ntfy_setup()
    qbittorrent()
    sab_api_key = sabnzbd()

    for app in enabled:
        library_app(app, sab_api_key)

    radarr_flat_films()
    prowlarr(enabled)
    quality_rules = recyclarr()
    bazarr()
    seerr(quality_rules)

    if problems:
        log(
            "Finished with %d problem(s) - the rest is connected"
            % len(problems)
        )

        return 1

    log("Everything is connected")

    return 0


if __name__ == "__main__":
    sys.exit(main())
