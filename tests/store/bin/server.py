# HTTPS test server for the Store: repo.test and evil.test (by Host header), /releases/ redirects to /packages/ (as GitHub's
# release downloads redirect), /downgrade/ redirects to plain HTTP (which the Store must refuse)
import http.server, ssl, sys, os, functools
ROOTS = {"repo.test": sys.argv[1], "evil.test": sys.argv[2]}
class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        host = (self.headers.get("Host") or "").split(":")[0]
        self.directory = ROOTS.get(host, ROOTS["repo.test"])
        return super().translate_path(path)
    def do_GET(self):
        if self.path.startswith("/releases/"):
            self.send_response(302); self.send_header("Location", "https://repo.test:8443/packages/" + self.path[10:]); self.end_headers(); return
        if self.path.startswith("/downgrade/"):
            self.send_response(302); self.send_header("Location", "http://repo.test:8081/packages/" + self.path[11:]); self.end_headers(); return
        return super().do_GET()
    def log_message(self, *a):
        with open("/tmp/server.log", "a") as f: f.write(self.headers.get("Host", "") + " " + (a[0] % a[1:]) + "\n")
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[3], sys.argv[4])
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), Handler); srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
