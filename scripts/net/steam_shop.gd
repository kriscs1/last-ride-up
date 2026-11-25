extends Node
## Server side of Steam purchases (child of Net on the dedicated server).
## Steam requires the publisher Web API key to stay off players' machines, so the server checks
## who the player is (a Web API auth ticket), prices the item in their Steam currency, starts
## (InitTxn) and finishes (FinalizeTxn) the order, and records who owns what.
##
## Environment:
##   STEAM_PUBLISHER_KEY  publisher Web API key (required; without it Steam purchases are off)
##   STEAM_APP_ID         the game's app id
##   STEAM_SANDBOX        "0" for real money; anything else (the default) uses ISteamMicroTxnSandbox
##   STEAM_API_BASE       optional, default https://partner.steam-api.com/ (for testing)
##
## Purchases are stored in user://steam_purchases.json (steamid → [product ids]).

const SAVE := "user://steam_purchases.json"

## Prices per Steam currency, in hundredths, for tier 1 (US$0.99) and tier 2 (US$1.99).
## Steam's increment rules apply (JPY/INR/… ×100, CRC ×500, KRW ×1000, VND ×50000).
const PRICES := {
	"USD": [99, 199], "EUR": [99, 199], "GBP": [89, 179], "CAD": [139, 279], "AUD": [149, 299], "NZD": [169, 329],
	"CHF": [99, 189], "NOK": [1100, 2200], "PLN": [449, 899], "BRL": [549, 1099], "MXN": [1900, 3900],
	"JPY": [15000, 30000], "KRW": [140000, 280000], "CNY": [700, 1400], "HKD": [800, 1600], "TWD": [3000, 6000],
	"SGD": [139, 279], "MYR": [450, 900], "THB": [3500, 7000], "PHP": [5500, 11000], "IDR": [1500000, 3000000],
	"VND": [2500000, 5000000], "INR": [9000, 18000], "RUB": [8900, 17900], "UAH": [4000, 8000], "KZT": [50000, 100000],
	"ZAR": [1800, 3600], "AED": [400, 750], "SAR": [400, 750], "QAR": [400, 750], "KWD": [30, 60], "ILS": [400, 750],
	"CLP": [90000, 180000], "COP": [400000, 800000], "PEN": [400, 750], "UYU": [4000, 8000], "CRC": [55000, 110000],
}
const STEP := {"CLP": 100, "COP": 100, "IDR": 100, "INR": 100, "JPY": 100, "KZT": 100, "TWD": 100, "UAH": 100,
	"UYU": 100, "CRC": 500, "KRW": 1000, "VND": 50000}
const SYMBOL := {"USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "AUD": "A$", "CAD": "C$", "NZD": "NZ$", "BRL": "R$",
	"INR": "₹", "KRW": "₩", "RUB": "₽", "PLN": "zł ", "CNY": "¥", "HKD": "HK$", "MXN": "Mex$", "SGD": "S$", "TWD": "NT$"}

var key := OS.get_environment("STEAM_PUBLISHER_KEY")
var app_id := OS.get_environment("STEAM_APP_ID")
var api := OS.get_environment("STEAM_API_BASE") if OS.get_environment("STEAM_API_BASE") != "" else "https://partner.steam-api.com/"
var txn := "ISteamMicroTxn" if OS.get_environment("STEAM_SANDBOX") == "0" else "ISteamMicroTxnSandbox"
var orders := {}   # order id → {"slot": CFSlot, "product"}
var owned := {}    # steamid → Array of product ids


