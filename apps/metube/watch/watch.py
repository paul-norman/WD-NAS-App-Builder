"""The Watch page's server: each household member's own downloads, through
MeTube (which never shows itself to them), with a player and clean-up. Run as
MeTube's user by metube_ctl.sh, with the app's own Python (MeTube's, with
aiohttp):

    python3 watch.py --data <Nas_Prog/_metube> --static <folder> \\
        --host 127.0.0.1 --port 8086 --metube http://127.0.0.1:8085

What it reads (written by the management page, as root):
    users.json     {"users": {"<name>": {"hash": "pbkdf2_sha256$<rounds>$
                   <salt>$<hex>"}}}
    settings.json  {"download_dir": ..., "watched_days": 3,
                   "unwatched_days": 30, "media_server": {"type": "plex" |
                   "jellyfin" | "emby" | "", "url", "token", "path_from",
                   "path_to"}}
    secret         what sessions are signed with
What it keeps (its own): watch/<name>.json - each person's kept and watched
videos, the videos cut by SponsorBlock, and their own settings (clean-up
days, playback speed, SponsorBlock).

Each person's videos are in <download_dir>/<name>/ (MeTube's folder for
their downloads). A video is deleted (unless kept) a number of days after it
was last watched - here, or in the media server, if one is set - or, never
watched, a number of days after it was downloaded (0: never).
"""
import argparse
import asyncio
import hashlib
import hmac
import json
import logging
import math
import mimetypes
import os
import re
import shutil
import time
import urllib.parse

import aiohttp
from aiohttp import web

MEDIA = (
    ".mp4", ".m4v", ".mkv", ".webm", ".mov",
    ".m4a", ".mp3", ".opus", ".ogg", ".flac", ".wav",
)
AUDIO = (".m4a", ".mp3", ".opus", ".ogg", ".flac", ".wav")
IMAGES = (".jpg", ".jpeg", ".webp", ".png")
# Files yt-dlp writes beside a video (deleted with it)
SIDECARS = IMAGES + (".info.json", ".vtt", ".srt", ".description")
SESSION_DAYS = 30
COOKIE = "watch_session"
CLEAN_EVERY = 3600
MEDIA_SERVER_CACHE = 600
DAY = 86400
# Playback speeds the player offers (0.25 steps)
SPEEDS = [x / 4 for x in range(1, 13)]
# SponsorBlock: its categories (what the page offers), the ones skipped by
# default, how long its answers are kept, and its API (another for the tests)
SPONSOR_CATEGORIES = (
    "sponsor", "selfpromo", "interaction", "intro", "outro", "preview",
    "hook", "music_offtopic", "filler",
)
SPONSOR_DEFAULT = ["sponsor", "selfpromo", "interaction"]
SPONSOR_CACHE = 3600
SPONSOR_API = os.environ.get(
    "WATCH_SPONSORBLOCK_URL", "https://sponsor.ajay.app"
).rstrip("/")
# The site and video's ID at the end of a file's name, as the app names
# downloads: Title [Site id].ext (yt-dlp's extractor, e.g. Youtube, Vimeo),
# or Title [id].ext before 2026.11.14-2 - hidden on the page, the site shown
# as a label, and YouTube's IDs (11 characters) looked up in SponsorBlock
ID_PATTERN = re.compile(
    r" \[(?:([A-Z][A-Za-z0-9]{0,39}) )?([^\]/]{1,64})\]$"
)
YOUTUBE_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
# Sites' names as people write them (others shown as yt-dlp names them;
# Generic - a plain link - not shown)
SITE_NAMES = {"Youtube": "YouTube", "Generic": None, "BiliBili": "Bilibili",
              "Twitch": "Twitch", "Vimeo": "Vimeo", "Dailymotion":
              "Dailymotion", "SoundCloud": "SoundCloud", "TikTok": "TikTok"}
# A playlist's (or channel's) video: its position, before its title -
# "<playlist>/001 - Title [id].ext"
INDEX_PATTERN = re.compile(r"^(\d{1,5}) - ")
# How many of a playlist's videos one link adds by default, and at most
# (0: all of them)
PLAYLIST_LIMIT = 25
PLAYLIST_LIMIT_MAX = 1000
# A playlist's name, as a person makes one (its folder's)
_UNSAFE = r"/\\:*?\"<>|\x00-\x1f"
PLAYLIST_NAME = re.compile(rf"^[^{_UNSAFE}.][^{_UNSAFE}]{{0,99}}$")
# A video's title, as a person renames it
TITLE = re.compile(rf"^[^{_UNSAFE}.][^{_UNSAFE}]{{0,149}}$")
# yt-dlp's errors for videos YouTube itself refuses, in plain words
REFUSALS = (
    ("not made this video available in your country",
     "Not available in this country"),
    ("Private video", "Private on YouTube"),
    ("confirm your age", "Age-restricted (needs a signed-in account)"),
    ("Sign in to confirm", "YouTube wants a sign-in (it suspects a bot)"),
    ("members-only", "Members only"),
    ("Video unavailable", "Removed or unavailable on YouTube"),
    ("This video is not available", "Removed or unavailable on YouTube"),
)

log = logging.getLogger("watch")


