"""Mock Steam Web API + App Store Server API for testing the game server. Usage: python mock_stores.py <repo> <outdir>"""
import sys, json, base64, time, os, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

repo, out = sys.argv[1], sys.argv[2]
apple_pub = serialization.load_pem_public_key(open(os.path.join(repo, 'tests/fixtures/test_apple_key.pub.pem'), 'rb').read())

# Google: make a signing key, publish its public key + one good and one forged purchase for the client driver
gkey = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pub_b64 = base64.b64encode(gkey.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
good = json.dumps({"orderId": "GPA.1", "packageName": "com.test.lru", "productId": "face_shades", "purchaseState": 0})
sig = base64.b64encode(gkey.sign(good.encode(), padding.PKCS1v15(), hashes.SHA1())).decode()
forged = good.replace("face_shades", "face_eyepatch")
json.dump({"pub": pub_b64, "good": {"store": "google_play", "json": good, "sig": sig},
           "forged": {"store": "google_play", "json": forged, "sig": sig}}, open(os.path.join(out, 'google.json'), 'w'))

log = open(os.path.join(out, 'mock.log'), 'w', buffering=1)
orders = {}


def b64d(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))


def b64e(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        log.write('GET %s %s\n' % (u.path, {k: v for k, v in q.items() if k != 'key'}))
        if u.path == '/ISteamUserAuth/AuthenticateUserTicket/v1/':
            if q.get('key') == 'testkey' and q.get('identity') == 'lastrideup' and q.get('ticket') == 'abcd1234':
                return self.reply(200, {"response": {"params": {"result": "OK", "steamid": "76561190000000001",
                                       "ownersteamid": "76561190000000001", "vacbanned": False, "publisherbanned": False}}})
            return self.reply(200, {"response": {"error": {"errorcode": 101, "errordesc": "Invalid ticket"}}})
        if u.path == '/ISteamMicroTxnSandbox/GetUserInfo/v2/':
            return self.reply(200, {"response": {"result": "OK", "params": {"state": "", "country": "DE", "currency": "EUR", "status": "Active"}}})
        if u.path.startswith('/apple') and '/inApps/v1/transactions/' in u.path:
            tok = self.headers.get('Authorization', '')[7:]
            h, c, s = tok.split('.')
            raw = b64d(s)
            try:
                apple_pub.verify(encode_dss_signature(int.from_bytes(raw[:32], 'big'), int.from_bytes(raw[32:], 'big')),
                                 (h + '.' + c).encode(), ec.ECDSA(hashes.SHA256()))
            except Exception as e:
                log.write('  JWT signature INVALID: %r\n' % e)
                return self.reply(401, {})
            claims = json.loads(b64d(c))
            head = json.loads(b64d(h))
            ok = head.get('alg') == 'ES256' and head.get('kid') == 'K1' and claims.get('iss') == 'I1' and \
                claims.get('aud') == 'appstoreconnect-v1' and claims.get('bid') == 'com.test.lru' and claims['exp'] > time.time()
            log.write('  JWT signature valid, claims ok=%s\n' % ok)
            if not ok:
                return self.reply(401, {})
            tid = u.path.rsplit('/', 1)[1]
            env = 'sandbox' if u.path.startswith('/applesb') else 'production'
            if (env, tid) == ('sandbox', '2000'):
                payload = {"transactionId": tid, "bundleId": "com.test.lru", "productId": "face_monocle", "environment": "Sandbox"}
                return self.reply(200, {"signedTransactionInfo": "eyJhbGciOiJFUzI1NiJ9." + b64e(json.dumps(payload).encode()) + ".sig"})
            return self.reply(404, {"errorCode": 4040010, "errorMessage": "Transaction id not found."})
        self.reply(404, {})

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        q = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        log.write('POST %s %s\n' % (self.path, {k: v for k, v in q.items() if k != 'key'}))
        if self.path == '/ISteamMicroTxnSandbox/InitTxn/v3/':
            ok = q.get('currency') == 'EUR' and q.get('amount[0]') == '199' and q.get('itemid[0]') == '103' and q.get('steamid') == '76561190000000001'
            if ok:
                orders[q['orderid']] = True
                return self.reply(200, {"response": {"result": "OK", "params": {"orderid": q['orderid'], "transid": "555"}}})
            return self.reply(200, {"response": {"result": "Failure", "error": {"errorcode": 2, "errordesc": "bad order"}}})
        if self.path == '/ISteamMicroTxnSandbox/FinalizeTxn/v2/':
            if orders.pop(q.get('orderid'), False):
                return self.reply(200, {"response": {"result": "OK", "params": {"orderid": q['orderid'], "transid": "555"}}})
            return self.reply(200, {"response": {"result": "Failure", "error": {"errorcode": 3, "errordesc": "unknown order"}}})
        self.reply(404, {})


ThreadingHTTPServer(('127.0.0.1', 8765), H).serve_forever()
