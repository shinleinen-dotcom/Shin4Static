"""Dev server for the web UI on Windows: static files from www/, the CGI runs
inside WSL against the fixture from tests/devroot.sh.

    wsl -d Debian -- sh /mnt/c/.../tests/devroot.sh
    python tests/devserver.py            # http://127.0.0.1:8099/
"""
import http.server
import pathlib
import shlex
import subprocess
import urllib.parse

REPO = pathlib.Path(__file__).resolve().parent.parent
WWW = REPO / "www"
WSL_CGI = "/mnt/" + str(REPO / "www/cgi-bin/s4s").replace(":", "").replace("\\", "/").lower()
ENV = {"S4S_ROOT": "/tmp/s4s-dev/opt", "S4S_BIN": "/tmp/s4s-dev/s4s"}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WWW), **kwargs)

    def do_GET(self):
        if self.path.startswith("/cgi-bin/"):
            return self.cgi(b"")
        return super().do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.cgi(self.rfile.read(length))

    def cgi(self, body):
        query = urllib.parse.urlsplit(self.path).query
        env = dict(ENV, REQUEST_METHOD=self.command, QUERY_STRING=query,
                   CONTENT_LENGTH=str(len(body)), HTTP_HOST=self.headers.get("Host", ""))
        # wsl.exe hands the command to a shell: quote everything.
        cmd = ["wsl.exe", "-d", "Debian", "--", "env"] + [shlex.quote(f"{k}={v}") for k, v in env.items()] + ["sh", WSL_CGI]
        out = subprocess.run(cmd, input=body, capture_output=True).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        self.send_response(200)
        for line in head.split(b"\r\n"):
            if b":" in line:
                k, v = line.split(b":", 1)
                self.send_header(k.decode(), v.strip().decode())
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", 8099), Handler).serve_forever()
