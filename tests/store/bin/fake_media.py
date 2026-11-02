"""A stand-in Plex (port 32400), Jellyfin (18096) and ntfy (2586) for the Arr
test: just enough for the apps' connection tests (Settings -> Connect) - each
checking the token or API key the recipe's hook gave them. ntfy's messages
(those with its token) are written to NTFY_LOG, a line each"""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PLEX_TOKEN = "plex-tok-123"
JELLYFIN_KEY = "jf-key-1"
NTFY_TOKEN = "tk_testtoken1234567890abcdefghijk"
NTFY_LOG = "/tmp/ntfy-messages"
SECTIONS = [
    {
        "key": str(i + 1),
        "type": kind,
        "title": kind,
        "language": "en",
        "Location": [{"id": i + 1, "path": "/library/" + kind}],
    }
    for i, kind in enumerate(("show", "movie", "artist"))
]


def handler(kind):
    """
    A request handler for one of the stand-ins.

    :param str kind: plex, jellyfin or ntfy

    :return: The handler's class
    """

    class Handler(BaseHTTPRequestHandler):
        """Answers as the stand-in does."""

        def answer(self, status, body):
            """
            Sends a JSON answer.

            :param int  status: The HTTP status
            :param dict body:   The answer
            """
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            """Answers a request (GET or POST), checking its token or key."""
            url = urlsplit(self.path)
            query = parse_qs(url.query)

            if kind == "ntfy":
                body = self.rfile.read(
                    int(self.headers.get("Content-Length") or 0)
                ).decode("utf-8", "replace")

                if (
                    self.headers.get("Authorization", "")
                    != "Bearer " + NTFY_TOKEN
                ):
                    return self.answer(
                        401, {"code": 40101, "error": "unauthorized"}
                    )

                with open(NTFY_LOG, "a") as f:
                    f.write(
                        json.dumps({
                            "path": url.path,
                            "title": self.headers.get("Title", ""),
                            "body": body,
                        })
                        + "\n"
                    )

                return self.answer(200, {"id": "m1", "event": "message"})

            if kind == "plex":
                if (
                    query.get(
                        "X-Plex-Token", [self.headers.get("X-Plex-Token", "")]
                    )[0]
                    != PLEX_TOKEN
                ):
                    return self.answer(401, {})

                if url.path == "/identity":
                    return self.answer(
                        200,
                        {
                            "MediaContainer": {
                                "size": 0,
                                "version": "1.42.1.10060",
                            }
                        },
                    )

                if url.path == "/library/sections":
                    return self.answer(
                        200,
                        {
                            "MediaContainer": {
                                "size": len(SECTIONS),
                                "Directory": SECTIONS,
                            }
                        },
                    )

                return self.answer(200, {"MediaContainer": {"size": 0}})

            tokens = [
                v
                for k, v in self.headers.items()
                if "token" in k.lower()
                or k.lower() in ("x-emby-authorization", "authorization")
            ]

            if not any(
                JELLYFIN_KEY in t for t in tokens
            ) and JELLYFIN_KEY not in query.get("api_key", []):
                return self.answer(401, {})

            return self.answer(200, {})

        do_POST = do_GET

        def log_message(self, *args):
            """
            Logs nothing.

            :param tuple args: The message's format and its values
            """
            pass

    return Handler


servers = [
    ThreadingHTTPServer(("0.0.0.0", 32400), handler("plex")),
    ThreadingHTTPServer(("0.0.0.0", 18096), handler("jellyfin")),
    ThreadingHTTPServer(("0.0.0.0", 2586), handler("ntfy")),
]

for server in servers[1:]:
    threading.Thread(target=server.serve_forever, daemon=True).start()

servers[0].serve_forever()