class Store:
    """
    The app's files: users and settings (reloaded when they change), the
    session secret, and each person's state.
    """

    def __init__(self, data):
        """
        Reads the files of the app's data folder.

        :param str data: Nas_Prog/_metube
        """
        self.data = data
        self.cache = {}
        with open(os.path.join(data, "secret"), "rb") as file:
            self.secret = file.read().strip()

    def _json(self, name, default):
        """
        A JSON file of the data folder, read again only once it changed.

        :param str  name:    Its name
        :param dict default: What to give if it's missing or broken

        :return: Its contents
        """
        path = os.path.join(self.data, name)

        try:
            mtime = os.stat(path).st_mtime_ns
        except OSError:
            return default

        cached = self.cache.get(name)

        if cached and cached[0] == mtime:
            return cached[1]

        try:
            with open(path, encoding="utf-8") as file:
                value = json.load(file)
        except (OSError, ValueError):
            log.warning("could not read %s", path)

            return cached[1] if cached else default

        self.cache[name] = (mtime, value)

        return value

    def users(self):
        """
        The users, as the management page wrote them.

        :return: Each user's entry, by name
        """
        return self._json("users.json", {}).get("users", {})

    def settings(self):
        """
        The app's settings, with their defaults.

        :return: The settings
        """
        settings = {
            "download_dir": "",
            "watched_days": 3,
            "unwatched_days": 30,
            "media_server": {},
        }
        settings.update(self._json("settings.json", {}))

        return settings

    def state(self, name):
        """
        A person's own state: their kept and watched videos, their settings.

        :param str name: The user

        :return: Their state
        """
        path = os.path.join(self.data, "watch", f"{name}.json")

        try:
            with open(path, encoding="utf-8") as file:
                state = json.load(file)
        except (OSError, ValueError):
            state = {}

        state.setdefault("kept", {})
        state.setdefault("watched", {})
        state.setdefault("cut", {})
        state.setdefault("playlists", [])
        state.setdefault("settings", {})

        return state

    def save_state(self, name, state):
        """
        Saves a person's state (in one step).

        :param str  name:  The user
        :param dict state: Their state
        """
        folder = os.path.join(self.data, "watch")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"{name}.json")
        temp = f"{path}.tmp"

        with open(temp, "w", encoding="utf-8") as file:
            json.dump(state, file)

        os.replace(temp, path)

    def days(self, state):
        """
        A person's clean-up days: their own, else the app's defaults.

        :param dict state: Their state

        :return: (days after watched, days if never watched), 0 for never
        """
        settings = self.settings()
        own = state["settings"]

        return (
            int(own.get("watched_days", settings["watched_days"])),
            int(own.get("unwatched_days", settings["unwatched_days"])),
        )

    def preferences(self, state):
        """
        A person's player settings, with their defaults.

        :param dict state: Their state

        :return: speed, sb_skip, sb_categories, sb_cut
        """
        own = state["settings"]

        return {
            "speed": float(own.get("speed", 1)),
            "sb_skip": bool(own.get("sb_skip", True)),
            "sb_categories": list(own.get("sb_categories", SPONSOR_DEFAULT)),
            "sb_cut": bool(own.get("sb_cut", False)),
        }

    def folder(self, name):
        """
        A person's download folder.

        :param str name: The user

        :return: Its path, or "" when no download folder is set
        """
        root = self.settings()["download_dir"]

        return os.path.join(root, name) if root else ""


def video_ids(stem):
    """
    A file name's site and video ID, as the app names downloads.

    :param str stem: The file's name without its extension

    :return: (where the [...] starts, its site's name or None, its YouTube
             ID or None) - (None, None, None) when it has none
    """
    match = ID_PATTERN.search(stem)

    if not match:
        return None, None, None

    site, video_id = match.group(1), match.group(2)
    youtube = (YOUTUBE_ID.match(video_id) and site in (None, "Youtube"))

    return (match.start(), SITE_NAMES.get(site, site) if site else
            ("YouTube" if youtube else None),
            video_id if youtube else None)


def check_password(password, stored):
    """
    Whether a password matches its stored PBKDF2-SHA256 hash.

    :param str password: The password given
    :param str stored:   pbkdf2_sha256$<rounds>$<salt>$<hex>

    :return: Whether it matches
    """
    try:
        kind, rounds, salt, digest = stored.split("$", 3)
        rounds = int(rounds)
    except ValueError:
        return False

    if kind != "pbkdf2_sha256":
        return False

    made = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), salt.encode(), rounds
    ).hex()

    return hmac.compare_digest(made, digest)


def sign(store, name, expires):
    """
    A session cookie's value.

    :param Store store:   The app's files
    :param str   name:    The user
    :param int   expires: When it expires (Unix time)

    :return: The value
    """
    text = f"{name}|{expires}"
    mac = hmac.new(store.secret, text.encode(), hashlib.sha256).hexdigest()

    return f"{text}|{mac}"


def session_user(request):
    """
    The user logged in, from the session cookie (still a user, not
    expired).

    :param web.Request request: The request

    :return: Their name, or None
    """
    store = request.app["store"]
    value = request.cookies.get(COOKIE, "")
    parts = value.split("|")

    if len(parts) != 3:
        return None

    name, expires = parts[0], parts[1]

    if not hmac.compare_digest(sign(store, name, expires), value):
        return None

    if not expires.isdigit() or int(expires) < time.time():
        return None

    return name if name in store.users() else None


def need_user(request):
    """
    The user logged in - or a 401 answer.

    :param web.Request request: The request

    :return: Their name
    :raises web.HTTPUnauthorized: When nobody is logged in
    """
    name = session_user(request)

    if not name:
        raise web.HTTPUnauthorized(text="Not logged in")

    return name


async def need_post(request):
    """
    The JSON posted by the page (which marks its requests: another site's
    form can't).

    :param web.Request request: The request

    :return: What was posted
    :raises web.HTTPForbidden: When it's not the page's request
    """
    if request.headers.get("X-Requested-With") != "watch":
        raise web.HTTPForbidden(text="Not from the Watch page")

    try:
        data = await request.json()
    except ValueError:
        raise web.HTTPBadRequest(text="Not JSON")

    if not isinstance(data, dict):
        raise web.HTTPBadRequest(text="Not an object")

    return data


