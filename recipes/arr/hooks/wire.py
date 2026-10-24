"""Connects the arr stack's apps to each other, as a person would in their settings pages - run by hooks/wire.sh after an
install, an update or a change of settings (the Store's post_install, post_update and post_change hooks), with .env's
values in the environment. Everything it does can be done again: it only adds what's missing and updates what changed.

 - the data folder's layout (torrents/, usenet/, media/ - one file system, so downloads are hard-linked into the library)
 - one user name and password for every web interface (qBittorrent, Prowlarr, Sonarr, Radarr, Lidarr, Bookshelf, Bazarr,
   SABnzbd)
 - qBittorrent: its save folder, a category per app, its listening port
 - Sonarr, Radarr (and Lidarr, Bookshelf): their library folder, qBittorrent (and SABnzbd) as download clients, renaming
 - Prowlarr: Sonarr, Radarr (and Lidarr, Bookshelf) as applications - indexers added in Prowlarr reach them all - and
   FlareSolverr as a proxy for indexers tagged "flaresolverr"
 - SABnzbd: its folders, a category per app, the address the other apps reach it at
 - Bazarr: Sonarr and Radarr, a subtitle language, subtitle sources that need no account
 - Seerr: Sonarr and Radarr (its own setup page then only asks for the media server - Jellyfin or Plex)
 - optional apps switched off: their container removed, and their links in Prowlarr

Written for Python 3.9 (the NAS's own) and its standard library only.
"""
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
TORRENT_PORT = int(ENV.get("TORRENT_PORT", "6881"))
LANGUAGE = ENV.get("SUBTITLE_LANGUAGE", "en")
# (how long to wait for an app to answer: the first start of some takes minutes on the NAS)
READY_TIMEOUT = int(ENV.get("WIRE_READY_TIMEOUT", "600"))
# The recipe's folder (where the Store runs its hooks)
DATA = ENV.get("STORE_DATA") or os.getcwd()
# The password last given to qBittorrent: it only takes a new one from someone logged in with the old one (root only,
# next to .env - which holds the password too)
QBIT_PASSWORD_FILE = os.path.join(DATA, ".qbittorrent-password")


def on(name):
    return ENV.get(name, "off") == "on"


# The library apps: name, port, API version, its key's setting, the option switching it on (None: always), its folder
# in media/ and its category's setting name in download clients
LIBRARY_APPS = [
    {"name": "sonarr", "title": "Sonarr", "port": 8989, "api": "v3", "key": "SONARR_API_KEY", "option": None,
     "folder": "tv", "category": "tvCategory", "rename": "renameEpisodes", "prowlarr": "Sonarr"},
    {"name": "radarr", "title": "Radarr", "port": 7878, "api": "v3", "key": "RADARR_API_KEY", "option": None,
     "folder": "movies", "category": "movieCategory", "rename": "renameMovies", "prowlarr": "Radarr"},
    {"name": "lidarr", "title": "Lidarr", "port": 8686, "api": "v1", "key": "LIDARR_API_KEY", "option": "LIDARR",
     "folder": "music", "category": "musicCategory", "rename": "renameTracks", "prowlarr": "Lidarr"},
    {"name": "bookshelf", "title": "Bookshelf", "port": 8787, "api": "v1", "key": "BOOKSHELF_API_KEY", "option": "BOOKS",
     # (Readarr - which Bookshelf continues - kept Lidarr's name for its download clients' category)
     "folder": "books", "category": "musicCategory", "rename": "renameBooks", "prowlarr": "Readarr"},
]
# Optional containers, by their option
OPTIONAL = {"LIDARR": "lidarr", "BOOKS": "bookshelf", "SABNZBD": "sabnzbd", "FLARESOLVERR": "flaresolverr"}

problems = []


def log(text):
    print(text, flush=True)


def problem(text):
    problems.append(text)
    log("Problem: " + text)


