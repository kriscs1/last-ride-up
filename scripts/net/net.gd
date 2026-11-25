extends Node
## Net (autoload). The same script runs on the dedicated server and on every client, so the RPC
## signatures always match. Functions starting c_ are client→server; s_ are server→client.
##
## Server:  godot --headless --path . -- --server [--port 24680]   (the --server flag is required)
## Client:  run the game normally; connect_to(address, port) from the menu.

signal connected_to_server
signal connection_failed
signal disconnected
signal welcomed(id: String, token: String)
signal room_changed(info: Dictionary)
signal match_started(data: Dictionary)
signal snapshot_received(snap: Dictionary)
signal items_changed(items: Array)
signal events_received(events: Array)
signal pong_received(rtt_ms: int)
signal error_received(message: String)
signal steam_order(product: String, order_id: String, error: String)
signal steam_owned(items: Array)
signal steam_prices(prices: Dictionary)
signal voice_received(from_id: String, seq: int, data: PackedByteArray)
signal chat_received(from_id: String, idx: int, target_id: String)
signal notice_received(message: String)
signal removed_from_room(message: String)

var role := "none"   # none, server, client

# ---------------------------------------------------------------- server state
var rooms := {}            # code → CFRoom
var slots_by_token := {}   # token → CFSlot
var slots_by_peer := {}    # peer id → CFSlot
var _housekeeping_t := 0.0
var steam_shop: Node      # server only: Steam purchases
var receipts: Node        # server only: Google Play / App Store purchase checks


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--server"):
		var port := CF.DEFAULT_PORT
		var i := args.find("--port")
		if i >= 0 and i + 1 < args.size():
			port = int(args[i + 1])
		start_server(port)


# ================================================================= SERVER