def inside(folder, relative):
    """
    A path inside a folder (never outside it, through .. or a link).

    :param str folder:   The folder
    :param str relative: The path, relative to it

    :return: The full path
    :raises web.HTTPForbidden: When it's outside the folder
    """
    base = os.path.realpath(folder)
    path = os.path.realpath(os.path.join(base, relative))

    if not path.startswith(base + os.sep):
        raise web.HTTPForbidden(text="Not yours")

    return path


def media_files(folder):
    """
    The videos and audio in a person's folder (and its playlist folders).

    :param str folder: The folder

    :return: Their paths, relative to it
    """
    found = []

    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if not d.startswith(".")]

        for name in files:
            if name.lower().endswith(MEDIA) and not name.startswith("."):
                path = os.path.join(root, name)
                found.append(os.path.relpath(path, folder))

    return sorted(found)


def thumbnail(folder, relative):
    """
    The thumbnail yt-dlp wrote beside a video, if any.

    :param str folder:   The person's folder
    :param str relative: The video, relative to it

    :return: The thumbnail's path relative to the folder, or None
    """
    stem = os.path.splitext(relative)[0]

    for ext in IMAGES:
        if os.path.isfile(os.path.join(folder, stem + ext)):
            return stem + ext

    return None


def remove_video(folder, relative):
    """
    Deletes a video and the files yt-dlp wrote beside it.

    :param str folder:   The person's folder
    :param str relative: The video, relative to it
    """
    path = inside(folder, relative)
    stem = os.path.splitext(path)[0]

    for other in [path] + [stem + ext for ext in SIDECARS]:
        try:
            os.remove(other)
        except FileNotFoundError:
            pass

    # A playlist's folder, once empty
    parent = os.path.dirname(path)

    if parent != os.path.realpath(folder):
        try:
            os.rmdir(parent)
        except OSError:
            pass


def tidy_playlist(store, name, relative):
    """
    Removes a downloaded playlist's folder once its last video is gone - with
    what yt-dlp left in it beside the videos (the playlist's own thumbnail and
    details). A person's own playlists (New playlist) stay, even empty.

    :param Store store:    The app's files
    :param str   name:     The user
    :param str   relative: The video removed, relative to their folder
    """
    if "/" not in relative:
        return

    playlist = relative.split("/")[0]
    folder = store.folder(name)
    path = os.path.join(folder, playlist)

    if playlist in store.state(name)["playlists"] or not os.path.isdir(path):
        return

    if not any(media_files(path)):
        shutil.rmtree(inside(folder, playlist), ignore_errors=True)


async def metube(app, method, path, body=None):
    """
    Calls MeTube's API.

    :param web.Application app:    This server
    :param str             method: GET or POST
    :param str             path:   Its path (e.g. history)
    :param dict            body:   What to post, as JSON

    :return: Its answer, decoded
    :raises web.HTTPBadGateway: When MeTube doesn't answer as expected
    """
    url = app["metube"] + "/" + path

    try:
        async with app["client"].request(
            method, url, json=body, timeout=aiohttp.ClientTimeout(total=30)
        ) as response:
            text = await response.text()

            if response.status != 200:
                raise web.HTTPBadGateway(
                    text=f"MeTube: {response.status} {text[:200]}"
                )

            return json.loads(text) if text else {}
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as error:
        raise web.HTTPBadGateway(text=f"MeTube isn't answering: {error}")


def mine(name, item):
    """
    Whether one of MeTube's downloads is a person's (its folder theirs).

    :param str  name: The user
    :param dict item: MeTube's download

    :return: Whether it's theirs
    """
    folder = (item.get("folder") or "").strip("/")

    return folder == name or folder.startswith(name + "/")


async def forget(app, name, relative):
    """
    Removes a deleted video from MeTube's list of finished downloads.

    :param web.Application app:      This server
    :param str             name:     The user
    :param str             relative: The video, relative to their folder
    """
    try:
        history = await metube(app, "GET", "history")
    except web.HTTPException:
        return

    base = os.path.basename(relative)
    ids = [
        item["url"] for item in history.get("done", [])
        if mine(name, item) and os.path.basename(
            item.get("filename") or ""
        ) == base and item.get("url")
    ]

    if ids:
        try:
            await metube(
                app, "POST", "delete",
                {"ids": ids, "where": "done", "delete_files": False},
            )
        except web.HTTPException:
            pass


def map_path(server, path):
    """
    A media server's path for a file, as this NAS sees it.

    :param dict server: The media server's settings
    :param str  path:   Its path

    :return: The NAS's path
    """
    source = (server.get("path_from") or "").rstrip("/")
    target = (server.get("path_to") or "").rstrip("/")

    if source and (path == source or path.startswith(source + "/")):
        return target + path[len(source):]

    return path


def iso_time(text):
    """
    Unix time from an ISO date (Jellyfin's and Emby's).

    :param str text: The date, e.g. 2026-11-17T10:20:30.0000000Z

    :return: The time, or 0
    """
    try:
        text = text.rstrip("Z").split(".")[0]

        return int(time.mktime(time.strptime(text, "%Y-%m-%dT%H:%M:%S"))
                   - time.timezone)
    except (ValueError, AttributeError):
        return 0


async def media_server_played(app, root):
    """
    When each file under the download folder was last played in the media
    server (any of its users), cached for a while. Only read: nothing is
    changed there.

    :param web.Application app:  This server
    :param str             root: The download folder

    :return: Last played times (Unix), by the file's path on this NAS
    """
    server = app["store"].settings().get("media_server") or {}
    kind = server.get("type") or ""

    if not kind or not server.get("url") or not server.get("token"):
        return {}

    cached = app.get("played")

    if cached and time.time() - cached[0] < MEDIA_SERVER_CACHE:
        return cached[1]

    played = {}

    try:
        if kind == "plex":
            played = await plex_played(app, server, root)
        else:
            played = await jellyfin_played(app, server, root)
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError,
            KeyError, TypeError) as error:
        log.warning("media server (%s): %s", kind, error)

        return cached[1] if cached else {}

    app["played"] = (time.time(), played)

    return played


