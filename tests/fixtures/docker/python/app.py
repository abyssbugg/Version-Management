#!/usr/bin/env python3
# Synthetic standard-library fixture: no downloaded Python dependencies.
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"status":"healthy"}\n'
        self.send_response(200 if self.path == '/healthz' else 404)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
