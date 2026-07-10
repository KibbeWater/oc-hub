#!/usr/bin/env python3
"""Tiny dev server for OpenComputers live sync (pairs with ocgit/ocdev.lua).

Serves a directory over plain HTTP plus a /__manifest endpoint that lists
every file with its SHA-1 hash, so the in-game ocdev script can detect and
download only what changed.

Usage:
    python serve.py [directory] [port] [--token=SECRET]

Defaults: directory = current folder, port = 8064.

When exposing the server through a public tunnel (e.g. `ngrok http 8064`),
pass --token=SECRET here and --token=SECRET to ocdev/ocrun in-game, so only
your own computers can read the files.
"""

import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

_positional = [a for a in sys.argv[1:] if not a.startswith("--")]
TOKEN = next((a.split("=", 1)[1] for a in sys.argv[1:]
              if a.startswith("--token=")), None)
ROOT = os.path.abspath(_positional[0] if _positional else ".")
PORT = int(_positional[1]) if len(_positional) > 1 else 8064

IGNORE_DIRS = {".git", "__pycache__", "node_modules", ".vscode", ".idea"}
IGNORE_FILES = {".ocgit"}


def build_manifest():
    files = {}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in IGNORE_DIRS and not d.startswith(".")]
        for name in filenames:
            if name in IGNORE_FILES or name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            with open(full, "rb") as f:
                files[rel] = hashlib.sha1(f.read()).hexdigest()
    return files


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type="application/octet-stream"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if TOKEN and self.headers.get("X-Token") != TOKEN:
            self._send(403, b"forbidden")
            return
        path = unquote(self.path).lstrip("/")
        if path == "__manifest":
            body = json.dumps({"files": build_manifest()}).encode()
            self._send(200, body, "application/json")
            return
        full = os.path.abspath(os.path.join(ROOT, path))
        if not (full == ROOT or full.startswith(ROOT + os.sep)):
            self._send(403, b"forbidden")
            return
        if not os.path.isfile(full):
            self._send(404, b"not found")
            return
        with open(full, "rb") as f:
            self._send(200, f.read())

    def log_message(self, fmt, *fmtargs):
        print("[serve]", fmt % fmtargs)


if __name__ == "__main__":
    print(f"Serving {ROOT} on http://0.0.0.0:{PORT}"
          + (" (token required)" if TOKEN else ""))
    print(f"In-game (LAN):   ocdev <this-machine's-LAN-IP>:{PORT} /home/work")
    print(f"Via ngrok:       ngrok http {PORT}")
    print("                 ocdev https://<id>.ngrok-free.app /home/work")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
