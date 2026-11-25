extends Node
## Server side of Steam microtransactions (child of Net on the dedicated server).
## Steam requires the publisher Web API key to stay off players' machines, so the server
## starts (InitTxn) and finishes (FinalizeTxn) each order and records who owns what.
##
## Environment:
##   STEAM_PUBLISHER_KEY  publisher Web API key (required; without it Steam purchases are off)
##   STEAM_APP_ID         the game's app id
##   STEAM_SANDBOX        "0" for real money; anything else (the default) uses ISteamMicroTxnSandbox
##
## Purchases are stored in user://steam_purchases.json (steamid → [product ids]).
## Note: the steamid a client sends is not yet verified with a session ticket.

const SAVE := "user://steam_purchases.json"

var key := OS.get_environment("STEAM_PUBLISHER_KEY")
var app_id := OS.get_environment("STEAM_APP_ID")
var base := "https://partner.steam-api.com/%s/" % ("ISteamMicroTxn" if OS.get_environment("STEAM_SANDBOX") == "0" else "ISteamMicroTxnSandbox")
var orders := {}   # order id → {"peer", "steamid", "product"}
var owned := {}    # steamid → Array of product ids


func _ready() -> void:
	var f := FileAccess.open(SAVE, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			owned = d
	if enabled():
		print("Steam purchases on (%s)" % base)


func enabled() -> bool:
	return key != "" and app_id.is_valid_int()


func begin(peer: int, steamid: String, product: String) -> void:
	var pi := CF.item_of_product(product)
	if not enabled():
		_reply_order(peer, product, "", "Steam purchases are not set up on this server.")
		return
	if not steamid.is_valid_int() or pi.is_empty() or CF.is_free(pi[0], pi[1]):
		_reply_order(peer, product, "", "That item can't be bought.")
		return
	if owned.get(steamid, []).has(product):
		get_parent().s_steam_owned.rpc_id(peer, owned[steamid])
		return
	var b := Crypto.new().generate_random_bytes(8)
	b[7] &= 0x7f
	var oid := str(maxi(b.decode_s64(0), 1))
	var names: Dictionary = CF.HAT_NAMES if pi[0] == "hat" else CF.FACE_NAMES
	var params := {"key": key, "orderid": oid, "steamid": steamid, "appid": app_id, "itemcount": 1,
		"language": "en", "currency": "USD", "usersession": "client",
		"itemid[0]": CF.steam_item_id(product), "qty[0]": 1, "amount[0]": CF.price_cents(pi[0], pi[1]),
		"description[0]": "Last Ride Up: %s" % names[pi[1]]}
	_post("InitTxn/v3/", params, func(resp: Dictionary):
		if resp.get("result", "") == "OK":
			orders[oid] = {"peer": peer, "steamid": steamid, "product": product}
			_reply_order(peer, product, oid, "")
		else:
			_reply_order(peer, product, "", "Steam refused the order: %s" % _err(resp)))


func finish(peer: int, oid: String) -> void:
	var o: Dictionary = orders.get(oid, {})
	if o.is_empty() or o["peer"] != peer:
		return
	_post("FinalizeTxn/v2/", {"key": key, "orderid": oid, "appid": app_id}, func(resp: Dictionary):
		orders.erase(oid)
		if resp.get("result", "") == "OK":
			var list: Array = owned.get(o["steamid"], [])
			if not list.has(o["product"]):
				list.append(o["product"])
			owned[o["steamid"]] = list
			_save()
			get_parent().s_steam_owned.rpc_id(peer, list)
		else:
			_reply_order(peer, o["product"], "", "Steam couldn't finish the payment: %s" % _err(resp)))


func send_owned(peer: int, steamid: String) -> void:
	get_parent().s_steam_owned.rpc_id(peer, owned.get(steamid, []))


func _reply_order(peer: int, product: String, oid: String, error: String) -> void:
	get_parent().s_steam_order.rpc_id(peer, product, oid, error)


static func _err(resp: Dictionary) -> String:
	var e = resp.get("error", {})
	return str(e.get("errordesc", "no answer")) if e is Dictionary else "no answer"


func _save() -> void:
	var f := FileAccess.open(SAVE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(owned))


func _post(path: String, params: Dictionary, done: Callable) -> void:
	var h := HTTPRequest.new()
	h.timeout = 15.0
	add_child(h)
	h.request_completed.connect(func(_result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray):
		h.queue_free()
		var j = JSON.parse_string(body.get_string_from_utf8())
		var resp = j.get("response", {}) if j is Dictionary else {}
		done.call(resp if resp is Dictionary else {}))
	var err := h.request(base + path, ["Content-Type: application/x-www-form-urlencoded"], HTTPClient.METHOD_POST,
		HTTPClient.new().query_string_from_dict(params))
	if err != OK:
		h.queue_free()
		done.call({})