func start_server(port: int) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 128)
	if err != OK:
		push_error("Could not start the server on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	# Clients may only talk to the server, never relay RPCs to each other.
	(multiplayer as SceneMultiplayer).server_relay = false
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	role = "server"
	steam_shop = preload("res://scripts/net/steam_shop.gd").new()
	add_child(steam_shop)
	receipts = preload("res://scripts/net/receipts.gd").new()
	add_child(receipts)
	print("Last Ride Up server listening on UDP port %d" % port)
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127."):
			print("  on your network: %s:%d" % [ip, port])


func _physics_process(delta: float) -> void:
	if role != "server":
		return
	for r in rooms.values():
		r.step()
	_housekeeping_t += delta
	if _housekeeping_t >= 1.0:
		_housekeeping_t = 0.0
		_housekeeping()


func _housekeeping() -> void:
	var now := Time.get_ticks_msec()
	for code in rooms.keys():
		var r: CFRoom = rooms[code]
		for s in r.housekeeping():
			slots_by_token.erase(s.token)
		if r.connected_count() == 0 and r.empty_since > 0 and now - r.empty_since > 60000:
			for s in r.slots:
				slots_by_token.erase(s.token)
			rooms.erase(code)
			print("room %s closed" % code)
	for tok in slots_by_token.keys():
		var s: CFSlot = slots_by_token[tok]
		if s.room_code == "" and not s.connected and now - s.last_seen > 120000:
			slots_by_token.erase(tok)


func _on_peer_disconnected(peer: int) -> void:
	var s: CFSlot = slots_by_peer.get(peer)
	slots_by_peer.erase(peer)
	if s == null or s.peer != peer:
		return
	var r: CFRoom = rooms.get(s.room_code)
	if r:
		r.disconnect_slot(s)
	else:
		s.connected = false
		s.peer = 0
		s.last_seen = Time.get_ticks_msec()


func _sender_slot() -> CFSlot:
	if role != "server":
		return null
	return slots_by_peer.get(multiplayer.get_remote_sender_id())


func _sender_room() -> CFRoom:
	var s := _sender_slot()
	return rooms.get(s.room_code) if s else null


func _new_room(is_private: bool) -> CFRoom:
	var code := CFRoom.make_code()
	while rooms.has(code):
		code = CFRoom.make_code()
	var r := CFRoom.new(code, is_private, self)
	rooms[code] = r
	print("room %s created (%s)" % [code, "private" if is_private else "public"])
	return r


func _leave_current(s: CFSlot) -> void:
	var r: CFRoom = rooms.get(s.room_code)
	if r:
		r.remove(s)


static func _clean_name(raw: String) -> String:
	var out := ""
	for ch in raw.strip_edges():
		if ch.is_valid_identifier() or ch == " " or ch == "-" or ch == "." or (ch >= "0" and ch <= "9"):
			out += ch
	out = out.strip_edges().substr(0, 14)
	return out if out != "" else "Explorer"


# ---------------------------------------------------------------- client → server RPCs

@rpc("any_peer", "call_remote", "reliable")
func c_hello(pname: String, token: String) -> void:
	if role != "server":
		return
	var peer := multiplayer.get_remote_sender_id()
	var s: CFSlot = slots_by_token.get(token) if token != "" else null
	if s:
		# Reconnect: same player, same seat, same room.
		if s.peer != 0 and s.peer != peer:
			slots_by_peer.erase(s.peer)
			multiplayer.multiplayer_peer.disconnect_peer(s.peer)
		s.name = _clean_name(pname)
		slots_by_peer[peer] = s
		s_welcome.rpc_id(peer, s.id, s.token)
		var r: CFRoom = rooms.get(s.room_code)
		if r:
			r.reconnect(s, peer)
			print("%s reconnected to %s" % [s.name, r.code])
		else:
			s.peer = peer
			s.connected = true
		return
	s = CFSlot.new()
	s.id = "%08x" % (randi() & 0x7fffffff)
	s.token = "%08x%08x%08x" % [randi() & 0x7fffffff, randi() & 0x7fffffff, Time.get_ticks_usec() & 0x7fffffff]
	s.name = _clean_name(pname)
	s.peer = peer
	s.last_seen = Time.get_ticks_msec()
	slots_by_token[s.token] = s
	slots_by_peer[peer] = s
	s_welcome.rpc_id(peer, s.id, s.token)


@rpc("any_peer", "call_remote", "reliable")
func c_look(animal: String, hat: String, face: String) -> void:
	var s := _sender_slot()
	if s == null:
		return
	s.animal = animal if CF.ANIMALS.has(animal) else ""
	s.hat = hat if CF.HATS.has(hat) else "none"
	s.face = face if CF.FACES.has(face) else "none"
	var r: CFRoom = rooms.get(s.room_code)
	if r:
		r.look_changed(s)


func owned_changed(s: CFSlot) -> void:
	## A purchase was checked: if the player is wearing it, everyone in the room now sees it.
	var r: CFRoom = rooms.get(s.room_code)
	if r:
		r.broadcast_room()


@rpc("any_peer", "call_remote", "reliable")
func c_proofs(proofs: Array) -> void:
	var s := _sender_slot()
	if s:
		receipts.check(proofs, func(pid: String):
			if not s.owned.has(pid):
				s.owned[pid] = true
				owned_changed(s))


@rpc("any_peer", "call_remote", "reliable")
func c_steam_auth(ticket_hex: String) -> void:
	var s := _sender_slot()
	if s:
		steam_shop.authenticate(s, ticket_hex)


@rpc("any_peer", "call_remote", "reliable")
func c_steam_buy(product: String) -> void:
	var s := _sender_slot()
	if s:
		steam_shop.begin(s, product)


@rpc("any_peer", "call_remote", "reliable")
func c_steam_finalize(order_id: String) -> void:
	var s := _sender_slot()
	if s:
		steam_shop.finish(s, order_id)


@rpc("any_peer", "call_remote", "reliable")
func c_steam_owned() -> void:
	var s := _sender_slot()
	if s:
		steam_shop.send_owned(s)


@rpc("any_peer", "call_remote", "reliable")
func c_quick() -> void:
	var s := _sender_slot()
	if s == null:
		return
	_leave_current(s)
	for r in rooms.values():
		if not r.is_private and r.state == "lobby" and not r.is_full() and not r.is_banned(s):
			r.join(s)
			return
	_new_room(false).join(s)


@rpc("any_peer", "call_remote", "reliable")
func c_create(is_private: bool) -> void:
	var s := _sender_slot()
	if s == null:
		return
	_leave_current(s)
	_new_room(is_private).join(s)


@rpc("any_peer", "call_remote", "reliable")
func c_join(code: String) -> void:
	var s := _sender_slot()
	if s == null:
		return
	var r: CFRoom = rooms.get(code.strip_edges().to_upper())
	if r == null:
		s_error.rpc_id(s.peer, "No room with that code.")
		return
	if r.is_full():
		s_error.rpc_id(s.peer, "That room is full.")
		return
	if r.is_banned(s):
		s_error.rpc_id(s.peer, "You can't join that room.")
		return
	if r.code != s.room_code:
		_leave_current(s)
		r.join(s)


@rpc("any_peer", "call_remote", "reliable")
func c_leave() -> void:
	var s := _sender_slot()
	if s:
		_leave_current(s)


@rpc("any_peer", "call_remote", "reliable")
func c_settings(mode: String, map: String) -> void:
	var r := _sender_room()
	if r:
		r.set_options(_sender_slot(), mode, map)


@rpc("any_peer", "call_remote", "reliable")
func c_sabotage(what: String) -> void:
	var r := _sender_room()
	if r:
		r.sabotage_request(_sender_slot(), what)


@rpc("any_peer", "call_remote", "reliable")
func c_vote(target: String) -> void:
	var r := _sender_room()
	if r:
		r.vote_request(_sender_slot(), target)


@rpc("any_peer", "call_remote", "reliable")
func c_start() -> void:
	var r := _sender_room()
	if r:
		r.request_start(_sender_slot())


@rpc("any_peer", "call_remote", "reliable")
func c_lobby() -> void:
	var r := _sender_room()
	if r:
		r.request_lobby()


@rpc("any_peer", "call_remote", "reliable")
func c_chat(idx: int, target: String) -> void:
	var r := _sender_room()
	if r:
		r.chat(_sender_slot(), idx, target)


@rpc("any_peer", "call_remote", "reliable")
func c_voice_mode(mode: String) -> void:
	var s := _sender_slot()
	if s and CF.VOICE_MODES.has(mode) and s.voice_mode != mode:
		s.voice_mode = mode
		var r: CFRoom = rooms.get(s.room_code)
		if r:
			r.broadcast_room()


@rpc("any_peer", "call_remote", "unreliable_ordered", 3)
func c_voice(seq: int, data: PackedByteArray) -> void:
	var r := _sender_room()
	if r:
		r.voice(_sender_slot(), seq, data)


@rpc("any_peer", "call_remote", "reliable")
func c_room_voice(on: bool) -> void:
	var r := _sender_room()
	if r:
		r.set_voice_allowed(_sender_slot(), on)


@rpc("any_peer", "call_remote", "reliable")
func c_report(target: String, reason: int) -> void:
	var r := _sender_room()
	if r:
		r.report(_sender_slot(), target, reason)


@rpc("any_peer", "call_remote", "reliable")
func c_kick(target: String) -> void:
	var r := _sender_room()
	if r:
		r.kick(_sender_slot(), target)


var report_path := "user://reports.jsonl"

func log_report(entry: Dictionary) -> void:
	## One JSON line per report. Review these and act on them (see README "Player safety").
	print("REPORT %s" % JSON.stringify(entry))
	var f := FileAccess.open(report_path, FileAccess.READ_WRITE if FileAccess.file_exists(report_path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line(JSON.stringify(entry))
		f.close()


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func c_inputs(frames: Array) -> void:
	var s := _sender_slot()
	var r := _sender_room()
	if s and r and r.state == "playing" and frames.size() <= 16:
		r.queue_inputs(s, frames)


@rpc("any_peer", "call_remote", "unreliable", 2)
func c_ping(client_ms: int) -> void:
	if role == "server":
		s_pong.rpc_id(multiplayer.get_remote_sender_id(), client_ms)


# ================================================================= CLIENT

func connect_to(address: String, port: int) -> void:
	disconnect_from_server()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer
	role = "client"
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_failed)
		multiplayer.server_disconnected.connect(_on_server_gone)


func disconnect_from_server() -> void:
	if role == "client" and multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	role = "none"


func is_online() -> bool:
	return role == "client" and multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _on_connected() -> void:
	connected_to_server.emit()


func _on_failed() -> void:
	role = "none"
	connection_failed.emit()


func _on_server_gone() -> void:
	role = "none"
	disconnected.emit()


## Convenience wrappers so client code never needs to know RPC details.
func send_hello(pname: String, token: String) -> void: c_hello.rpc_id(1, pname, token)
func send_look(animal: String, hat: String, face: String) -> void: c_look.rpc_id(1, animal, hat, face)
func send_proofs(proofs: Array) -> void: c_proofs.rpc_id(1, proofs)
func send_steam_auth(ticket_hex: String) -> void: c_steam_auth.rpc_id(1, ticket_hex)
func send_steam_buy(product: String) -> void: c_steam_buy.rpc_id(1, product)
func send_steam_finalize(order_id: String) -> void: c_steam_finalize.rpc_id(1, order_id)
func send_steam_owned() -> void: c_steam_owned.rpc_id(1)
func send_quick() -> void: c_quick.rpc_id(1)
func send_create(is_private: bool) -> void: c_create.rpc_id(1, is_private)
func send_join(code: String) -> void: c_join.rpc_id(1, code)
func send_leave() -> void: c_leave.rpc_id(1)
func send_settings(mode: String, map: String) -> void: c_settings.rpc_id(1, mode, map)
func send_sabotage(what: String) -> void: c_sabotage.rpc_id(1, what)
func send_vote(target: String) -> void: c_vote.rpc_id(1, target)
func send_start() -> void: c_start.rpc_id(1)
func send_lobby() -> void: c_lobby.rpc_id(1)
func send_inputs(frames: Array) -> void: c_inputs.rpc_id(1, frames)
func send_ping() -> void: c_ping.rpc_id(1, Time.get_ticks_msec())
func send_chat(idx: int, target: String) -> void: c_chat.rpc_id(1, idx, target)
func send_voice_mode(mode: String) -> void: c_voice_mode.rpc_id(1, mode)
func send_voice(seq: int, data: PackedByteArray) -> void: c_voice.rpc_id(1, seq, data)
func send_room_voice(on: bool) -> void: c_room_voice.rpc_id(1, on)
func send_report(target: String, reason: int) -> void: c_report.rpc_id(1, target, reason)
func send_kick(target: String) -> void: c_kick.rpc_id(1, target)


# ---------------------------------------------------------------- server → client RPCs

@rpc("authority", "call_remote", "reliable")
func s_welcome(id: String, token: String) -> void:
	welcomed.emit(id, token)


@rpc("authority", "call_remote", "reliable")
func s_room(info: Dictionary) -> void:
	room_changed.emit(info)


@rpc("authority", "call_remote", "reliable")
func s_start(data: Dictionary) -> void:
	match_started.emit(data)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func s_snap(packed: PackedByteArray, mine: Dictionary) -> void:
	## Shared snapshot (compressed) plus this player's private part.
	var snap := CFWire.unpack_snapshot(packed)
	if snap.is_empty():
		return
	snap["me"] = mine
	snapshot_received.emit(snap)


@rpc("authority", "call_remote", "reliable")
func s_snap_reliable(snap: Dictionary) -> void:
	snapshot_received.emit(snap)


@rpc("authority", "call_remote", "reliable")
func s_items(items: Array) -> void:
	items_changed.emit(items)


@rpc("authority", "call_remote", "reliable")
func s_events(events: Array) -> void:
	events_received.emit(events)


@rpc("authority", "call_remote", "unreliable", 2)
func s_pong(client_ms: int) -> void:
	pong_received.emit(Time.get_ticks_msec() - client_ms)


@rpc("authority", "call_remote", "reliable")
func s_error(message: String) -> void:
	error_received.emit(message)


@rpc("authority", "call_remote", "reliable")
func s_steam_order(product: String, order_id: String, error: String) -> void:
	steam_order.emit(product, order_id, error)


@rpc("authority", "call_remote", "reliable")
func s_steam_owned(items: Array) -> void:
	steam_owned.emit(items)


@rpc("authority", "call_remote", "reliable")
func s_steam_prices(prices: Dictionary) -> void:
	steam_prices.emit(prices)


@rpc("authority", "call_remote", "unreliable_ordered", 3)
func s_voice(from: String, seq: int, data: PackedByteArray) -> void:
	voice_received.emit(from, seq, data)


@rpc("authority", "call_remote", "reliable")
func s_chat(from: String, idx: int, target: String) -> void:
	chat_received.emit(from, idx, target)


@rpc("authority", "call_remote", "reliable")
func s_notice(message: String) -> void:
	notice_received.emit(message)


@rpc("authority", "call_remote", "reliable")
func s_removed(message: String) -> void:
	removed_from_room.emit(message)