async def get_json(app, url, headers):
    """
    Fetches JSON from a media server.

    :param web.Application app:     This server
    :param str             url:     Its address
    :param dict            headers: Headers to send (e.g. its token)

    :return: The answer, decoded
    """
    async with app["client"].get(
        url, headers=headers, timeout=aiohttp.ClientTimeout(total=60)
    ) as response:
        response.raise_for_status()

        return await response.json(content_type=None)


async def jellyfin_played(app, server, root):
    """
    Last played times from Jellyfin or Emby (their APIs are the same here):
    every user's played items, by path.

    :param web.Application app:    This server
    :param dict            server: The media server's settings
    :param str             root:   The download folder

    :return: Last played times, by path
    """
    base = server["url"].rstrip("/")
    headers = {"X-Emby-Token": server["token"], "Accept": "application/json"}
    played = {}

    for user in await get_json(app, f"{base}/Users", headers):
        url = (
            f"{base}/Users/{user['Id']}/Items?Recursive=true&IsPlayed=true"
            "&Fields=Path&EnableUserData=true"
        )
        items = (await get_json(app, url, headers)).get("Items", [])

        for item in items:
            path = map_path(server, item.get("Path") or "")
            data = item.get("UserData") or {}
            when = iso_time(data.get("LastPlayedDate") or "")

            if path.startswith(root + "/"):
                played[path] = max(played.get(path, 0), when or 1)

    return played


async def plex_played(app, server, root):
    """
    Last played times from Plex (the token's account): the items of the
    libraries with a folder under the download folder.

    :param web.Application app:    This server
    :param dict            server: The media server's settings
    :param str             root:   The download folder

    :return: Last played times, by path
    """
    base = server["url"].rstrip("/")
    headers = {"X-Plex-Token": server["token"], "Accept": "application/json"}
    sections = await get_json(app, f"{base}/library/sections", headers)
    played = {}

    for section in sections["MediaContainer"].get("Directory", []):
        places = [
            map_path(server, place.get("path") or "")
            for place in section.get("Location", [])
        ]

        if not any(p == root or p.startswith(root + "/")
                   or root.startswith(p + "/") for p in places):
            continue

        url = f"{base}/library/sections/{section['key']}/all"
        container = (await get_json(app, url, headers))["MediaContainer"]

        for item in container.get("Metadata", []):
            when = int(item.get("lastViewedAt") or 0)

            if not when and not item.get("viewCount"):
                continue

            for media in item.get("Media", []):
                for part in media.get("Part", []):
                    path = map_path(server, part.get("file") or "")

                    if path.startswith(root + "/"):
                        played[path] = max(played.get(path, 0), when or 1)

    return played


async def videos_of(app, name):
    """
    A person's videos, with what the page shows of each.

    :param web.Application app:  This server
    :param str             name: The user

    :return: Their videos (newest first)
    """
    store = app["store"]
    folder = store.folder(name)

    if not folder or not os.path.isdir(folder):
        return []

    state = store.state(name)
    watched_days, unwatched_days = store.days(state)
    played = await media_server_played(app, store.settings()["download_dir"])
    now = time.time()
    videos = []

    for relative in media_files(folder):
        path = os.path.join(folder, relative)

        try:
            info = os.stat(path)
        except OSError:
            continue

        here = state["watched"].get(relative, 0)
        there = played.get(path, 0)
        last = max(here, there)
        kept = bool(state["kept"].get(relative))

        if kept:
            deleted = None
        elif last:
            deleted = last + watched_days * DAY if watched_days else None
        else:
            deleted = (info.st_ctime + unwatched_days * DAY
                       if unwatched_days else None)

        stem = os.path.splitext(os.path.basename(relative))[0]
        start, site, video_id = video_ids(stem)
        title = stem[:start] if start is not None else stem
        playlist = relative.split("/")[0] if "/" in relative else None
        position = INDEX_PATTERN.match(title) if playlist else None

        if position:
            title = title[position.end():]

        videos.append({
            "file": relative,
            "title": title,
            "playlist": playlist,
            "index": int(position.group(1)) if position else None,
            "video_id": video_id,
            "site": site,
            "cut": bool(state["cut"].get(relative)),
            "audio": relative.lower().endswith(AUDIO),
            "size": info.st_size,
            "added": int(info.st_ctime),
            "thumbnail": thumbnail(folder, relative),
            "watched": int(last) or None,
            "watched_elsewhere": bool(there and there >= here),
            "kept": kept,
            "deleted_after": int(deleted) if deleted else None,
            "days_left": (max(0, int(math.ceil((deleted - now) / DAY)))
                          if deleted else None),
        })

    videos.sort(key=lambda v: v["added"], reverse=True)

    return videos


async def clean(app):
    """
    Deletes the videos due for clean-up, for every person.

    :param web.Application app: This server

    :return: How many were deleted
    """
    store = app["store"]
    deleted = 0

    for name in list(store.users()):
        folder = store.folder(name)

        for video in await videos_of(app, name):
            due = video["deleted_after"]

            if due and due <= time.time():
                remove_video(folder, video["file"])
                state = store.state(name)
                state["kept"].pop(video["file"], None)
                state["watched"].pop(video["file"], None)
                store.save_state(name, state)
                tidy_playlist(store, name, video["file"])
                await forget(app, name, video["file"])
                log.warning("clean-up: deleted %s's %s", name, video["file"])
                deleted += 1

    return deleted


