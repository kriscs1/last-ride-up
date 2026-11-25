class_name CFRoom
extends RefCounted
## One game room on the server: lobby → match → lobby. The room owns the only real copy of the match.
## Clients send inputs; the room steps the shared rules and sends snapshots and events.

const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var code := ""
var is_private := false
var slots: Array = []        # CFSlot
var host_id := ""
var state := "lobby"         # lobby, playing
var mode := "none"           # none, bot, traitors (CF.MODES)
var map_choice := "verdant"   # a map id or "random"
var match_state: CFMatch = null
var tick := 0
var empty_since := 0
var net                      # the Net autoload (untyped: its RPC methods are looked up at runtime)


static func make_code() -> String:
	var s := ""
	for i in 6:
		s += CODE_CHARS[randi() % CODE_CHARS.length()]
	return s


func _init(room_code: String, private_room: bool, net_node) -> void:
	code = room_code
	is_private = private_room
	net = net_node


func is_full() -> bool:
	return slots.size() >= CF.MAX_PLAYERS


func connected_count() -> int:
	return slots.filter(func(s): return s.connected).size()


func join(slot: CFSlot) -> void:
	if not slots.has(slot):
		slot.color = _free_color(slot)
		slots.append(slot)
	slot.room_code = code
	if host_id == "" or not slots.any(func(s): return s.id == host_id and s.connected):
		host_id = slot.id
	empty_since = 0
	broadcast_room()
	if state == "playing" and match_state:
		# Someone new joining a running match gets a fox at camp (a reconnect already has one).
		var running := match_state.phase == "running" or match_state.phase == "escape"
		if running and match_state.find_player(slot.id) == null:
			CFSim.add_player(match_state, slot.id, slot.name, slot.color)
			slot.inputs.clear()
			slot.ack = 0
			slot.last_input = CFInput.new()
		send_start(slot)


func disconnect_slot(slot: CFSlot) -> void:
	## Socket dropped: keep the seat for the reconnect grace period.
	slot.peer = 0
	slot.connected = false
	slot.last_seen = Time.get_ticks_msec()
	slot.inputs.clear()
	slot.last_input = CFInput.new()
	if match_state:
		var p := match_state.find_player(slot.id)
		if p:
			p.connected = false
	if host_id == slot.id:
		for s in slots:
			if s.connected:
				host_id = s.id
				break
	if connected_count() == 0:
		empty_since = Time.get_ticks_msec()
	# Deferred: when several players drop at once, the others' sockets are already closed but not yet
	# handled, and sending to them fails. By the end of the frame every disconnect has been handled.
	broadcast_room.call_deferred()


func _color_taken(color: Color, by_other_than: CFSlot) -> bool:
	return slots.any(func(s): return s != by_other_than and s.color.to_html(false) == color.to_html(false))


func _free_color(slot: CFSlot) -> Color:
	## The player's preferred animal if nobody else has it, otherwise the first free one.
	if slot.animal != "" and not _color_taken(CF.color_for_animal(slot.animal), slot):
		return CF.color_for_animal(slot.animal)
	for c in CF.PLAYER_COLORS:
		if not _color_taken(Color(c), slot):
			return Color(c)
	return Color(CF.PLAYER_COLORS[0])


static func shown(s: CFSlot, part: String) -> String:
	## Paid items are only shown once the server has checked the purchase.
	var item := s.hat if part == "hat" else s.face
	return item if CF.is_free(part, item) or s.owned.has(CF.product_id(part, item)) else "none"


func look_changed(slot: CFSlot) -> void:
	## Hats and faces change straight away. The animal only changes in the lobby, and only to a free one.
	if state == "lobby" and slot.animal != "" and not _color_taken(CF.color_for_animal(slot.animal), slot):
		slot.color = CF.color_for_animal(slot.animal)
	broadcast_room()


func reconnect(slot: CFSlot, peer: int) -> void:
	slot.peer = peer
	slot.connected = true
	slot.last_seen = Time.get_ticks_msec()
	if match_state:
		var p := match_state.find_player(slot.id)
		if p:
			p.connected = true
	join(slot)


func remove(slot: CFSlot) -> void:
	## Leaving for good (or the grace period ran out).
	slots.erase(slot)
	slot.room_code = ""
	if match_state:
		CFSim.remove_player(match_state, slot.id)
	if host_id == slot.id:
		host_id = ""
		for s in slots:
			if s.connected:
				host_id = s.id
				break
	if connected_count() == 0 and empty_since == 0:
		empty_since = Time.get_ticks_msec()
	broadcast_room()


func set_options(slot: CFSlot, new_mode: String, map: String) -> void:
	if slot.id == host_id and state == "lobby":
		mode = new_mode if CF.MODES.has(new_mode) else mode
		map_choice = map if (CFMaps.is_valid(map) or map == "random") else map_choice
		broadcast_room()


func request_start(slot: CFSlot) -> void:
	if slot.id == host_id and state == "lobby":
		start_match()


func request_lobby() -> void:
	if state == "playing" and match_state and (match_state.phase == "won" or match_state.phase == "lost"):
		to_lobby()


func queue_inputs(slot: CFSlot, frames: Array) -> void:
	## Inputs arrive unreliably and with redundancy: keep each sequence number once, in order.
	for raw in frames:
		var f := CFInput.from_wire(raw)
		if f == null or f.seq <= slot.ack:
			continue
		var dup := false
		for q in slot.inputs:
			if q.seq == f.seq:
				dup = true
				break
		if not dup:
			slot.inputs.append(f)
	slot.inputs.sort_custom(func(a, b): return a.seq < b.seq)
	# A client far behind (lag spike) skips old frames rather than building delay; presses are kept.
	while slot.inputs.size() > CF.MAX_QUEUED_INPUTS:
		var dropped: CFInput = slot.inputs.pop_front()
		slot.ack = dropped.seq
		var n: CFInput = slot.inputs[0]
		n.jump = n.jump or dropped.jump
		n.act = n.act or dropped.act
		n.ability = n.ability or dropped.ability


