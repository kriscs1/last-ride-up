"""Pretends to be Backblaze B2 (native API v2) for testing scripts/net/backup.gd.

    python tests/stores/mock_b2.py OUT_DIR [PORT]

Accepts key id "testkey" / application key "testsecret" and bucket "lru-backups". It checks
the upload's SHA-1 and saves each uploaded file in OUT_DIR. Every request goes to OUT_DIR/b2.log.
"""
import base64, hashlib, json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8766
os.makedirs(out, exist_ok=True)
log = open(os.path.join(out, 'b2.log'), 'w', buffering=1)
BASE = 'http://127.0.0.1:%d' % port


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        return self.rfile.read(int(self.headers.get('Content-Length', 0)))

    def do_GET(self):
        log.write('GET %s\n' % self.path)
        if self.path == '/b2api/v2/b2_authorize_account':
            want = 'Basic ' + base64.b64encode(b'testkey:testsecret').decode()
            if self.headers.get('Authorization') != want:
                return self._send(401, {'code': 'bad_auth_token'})
            # An unrestricted key: no "allowed" bucket, so the server has to list buckets.
            return self._send(200, {'accountId': 'acc1', 'apiUrl': BASE, 'authorizationToken': 'tok-api',
                                    'allowed': {'capabilities': ['listBuckets', 'writeFiles']}})
        self._send(404, {'code': 'not_found'})

    def do_POST(self):
        body = self._body()
        log.write('POST %s %s\n' % (self.path, body[:200] if self.path != '/upload' else '<%d bytes>' % len(body)))
        if self.path == '/b2api/v2/b2_list_buckets':
            q = json.loads(body)
            if self.headers.get('Authorization') != 'tok-api' or q.get('accountId') != 'acc1':
                return self._send(401, {'code': 'unauthorized'})
            found = q.get('bucketName') == 'lru-backups'
            return self._send(200, {'buckets': [{'bucketId': 'b123', 'bucketName': 'lru-backups'}] if found else []})
        if self.path == '/b2api/v2/b2_get_upload_url':
            if self.headers.get('Authorization') != 'tok-api' or json.loads(body).get('bucketId') != 'b123':
                return self._send(401, {'code': 'unauthorized'})
            return self._send(200, {'uploadUrl': BASE + '/upload', 'authorizationToken': 'tok-up'})
        if self.path == '/upload':
            if self.headers.get('Authorization') != 'tok-up':
                return self._send(401, {'code': 'unauthorized'})
            if hashlib.sha1(body).hexdigest() != self.headers.get('X-Bz-Content-Sha1'):
                return self._send(400, {'code': 'bad_request', 'message': 'sha1 did not match'})
            name = urllib.parse.unquote(self.headers.get('X-Bz-File-Name', ''))
            log.write('UPLOADED %s %d bytes sse=%s files=%s\n' % (name, len(body),
                      self.headers.get('X-Bz-Server-Side-Encryption'), urllib.parse.unquote(self.headers.get('X-Bz-Info-files', ''))))
            open(os.path.join(out, os.path.basename(name)), 'wb').write(body)
            return self._send(200, {'fileId': 'f1', 'fileName': name})
        self._send(404, {'code': 'not_found'})

    def log_message(self, *a):
        pass


ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