class HttpError(Exception):
    def __init__(self, status, body):
        super().__init__("HTTP %s: %s" % (status, body[:300]))
        self.status = status


def http(method, url, headers=None, body=None, form=None, timeout=30):
    """A request: (status, body as text, response). body is sent as JSON, form as a URL-encoded form"""
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form, doseq=True).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace"), response
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace"), error


def wait_for(title, check):
    """Waits for check() to be true, up to READY_TIMEOUT seconds"""
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
    """Runs docker, returning its output (stdout and stderr)"""
    result = subprocess.run(["docker"] + list(args), input=stdin, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return result.returncode, result.stdout.decode("utf-8", "replace")


def container_running(name):
    code, output = docker("inspect", "-f", "{{.State.Running}}", name)
    return code == 0 and output.strip() == "true"


# ---------------------------------------------------------------------------------------------------------------------
# The data folder

def folders():
    if not DATA_ROOT:
        return
    names = ["torrents", "usenet/incomplete", "media"]
    for app in LIBRARY_APPS:
        names += ["torrents/" + app["folder"], "usenet/complete/" + app["folder"], "media/" + app["folder"]]
    for name in names:
        path = os.path.join(DATA_ROOT, name)
        if not os.path.isdir(path):
            os.makedirs(path)
            log("Created " + path)
        # (the apps' user and the share group; new files and folders inside keep the group - setgid)
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


# ---------------------------------------------------------------------------------------------------------------------
# qBittorrent

QBIT = "http://127.0.0.1:8090"


def qbit_login(password, previous=False):
    # (the temporary password is admin's; the others are the user name's - which may have changed too, so the previous
    # password is tried with both)
    users = [USER] if password == PASSWORD else (["admin"] if not previous else [USER, "admin"])
    for user in users:
        sid = qbit_login_as(user, password)
        if sid:
            return sid
    return None


def qbit_login_as(user, password):
    status, text, response = http("POST", QBIT + "/api/v2/auth/login", headers={"Referer": QBIT},
                                  form={"username": user, "password": password})
    # (qBittorrent 5 answers 204 with no text; earlier versions 200 "Ok.")
    if status == 204 or (status == 200 and text.strip() == "Ok."):
        cookie = response.headers.get("Set-Cookie", "")
        match = re.search(r"(SID|QBT_SID_\d+)=([^;]+)", cookie)
        return match.group(0) if match else None
    return None


def qbittorrent():
    if not wait_for("qBittorrent", lambda: http("GET", QBIT + "/api/v2/app/version")[0] in (200, 401, 403)):
        return
    sid = qbit_login(PASSWORD)
    if not sid and os.path.isfile(QBIT_PASSWORD_FILE):
        # The password was changed: the previous one
        with open(QBIT_PASSWORD_FILE) as f:
            sid = qbit_login(f.read().strip(), previous=True)
    if not sid:
        # The first time: the temporary password it logs (as user admin)
        code, logs = docker("logs", "qbittorrent")
        found = re.findall(r"temporary password is provided for this session: (\S+)", logs)
        sid = qbit_login(found[-1]) if found else None
    if not sid:
        problem("Couldn't log in to qBittorrent (its password was changed in qBittorrent?)")
        return
    headers = {"Cookie": sid, "Referer": QBIT}
    preferences = {
        "web_ui_username": USER,
        "web_ui_password": PASSWORD,
        "save_path": "/data/torrents",
        "temp_path_enabled": False,
        "listen_port": TORRENT_PORT,
        "upnp": False,
        # (reached through the Nginx app's address too, and by the other apps by its container's name)
        "web_ui_host_header_validation_enabled": False,
        # Torrents of the apps' categories go in their folder (automatic torrent management)
        "auto_tmm_enabled": True,
        "torrent_changed_tmm_enabled": True,
        "save_path_changed_tmm_enabled": True,
        "category_changed_tmm_enabled": True,
    }
    status, text, _ = http("POST", QBIT + "/api/v2/app/setPreferences", headers=headers,
                           form={"json": json.dumps(preferences)})
    if status != 200:
        problem("qBittorrent's settings weren't saved: %s %s" % (status, text[:200]))
    else:
        fd = os.open(QBIT_PASSWORD_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(PASSWORD)
    status, text, _ = http("GET", QBIT + "/api/v2/torrents/categories", headers=headers)
    existing = json.loads(text) if status == 200 else {}
    for app in LIBRARY_APPS:
        category = app["folder"]
        path = "/data/torrents/" + category
        if category not in existing:
            http("POST", QBIT + "/api/v2/torrents/createCategory", headers=headers, form={"category": category, "savePath": path})
        elif existing[category].get("savePath") != path:
            http("POST", QBIT + "/api/v2/torrents/editCategory", headers=headers, form={"category": category, "savePath": path})
    log("qBittorrent: user %s, saving to /data/torrents (a category per app), listening on port %d" % (USER, TORRENT_PORT))


# ---------------------------------------------------------------------------------------------------------------------
# SABnzbd

SAB = "http://127.0.0.1:8085"


def sab_key():
    code, ini = docker("exec", "sabnzbd", "cat", "/config/sabnzbd.ini")
    match = re.search(r"^api_key\s*=\s*(\S+)", ini, re.M)
    return match.group(1) if code == 0 and match else None


def sabnzbd():
    if not on("SABNZBD"):
        return None
    if not wait_for("SABnzbd", lambda: sab_key() is not None and http("GET", SAB + "/api?mode=version&output=json")[0] == 200):
        return None
    key = sab_key()

    def setting(section, keyword, value):
        status, text, _ = http("GET", SAB + "/api?" + urllib.parse.urlencode(
            {"mode": "set_config", "section": section, "keyword": keyword, "value": value, "apikey": key, "output": "json"}))
        if status != 200:
            problem("SABnzbd's %s %s wasn't saved: %s" % (section, keyword, text[:200]))

    # (it only answers addresses it knows: the other apps reach it as "sabnzbd")
    status, text, _ = http("GET", SAB + "/api?" + urllib.parse.urlencode(
        {"mode": "get_config", "section": "misc", "keyword": "host_whitelist", "apikey": key, "output": "json"}))
    hosts = []
    try:
        value = json.loads(text)["config"]["misc"]["host_whitelist"]
        hosts = [h for h in (value if isinstance(value, list) else value.split(",")) if h.strip()]
    except (ValueError, KeyError, TypeError):
        pass
    if "sabnzbd" not in hosts:
        setting("misc", "host_whitelist", ",".join(hosts + ["sabnzbd"]))
    setting("misc", "download_dir", "/data/usenet/incomplete")
    setting("misc", "complete_dir", "/data/usenet/complete")
    setting("misc", "username", USER)
    setting("misc", "password", PASSWORD)
    for app in LIBRARY_APPS:
        http("GET", SAB + "/api?" + urllib.parse.urlencode(
            {"mode": "set_config", "section": "categories", "name": app["folder"], "dir": app["folder"], "apikey": key,
             "output": "json"}))
    log("SABnzbd: user %s, downloading to /data/usenet (a category per app) - add your Usenet provider in its settings" % USER)
    return key


# ---------------------------------------------------------------------------------------------------------------------
# Sonarr, Radarr, Lidarr, Bookshelf and Prowlarr (the same API, by version)

class Arr:
    def __init__(self, title, port, api, key):
        self.title = title
        self.base = "http://127.0.0.1:%d/api/%s" % (port, api)
        self.key = key

    def call(self, method, path, body=None):
        status, text, _ = http(method, self.base + path, headers={"X-Api-Key": self.key}, body=body)
        if status >= 400:
            raise HttpError(status, text)
        return json.loads(text) if text.strip() else None

    def ready(self):
        return wait_for(self.title, lambda: http("GET", self.base + "/system/status", headers={"X-Api-Key": self.key})[0] == 200)

    def login(self):
        """Its web interface: a login page, with the user name and password"""
        host = self.call("GET", "/config/host")
        host.update({"authenticationMethod": "forms", "authenticationRequired": "enabled", "username": USER,
                     "password": PASSWORD, "passwordConfirmation": PASSWORD})
        self.call("PUT", "/config/host/%s" % host["id"], host)

    def ensure(self, path, match, item, schema_path=None):
        """Adds (or updates) a thing - a download client, an application... - from its schema: match picks the existing one,
        item(schema) fills in the fields"""
        existing = [x for x in self.call("GET", path) if match(x)]
        schema = existing[0] if existing else [x for x in self.call("GET", schema_path or path + "/schema") if match(x)][0]
        wanted = item(json.loads(json.dumps(schema)))
        if existing:
            if wanted != existing[0]:
                self.call("PUT", "%s/%s?forceSave=true" % (path, existing[0]["id"]), wanted)
        else:
            self.call("POST", path + "?forceSave=true", wanted)

    def remove(self, path, match):
        for thing in self.call("GET", path):
            if match(thing):
                self.call("DELETE", "%s/%s" % (path, thing["id"]))


def set_fields(item, values):
    for field in item.get("fields", []):
        if field["name"] in values:
            field["value"] = values[field["name"]]
    return item


def library_app(app, sab_api_key):
    arr = Arr(app["title"], app["port"], app["api"], ENV.get(app["key"], ""))
    if not arr.ready():
        return
    try:
        arr.login()
        folder = "/data/media/" + app["folder"]
        if not any(r["path"].rstrip("/") == folder for r in arr.call("GET", "/rootfolder")):
            root = {"path": folder}
            if app["api"] == "v1":
                # (Lidarr and Bookshelf: a name, and the profiles new artists or authors get)
                root.update({"name": app["title"], "defaultQualityProfileId": arr.call("GET", "/qualityprofile")[0]["id"],
                             "defaultMetadataProfileId": arr.call("GET", "/metadataprofile")[0]["id"],
                             "defaultMonitorOption": "all", "defaultNewItemMonitorOption": "all", "defaultTags": [],
                             "isCalibreLibrary": False})
            arr.call("POST", "/rootfolder", root)

        def client(implementation, values):
            def fill(item):
                item.update({"enable": True, "name": implementation if implementation != "QBittorrent" else "qBittorrent",
                             "priority": 1, "removeCompletedDownloads": True, "removeFailedDownloads": True})
                return set_fields(item, values)
            arr.ensure("/downloadclient", lambda x: x["implementation"] == implementation, fill)

        client("QBittorrent", {"host": "qbittorrent", "port": 8090, "username": USER, "password": PASSWORD,
                               app["category"]: app["folder"]})
        if sab_api_key:
            client("Sabnzbd", {"host": "sabnzbd", "port": 8080, "apiKey": sab_api_key, "username": USER,
                               "password": PASSWORD, app["category"]: app["folder"]})
        else:
            arr.remove("/downloadclient", lambda x: x["implementation"] == "Sabnzbd")
        # Files renamed as they're imported (tidy names for Jellyfin and Plex)
        naming = arr.call("GET", "/config/naming")
        if app["rename"] in naming and not naming[app["rename"]]:
            naming[app["rename"]] = True
            arr.call("PUT", "/config/naming/%s" % naming["id"], naming)
        log("%s: user %s, library %s, downloads through qBittorrent%s" % (app["title"], USER, folder, " and SABnzbd" if sab_api_key else ""))
    except (HttpError, KeyError, IndexError, ValueError) as error:
        problem("%s: %s" % (app["title"], error))


def prowlarr(enabled_apps):
    arr = Arr("Prowlarr", 9696, "v1", ENV.get("PROWLARR_API_KEY", ""))
    if not arr.ready():
        return
    try:
        arr.login()
        for app in LIBRARY_APPS:
            match = lambda x, app=app: x["implementation"] == app["prowlarr"]
            if app in enabled_apps:
                def fill(item, app=app):
                    item.update({"name": app["title"], "syncLevel": "fullSync"})
                    return set_fields(item, {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": "http://%s:%d" % (app["name"], app["port"]),
                                             "apiKey": ENV.get(app["key"], "")})
                arr.ensure("/applications", match, fill)
            else:
                arr.remove("/applications", match)
        tags = arr.call("GET", "/tag")
        tag = [t for t in tags if t["label"] == "flaresolverr"]
        if on("FLARESOLVERR"):
            tag_id = tag[0]["id"] if tag else arr.call("POST", "/tag", {"label": "flaresolverr"})["id"]
            def proxy(item):
                item.update({"name": "FlareSolverr", "tags": [tag_id]})
                return set_fields(item, {"host": "http://flaresolverr:8191/", "requestTimeout": 60})
            arr.ensure("/indexerproxy", lambda x: x["implementation"] == "FlareSolverr", proxy)
        else:
            arr.remove("/indexerproxy", lambda x: x["implementation"] == "FlareSolverr")
        log("Prowlarr: user %s, linked to %s%s - add indexers in Prowlarr" % (USER, ", ".join(a["title"] for a in enabled_apps),
            " (FlareSolverr for indexers tagged flaresolverr)" if on("FLARESOLVERR") else ""))
    except (HttpError, KeyError, IndexError, ValueError) as error:
        problem("Prowlarr: %s" % error)


# ---------------------------------------------------------------------------------------------------------------------
# Bazarr

BAZARR = "http://127.0.0.1:6767"


def bazarr_key():
    code, config = docker("exec", "bazarr", "cat", "/config/config/config.yaml")
    match = re.search(r"^auth:\s*\n(?:[ \t]+.*\n)*?[ \t]+apikey:\s*'?([0-9a-f]+)'?", config, re.M)
    return match.group(1) if code == 0 and match else None


def bazarr():
    if not wait_for("Bazarr", lambda: bazarr_key() is not None and http("GET", BAZARR + "/api/system/status", headers={"X-API-KEY": bazarr_key()})[0] == 200):
        return
    key = bazarr_key()
    status, text, _ = http("GET", BAZARR + "/api/system/languages/profiles", headers={"X-API-KEY": key})
    profiles = json.loads(text) if status == 200 else []
    form = [
        ("settings-auth-type", "form"), ("settings-auth-username", USER), ("settings-auth-password", PASSWORD),
        ("settings-general-use_sonarr", "true"), ("settings-sonarr-ip", "sonarr"), ("settings-sonarr-port", "8989"),
        ("settings-sonarr-apikey", ENV.get("SONARR_API_KEY", "")), ("settings-sonarr-base_url", "/"), ("settings-sonarr-ssl", "false"),
        ("settings-general-use_radarr", "true"), ("settings-radarr-ip", "radarr"), ("settings-radarr-port", "7878"),
        ("settings-radarr-apikey", ENV.get("RADARR_API_KEY", "")), ("settings-radarr-base_url", "/"), ("settings-radarr-ssl", "false"),
    ]
    if not profiles:
        # The first time: the chosen language, a profile with it for every series and film, and sources needing no account
        form += [
            ("languages-enabled", LANGUAGE),
            ("languages-profiles", json.dumps([{"profileId": 1, "name": LANGUAGE, "cutoff": None, "mustContain": [], "mustNotContain": [],
                                                "originalFormat": False, "tag": None,
                                                "items": [{"id": 1, "language": LANGUAGE, "audio_exclude": "False",
                                                           "audio_only_include": "False", "hi": "False", "forced": "False"}]}])),
            ("settings-general-serie_default_enabled", "true"), ("settings-general-serie_default_profile", "1"),
            ("settings-general-movie_default_enabled", "true"), ("settings-general-movie_default_profile", "1"),
            ("settings-general-enabled_providers", "podnapisi"), ("settings-general-enabled_providers", "embeddedsubtitles"),
        ]
    status, text, _ = http("POST", BAZARR + "/api/system/settings", headers={"X-API-KEY": key}, form=form)
    if status not in (200, 204):
        problem("Bazarr's settings weren't saved: %s %s" % (status, text[:200]))
    else:
        log("Bazarr: user %s, linked to Sonarr and Radarr%s" % (USER, ", subtitles in %s" % LANGUAGE if not profiles else ""))


# ---------------------------------------------------------------------------------------------------------------------
# Seerr

def seerr():
    if not wait_for("Seerr", lambda: http("GET", "http://127.0.0.1:5055/api/v1/status")[0] == 200 and
                    docker("exec", "seerr", "test", "-f", "/app/config/settings.json")[0] == 0):
        return
    code, text = docker("exec", "seerr", "cat", "/app/config/settings.json")
    try:
        settings = json.loads(text)
    except ValueError:
        problem("Seerr's settings couldn't be read")
        return
    changed = False
    for app, kind in ((LIBRARY_APPS[0], "sonarr"), (LIBRARY_APPS[1], "radarr")):
        if settings.get(kind):
            continue
        try:
            arr = Arr(app["title"], app["port"], app["api"], ENV.get(app["key"], ""))
            profiles = arr.call("GET", "/qualityprofile")
            # (a 1080p profile if there is one: the usual choice for a home library)
            profile = ([p for p in profiles if p["name"] in ("HD-1080p", "HD - 720p/1080p")] or profiles)[0]
        except (HttpError, IndexError, ValueError) as error:
            problem("Seerr: %s's profiles: %s" % (app["title"], error))
            continue
        entry = {"id": 0, "name": app["title"], "hostname": app["name"], "port": app["port"], "apiKey": ENV.get(app["key"], ""),
                 "useSsl": False, "baseUrl": "", "activeProfileId": profile["id"], "activeProfileName": profile["name"],
                 "activeDirectory": "/data/media/" + app["folder"], "tags": [], "is4k": False, "isDefault": True,
                 "externalUrl": "", "syncEnabled": True, "preventSearch": False, "tagRequests": False, "overrideRule": []}
        if kind == "sonarr":
            entry.update({"seriesType": "standard", "animeSeriesType": "anime", "activeAnimeProfileId": profile["id"],
                          "activeAnimeProfileName": profile["name"], "activeAnimeDirectory": entry["activeDirectory"],
                          "animeTags": [], "enableSeasonFolders": True, "monitorNewItems": "all"})
        else:
            entry["minimumAvailability"] = "released"
        settings[kind] = [entry]
        changed = True
    if changed:
        # (written through its own container, then read again as it restarts)
        code, output = docker("exec", "-i", "seerr", "sh", "-c", "cat > /app/config/settings.json.new && mv /app/config/settings.json.new /app/config/settings.json",
                              stdin=json.dumps(settings, indent=1).encode())
        if code != 0:
            problem("Seerr's settings couldn't be written: " + output)
        docker("restart", "seerr")
        log("Seerr: linked to Sonarr and Radarr - open it to choose your media server (Jellyfin or Plex)")


# ---------------------------------------------------------------------------------------------------------------------

def main():
    folders()
    # Optional apps switched off: their containers go (Docker Compose leaves them running otherwise)
    for option, container in OPTIONAL.items():
        if not on(option) and docker("inspect", container)[0] == 0:
            docker("rm", "-f", container)
            log("Removed %s (switched off)" % container)
    enabled = [app for app in LIBRARY_APPS if app["option"] is None or on(app["option"])]
    qbittorrent()
    sab_api_key = sabnzbd()
    for app in enabled:
        library_app(app, sab_api_key)
    prowlarr(enabled)
    bazarr()
    seerr()
    if problems:
        log("Finished with %d problem(s) - the rest is connected" % len(problems))
        return 1
    log("Everything is connected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
