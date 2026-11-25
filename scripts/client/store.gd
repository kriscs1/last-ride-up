extends Node
## Store (autoload): which paid cosmetics this player owns, and buying them.
##
## Free items (CF.FREE_HATS / CF.FREE_FACES) are always owned. Paid items are one-off,
## non-consumable purchases whose store product id is CF.product_id(part, item), e.g. "hat_crown".
## The same ids must be created in Google Play Console, App Store Connect and the Steam
## microtransaction setup; see README "Selling cosmetics".
##
## The server decides what other players see: the client sends a proof for each purchase
## (Google's signed purchase, an App Store transaction id), and Steam players sign in with a
## Steam Web API ticket so the server can use its own purchase records.
##
## Backends, picked at start-up:
##   google_play  Android build with the GodotGooglePlayBilling addon enabled (BillingClient).
##   app_store    iOS build with the InAppStore plugin.
##   steam        Desktop build with GodotSteam. Purchases run through our dedicated server.
##   test         Debug builds with none of the above: purchases succeed at once, no money taken.
##                Other players only see them on a server started with --test-purchases.
##   none         Release build with no store: paid items can be tried on but not bought.

signal owned_changed
signal message(text: String)

var save_path := "user://purchases.cfg"
var owned := {}          # product id → true (paid items only)
var proofs := {}         # product id → proof dictionary sent to the server
var prices := {}         # product id → price text in the player's currency
var backend := "none"

var _net: Node
var _play: Object
var _play_script: Script
var _ios: Object
var _steam: Object

const PLAY_OK := 0
const PLAY_USER_CANCELED := 1
const PLAY_PURCHASED := 1   # Google Play Billing Purchase.PurchaseState
const PLAY_PENDING := 2


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--server"):
		return
	_net = get_node_or_null("/root/Net")
	load_owned()
	_pick_backend()
	if _net:
		_net.welcomed.connect(_on_welcomed)


func _pick_backend() -> void:
	if OS.has_feature("android"):
		for c in ProjectSettings.get_global_class_list():
			if c["class"] == "BillingClient":
				_setup_play(c["path"])
				return
	if Engine.has_singleton("InAppStore"):
		_setup_ios()
		return
	if Engine.has_singleton("Steam") and _setup_steam():
		return
	backend = "test" if OS.is_debug_build() else "none"


# ---------------------------------------------------------------- queries

func owns(part: String, item: String) -> bool:
	return CF.is_free(part, item) or owned.has(CF.product_id(part, item))


func can_buy() -> bool:
	if backend == "steam":
		return _net != null and _net.is_online()
	return backend != "none"


func price_text(part: String, item: String) -> String:
	var pid := CF.product_id(part, item)
	if prices.has(pid):
		return prices[pid]
	var c := CF.price_cents(part, item)
	return "$%d.%02d" % [c / 100, c % 100]


func unavailable_reason() -> String:
	if backend == "steam":
		return "Connect to a server to buy on Steam."
	return "Purchases aren't available in this version of the game."


# ---------------------------------------------------------------- actions

func buy(part: String, item: String) -> void:
	var pid := CF.product_id(part, item)
	if owns(part, item):
		return
	if not can_buy():
		message.emit(unavailable_reason())
		return
	match backend:
		"google_play":
			_play.purchase(pid)
		"app_store":
			_ios.purchase({"product_id": pid})
		"steam":
			message.emit("Opening Steam…")
			_net.send_steam_buy(pid)
		"test":
			grant(pid, {"store": "test", "product": pid})
			message.emit("Test purchase: %s unlocked (debug builds only, no money taken)." % _item_name(pid))


func restore() -> void:
	match backend:
		"google_play":
			_play.query_purchases(_play_script.ProductType.INAPP)
			message.emit("Checking your purchases…")
		"app_store":
			_ios.restore_purchases()
			message.emit("Checking your purchases…")
		"steam":
			if _net and _net.is_online():
				_net.send_steam_owned()
				message.emit("Checking your purchases…")
			else:
				message.emit(unavailable_reason())
		_:
			message.emit("Nothing to restore here.")