async def clean_loop(app):
    """
    Runs the clean-up every hour.

    :param web.Application app: This server
    """
    while True:
        try:
            await clean(app)
        except Exception:
            log.exception("clean-up failed")

        await asyncio.sleep(CLEAN_EVERY)


async def handle_login(request):
    """
    Logs in (name and password): sets the session cookie.

    :param web.Request request: The request

    :return: The answer
    """
    data = await need_post(request)
    name = str(data.get("name", "")).strip().lower()
    password = str(data.get("password", ""))
    user = request.app["store"].users().get(name)

    if not user or not check_password(password, user.get("hash", "")):
        await asyncio.sleep(1)

        raise web.HTTPUnauthorized(text="Wrong name or password")

    expires = int(time.time()) + SESSION_DAYS * DAY
    response = web.json_response({"name": name})
    secure = request.headers.get("X-Forwarded-Proto") == "https"
    response.set_cookie(
        COOKIE, sign(request.app["store"], name, expires),
        max_age=SESSION_DAYS * DAY, httponly=True, samesite="Lax",
        secure=secure, path="/",
    )

    return response


async def handle_logout(request):
    """
    Logs out.

    :param web.Request request: The request

    :return: The answer
    """
    await need_post(request)
    response = web.json_response({})
    response.del_cookie(COOKIE, path="/")

    return response


async def handle_videos(request):
    """
    The person's videos, their downloads in progress (or failed), and their
    clean-up days.

    :param web.Request request: The request

    :return: The answer
    """
    name = need_user(request)
    app = request.app
    queue = []

    try:
        history = await metube(app, "GET", "history")
    except web.HTTPException as error:
        history = {}
        queue.append({"id": "", "title": error.text, "status": "error"})

    for where in ("queue", "pending", "done"):
        for item in history.get(where, []):
            if not mine(name, item):
                continue

            if where == "done" and item.get("status") != "error":
                continue

            queue.append({
                "id": item.get("url") or "",
                "where": "done" if where == "done" else "queue",
                "title": item.get("title") or item.get("url") or "",
                "status": item.get("status") or "",
                "percent": item.get("percent"),
                "speed": item.get("speed"),
                "eta": item.get("eta"),
                "error": plain_error(item.get("msg") or item.get("error")
                                     or ""),
            })

    store = app["store"]
    remember_cut(store, name, history)
    state = store.state(name)
    watched_days, unwatched_days = store.days(state)
    settings = store.preferences(state)
    settings.update({
        "watched_days": watched_days,
        "unwatched_days": unwatched_days,
    })

    return web.json_response({
        "name": name,
        "folder": bool(store.folder(name)),
        "videos": await videos_of(app, name),
        "playlists": playlists_of(store.folder(name)),
        "queue": queue,
        "settings": settings,
        "speeds": SPEEDS,
        "sponsor_categories": SPONSOR_CATEGORIES,
    })


def plain_error(text):
    """
    A download's error in plain words, when it's YouTube refusing the video
    (else as yt-dlp gave it).

    :param str text: yt-dlp's error

    :return: The error to show
    """
    for words, plain in REFUSALS:
        if words.lower() in text.lower():
            return plain

    return text


def playlist_folder(store, name, playlist):
    """
    One of a person's playlists: its folder (which must exist).

    :param Store store:    The app's files
    :param str   name:     The user
    :param str   playlist: The playlist's name

    :return: Its folder
    :raises web.HTTPNotFound: When there's no such playlist
    """
    folder = store.folder(name)

    if not folder or not PLAYLIST_NAME.match(playlist):
        raise web.HTTPNotFound(text="No such playlist")

    path = inside(folder, playlist)

    if not os.path.isdir(path):
        raise web.HTTPNotFound(text="No such playlist")

    return path


def playlists_of(folder):
    """
    A person's playlists: the folders in theirs (empty ones too).

    :param str folder: Their folder

    :return: The playlists' names
    """
    try:
        entries = os.listdir(folder)
    except OSError:
        return []

    return sorted(
        entry for entry in entries
        if not entry.startswith(".")
        and os.path.isdir(os.path.join(folder, entry))
    )


def remember_cut(store, name, history):
    """
    Remembers which of a person's videos MeTube downloaded with their
    sponsor segments cut out (its history may be cleared later): the player
    mustn't skip segments in them - their times have moved.

    :param Store store:   The app's files
    :param str   name:    The user
    :param dict  history: MeTube's history
    """
    folder = store.folder(name)

    if not folder:
        return

    cut = {
        os.path.basename(item.get("filename") or "")
        for item in history.get("done", [])
        if mine(name, item) and item.get("sponsorblock")
        and item.get("status") == "finished"
    }
    cut.discard("")

    if not cut:
        return

    state = store.state(name)
    changed = False

    for relative in media_files(folder):
        if os.path.basename(relative) in cut and relative not in state["cut"]:
            state["cut"][relative] = True
            changed = True

    if changed:
        store.save_state(name, state)


