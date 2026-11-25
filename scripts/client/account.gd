extends Node
## Account (autoload): signs the player in to the game server.
##
## Every install has a device id and secret (user://device.cfg), so a player always has an
## account, even as a guest. On top of that the player signs in with their platform when the
## build has one, and the server links the two (see scripts/net/accounts.gd):
##   Steam               GodotSteam; the Web API ticket that Store already sends for purchases.
##   Google Play Games   the godot-play-game-services plugin (singleton GodotPlayGameServices).
##                       Needs CF.GPGS_SERVER_CLIENT_ID, the OAuth web client id of the project.
##   Game Center         the GameCenter singleton from godot-ios-plugins.
## Each time we connect, the platform gives us something fresh to prove who we are (a one-time
## auth code, a new signature), and the server checks it with Google, Apple or Valve.

signal changed

var device_path := "user://device.cfg"
var device_id := ""
var device_secret := ""
var platform := ""        # steam, gpgs, gc or "" (guest)
var platform_name := ""   # the player's name on that platform, when we know it
var account_id := ""      # from the server, once signed in
var server_platform := "" # what the server accepted: device, steam, gpgs or gc
var problem := ""         # the last sign-in error, shown on the menu

var _net: Node
var _gpgs: Object
var _gc: Object
var _gc_ok := false
var _retried_device := false

const PLATFORM_NAMES := {"steam": "Steam", "gpgs": "Google Play Games", "gc": "Game Center"}


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--server"):
		return
	load_device()
	_net = get_node_or_null("/root/Net")
	if _net:
		_net.welcomed.connect(_on_welcomed)
		_net.signed_in.connect(_on_signed_in)
		_net.sign_in_failed.connect(_on_failed)
		_net.disconnected.connect(func():
			account_id = ""
			changed.emit())
	_setup_platform.call_deferred()


# ---------------------------------------------------------------- device id

func load_device() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(device_path) == OK:
		device_id = str(cfg.get_value("device", "id", ""))
		device_secret = str(cfg.get_value("device", "secret", ""))
	if device_id.length() != 32 or device_secret.length() != 64:
		new_device()


func new_device() -> void:
	var c := Crypto.new()
	device_id = c.generate_random_bytes(16).hex_encode()
	device_secret = c.generate_random_bytes(32).hex_encode()
	var cfg := ConfigFile.new()
	cfg.set_value("device", "id", device_id)
	cfg.set_value("device", "secret", device_secret)
	cfg.save(device_path)


# ---------------------------------------------------------------- status

func status_text() -> String:
	if problem != "":
		return problem
	var pname := " as %s" % platform_name if platform_name != "" else ""
	if account_id != "" and server_platform != "device":
		return "Signed in with %s%s" % [PLATFORM_NAMES.get(server_platform, server_platform), pname]
	if platform != "":
		return "%s%s (checked when you connect)" % [PLATFORM_NAMES[platform], pname]
	return "Playing as a guest on this device"


# ---------------------------------------------------------------- platforms

func _setup_platform() -> void:
	var store := get_node_or_null("/root/Store")
	if store and store.backend == "steam" and Engine.has_singleton("Steam"):
		platform = "steam"
		var st := Engine.get_singleton("Steam")
		if st.has_method("getPersonaName"):
			platform_name = str(st.getPersonaName())
	elif OS.has_feature("android") and Engine.has_singleton("GodotPlayGameServices"):
		_setup_gpgs()
	elif Engine.has_singleton("GameCenter"):
		_setup_gc()
	changed.emit()


func _setup_gpgs() -> void:
	if CF.GPGS_SERVER_CLIENT_ID == "":
		push_warning("CF.GPGS_SERVER_CLIENT_ID is empty, so Google Play Games sign-in is off.")
		return
	_gpgs = Engine.get_singleton("GodotPlayGameServices")
	_connect_any(_gpgs, ["userAuthenticated", "user_authenticated"], _on_gpgs_authenticated)
	_connect_any(_gpgs, ["serverSideAccessRequested", "server_side_access_requested"], _on_gpgs_code)
	_call_any(_gpgs, ["initialize"], [])
	_call_any(_gpgs, ["isAuthenticated", "is_authenticated"], [])   # answered by userAuthenticated