func grant(pid: String, proof := {}) -> void:
	if CF.item_of_product(pid).is_empty():
		return
	owned[pid] = true
	if not proof.is_empty():
		proofs[pid] = proof
	save_owned()
	owned_changed.emit()
	_share()


func replace_owned(pids: Array, new_proofs := {}) -> void:
	## The store is the record: whatever it lists is exactly what is owned (refunds drop out).
	owned.clear()
	proofs.clear()
	for pid in pids:
		if not CF.item_of_product(str(pid)).is_empty():
			owned[str(pid)] = true
			if new_proofs.has(pid):
				proofs[str(pid)] = new_proofs[pid]
	save_owned()
	owned_changed.emit()
	_share()


func load_owned() -> void:
	owned.clear()
	proofs.clear()
	var cfg := ConfigFile.new()
	if cfg.load(save_path) == OK:
		for pid in cfg.get_value("owned", "items", []):
			if not CF.item_of_product(str(pid)).is_empty():
				owned[str(pid)] = true
		var pr = cfg.get_value("owned", "proofs", {})
		if pr is Dictionary:
			for pid in pr:
				if owned.has(pid):
					proofs[pid] = pr[pid]


func save_owned() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("owned", "items", owned.keys())
	cfg.set_value("owned", "proofs", proofs)
	cfg.save(save_path)


func _share() -> void:
	## Send the server our proofs so other players see what we've bought (Steam uses its own records).
	if backend != "steam" and _net and _net.is_online() and not proofs.is_empty():
		_net.send_proofs(proofs.values())


func _on_welcomed(_id: String, _tok: String) -> void:
	if backend == "steam":
		_steam.getAuthTicketForWebApi(CF.STEAM_IDENTITY)   # answered by get_ticket_for_web_api
	else:
		_share()


func _item_name(pid: String) -> String:
	var pi := CF.item_of_product(pid)
	if pi.is_empty():
		return pid
	return (CF.HAT_NAMES if pi[0] == "hat" else CF.FACE_NAMES)[pi[1]]


func _process(_delta: float) -> void:
	if _ios:
		while _ios.get_pending_event_count() > 0:
			_on_ios_event(_ios.pop_pending_event())
	if _steam:
		_steam.run_callbacks()


# ---------------------------------------------------------------- Google Play

func _setup_play(path: String) -> void:
	_play_script = load(path)
	_play = _play_script.new()
	if _play is Node:
		add_child(_play)
	_play.connected.connect(_on_play_connected)
	_play.connect_error.connect(func(code: int, msg: String): push_warning("Play Billing: %d %s" % [code, msg]))
	_play.query_product_details_response.connect(_on_play_details)
	_play.on_purchase_updated.connect(_on_play_purchases.bind(false))
	_play.query_purchases_response.connect(_on_play_purchases.bind(true))
	_play.start_connection()
	backend = "google_play"


func _on_play_connected() -> void:
	var inapp = _play_script.ProductType.INAPP
	_play.query_product_details(PackedStringArray(CF.paid_products()), inapp)
	_play.query_purchases(inapp)


func _on_play_details(r: Dictionary) -> void:
	if int(r.get("response_code", -1)) != PLAY_OK:
		return
	for d in r.get("product_details", []):
		if d is Dictionary:
			var pid := str(d.get("product_id", ""))
			var price := _find_key(d.get("one_time_purchase_offer_details_list", []), "formatted_price")
			if pid != "" and price != "":
				prices[pid] = price
	owned_changed.emit()


static func _find_key(d, key: String) -> String:
	if d is Dictionary:
		if d.has(key):
			return str(d[key])
		for v in d.values():
			var f := _find_key(v, key)
			if f != "":
				return f
	elif d is Array:
		for v in d:
			var f := _find_key(v, key)
			if f != "":
				return f
	return ""