async def handle_add(request):
    """
    Has MeTube download a link into the person's folder: video (MP4, H.264
    where there is one - what browsers and phones play) or audio.

    :param web.Request request: The request

    :return: MeTube's answer
    """
    name = need_user(request)
    data = await need_post(request)
    url = str(data.get("url", "")).strip()
    kind = data.get("kind")
    quality = str(data.get("quality") or "best")

    if not url.startswith(("http://", "https://")):
        raise web.HTTPBadRequest(text="Give a link (https://...)")

    if not request.app["store"].folder(name):
        raise web.HTTPConflict(text="No download folder is set up yet")

    if kind == "audio":
        audio_format = data.get("format")

        if audio_format not in ("m4a", "mp3", "opus"):
            audio_format = "m4a"

        body = {"download_type": "audio", "format": audio_format,
                "quality": "best"}
    else:
        if quality not in ("best", "2160", "1440", "1080", "720", "480",
                           "360"):
            quality = "best"

        state = request.app["store"].state(name)
        cut = request.app["store"].preferences(state)["sb_cut"]
        body = {"download_type": "video", "format": "mp4", "codec": "h264",
                "quality": quality, "sponsorblock": cut}

    # A playlist's or channel's first videos only, unless asked for all
    try:
        limit = int(data.get("limit", PLAYLIST_LIMIT))
    except (TypeError, ValueError):
        limit = PLAYLIST_LIMIT

    if not 0 <= limit <= PLAYLIST_LIMIT_MAX:
        limit = PLAYLIST_LIMIT

    # Into one of their playlists, if asked
    folder = name
    playlist = str(data.get("playlist") or "")

    if playlist:
        playlist_folder(request.app["store"], name, playlist)
        folder = f"{name}/{playlist}"

    body.update({"url": url, "folder": folder, "auto_start": True,
                 "playlist_item_limit": limit})

    return web.json_response(await metube(request.app, "POST", "add", body))


async def handle_cancel(request):
    """
    Cancels a download in progress, or clears a failed one (the person's
    own only).

    :param web.Request request: The request

    :return: The answer
    """
    name = need_user(request)
    data = await need_post(request)
    item_id = str(data.get("id", ""))
    where = "done" if data.get("where") == "done" else "queue"
    history = await metube(request.app, "GET", "history")
    lists = ("done",) if where == "done" else ("queue", "pending")
    found = any(
        item.get("url") == item_id and mine(name, item)
        for key in lists for item in history.get(key, [])
    )

    if not found:
        raise web.HTTPNotFound(text="No such download")

    await metube(request.app, "POST", "delete",
                 {"ids": [item_id], "where": where, "delete_files": False})

    return web.json_response({})


def video_of(request, data):
    """
    The person's folder and the video a request names (which must be
    there).

    :param web.Request request: The request
    :param dict        data:    What was posted (its file)

    :return: (user, folder, the video relative to the folder)
    """
    name = need_user(request)
    folder = request.app["store"].folder(name)
    relative = str(data.get("file", ""))

    if not folder or not relative.lower().endswith(MEDIA):
        raise web.HTTPNotFound(text="No such video")

    if not os.path.isfile(inside(folder, relative)):
        raise web.HTTPNotFound(text="No such video")

    return name, folder, relative


async def handle_delete(request):
    """
    Deletes one of the person's videos.

    :param web.Request request: The request

    :return: The answer
    """
    data = await need_post(request)
    name, folder, relative = video_of(request, data)
    store = request.app["store"]
    remove_video(folder, relative)
    state = store.state(name)
    state["kept"].pop(relative, None)
    state["watched"].pop(relative, None)
    store.save_state(name, state)
    tidy_playlist(store, name, relative)
    await forget(request.app, name, relative)

    return web.json_response({})


async def handle_delete_playlist(request):
    """
    Deletes one of the person's playlists: its folder and its videos -
    except the ones they kept (the playlist then stays, with them).

    :param web.Request request: The request

    :return: How many were deleted, and how many kept stay
    """
    name = need_user(request)
    data = await need_post(request)
    store = request.app["store"]
    folder = store.folder(name)
    playlist = str(data.get("playlist", ""))
    path = playlist_folder(store, name, playlist)
    state = store.state(name)
    deleted = kept = 0

    for relative in media_files(folder):
        if not relative.startswith(playlist + "/"):
            continue

        if state["kept"].get(relative):
            kept += 1

            continue

        remove_video(folder, relative)
        state["watched"].pop(relative, None)
        state["cut"].pop(relative, None)
        await forget(request.app, name, relative)
        deleted += 1

    # Its folder too, unless a kept video is still in it - with what yt-dlp
    # left beside the videos (the playlist's thumbnail and details)
    if not kept:
        shutil.rmtree(path, ignore_errors=True)

        if playlist in state["playlists"]:
            state["playlists"].remove(playlist)

    store.save_state(name, state)

    return web.json_response({"deleted": deleted, "kept": kept})


def move_state(state, old, new, playlist=False):
    """
    Moves a person's state from a video's old name to its new one (or, for a
    playlist, every video in it).

    :param dict state:    Their state
    :param str  old:      The old name, relative to their folder
    :param str  new:      The new name
    :param bool playlist: Whether they're a playlist's folders
    """
    for key in ("kept", "watched", "cut"):
        moved = {}

        for relative, value in state[key].items():
            if relative == old:
                moved[new] = value
            elif playlist and relative.startswith(old + "/"):
                moved[new + relative[len(old):]] = value
            else:
                moved[relative] = value

        state[key] = moved


async def handle_rename(request):
    """
    Renames one of the person's videos: its title only - its playlist
    number, ID and type stay, and what yt-dlp wrote beside it (its thumbnail)
    is renamed with it.

    :param web.Request request: The request

    :return: Its new name, relative to their folder
    """
    data = await need_post(request)
    name, folder, relative = video_of(request, data)
    title = " ".join(str(data.get("title", "")).split())

    if not TITLE.match(title):
        raise web.HTTPBadRequest(
            text="Titles are up to 150 characters, without / \\ : * ? \" < > |"
                 " (and not starting with a dot)"
        )

    directory, base = os.path.split(relative)
    stem, ext = os.path.splitext(base)
    start = video_ids(stem)[0]
    suffix = stem[start:] if start is not None else ""
    shown = stem[:start] if start is not None else stem
    position = INDEX_PATTERN.match(shown) if directory else None
    prefix = shown[:position.end()] if position else ""
    new_stem = f"{prefix}{title}{suffix}"
    new = os.path.join(directory, new_stem + ext)

    if new == relative:
        return web.json_response({"file": relative})

    old_path = inside(folder, relative)
    new_path = inside(folder, new)

    if os.path.exists(new_path):
        raise web.HTTPConflict(text="There's already a video with that title")

    os.rename(old_path, new_path)

    for extra in SIDECARS:
        try:
            os.rename(os.path.splitext(old_path)[0] + extra,
                      os.path.splitext(new_path)[0] + extra)
        except OSError:
            pass

    store = request.app["store"]
    state = store.state(name)
    move_state(state, relative, new)
    store.save_state(name, state)
    # (MeTube's history knows it by its old name)
    await forget(request.app, name, relative)

    return web.json_response({"file": new})


