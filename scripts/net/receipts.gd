extends Node
## Server-side checks of Google Play and App Store purchases (child of Net on the dedicated server).
## Clients send a proof for each paid item they own; only checked items are shown to other players.
## Steam purchases are handled by steam_shop.gd, which records them itself.
##
## Environment:
##   GOOGLE_PLAY_PUBLIC_KEY   Play Console → Monetization setup → Licensing: the base64 RSA public key
##   GOOGLE_PLAY_PACKAGE      the Android package name, e.g. com.example.lastrideup
##   APPLE_PRIVATE_KEY_PATH   App Store Connect API in-app purchase key (.p8 file)
##   APPLE_KEY_ID, APPLE_ISSUER_ID, APPLE_BUNDLE_ID
##   APPLE_API_BASES          optional, comma-separated (default: production, then sandbox)
## Server flag --test-purchases accepts the debug "test store" proofs (never use it on a public server).

var test_allowed := OS.get_cmdline_user_args().has("--test-purchases")
var play_key: CryptoKey
var play_package := OS.get_environment("GOOGLE_PLAY_PACKAGE")
var apple_key: CryptoKey
var apple_key_id := OS.get_environment("APPLE_KEY_ID")
var apple_issuer := OS.get_environment("APPLE_ISSUER_ID")
var apple_bundle := OS.get_environment("APPLE_BUNDLE_ID")
var apple_bases: PackedStringArray = (OS.get_environment("APPLE_API_BASES") if OS.get_environment("APPLE_API_BASES") != ""
	else "https://api.storekit.itunes.apple.com,https://api.storekit-sandbox.itunes.apple.com").split(",", false)
var _checked := {}     # proof key → product id ("" = rejected), so each proof is checked once
var _jwt := ""
var _jwt_until := 0


func _ready() -> void:
	if OS.get_environment("GOOGLE_PLAY_PUBLIC_KEY") != "":
		play_key = public_key_from_base64(OS.get_environment("GOOGLE_PLAY_PUBLIC_KEY"))
		print("Google Play purchase checks %s" % ("on" if play_key else "OFF: GOOGLE_PLAY_PUBLIC_KEY is not a valid key"))
	var p8 := OS.get_environment("APPLE_PRIVATE_KEY_PATH")
	if p8 != "":
		apple_key = CryptoKey.new()
		if apple_key.load(p8) != OK:
			apple_key = null
		print("App Store purchase checks %s" % ("on" if apple_key else "OFF: could not read " + p8))
	if test_allowed:
		print("Test-store purchases are accepted (--test-purchases)")


func check(proofs: Array, granted: Callable) -> void:
	## Calls granted(product_id) for each proof that checks out (some answers arrive later).
	for p in proofs.slice(0, 64):
		if not p is Dictionary:
			continue
		match str(p.get("store", "")):
			"test":
				var pid := str(p.get("product", ""))
				if test_allowed and not CF.item_of_product(pid).is_empty():
					granted.call(pid)
			"google_play":
				var json := str(p.get("json", ""))
				var key := "g:" + json.sha256_text()
				if not _checked.has(key):
					_checked[key] = check_play(json, str(p.get("sig", "")), play_key, play_package)
				if _checked[key] != "":
					granted.call(_checked[key])
			"app_store":
				var tid := str(p.get("transaction_id", ""))
				if tid.is_valid_int() and apple_key:
					if _checked.has("a:" + tid):
						if _checked["a:" + tid] != "":
							granted.call(_checked["a:" + tid])
					else:
						_apple_lookup(tid, 0, granted)


# ---------------------------------------------------------------- Google Play

static func public_key_from_base64(b64: String) -> CryptoKey:
	var body := b64.strip_edges().replace("\n", "").replace("\r", "").replace(" ", "")
	var pem := "-----BEGIN PUBLIC KEY-----\n"
	for i in range(0, body.length(), 64):
		pem += body.substr(i, 64) + "\n"
	pem += "-----END PUBLIC KEY-----\n"
	var k := CryptoKey.new()
	return k if k.load_from_string(pem, true) == OK else null