func _on_play_purchases(r: Dictionary, full_list: bool) -> void:
	var code := int(r.get("response_code", -1))
	if code != PLAY_OK:
		if not full_list:
			message.emit("Purchase cancelled." if code == PLAY_USER_CANCELED else "The store couldn't finish that purchase (code %d)." % code)
		return
	var got := {}   # product id → proof
	for p in r.get("purchases", []):
		var state := int(p.get("purchase_state", 0))
		if state == PLAY_PENDING:
			message.emit("Payment pending: the item unlocks when it clears.")
			continue
		if state != PLAY_PURCHASED:
			continue
		for pid in p.get("product_ids", []):
			got[str(pid)] = {"store": "google_play", "json": str(p.get("original_json", "")), "sig": str(p.get("signature", ""))}
		if not p.get("is_acknowledged", false):
			_play.acknowledge_purchase(p["purchase_token"])   # unacknowledged purchases are refunded after 3 days
	if full_list:
		replace_owned(got.keys(), got)
	else:
		for pid in got:
			grant(pid, got[pid])
		if not got.is_empty():
			message.emit("Unlocked! Thanks for supporting the game.")


# ---------------------------------------------------------------- App Store

func _setup_ios() -> void:
	_ios = Engine.get_singleton("InAppStore")
	_ios.set_auto_finish_transaction(true)
	_ios.request_product_info({"product_ids": PackedStringArray(CF.paid_products())})
	backend = "app_store"


func _on_ios_event(e: Dictionary) -> void:
	match e.get("type", ""):
		"product_info":
			var ids: Array = Array(e.get("ids", []))
			var lp: Array = Array(e.get("localized_prices", []))
			for i in mini(ids.size(), lp.size()):
				prices[str(ids[i])] = str(lp[i])
			owned_changed.emit()
		"purchase", "restore":
			if e.get("result", "") == "ok":
				grant(str(e.get("product_id", "")), {"store": "app_store", "transaction_id": str(e.get("transaction_id", ""))})
				if e["type"] == "purchase":
					message.emit("Unlocked! Thanks for supporting the game.")
			elif e.get("result", "") == "error":
				message.emit("The App Store couldn't finish that (%s)." % str(e.get("error", "error")))


# ---------------------------------------------------------------- Steam

func _setup_steam() -> bool:
	_steam = Engine.get_singleton("Steam")
	var init = _steam.steamInitEx(0, false)
	if init is Dictionary and int(init.get("status", 0)) != 0:
		push_warning("Steam did not start: %s" % str(init))
		_steam = null
		return false
	if not _steam.has_signal("microtransaction_auth_response") or not _steam.has_signal("get_ticket_for_web_api"):
		push_warning("This GodotSteam has no microtransaction/web-ticket signals; Steam purchases are off.")
		_steam = null
		return false
	_steam.microtransaction_auth_response.connect(_on_steam_auth)
	_steam.get_ticket_for_web_api.connect(_on_steam_ticket)
	if _net:
		_net.steam_order.connect(func(_pid: String, _oid: String, error: String):
			message.emit(error if error != "" else "Confirm the purchase in the Steam overlay."))
		_net.steam_owned.connect(func(items: Array): replace_owned(items))
		_net.steam_prices.connect(func(p: Dictionary):
			prices.merge(p, true)
			owned_changed.emit())
	backend = "steam"
	return true


static func ticket_hex(args: Array) -> String:
	## get_ticket_for_web_api(auth_ticket, result, ticket_size, ticket_buffer): the buffer may be an
	## Array of ints or a PackedByteArray depending on the GodotSteam version.
	if args.is_empty():
		return ""
	var buf = args[-1]
	var bytes: PackedByteArray = buf if buf is PackedByteArray else PackedByteArray(buf if buf is Array else [])
	if args.size() >= 4 and int(args[2]) > 0 and int(args[2]) < bytes.size():
		bytes = bytes.slice(0, int(args[2]))
	return bytes.hex_encode()


func _on_steam_ticket(...args: Array) -> void:
	var hex := ticket_hex(args)
	if hex != "" and _net and _net.is_online():
		_net.send_steam_auth(hex)


func _on_steam_auth(...args: Array) -> void:
	## microtransaction_auth_response(app_id, order_id, authorized)
	if args.size() < 2:
		return
	if bool(args[-1]):
		message.emit("Finishing the purchase…")
		_net.send_steam_finalize(str(args[-2]))
	else:
		message.emit("Purchase cancelled.")
