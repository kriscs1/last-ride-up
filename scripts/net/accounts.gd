extends Node
## Server side of player accounts (child of Net on the dedicated server).
##
## An account is the one thing a ban, a report history and server-checked purchases hang on.
## Every account is reached through one or more links, each one proven by the client:
##   device:<id>   a random id and secret the game makes on first start (user://device.cfg).
##                 The server keeps only a SHA-256 of the secret; it must match from then on.
##   steam:<id>    a Steam Web API ticket, checked by steam_shop (ISteamUserAuth).
##   gpgs:<id>     Google Play Games Services v2: a one-time server auth code, swapped for a
##                 token at Google, then games/v1/players/me gives the player id.
##   gc:<id>       Game Center: Apple's identity verification signature, checked against
##                 Apple's certificate.
## A guest's device account is merged into their platform account the first time they sign in
## on the platform, so whatever they had as a guest carries over.
##
## Saved in user://accounts.json. Bans are read from user://bans.txt (one account id or link per
## line, then an optional reason) and re-read while the server runs, so you can ban without a restart.
##
## Environment:
##   GPGS_CLIENT_ID, GPGS_CLIENT_SECRET  the OAuth "Web application" client of the Play Games project
##   APPLE_BUNDLE_ID                     the iOS bundle id (shared with receipts.gd)
##   GOOGLE_OAUTH_BASE, GOOGLE_GAMES_BASE, GC_CERT_HOSTS   optional, for testing

const MAX_SIGNATURE_AGE_MS := 60 * 60 * 1000

var save_path := "user://accounts.json"
var bans_path := "user://bans.txt"
var accounts := {}     # account id → {created, last_seen, name, links: [], owned: [], reports}
var links := {}        # link → account id
var secrets := {}      # device link → SHA-256 hex of its secret
var claims := {}       # store receipt → the account that first sent it
var bans := {}         # account id or link → reason
var _bans_time := -1
var _bans_check_t := 0.0
var _certs := {}       # Game Center certificate url → DER bytes

var gpgs_id := OS.get_environment("GPGS_CLIENT_ID")
var gpgs_secret := OS.get_environment("GPGS_CLIENT_SECRET")
var bundle_id := OS.get_environment("APPLE_BUNDLE_ID")
var oauth_base := _env("GOOGLE_OAUTH_BASE", "https://oauth2.googleapis.com/")
var games_base := _env("GOOGLE_GAMES_BASE", "https://games.googleapis.com/")
var cert_hosts := _env("GC_CERT_HOSTS", ".apple.com").split(",")


static func _env(k: String, fallback: String) -> String:
	var v := OS.get_environment(k)
	return v if v != "" else fallback


func _ready() -> void:
	load_all()
	print("Accounts: %d saved; Google Play Games sign-in %s; Game Center sign-in %s" % [accounts.size(),
		"on" if gpgs_enabled() else "off (GPGS_CLIENT_ID/GPGS_CLIENT_SECRET not set)",
		"on" if bundle_id != "" else "off (APPLE_BUNDLE_ID not set)"])


func gpgs_enabled() -> bool:
	return gpgs_id != "" and gpgs_secret != ""


# ---------------------------------------------------------------- storage

func load_all() -> void:
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			accounts = d.get("accounts", {})
			links = d.get("links", {})
			secrets = d.get("secrets", {})
			claims = d.get("claims", {})
	reload_bans(true)


func save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"accounts": accounts, "links": links, "secrets": secrets, "claims": claims}, "\t"))


func reload_bans(force := false) -> bool:
	## True when the list changed.
	if not FileAccess.file_exists(bans_path):
		var had := not bans.is_empty()
		bans.clear()
		_bans_time = -1
		return had
	var t := FileAccess.get_modified_time(bans_path)
	if t == _bans_time and not force:
		return false
	_bans_time = t
	bans.clear()
	var f := FileAccess.open(bans_path, FileAccess.READ)
	while f and not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var cut := line.find(" ")
		bans[line if cut < 0 else line.substr(0, cut)] = "" if cut < 0 else line.substr(cut + 1).strip_edges()
	return true


