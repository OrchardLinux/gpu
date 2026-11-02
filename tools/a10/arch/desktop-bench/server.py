#!/usr/bin/env python3
"""Serves the benchmark pages on 127.0.0.1:8765 and appends each page's POSTed
result (JSON) to the file named on the command line."""
import http.server
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = pathlib.Path(sys.argv[1])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(HERE), **kwargs)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with OUT.open('ab') as f:
            f.write(body + b'\n')
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