async def handle_rename_playlist(request):
    """
    Renames one of the person's playlists (its folder).

    :param web.Request request: The request

    :return: Its new name
    """
    name = need_user(request)
    data = await need_post(request)
    store = request.app["store"]
    folder = store.folder(name)
    playlist = str(data.get("playlist", ""))
    path = playlist_folder(store, name, playlist)
    new = " ".join(str(data.get("name", "")).split())

    if not PLAYLIST_NAME.match(new):
        raise web.HTTPBadRequest(
            text="Playlist names are up to 100 characters, without / \\ : "
                 "* ? \" < > | (and not starting with a dot)"
        )

    if new == playlist:
        return web.json_response({"name": new})

    if os.path.exists(inside(folder, new)):
        raise web.HTTPConflict(text=f"There's already a playlist called {new}")

    os.rename(path, inside(folder, new))
    state = store.state(name)
    move_state(state, playlist, new, playlist=True)

    if playlist in state["playlists"]:
        state["playlists"][state["playlists"].index(playlist)] = new

    store.save_state(name, state)

    return web.json_response({"name": new})


async def handle_new_playlist(request):
    """
    Makes one of the person's own playlists: a folder in theirs, which
    downloads can go into.

    :param web.Request request: The request

    :return: Its name
    """
    name = need_user(request)
    data = await need_post(request)
    store = request.app["store"]
    folder = store.folder(name)
    playlist = str(data.get("name", "")).strip()

    if not folder:
        raise web.HTTPConflict(text="No download folder is set up yet")

    if not PLAYLIST_NAME.match(playlist):
        raise web.HTTPBadRequest(
            text="Playlist names are up to 100 characters, without / \\ : "
                 "* ? \" < > | (and not starting with a dot)"
        )

    path = inside(folder, playlist)

    if os.path.exists(path):
        raise web.HTTPConflict(text=f"There's already a playlist called "
                                    f"{playlist}")

    os.makedirs(path)
    os.chmod(path, 0o2775)
    # (one of theirs: it stays when empty, unlike a downloaded playlist's)
    state = store.state(name)
    state["playlists"].append(playlist)
    store.save_state(name, state)

    return web.json_response({"name": playlist})


async def handle_keep(request):
    """
    Keeps one of the person's videos from the clean-up (or not).

    :param web.Request request: The request

    :return: The answer
    """
    data = await need_post(request)
    name, _, relative = video_of(request, data)
    store = request.app["store"]
    state = store.state(name)

    if data.get("keep"):
        state["kept"][relative] = True
    else:
        state["kept"].pop(relative, None)

    store.save_state(name, state)

    return web.json_response({"kept": bool(data.get("keep"))})


async def handle_watched(request):
    """
    Marks one of the person's videos watched now (the player, near its
    end), or not watched.

    :param web.Request request: The request

    :return: The answer
    """
    data = await need_post(request)
    name, _, relative = video_of(request, data)
    store = request.app["store"]
    state = store.state(name)

    if data.get("watched", True):
        state["watched"][relative] = int(time.time())
    else:
        state["watched"].pop(relative, None)

    store.save_state(name, state)

    return web.json_response({})


async def handle_settings(request):
    """
    Saves any of the person's own settings given: clean-up days (0: never),
    playback speed, SponsorBlock (skipping in the player, its categories,
    cutting sponsors from new downloads).

    :param web.Request request: The request

    :return: The answer
    """
    name = need_user(request)
    data = await need_post(request)
    store = request.app["store"]
    state = store.state(name)
    own = state["settings"]

    for key in ("watched_days", "unwatched_days"):
        if key not in data:
            continue

        try:
            value = int(data[key])
        except (TypeError, ValueError):
            raise web.HTTPBadRequest(text=f"{key}: a number of days")

        if not 0 <= value <= 3650:
            raise web.HTTPBadRequest(text=f"{key}: 0 to 3650 days")

        own[key] = value

    if "speed" in data:
        try:
            speed = float(data["speed"])
        except (TypeError, ValueError):
            speed = 0

        if speed not in SPEEDS:
            raise web.HTTPBadRequest(text="speed: 0.25 to 3, in 0.25 steps")

        own["speed"] = speed

    for key in ("sb_skip", "sb_cut"):
        if key in data:
            own[key] = bool(data[key])

    if "sb_categories" in data:
        categories = data["sb_categories"]

        if not isinstance(categories, list) or any(
            c not in SPONSOR_CATEGORIES for c in categories
        ):
            raise web.HTTPBadRequest(text="sb_categories: unknown category")

        own["sb_categories"] = sorted(set(categories))

    store.save_state(name, state)

    return web.json_response({})