func _on_gpgs_authenticated(ok: bool) -> void:
	if ok:
		platform = "gpgs"
		problem = ""
		if _net and _net.is_online():
			_request_gpgs_code()
	else:
		# Play Games signs in automatically when it can; otherwise we stay a guest.
		platform = ""
	changed.emit()


func sign_in_gpgs() -> void:
	## For a "Sign in with Google Play Games" button: shows Google's sign-in.
	if _gpgs:
		_call_any(_gpgs, ["signIn", "sign_in"], [])


func _request_gpgs_code() -> void:
	_call_any(_gpgs, ["requestServerSideAccess", "request_server_side_access"], [CF.GPGS_SERVER_CLIENT_ID, false])


func _on_gpgs_code(code: String) -> void:
	if code != "" and _net and _net.is_online():
		_net.send_sign_in("gpgs", {"code": code})


func _setup_gc() -> void:
	_gc = Engine.get_singleton("GameCenter")
	_call_any(_gc, ["authenticate"], [])


func _process(_delta: float) -> void:
	if _gc:
		while _gc.get_pending_event_count() > 0:
			_on_gc_event(_gc.pop_pending_event())


func _on_gc_event(e: Dictionary) -> void:
	match str(e.get("type", "")):
		"authentication":
			_gc_ok = str(e.get("result", "")) == "ok"
			platform = "gc" if _gc_ok else ""
			platform_name = str(e.get("alias", e.get("displayName", "")))
			if _gc_ok and _net and _net.is_online():
				_call_any(_gc, ["request_identity_verification_signature"], [])
			changed.emit()
		"identity_verification_signature":
			if str(e.get("result", "")) != "ok" or not _net or not _net.is_online():
				return
			_net.send_sign_in("gc", {"public_key_url": str(e.get("public_key_url", "")),
				"signature": str(e.get("signature", "")), "salt": str(e.get("salt", "")),
				"timestamp": int(e.get("timestamp", 0)), "player_id": str(e.get("player_id", "")),
				"display_name": platform_name})


static func _connect_any(o: Object, names: Array, f: Callable) -> void:
	for n in names:
		if o.has_signal(n):
			o.connect(n, f)
			return
	push_warning("Sign-in plugin has none of the signals %s" % str(names))


static func _call_any(o: Object, names: Array, args: Array) -> void:
	for n in names:
		if o.has_method(n):
			o.callv(n, args)
			return


# ---------------------------------------------------------------- server

func _on_welcomed(_id: String, _tok: String) -> void:
	problem = ""
	# The device sign-in is answered at once, so it is in place before we ask for a room.
	_net.send_sign_in("device", {"id": device_id, "secret": device_secret})
	if platform == "gpgs":
		_request_gpgs_code()
	elif platform == "gc" and _gc_ok:
		_call_any(_gc, ["request_identity_verification_signature"], [])
	# Steam: Store sends the Web API ticket; the server links it to this account.


func _on_signed_in(id: String, plat: String, display: String) -> void:
	account_id = id
	server_platform = plat
	if display != "" and plat != "device" and plat != "steam":
		platform_name = display
	changed.emit()


func _on_failed(plat: String, message: String) -> void:
	if plat == "device" and not _retried_device:
		# Our id is taken by another install (a copied save folder): start a fresh guest.
		_retried_device = true
		new_device()
		if _net and _net.is_online():
			_net.send_sign_in("device", {"id": device_id, "secret": device_secret})
		return
	if plat != "device":
		problem = "%s sign-in didn't work: %s Playing as a guest." % [PLATFORM_NAMES.get(plat, plat), message]
	changed.emit()
