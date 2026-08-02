#!/usr/bin/env python3
"""
Tiny origin server for the web-delivery arms.

It serves one route per delivery technique and logs every request it receives. That log is
the control for the web arms: if the GET never arrives, the browser never loaded the page and
the arm measured nothing, which is a different outcome from "the page loaded and the platform
refused to hand the URL to the receiver".

Usage: webserver.py <port> <scheme-url-prefix>
"""

import http.server
import sys

PORT = int(sys.argv[1])
SCHEME = sys.argv[2]  # e.g. "probeb://from-web"

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>%(title)s</title>%(head)s</head>
<body style="font:16px -apple-system;padding:2em">
<h1>%(title)s</h1>
%(body)s
</body></html>
"""


def page(title, head="", body=""):
    return (PAGE % {"title": title, "head": head, "body": body}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("WEBLOG %s\n" % (fmt % args))
        sys.stderr.flush()

    def _send(self, body, ctype="text/html; charset=utf-8", code=200, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = self.path.split("?")[0]

        # Control. Proves the browser can reach this origin and render a page.
        if route == "/control":
            self._send(page("control", body="<p>origin reachable</p>"))

        # No JavaScript at all. A plain HTTP redirect to the custom scheme.
        elif route == "/r302":
            body = b"redirecting"
            self.send_response(302)
            self.send_header("Location", SCHEME + "-302")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        # No JavaScript. Declarative meta refresh.
        elif route == "/meta":
            head = '<meta http-equiv="refresh" content="0;url=%s-meta">' % SCHEME
            self._send(page("meta refresh", head=head))

        # JavaScript, no user gesture, on load.
        elif route == "/js":
            body = '<script>location.href="%s-js";</script>' % SCHEME
            self._send(page("js on load", body=body))

        # JavaScript inside a subframe, no user gesture. The classic malvertising shape.
        elif route == "/iframe":
            body = '<iframe src="/framed" style="width:1px;height:1px;border:0"></iframe>'
            self._send(page("iframe", body=body))

        elif route == "/framed":
            body = '<script>location.href="%s-iframe";</script>' % SCHEME
            self._send(page("framed", body=body))

        # One tap on an ordinary link, for the case where nothing automatic is allowed.
        elif route == "/link":
            body = (
                '<p><a id="go" href="%s-link" '
                'style="display:block;padding:3em;background:#08f;color:#fff;'
                'text-align:center;font-size:2em">OPEN</a></p>' % SCHEME
            )
            self._send(page("link", body=body))

        else:
            self._send(page("not found", body="<p>no route</p>"), code=404)


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write("WEBLOG serving on 127.0.0.1:%d scheme=%s\n" % (PORT, SCHEME))
    sys.stderr.flush()
    srv.serve_forever()