func _ready() -> void:
	var f := FileAccess.open(SAVE, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			owned = d
	if enabled():
		print("Steam purchases on (%s%s)" % [api, txn])


func enabled() -> bool:
	return key != "" and app_id.is_valid_int()


static func amount(currency: String, tier: int) -> int:
	return PRICES[currency][tier - 1] if PRICES.has(currency) else 0


static func price_label(currency: String, hundredths: int) -> String:
	var whole := hundredths % 100 == 0
	var num := str(hundredths / 100) if whole else "%d.%02d" % [hundredths / 100, hundredths % 100]
	return SYMBOL[currency] + num if SYMBOL.has(currency) else "%s %s" % [num, currency]


func prices_for(currency: String) -> Dictionary:
	var out := {}
	for pid in CF.paid_products():
		var pi := CF.item_of_product(pid)
		out[pid] = price_label(currency, amount(currency, CF.price_tier(pi[0], pi[1])))
	return out


# ---------------------------------------------------------------- who is this?

func authenticate(slot: CFSlot, ticket_hex: String) -> void:
	if not enabled() or not ticket_hex.is_valid_hex_number() or ticket_hex.length() > 8192:
		return
	_call("GET", "ISteamUserAuth/AuthenticateUserTicket/v1/", {"key": key, "appid": app_id, "ticket": ticket_hex,
		"identity": CF.STEAM_IDENTITY}, func(resp: Dictionary):
		var params = resp.get("params", {})
		if not params is Dictionary or str(params.get("result", "")) != "OK" or not str(params.get("steamid", "")).is_valid_int():
			push_warning("Steam ticket rejected: %s" % str(resp))
			return
		slot.steamid = str(params["steamid"])
		get_parent().accounts.steam_verified(slot)
		if slot.refused:
			return
		_grant_recorded(slot)
		_call("GET", txn + "/GetUserInfo/v2/", {"key": key, "appid": app_id, "steamid": slot.steamid}, func(info: Dictionary):
			var p = info.get("params", {})
			slot.steam_currency = str(p.get("currency", "USD")) if p is Dictionary else "USD"
			if slot.peer != 0:
				get_parent().s_steam_prices.rpc_id(slot.peer, prices_for(slot.steam_currency))))


func _grant_recorded(slot: CFSlot) -> void:
	var list: Array = owned.get(slot.steamid, [])
	for pid in list:
		slot.owned[pid] = true
	get_parent().owned_changed(slot)
	if slot.peer != 0:
		get_parent().s_steam_owned.rpc_id(slot.peer, list)


func send_owned(slot: CFSlot) -> void:
	if slot.steamid != "":
		_grant_recorded(slot)


# ---------------------------------------------------------------- buying

func begin(slot: CFSlot, product: String) -> void:
	var pi := CF.item_of_product(product)
	if not enabled():
		_reply(slot, product, "", "Steam purchases are not set up on this server.")
		return
	if slot.steamid == "":
		_reply(slot, product, "", "Still checking your Steam account; try again in a moment.")
		return
	if pi.is_empty():
		_reply(slot, product, "", "That item can't be bought.")
		return
	if owned.get(slot.steamid, []).has(product):
		_grant_recorded(slot)
		return
	var currency := slot.steam_currency if PRICES.has(slot.steam_currency) else "USD"
	var b := Crypto.new().generate_random_bytes(8)
	b[7] &= 0x7f
	var oid := str(maxi(b.decode_s64(0), 1))
	var names: Dictionary = CF.HAT_NAMES if pi[0] == "hat" else CF.FACE_NAMES
	var params := {"key": key, "orderid": oid, "steamid": slot.steamid, "appid": app_id, "itemcount": 1,
		"language": "en", "currency": currency, "usersession": "client",
		"itemid[0]": CF.steam_item_id(product), "qty[0]": 1, "amount[0]": amount(currency, CF.price_tier(pi[0], pi[1])),
		"description[0]": "Last Ride Up: %s" % names[pi[1]]}
	_call("POST", txn + "/InitTxn/v3/", params, func(resp: Dictionary):
		if resp.get("result", "") == "OK":
			orders[oid] = {"slot": slot, "product": product}
			_reply(slot, product, oid, "")
		else:
			_reply(slot, product, "", "Steam refused the order: %s" % _err(resp)))


func finish(slot: CFSlot, oid: String) -> void:
	var o: Dictionary = orders.get(oid, {})
	if o.is_empty() or o["slot"] != slot:
		return
	orders.erase(oid)
	_call("POST", txn + "/FinalizeTxn/v2/", {"key": key, "orderid": oid, "appid": app_id}, func(resp: Dictionary):
		if resp.get("result", "") == "OK":
			var list: Array = owned.get(slot.steamid, [])
			if not list.has(o["product"]):
				list.append(o["product"])
			owned[slot.steamid] = list
			_save()
			_grant_recorded(slot)
		else:
			_reply(slot, o["product"], "", "Steam couldn't finish the payment: %s" % _err(resp)))


func _reply(slot: CFSlot, product: String, oid: String, error: String) -> void:
	if slot.peer != 0:
		get_parent().s_steam_order.rpc_id(slot.peer, product, oid, error)


static func _err(resp: Dictionary) -> String:
	var e = resp.get("error", {})
	return str(e.get("errordesc", "no answer")) if e is Dictionary else "no answer"


func _save() -> void:
	var f := FileAccess.open(SAVE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(owned))


func _call(method: String, path: String, params: Dictionary, done: Callable) -> void:
	## Steam Web API call; done gets the "response" object ({} on failure).
	var h := HTTPRequest.new()
	h.timeout = 15.0
	add_child(h)
	h.request_completed.connect(func(_result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray):
		h.queue_free()
		var j = JSON.parse_string(body.get_string_from_utf8())
		var resp = j.get("response", {}) if j is Dictionary else {}
		done.call(resp if resp is Dictionary else {}))
	var q := HTTPClient.new().query_string_from_dict(params)
	var err: int
	if method == "GET":
		err = h.request(api + path + "?" + q)
	else:
		err = h.request(api + path, ["Content-Type: application/x-www-form-urlencoded"], HTTPClient.METHOD_POST, q)
	if err != OK:
		h.queue_free()
		done.call({})