static func check_play(json_text: String, sig_b64: String, key: CryptoKey, package: String) -> String:
	## Google signs each purchase's JSON with the app's key (SHA1withRSA). Returns the product id or "".
	if key == null or json_text == "" or sig_b64 == "":
		return ""
	var sig := Marshalls.base64_to_raw(sig_b64)
	if not Crypto.new().verify(HashingContext.HASH_SHA1, json_text.sha1_buffer(), sig, key):
		return ""
	var d = JSON.parse_string(json_text)
	if not d is Dictionary or str(d.get("packageName", "")) != package or int(d.get("purchaseState", 1)) != 0:
		return ""
	var pid := str(d.get("productId", ""))
	if pid == "" and d.get("productIds") is Array and not d["productIds"].is_empty():
		pid = str(d["productIds"][0])
	return pid if not CF.item_of_product(pid).is_empty() else ""


# ---------------------------------------------------------------- App Store

func _apple_lookup(tid: String, base_i: int, granted: Callable) -> void:
	if base_i >= apple_bases.size():
		_checked["a:" + tid] = ""
		return
	var token := _apple_token()
	if token == "":
		return
	var h := HTTPRequest.new()
	h.timeout = 15.0
	add_child(h)
	h.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
		h.queue_free()
		if code == 404:   # not in this environment: try the next (production → sandbox)
			_apple_lookup(tid, base_i + 1, granted)
			return
		if code != 200:
			push_warning("App Store lookup failed (%d) for transaction %s" % [code, tid])
			return   # not cached: a later proof can try again
		var pid := apple_product_from(JSON.parse_string(body.get_string_from_utf8()), apple_bundle)
		_checked["a:" + tid] = pid
		if pid != "":
			granted.call(pid))
	if h.request(apple_bases[base_i].strip_edges() + "/inApps/v1/transactions/" + tid, ["Authorization: Bearer " + token]) != OK:
		h.queue_free()


func _apple_token() -> String:
	var now := int(Time.get_unix_time_from_system())
	if _jwt == "" or now > _jwt_until:
		_jwt = es256_jwt(apple_key, apple_key_id, apple_issuer, apple_bundle, now)
		_jwt_until = now + 240
	return _jwt


static func apple_product_from(resp, bundle: String) -> String:
	## Apple answers over TLS with the transaction as a JWS; its middle part is the JSON payload.
	if not resp is Dictionary:
		return ""
	var parts := str(resp.get("signedTransactionInfo", "")).split(".")
	if parts.size() != 3:
		return ""
	var d = JSON.parse_string(b64url_decode(parts[1]).get_string_from_utf8())
	if not d is Dictionary or str(d.get("bundleId", "")) != bundle or d.get("revocationDate") != null:
		return ""
	var pid := str(d.get("productId", ""))
	return pid if not CF.item_of_product(pid).is_empty() else ""


static func es256_jwt(key: CryptoKey, key_id: String, issuer: String, bundle: String, now: int) -> String:
	if key == null:
		return ""
	var head := b64url_encode(JSON.stringify({"alg": "ES256", "kid": key_id, "typ": "JWT"}).to_utf8_buffer())
	var claims := b64url_encode(JSON.stringify({"iss": issuer, "iat": now, "exp": now + 300,
		"aud": "appstoreconnect-v1", "bid": bundle}).to_utf8_buffer())
	var signing := head + "." + claims
	var raw := der_to_raw_ecdsa(Crypto.new().sign(HashingContext.HASH_SHA256, signing.sha256_buffer(), key))
	return "" if raw.is_empty() else signing + "." + b64url_encode(raw)


static func der_to_raw_ecdsa(der: PackedByteArray) -> PackedByteArray:
	## mbedTLS signs ECDSA as DER SEQUENCE{INTEGER r, INTEGER s}; JWT wants r and s as 32 bytes each.
	var out := PackedByteArray()
	if der.size() < 8 or der[0] != 0x30:
		return out
	var i := 2 + ((der[1] & 0x7f) if der[1] & 0x80 else 0)
	for n in 2:
		if i + 2 > der.size() or der[i] != 0x02:
			return PackedByteArray()
		var ln: int = der[i + 1]
		var v := der.slice(i + 2, i + 2 + ln)
		i += 2 + ln
		while v.size() > 32 and v[0] == 0:
			v = v.slice(1)
		if v.size() > 32:
			return PackedByteArray()
		var pad := PackedByteArray()
		pad.resize(32 - v.size())
		out.append_array(pad)
		out.append_array(v)
	return out


static func b64url_encode(raw: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(raw).replace("+", "-").replace("/", "_").replace("=", "")


static func b64url_decode(s: String) -> PackedByteArray:
	s = s.replace("-", "+").replace("_", "/")
	while s.length() % 4 != 0:
		s += "="
	return Marshalls.base64_to_raw(s)