func start_match() -> void:
	var active := slots.filter(func(s): return s.connected)
	var seed_value := randi()
	match_state = CFSim.create_match(seed_value, mode == "bot", active.size(), CFMaps.pick(map_choice))
	match_state.mode = mode
	for s in active:
		CFSim.add_player(match_state, s.id, s.name, s.color)
		s.inputs.clear()
		s.ack = 0
		s.last_input = CFInput.new()
	if mode == "traitors":
		# Roles come from the server's own randomness, never from the seed clients are sent.
		var role_rng := RandomNumberGenerator.new()
		role_rng.randomize()
		CFSim.assign_roles(match_state, role_rng)
	state = "playing"
	tick = 0
	print("room %s: match started on %s with %d players (seed %d)" % [code, match_state.map_id, active.size(), seed_value])
	broadcast_room()
	for s in active:
		send_start(s)


func send_start(slot: CFSlot) -> void:
	if slot.peer == 0:
		return
	var items: Array = []
	for it in match_state.items:
		items.append(CFWire.encode_item(it))
	var snap := CFWire.encode_snapshot(match_state, tick, _acks(), true)
	snap["me"] = CFWire.encode_private(match_state, slot.id, _acks().get(slot.id, 0))
	var d := {"seed": match_state.match_seed, "sabotage": match_state.director["enabled"], "players": match_state.players.size(), "map": match_state.map_id,
		"mode": match_state.mode, "items": items, "snap": snap}
	net.s_start.rpc_id(slot.peer, d)


func _acks() -> Dictionary:
	var a := {}
	for s in slots:
		a[s.id] = s.ack
	return a


## One server tick (called at 60 Hz while playing).
func step() -> void:
	if state != "playing" or match_state == null:
		return
	if match_state.phase == "won" or match_state.phase == "lost":
		return
	tick += 1
	var inputs := {}
	for s in slots:
		if s.inputs.size() > 0:
			var nxt: CFInput = s.inputs.pop_front()
			s.ack = nxt.seq
			s.last_input = nxt
			inputs[s.id] = nxt
		else:
			# No fresh input: keep holding the last direction, but never repeat a press.
			inputs[s.id] = s.last_input.duplicate_held()
	CFSim.step_match(match_state, inputs, CF.DT)
	if match_state.events.size() > 0:
		for s in slots:
			if s.peer == 0:
				continue
			var mine := match_state.events.filter(func(e): return not e.has("to") or e["to"] == s.id)
			if mine.size() > 0:
				net.s_events.rpc_id(s.peer, mine)
		match_state.events.clear()
	if match_state.dirty_items.size() > 0:
		var l := CFWire.encode_items(match_state, match_state.dirty_items.keys())
		match_state.dirty_items.clear()
		_broadcast(net.s_items, l)
	var ended := match_state.phase == "won" or match_state.phase == "lost"
	if tick % CF.SNAPSHOT_EVERY == 0 or ended:
		# One shared snapshot, plus each player's private part (their role; Guile and allies for traitors).
		var acks := _acks()
		var snap := CFWire.encode_snapshot(match_state, tick, acks, true)
		# Unreliable snapshots are compressed once and shared; the final one goes reliably and uncompressed.
		var packed := PackedByteArray() if ended else CFWire.pack_snapshot(snap)
		for s in slots:
			if s.peer == 0:
				continue
			var mine := CFWire.encode_private(match_state, s.id, acks.get(s.id, 0))
			if ended:
				var full := snap.duplicate()
				full["me"] = mine
				net.s_snap_reliable.rpc_id(s.peer, full)
			else:
				net.s_snap.rpc_id(s.peer, packed, mine)
	if ended:
		print("room %s: match ended (%s) at %.1fs" % [code, match_state.phase, match_state.t])


func sabotage_request(slot: CFSlot, what: String) -> void:
	if state != "playing" or match_state == null:
		return
	var err := CFSim.traitor_sabotage(match_state, slot.id, what)
	if err != "":
		match_state.emit("toast", {"to": slot.id, "msg": err, "tone": "vio"})


func vote_request(slot: CFSlot, target: String) -> void:
	if state == "playing" and match_state:
		CFSim.cast_vote(match_state, slot.id, target)


func to_lobby() -> void:
	state = "lobby"
	match_state = null
	var now := Time.get_ticks_msec()
	slots = slots.filter(func(s): return s.connected or now - s.last_seen < CF.RECONNECT_GRACE * 1000)
	broadcast_room()


## Called once a second by the server.
func housekeeping() -> Array:
	var now := Time.get_ticks_msec()
	var expired: Array = []
	for s in slots.duplicate():
		if not s.connected and now - s.last_seen > CF.RECONNECT_GRACE * 1000:
			print("room %s: %s timed out" % [code, s.name])
			remove(s)
			expired.append(s)
	return expired


func roster() -> Array:
	var r: Array = []
	for s in slots:
		r.append({"id": s.id, "name": s.name, "color": s.color.to_html(false), "connected": s.connected, "host": s.id == host_id,
			"hat": shown(s, "hat"), "face": shown(s, "face")})
	return r


func broadcast_room() -> void:
	_broadcast(net.s_room, {"code": code, "private": is_private, "state": state, "roster": roster(), "mode": mode, "map": map_choice})


func _broadcast(fn: Callable, arg: Variant) -> void:
	for s in slots:
		if s.peer != 0:
			fn.rpc_id(s.peer, arg)