async def sponsor_segments(app, video_id):
    """
    A YouTube video's SponsorBlock segments (every category), cached for a
    while. Asked by the first 4 characters of the ID's SHA-256 (SponsorBlock's
    private lookup: it never learns which video it was), then picked out here.

    :param web.Application app:      This server
    :param str             video_id: The video's ID

    :return: Its segments: (start, end, category), seconds
    """
    cache = app["segments"]
    cached = cache.get(video_id)

    if cached and time.time() - cached[0] < SPONSOR_CACHE:
        return cached[1]

    prefix = hashlib.sha256(video_id.encode()).hexdigest()[:4]
    categories = json.dumps(list(SPONSOR_CATEGORIES))
    url = (f"{SPONSOR_API}/api/skipSegments/{prefix}?categories="
           f"{urllib.parse.quote(categories)}")
    segments = []

    try:
        async with app["client"].get(
            url, timeout=aiohttp.ClientTimeout(total=10),
            headers={"User-Agent": "nas-watch-page"},
        ) as response:
            # (404: no segments for any video with that prefix)
            if response.status == 200:
                for video in await response.json(content_type=None):
                    if video.get("videoID") != video_id:
                        continue

                    for item in video.get("segments", []):
                        start, end = item["segment"][:2]

                        if item.get("actionType", "skip") == "skip":
                            segments.append(
                                (float(start), float(end), item["category"])
                            )
            elif response.status != 404:
                return cached[1] if cached else []
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError,
            KeyError, TypeError) as error:
        log.warning("SponsorBlock: %s", error)

        return cached[1] if cached else []

    segments.sort()
    cache[video_id] = (time.time(), segments)

    return segments


async def handle_segments(request):
    """
    The parts of one of the person's videos the player should skip: its
    SponsorBlock segments in their categories (none if they turned skipping
    off, or the video's sponsors were cut when it was downloaded).

    :param web.Request request: The request

    :return: The segments: [{start, end, category}]
    """
    name, _, relative = video_of(
        request, {"file": request.query.get("file", "")}
    )
    store = request.app["store"]
    state = store.state(name)
    preferences = store.preferences(state)
    video_id = video_ids(os.path.splitext(os.path.basename(relative))[0])[2]

    if (not video_id or not preferences["sb_skip"]
            or state["cut"].get(relative)):
        return web.json_response({"segments": []})

    wanted = set(preferences["sb_categories"])
    segments = [
        {"start": start, "end": end, "category": category}
        for start, end, category in await sponsor_segments(
            request.app, video_id
        )
        if category in wanted
    ]

    return web.json_response({"segments": segments})


async def handle_file(request):
    """
    One of the person's videos (or its thumbnail), for the player: with
    ranges, so it can seek.

    :param web.Request request: The request

    :return: The file
    """
    name = need_user(request)
    folder = request.app["store"].folder(name)
    relative = urllib.parse.unquote(request.match_info["path"])
    kind = request.match_info["kind"]
    allowed = MEDIA if kind == "media" else IMAGES

    if not folder or not relative.lower().endswith(allowed):
        raise web.HTTPNotFound()

    path = inside(folder, relative)

    if not os.path.isfile(path):
        raise web.HTTPNotFound()

    content_type = mimetypes.guess_type(path)[0]
    response = web.FileResponse(path)

    if content_type:
        response.content_type = content_type

    response.headers["Cache-Control"] = "private, max-age=3600"

    return response


async def handle_page(request):
    """
    The Watch page itself.

    :param web.Request request: The request

    :return: The page
    """
    response = web.FileResponse(
        os.path.join(request.app["static"], "index.html")
    )
    response.headers["Cache-Control"] = "no-store"

    return response


async def handle_health(request):
    """
    Whether it's the Watch server answering (for the app's checks).

    :param web.Request request: The request

    :return: The answer
    """
    return web.json_response({"watch": True})


@web.middleware
async def headers(request, handler):
    """
    Adds headers every answer gets: no framing by other sites, no guessing
    of types.

    :param web.Request request: The request
    :param callable    handler: The route's handler

    :return: The answer
    """
    response = await handler(request)
    response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")

    return response


async def start_background(app):
    """
    Starts the HTTP client (for MeTube and the media server) and the
    clean-up.

    :param web.Application app: This server
    """
    app["client"] = aiohttp.ClientSession()
    app["segments"] = {}
    app["cleaner"] = asyncio.ensure_future(clean_loop(app))


async def stop_background(app):
    """
    Stops the clean-up and the HTTP client.

    :param web.Application app: This server
    """
    app["cleaner"].cancel()
    await app["client"].close()


def main():
    """
    Runs the server.
    """
    parser = argparse.ArgumentParser(description="The Watch page's server")
    parser.add_argument("--data", required=True)
    parser.add_argument("--static", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8086)
    parser.add_argument("--metube", default="http://127.0.0.1:8085")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.WARNING,
        format="%(asctime)s [%(levelname)s] watch: %(message)s",
    )

    app = web.Application(middlewares=[headers])
    app["store"] = Store(args.data)
    app["static"] = args.static
    app["metube"] = args.metube.rstrip("/")
    app.on_startup.append(start_background)
    app.on_cleanup.append(stop_background)
    app.add_routes([
        web.get("/", handle_page),
        web.get("/health", handle_health),
        web.post("/api/login", handle_login),
        web.post("/api/logout", handle_logout),
        web.get("/api/videos", handle_videos),
        web.post("/api/add", handle_add),
        web.post("/api/cancel", handle_cancel),
        web.post("/api/delete", handle_delete),
        web.post("/api/delete-playlist", handle_delete_playlist),
        web.post("/api/new-playlist", handle_new_playlist),
        web.post("/api/rename", handle_rename),
        web.post("/api/rename-playlist", handle_rename_playlist),
        web.post("/api/keep", handle_keep),
        web.post("/api/watched", handle_watched),
        web.post("/api/settings", handle_settings),
        web.get("/api/segments", handle_segments),
        web.get(r"/{kind:media|thumb}/{path:.+}", handle_file),
        web.static("/static", args.static),
    ])
    web.run_app(app, host=args.host, port=args.port, access_log=None,
                print=None)


if __name__ == "__main__":
    main()