func ban(key: String, reason := "") -> void:
	## Adds a line to bans.txt; key is an account id or a link such as steam:7656….
	var f := FileAccess.open(bans_path, FileAccess.READ_WRITE if FileAccess.file_exists(bans_path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line((key + " " + reason).strip_edges())
		f.close()
	reload_bans(true)


func ban_reason(account_id: String) -> Variant:
	## null when not banned, otherwise the reason text.
	if bans.has(account_id):
		return bans[account_id]
	var acc: Dictionary = accounts.get(account_id, {})
	for l in acc.get("links", []):
		if bans.has(l):
			return bans[l]
	return null


func poll(delta: float) -> void:
	## Called by Net once a second: picks up edits to bans.txt.
	_bans_check_t += delta
	if _bans_check_t < 5.0:
		return
	_bans_check_t = 0.0
	if reload_bans():
		print("bans.txt reloaded: %d entries" % bans.size())
		for s in get_parent().slots_by_peer.values():
			_enforce(s)


# ---------------------------------------------------------------- linking

static func _new_id() -> String:
	return "a" + Crypto.new().generate_random_bytes(6).hex_encode()


static func _now() -> String:
	return Time.get_datetime_string_from_system(true)


func _make_account() -> String:
	var id := _new_id()
	while accounts.has(id):
		id = _new_id()
	accounts[id] = {"created": _now(), "last_seen": _now(), "name": "", "links": [], "owned": [], "reports": 0}
	return id


func _link(link: String, account_id: String) -> void:
	var old: String = links.get(link, "")
	if old != "" and accounts.has(old):
		accounts[old]["links"].erase(link)
	links[link] = account_id
	if not accounts[account_id]["links"].has(link):
		accounts[account_id]["links"].append(link)


func _only_device(account_id: String) -> bool:
	for l in accounts.get(account_id, {}).get("links", []):
		if not str(l).begins_with("device:"):
			return false
	return true


func _merge(from_id: String, into_id: String) -> void:
	## A guest signs in on a platform: their device account becomes part of the platform account.
	var a: Dictionary = accounts[from_id]
	var b: Dictionary = accounts[into_id]
	for l in a["links"].duplicate():
		_link(l, into_id)
	for pid in a["owned"]:
		if not b["owned"].has(pid):
			b["owned"].append(pid)
	b["reports"] = int(b["reports"]) + int(a["reports"])
	for k in claims:
		if claims[k] == from_id:
			claims[k] = into_id
	accounts.erase(from_id)


func attach(slot: CFSlot, link: String) -> String:
	## Puts the slot on the account behind a proven link. Returns the account id ("" if refused).
	var platform := link.get_slice(":", 0)
	var cur := slot.account_id if accounts.has(slot.account_id) else ""
	var acc_id: String = links.get(link, "")
	if acc_id != "" and not accounts.has(acc_id):
		links.erase(link)
		acc_id = ""
	if platform == "device" and cur != "":
		# The device never moves a player off the account they are already on.
		if acc_id == "":
			_link(link, cur)
		acc_id = cur
	elif acc_id == "":
		acc_id = cur if cur != "" else _make_account()
		_link(link, acc_id)
	elif cur != "" and cur != acc_id and _only_device(cur):
		_merge(cur, acc_id)
	slot.account_id = acc_id
	if platform != "device" or slot.platform == "":
		slot.platform = platform
	var acc: Dictionary = accounts[acc_id]
	acc["name"] = slot.name
	acc["last_seen"] = _now()
	var added := false
	for pid in acc["owned"]:
		if not slot.owned.has(pid):
			slot.owned[pid] = true
			added = true
	remember_owned(slot)
	save()
	if not _enforce(slot):
		return ""
	if added:
		get_parent().owned_changed(slot)
	return acc_id


func _enforce(slot: CFSlot) -> bool:
	## Refuses a banned player. False when refused.
	var why = ban_reason(slot.account_id)
	if why == null:
		return true
	print("refused banned account %s (%s)" % [slot.account_id, why])
	get_parent().refuse(slot, "This account is banned%s." % (": " + str(why) if str(why) != "" else ""))
	return false


func remember_owned(slot: CFSlot) -> void:
	## Server-checked purchases stay with the account, so they show on any device they sign in on.
	var acc: Dictionary = accounts.get(slot.account_id, {})
	if acc.is_empty():
		return
	var changed := false
	for pid in slot.owned:
		if not acc["owned"].has(pid):
			acc["owned"].append(pid)
			changed = true
	if changed:
		save()


static func proof_key(p: Dictionary) -> String:
	match str(p.get("store", "")):
		"google_play":
			return "g:" + str(p.get("json", "")).sha256_text()
		"app_store":
			return "a:" + str(p.get("transaction_id", ""))
	return ""


func claim_proofs(slot: CFSlot, proofs: Array) -> Array:
	## A store receipt belongs to the first account that sends it, so copying someone else's
	## purchase data shows nothing. Test-store proofs are not claimed.
	var out := []
	var changed := false
	for p in proofs.slice(0, 64):
		if not p is Dictionary:
			continue
		var k := proof_key(p)
		if k != "":
			var owner: String = claims.get(k, "")
			if owner != "" and owner != slot.account_id and accounts.has(owner):
				push_warning("account %s sent a receipt that belongs to %s" % [slot.account_id, owner])
				continue
			if owner != slot.account_id:
				claims[k] = slot.account_id
				changed = true
		out.append(p)
	if changed:
		save()
	return out


func note_report(target: CFSlot) -> int:
	## Counts reports against the account across all rooms; returns the new total.
	var acc: Dictionary = accounts.get(target.account_id, {})
	if acc.is_empty():
		return 0
	acc["reports"] = int(acc["reports"]) + 1
	save()
	return acc["reports"]


func _done(slot: CFSlot, link: String, display: String) -> void:
	var id := attach(slot, link)
	if id != "" and slot.peer != 0:
		get_parent().s_signed_in.rpc_id(slot.peer, id, slot.platform, display)


func _fail(slot: CFSlot, platform: String, why: String) -> void:
	push_warning("sign-in (%s) failed: %s" % [platform, why])
	if slot.peer != 0:
		get_parent().s_sign_in_failed.rpc_id(slot.peer, platform, why)


# ---------------------------------------------------------------- sign-in by platform

func sign_in(slot: CFSlot, platform: String, creds: Dictionary) -> void:
	match platform:
		"device":
			_device(slot, str(creds.get("id", "")), str(creds.get("secret", "")))
		"gpgs":
			_gpgs(slot, str(creds.get("code", "")))
		"gc":
			_game_center(slot, creds)
		_:
			_fail(slot, platform, "Unknown sign-in.")


func steam_verified(slot: CFSlot) -> void:
	_done(slot, "steam:" + slot.steamid, "Steam")


static func secret_hash(secret: String) -> String:
	return secret.sha256_text()


func _device(slot: CFSlot, id: String, secret: String) -> void:
	if not id.is_valid_hex_number() or id.length() != 32 or not secret.is_valid_hex_number() or secret.length() != 64:
		_fail(slot, "device", "That device id isn't valid.")
		return
	var link := "device:" + id
	var h := secret_hash(secret)
	if secrets.has(link) and secrets[link] != h:
		_fail(slot, "device", "That device id belongs to another install.")
		return
	secrets[link] = h
	_done(slot, link, "")


# Google Play Games Services v2 -----------------------------------------------------------

func _gpgs(slot: CFSlot, code: String) -> void:
	if not gpgs_enabled():
		_fail(slot, "gpgs", "Google Play Games sign-in isn't set up on this server.")
		return
	if code == "" or code.length() > 2048:
		_fail(slot, "gpgs", "No auth code.")
		return
	var q := HTTPClient.new().query_string_from_dict({"code": code, "client_id": gpgs_id,
		"client_secret": gpgs_secret, "grant_type": "authorization_code", "redirect_uri": ""})
	_http(oauth_base + "token", HTTPClient.METHOD_POST, ["Content-Type: application/x-www-form-urlencoded"], q,
		func(status: int, body: PackedByteArray):
			var tok = JSON.parse_string(body.get_string_from_utf8())
			if status != 200 or not tok is Dictionary or str(tok.get("access_token", "")) == "":
				_fail(slot, "gpgs", "Google didn't accept the sign-in (%d)." % status)
				return
			_http(games_base + "games/v1/players/me", HTTPClient.METHOD_GET,
				["Authorization: Bearer " + str(tok["access_token"])], "",
				func(st2: int, b2: PackedByteArray):
					var me = JSON.parse_string(b2.get_string_from_utf8())
					var pid := str(me.get("playerId", "")) if me is Dictionary else ""
					if st2 != 200 or pid == "":
						_fail(slot, "gpgs", "Google Play Games didn't return a player (%d)." % st2)
						return
					_done(slot, "gpgs:" + pid, str(me.get("displayName", "")))))


# Game Center -----------------------------------------------------------------------------

func _game_center(slot: CFSlot, c: Dictionary) -> void:
	if bundle_id == "":
		_fail(slot, "gc", "Game Center sign-in isn't set up on this server.")
		return
	var url := str(c.get("public_key_url", ""))
	var player := str(c.get("player_id", ""))
	var ts := int(c.get("timestamp", 0))
	var sig := Marshalls.base64_to_raw(str(c.get("signature", "")))
	var salt := Marshalls.base64_to_raw(str(c.get("salt", "")))
	if not cert_url_ok(url):
		_fail(slot, "gc", "That certificate address isn't Apple's.")
		return
	if player == "" or sig.is_empty() or salt.is_empty() or absi(int(Time.get_unix_time_from_system() * 1000.0) - ts) > MAX_SIGNATURE_AGE_MS:
		_fail(slot, "gc", "The Game Center signature is missing or too old.")
		return
	var payload := gc_payload(player, bundle_id, ts, salt)
	var check := func(der: PackedByteArray):
		if gc_verify(der, payload, sig):
			_done(slot, "gc:" + player, str(c.get("display_name", "")))
		else:
			_fail(slot, "gc", "The Game Center signature didn't check out.")
	if _certs.has(url):
		check.call(_certs[url])
		return
	_http(url, HTTPClient.METHOD_GET, [], "", func(status: int, body: PackedByteArray):
		if status != 200 or body.is_empty():
			_fail(slot, "gc", "Couldn't fetch Apple's certificate (%d)." % status)
			return
		_certs[url] = body
		check.call(body))


func cert_url_ok(url: String) -> bool:
	## Apple's key must come from Apple: https, and a host ending in one of cert_hosts.
	if not url.begins_with("https://"):
		return false
	var host := url.substr(8).get_slice("/", 0).get_slice(":", 0).to_lower()
	for h in cert_hosts:
		var hh := h.strip_edges().to_lower()
		if hh != "" and (host.ends_with(hh) or "." + host == hh):
			return true
	return false


static func gc_payload(player_id: String, bundle: String, timestamp: int, salt: PackedByteArray) -> PackedByteArray:
	## What Apple signs: player id, bundle id, timestamp as big-endian uint64, salt.
	var out := player_id.to_utf8_buffer()
	out.append_array(bundle.to_utf8_buffer())
	var ts := PackedByteArray()
	ts.resize(8)
	for i in 8:
		ts[i] = (timestamp >> (8 * (7 - i))) & 0xff
	out.append_array(ts)
	out.append_array(salt)
	return out


static func gc_verify(cert_der: PackedByteArray, payload: PackedByteArray, sig: PackedByteArray) -> bool:
	var spki := spki_from_der(cert_der)
	if spki.is_empty():
		return false
	var key := CryptoKey.new()
	var pem := "-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n" % Marshalls.raw_to_base64(spki)
	if key.load_from_string(pem, true) != OK:
		return false
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(payload)
	return Crypto.new().verify(HashingContext.HASH_SHA256, ctx.finish(), sig, key)


static func _der_item(d: PackedByteArray, at: int) -> Array:
	## [tag, header length, content length] of the DER element at `at`, or [] if malformed.
	if at + 2 > d.size():
		return []
	var tag: int = d[at]
	var n: int = d[at + 1]
	var hl := 2
	if n & 0x80:
		var k := n & 0x7f
		if k < 1 or k > 4 or at + 2 + k > d.size():
			return []
		n = 0
		for i in k:
			n = (n << 8) | d[at + 2 + i]
		hl += k
	if at + hl + n > d.size():
		return []
	return [tag, hl, n]


static func spki_from_der(cert: PackedByteArray) -> PackedByteArray:
	## The SubjectPublicKeyInfo of an X.509 certificate: Certificate → tbsCertificate → 7th field
	## (6th when the optional [0] version is missing).
	var outer := _der_item(cert, 0)
	if outer.is_empty() or outer[0] != 0x30:
		return PackedByteArray()
	var tbs_at: int = outer[1]
	var tbs := _der_item(cert, tbs_at)
	if tbs.is_empty() or tbs[0] != 0x30:
		return PackedByteArray()
	var at: int = tbs_at + tbs[1]
	var first := _der_item(cert, at)
	if first.is_empty():
		return PackedByteArray()
	var skip := 6 if first[0] == 0xa0 else 5   # [version], serial, signature, issuer, validity, subject
	for i in skip:
		var it := _der_item(cert, at)
		if it.is_empty():
			return PackedByteArray()
		at += it[1] + it[2]
	var spki := _der_item(cert, at)
	if spki.is_empty() or spki[0] != 0x30:
		return PackedByteArray()
	return cert.slice(at, at + spki[1] + spki[2])


# ---------------------------------------------------------------- http

func _http(url: String, method: int, headers: Array, body: String, done: Callable) -> void:
	var h := HTTPRequest.new()
	h.timeout = 15.0
	add_child(h)
	h.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, data: PackedByteArray):
		h.queue_free()
		done.call(code, data))
	if h.request(url, PackedStringArray(headers), method, body) != OK:
		h.queue_free()
		done.call(0, PackedByteArray())
