"""Stand-ins for the MeTube suite (tests/metube/test_app.sh), run with the
app's own Python:

    python3 stubs.py media <port> <played.json>
        a media server answering as Jellyfin / Emby and as Plex do, for the
        files listed in played.json ({"<path>": <last played, Unix time>});
        and as SponsorBlock does (its private lookup by hash prefix) for the
        videos in SEGMENTS
    python3 stubs.py index <folder> <version> [broken]
        a package index (<folder>/simple/...) with yt-dlp and yt-dlp-ejs
        wheels of that version - small stand-ins that print it (or, broken,
        fail to import)
"""
import base64
import hashlib
import http.server
import json
import os
import sys
import time
import zipfile

TOKEN = "stubtoken123"
# SponsorBlock's segments, by video (another video shares abcdefghijk's
# hash prefix, as real ones do: the server must pick its own out)
SEGMENTS = {
    "abcdefghijk": [
        {"segment": [1.0, 2.0], "category": "sponsor", "actionType": "skip"},
        {"segment": [2.5, 3.0], "category": "intro", "actionType": "skip"},
        {"segment": [0.2, 0.4], "category": "selfpromo",
         "actionType": "skip"},
        {"segment": [3.0, 3.5], "category": "sponsor", "actionType": "mute"},
    ],
    "lmnopqrstuv": [
        {"segment": [1.0, 2.0], "category": "sponsor", "actionType": "skip"},
    ],
}


class MediaServer(http.server.BaseHTTPRequestHandler):
    """
    Answers as Jellyfin / Emby (/Users, /Users/<id>/Items,
    /Library/VirtualFolders) and as Plex (/library/sections, .../all) do.
    """

    played_file = ""

    def log_message(self, format, *args):
        """
        Logs nothing.
        """

    def send_json(self, data):
        """
        Answers with JSON.

        :param object data: What to send
        """
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        """
        Answers a GET: SponsorBlock's lookup, or the media server's API if
        the token is right.
        """
        if self.path.startswith("/api/skipSegments/"):
            prefix = self.path.split("/")[3].split("?")[0]
            found = [
                {"videoID": video, "segments": segments}
                for video, segments in SEGMENTS.items()
                if hashlib.sha256(video.encode()).hexdigest()[:4] == prefix
            ]

            if not found:
                self.send_response(404)
                self.end_headers()

                return

            found.append({"videoID": "zzzzzzzzzzz", "segments": [
                {"segment": [9.0, 9.5], "category": "sponsor",
                 "actionType": "skip"},
            ]})
            self.send_json(found)

            return

        token = (self.headers.get("X-Emby-Token")
                 or self.headers.get("X-Plex-Token"))

        if token != TOKEN:
            self.send_response(401)
            self.end_headers()

            return

        with open(self.played_file, encoding="utf-8") as file:
            played = json.load(file)

        root = played.pop("_root", "/")
        path = self.path.split("?")[0]

        if path == "/Users":
            self.send_json([{"Id": "u1", "Name": "tv"}])
        elif path == "/Users/u1/Items":
            items = []

            for name, when in played.items():
                stamp = time.strftime("%Y-%m-%dT%H:%M:%S.0000000Z",
                                      time.gmtime(when))
                items.append({"Path": name,
                              "UserData": {"LastPlayedDate": stamp}})

            self.send_json({"Items": items})
        elif path == "/Library/VirtualFolders":
            self.send_json([{"Name": "Watch later", "Locations": [root]}])
        elif path == "/library/sections":
            self.send_json({"MediaContainer": {"Directory": [{
                "key": "7", "title": "Watch later",
                "Location": [{"path": root}],
            }]}})
        elif path == "/library/sections/7/all":
            metadata = [
                {"lastViewedAt": when, "viewCount": 1,
                 "Media": [{"Part": [{"file": name}]}]}
                for name, when in played.items()
            ]
            self.send_json({"MediaContainer": {"Metadata": metadata}})
        else:
            self.send_response(404)
            self.end_headers()


def wheel(folder, name, version, files):
    """
    Writes a wheel (a pure Python package) into a folder.

    :param str  folder:  The folder
    :param str  name:    Its distribution name, e.g. yt_dlp
    :param str  version: Its version
    :param dict files:   Its files (path: text)

    :return: The wheel's file name
    """
    file_name = f"{name}-{version}-py3-none-any.whl"
    info = f"{name}-{version}.dist-info"
    files = dict(files)
    files[f"{info}/METADATA"] = (
        f"Metadata-Version: 2.1\nName: {name.replace('_', '-')}\n"
        f"Version: {version}\n"
    )
    files[f"{info}/WHEEL"] = (
        "Wheel-Version: 1.0\nGenerator: stub\nRoot-Is-Purelib: true\n"
        "Tag: py3-none-any\n"
    )
    record = []

    for path, text in files.items():
        digest = base64.urlsafe_b64encode(
            hashlib.sha256(text.encode()).digest()
        ).rstrip(b"=").decode()
        record.append(f"{path},sha256={digest},{len(text.encode())}")

    record.append(f"{info}/RECORD,,")
    files[f"{info}/RECORD"] = "\n".join(record) + "\n"

    with zipfile.ZipFile(os.path.join(folder, file_name), "w") as archive:
        for path, text in files.items():
            archive.writestr(path, text)

    return file_name


def index(folder, version, broken):
    """
    Writes a simple package index with stand-in yt-dlp and yt-dlp-ejs.

    :param str  folder:  Where it goes
    :param str  version: Their version
    :param bool broken:  Whether yt-dlp fails to import
    """
    if broken:
        code = "raise ImportError('a broken yt-dlp')\n"
    else:
        code = ""

    packages = {
        "yt-dlp": ("yt_dlp", {
            "yt_dlp/__init__.py": code,
            "yt_dlp/version.py": f"__version__ = '{version}'\n",
            "yt_dlp/__main__.py": (
                "from yt_dlp.version import __version__\n"
                "print(__version__)\n"
            ),
        }),
        "yt-dlp-ejs": ("yt_dlp_ejs", {"yt_dlp_ejs/__init__.py": ""}),
    }

    for project, (name, files) in packages.items():
        target = os.path.join(folder, "simple", project)
        os.makedirs(target, exist_ok=True)
        file_name = wheel(target, name, version, files)

        with open(os.path.join(target, "index.html"), "w") as page:
            page.write(f'<a href="{file_name}">{file_name}</a>\n')


def main():
    """
    Runs the stand-in asked for.
    """
    if sys.argv[1] == "media":
        MediaServer.played_file = sys.argv[3]
        server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])),
                                        MediaServer)
        server.serve_forever()
    else:
        index(sys.argv[2], sys.argv[3], len(sys.argv) > 4)


if __name__ == "__main__":
    main()
