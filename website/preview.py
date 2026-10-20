"""Local-only preview of the static site with Vercel-style clean URLs."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ('/privacy', '/support'):
            self.path = path + '.html'
        super().do_GET()

if __name__ == '__main__':
    public = Path(__file__).resolve().parent / 'public'
    server = ThreadingHTTPServer(('127.0.0.1', 8765), partial(Handler, directory=str(public)))
    print('Preview: http://127.0.0.1:8765', flush=True)
    server.serve_forever()
