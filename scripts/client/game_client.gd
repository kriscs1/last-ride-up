class_name CFGameClient
extends Node
## Client controller.
## - Own player: predicted locally with CFSim.step_movement, reconciled against server snapshots.
## - Other players: drawn CF.INTERP_DELAY seconds in the past, interpolated between snapshots.
## - Everything that matters (pickups, loads, hazards, sabotage, timers, wins) comes from the server.

var view: CFWorldView
var ui: CFUI

var my_id := ""
var token := ""
var room := {}
var in_room := false
var pending_action := Callable()
var world: CFMatch = null
var me: CFPlayer = null
var me_draw := CFPlayer.new()
var remotes := {}            # id → {"p": CFPlayer, "buf": [[t, wire]]}
var pending: Array = []      # unacknowledged CFInput, oldest first
var recent_sent: Array = []  # last frames, resent for redundancy (inputs travel unreliably)
var seq := 0
var time_offset := 0.0
var has_offset := false
var rtt := 0
var guile := {}
var info := {}               # my private part of each snapshot: role, meetings left; Guile and allies if traitor
var had_bot := false
var end_shown := false
var render_offset := Vector2.ZERO
var _batch := 0
var _hud_t := 0.0
var _ping_t := 0.0
var _retry_t := -1.0
var _me_prev := Vector2.ZERO          # last physics-step position, for smooth drawing between steps
var _mover_prev := {}
var _area := ""


func _ready() -> void:
	_register_actions()
	view = CFWorldView.new()
	add_child(view)
	ui = CFUI.new()
	add_child(ui)
	ui.quick_requested.connect(func(): _act(Net.send_quick))
	ui.create_requested.connect(func(): _act(Net.send_create.bind(true)))
	ui.join_requested.connect(func(code): _act(Net.send_join.bind(code)))
	ui.start_requested.connect(func(): Net.send_start())
	ui.leave_requested.connect(_leave)
	ui.options_changed.connect(func(mode, map): Net.send_settings(mode, map))
	ui.sabotage_requested.connect(_sabotage)
	ui.vote_requested.connect(func(target): Net.send_vote(target))
	ui.lobby_requested.connect(_back_to_lobby)
	ui.map_requested.connect(_on_map_requested)
	ui.look_changed.connect(_send_look)
	Net.connected_to_server.connect(_on_connected)
	Net.connection_failed.connect(_on_connection_failed)
	Net.disconnected.connect(_on_disconnected)
	Net.welcomed.connect(_on_welcome)
	Net.room_changed.connect(_on_room)
	Net.match_started.connect(_on_match_started)
	Net.snapshot_received.connect(_on_snapshot)
	Net.items_changed.connect(_on_items)
	Net.events_received.connect(_on_events)
	Net.pong_received.connect(func(ms): rtt = ms if rtt == 0 else int(rtt * 0.7 + ms * 0.3))
	Net.error_received.connect(func(msg): ui.set_status(msg, true))


func _register_actions() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT], "move_down": [KEY_S, KEY_DOWN], "move_up": [KEY_W, KEY_UP],
		"jump": [KEY_SPACE, KEY_K], "interact": [KEY_E, KEY_F, KEY_ENTER], "ability": [KEY_SHIFT, KEY_J], "menu": [KEY_ESCAPE], "map": [KEY_M, KEY_TAB],
	}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for k in keys[action]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(action, e)
	var pads := {"jump": JOY_BUTTON_A, "interact": JOY_BUTTON_X, "ability": JOY_BUTTON_B, "menu": JOY_BUTTON_START, "map": JOY_BUTTON_BACK}
	for action in pads:
		var j := InputEventJoypadButton.new()
		j.button_index = pads[action]
		InputMap.action_add_event(action, j)
	for spec in [["move_left", JOY_AXIS_LEFT_X, -1.0], ["move_right", JOY_AXIS_LEFT_X, 1.0], ["move_up", JOY_AXIS_LEFT_Y, -1.0], ["move_down", JOY_AXIS_LEFT_Y, 1.0]]:
		var ax := InputEventJoypadMotion.new()
		ax.axis = spec[1]
		ax.axis_value = spec[2]
		InputMap.action_add_event(spec[0], ax)


func _unhandled_input(event: InputEvent) -> void:
	if ui.current_screen() == "meeting":
		return
	# Traitors: number keys 1-5 sabotage (the panel buttons do the same)
	if event is InputEventKey and event.pressed and not event.echo and world and info.get("role", "") == "traitor" and ui.current_screen() == "":
		var k: int = event.physical_keycode - KEY_1
		if k >= 0 and k < CFUI.SAB_ORDER.size():
			_sabotage(CFUI.SAB_ORDER[k])
			return
	if event.is_action_pressed("menu") and world and not end_shown:
		if ui.map.visible:
			ui.map.close()
		else:
			ui.show_screen("" if ui.current_screen() == "pause" else "pause")
	elif event.is_action_pressed("map") and world and not end_shown:
		toggle_map()


func _sabotage(what: String) -> void:
	if world and Net.is_online() and info.get("role", "") == "traitor":
		Net.send_sabotage(what)


func _on_map_requested() -> void:
	if world:
		toggle_map()


func toggle_map() -> void:
	if ui.map.visible:
		ui.map.close()
	else:
		ui.map.bounty_areas = world.bounties.map(func(b): return b["area"]).filter(func(a): return a != "")
		ui.map.open(world, me_draw if me else null)


# ---------------------------------------------------------------- connection

func _act(action: Callable) -> void:
	if Net.is_online() and my_id != "":
		action.call()
		return
	pending_action = action
	_connect()


func _connect() -> void:
	var addr := ui.server_address()
	ui.set_status("Connecting to %s:%d…" % [addr[0], addr[1]])
	Net.connect_to(addr[0], addr[1])


func _on_connected() -> void:
	Net.send_hello(ui.player_name(), token)


func _on_connection_failed() -> void:
	if in_room:
		_retry_t = 2.0
	else:
		pending_action = Callable()
		ui.set_status("Could not reach the server. Check the address and that the server is running.", true)


func _on_disconnected() -> void:
	my_id = ""
	if in_room:
		ui.toast("Connection lost. Reconnecting…", "bad")
		_retry_t = 1.5
	else:
		ui.set_status("Disconnected from the server.", true)


func _send_look() -> void:
	if Net.is_online() and my_id != "":
		Net.send_look(ui.settings["animal"], ui.settings["hat"], ui.settings["face"])


func _on_welcome(id: String, tok: String) -> void:
	my_id = id
	token = tok
	ui.set_status("")
	_send_look()   # before joining a room, so the preferred animal is free to be given
	if pending_action.is_valid():
		var a := pending_action
		pending_action = Callable()
		a.call()


func _leave() -> void:
	if Net.is_online():
		Net.send_leave()
	in_room = false
	room = {}
	_clear_world()
	ui.show_screen("menu")


func _back_to_lobby() -> void:
	end_shown = false
	_clear_world()
	Net.send_lobby()
	ui.show_screen("lobby")


func _clear_world() -> void:
	world = null
	me = null
	remotes.clear()
	view.m = null
	view.me = null
	end_shown = false
	info = {}


# ---------------------------------------------------------------- room and match

func _on_room(info: Dictionary) -> void:
	room = info
	in_room = true
	ui.update_lobby(info, my_id)
	if info["state"] == "lobby" and not end_shown:
		_clear_world()
		if ui.current_screen() == "look":
			ui._look_return = "lobby"   # stay in Customize; Done goes back to the lobby
		else:
			ui.show_screen("lobby")
	elif info["state"] == "playing" and world == null and ui.current_screen() == "menu":
		ui.show_screen("lobby")
	if world:
		for p in world.players:
			for r in info["roster"]:
				if r["id"] == p.id:
					p.name = r["name"]
					p.color = Color(r["color"])
					p.hat = r.get("hat", "none")
					p.face = r.get("face", "none")


func _roster_entry(pid: String) -> Dictionary:
	for r in room.get("roster", []):
		if r["id"] == pid:
			return r
	return {}


func _on_match_started(d: Dictionary) -> void:
	var m := CFSim.create_match(d["seed"], d["sabotage"], d["players"], d.get("map", "verdant"))
	m.items.clear()
	for w in d["items"]:
		CFWire.apply_item(m, w)
	m.players.clear()
	remotes.clear()
	me = null
	pending.clear()
	recent_sent.clear()
	world = m
	end_shown = false
	has_offset = false
	guile = {}
	info = {}
	had_bot = d["sabotage"]
	world.mode = d.get("mode", "bot" if had_bot else "none")
	var self_part: Array = d["snap"].get("me", {}).get("self", [])
	for w in d["snap"]["ps"]:
		_add_world_player(CFWire.with_self(w, self_part) if w[0] == my_id else w)
	_on_snapshot(d["snap"])
	if me:
		_copy_for_draw(me, me_draw)
	view.me = me_draw if me else null
	view.set_match(world)
	ui.clear_toasts()
	ui.show_screen("")
	ui.area_banner(world.map_name)
	ui.toast("Gather %d Sunstone to charge the skyship, then get aboard." % world.target if me else "Watching this match. You will join the next one.")
	if me and world.mode == "traitors":
		_reveal_role()
	if world.meeting["active"]:
		ui.open_meeting(world, my_id)


func _reveal_role() -> void:
	var n := CF.traitor_count(world.players.size())
	if info.get("role", "") == "traitor":
		var others: Array = info.get("allies", []).filter(func(id): return id != my_id).map(func(id): return _name_of(id))
		var allies := ("Your fellow traitor: %s. " % ", ".join(PackedStringArray(others))) if others.size() > 0 else ""
		ui.role_banner("You are a TRAITOR", allies + "Sabotage the expedition without getting caught. Keys 1-5 or the violet buttons.", true)
	else:
		ui.role_banner("You are an EXPLORER", "%d hidden traitor%s among you. Watch who wanders off. Ring the bell at camp to call a vote." % [n, "" if n == 1 else "s"], false)


func _add_world_player(w: Array) -> CFPlayer:
	var r := _roster_entry(w[0])
	var p := CFSim.add_player(world, w[0], r.get("name", "Explorer"), Color(r.get("color", "#2f8f86")))
	p.hat = r.get("hat", "none")
	p.face = r.get("face", "none")
	CFWire.apply_player(p, w)
	if p.id == my_id:
		me = p
		seq = w[19]
	else:
		remotes[p.id] = {"p": p, "buf": []}
	return p


func _on_snapshot(s: Dictionary) -> void:
	if world == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var off: float = s["st"] - now
	if not has_offset or absf(off - time_offset) > 0.5:
		time_offset = off
		has_offset = true
	else:
		time_offset += (off - time_offset) * 0.1
	world.t = s["st"]
	world.time_left = s["tl"]
	world.phase = s["ph"]
	world.depart_at = s["da"]
	world.end_reason = s["er"]
	world.deposited = s["v"][0]
	world.target = s["v"][1]
	world.recent = s["rec"]
	world.mech = s["mech"]
	world.stats = s["stats"]
	world.mode = s.get("mode", world.mode)
	world.winner = s.get("win", "")
	guile = s.get("dir", {})
	info = s.get("me", info)
	world.mech["taint"] = {"available_at": info.get("taint_at", 0.0)}   # only traitors are told the taint cooldown
	if s.has("mt"):
		CFWire.apply_meeting(world, s["mt"])
	CFWire.apply_veins(world, s.get("vn", []))
	world.bounties = s.get("bt", [])
	world.next_surge_at = s.get("ns", world.next_surge_at)
	# movers: take the server's, then fast-forward by half the round trip to line up with my prediction
	for i in world.movers.size():
		var mv: CFMover = world.movers[i]
		var w: Array = s["mv"][i]
		mv.x = w[0]; mv.y = w[1]; mv.dir = w[2]; mv.paused = w[3]; mv.jammed = w[4]
	for k in mini(15, roundi(rtt / 2000.0 / CF.DT)):
		for mv in world.movers:
			mv.step(CF.DT)
	# carried Heartstones
	var carried := {}
	for c in s["idol"]:
		carried[c[0]] = true
		var it := world.find_item(c[0])
		if it:
			it.x = c[1]; it.y = c[2]; it.carriers = c[3]
	for it in world.items:
		if it.kind == "idol" and not carried.has(it.id):
			it.carriers = []
	# players
	var seen := {}
	for sw in s["ps"]:
		var w: Array = CFWire.with_self(sw, info.get("self", [])) if sw[0] == my_id else sw
		seen[w[0]] = true
		if world.find_player(w[0]) == null:
			_add_world_player(w)
		if w[0] == my_id and me:
			_reconcile(w)
		elif remotes.has(w[0]):
			var r: Dictionary = remotes[w[0]]
			r["buf"].append([s["st"], w])
			if r["buf"].size() > 30:
				r["buf"].pop_front()
			var rp: CFPlayer = r["p"]
			if not (w[20] as Dictionary).is_empty():
				rp.stats = w[20]
			rp.connected = w[18]; rp.aboard = w[15]; rp.carried = w[6]; rp.coop_item = w[16]
	world.players = world.players.filter(func(p): return seen.has(p.id))
	if me:
		me.role = info.get("role", me.role)
		me.guile = info.get("guile", 0.0)
		me.sab_lock = info.get("lock", 0.0)
		me.meetings_left = info.get("meetings", me.meetings_left)
	for id in info.get("allies", []):
		var ally := world.find_player(id)
		if ally:
			ally.role = "traitor"
	if world.meeting["active"] and ui.current_screen() != "meeting" and not end_shown:
		ui.open_meeting(world, my_id)
	elif not world.meeting["active"] and ui.current_screen() == "meeting":
		ui.show_screen("")
	for id in remotes.keys():
		if not seen.has(id):
			remotes.erase(id)
	if (world.phase == "won" or world.phase == "lost") and not end_shown:
		end_shown = true
		get_tree().create_timer(0.9).timeout.connect(_show_end_if_world)


func _show_end_if_world() -> void:
	if world:
		ui.show_end(world, my_id, had_bot)


## Server state for me, then replay the inputs it has not applied yet. Small corrections are smoothed.
func _reconcile(w: Array) -> void:
	var before := Vector2(me.x, me.y)
	CFWire.apply_player(me, w)
	var ack: int = w[19]
	pending = pending.filter(func(f): return f.seq > ack)
	for f in pending:
		CFSim.step_movement(world, me, f, CF.DT)
	var err := before - Vector2(me.x, me.y)
	if err.length() > 120.0 or me.recover_t > 0.0:
		render_offset = Vector2.ZERO
	else:
		render_offset += err


func _on_items(list: Array) -> void:
	if world:
		for w in list:
			CFWire.apply_item(world, w)


# ---------------------------------------------------------------- per-tick prediction and input

func _physics_process(_delta: float) -> void:
	if _retry_t > 0.0:
		_retry_t -= CF.DT
		if _retry_t <= 0.0:
			_retry_t = -1.0
			_connect()
	if world == null:
		return
	if world.meeting["active"]:
		return   # the world stands still while everyone votes
	for mv in world.movers:
		_mover_prev[mv.id] = Vector2(mv.x, mv.y)
		mv.step(CF.DT)
	if world.phase == "running" or world.phase == "escape":
		world.time_left = maxf(0.0, world.time_left - CF.DT)
		world.t += CF.DT   # advance between snapshots so animations run smoothly
	if me == null or world.phase == "won" or world.phase == "lost":
		return
	_me_prev = Vector2(me.x, me.y)
	var f := _sample_input()
	pending.append(f)
	if pending.size() > 180:
		pending.pop_front()
	recent_sent.append(f.to_wire())
	if recent_sent.size() > CF.INPUT_REDUNDANCY + CF.INPUT_BATCH:
		recent_sent.pop_front()
	_batch += 1
	if _batch >= CF.INPUT_BATCH and Net.is_online():
		_batch = 0
		Net.send_inputs(recent_sent.duplicate())
	CFSim.step_movement(world, me, f, CF.DT, _local_fx)
	_ping_t += CF.DT
	if _ping_t > 2.0 and Net.is_online():
		_ping_t = 0.0
		Net.send_ping()


func _sample_input() -> CFInput:
	var f := CFInput.new()
	seq += 1
	f.seq = seq
	var t := ui.touch
	var playing := ui.current_screen() == ""
	if playing:
		var kx := Input.get_axis("move_left", "move_right")
		f.move_x = snappedf(kx if absf(kx) > 0.05 else t.move_x, 0.01)
		f.down = Input.is_action_pressed("move_down") or t.down
		f.up = Input.is_action_pressed("move_up") or t.up
		# W / Up climbs on a ladder and jumps everywhere else
		var near_ladder := me != null and (CFSim._ladder_column(world, me) >= 0 or me.climbing)
		f.jump = Input.is_action_just_pressed("jump") or t.jump_pressed or (Input.is_action_just_pressed("move_up") and not near_ladder)
		f.jump_held = Input.is_action_pressed("jump") or t.jump_held
		f.act = Input.is_action_just_pressed("interact") or t.act_pressed
		f.act_held = Input.is_action_pressed("interact") or t.act_held
		f.ability = Input.is_action_just_pressed("ability") or t.ability_pressed
	t.consume_presses()
	return f


func _local_fx(type: String, d: Dictionary) -> void:
	## My own jumps and landings show at once; no waiting for the server.
	match type:
		"jump": view.burst(Vector2(d["x"], d["y"]), 5, Color("#d9c39a"), true, 60.0, 0.3, 200.0)
		"hit":
			view.shake = 7.0
			view.burst(Vector2(d["x"], d["y"]), 14, Color("#bfe9ff") if d["recover"] else Color("#ff8a6a"), false, 180.0)
		"land":
			view.burst(Vector2(d["x"], d["y"]), 10 if d["hard"] else 5, Color("#d9c39a"), true, 90.0, 0.35)
			if d["hard"]:
				view.shake = 4.0


# ---------------------------------------------------------------- per-frame: interpolation, HUD

func _process(delta: float) -> void:
	if world == null:
		return
	_interpolate_remotes()
	render_offset *= pow(0.85, delta * 60.0)
	var frac := Engine.get_physics_interpolation_fraction()
	for mv in world.movers:
		var prev: Vector2 = _mover_prev.get(mv.id, Vector2(mv.x, mv.y))
		view.mover_draw[mv.id] = prev.lerp(Vector2(mv.x, mv.y), frac)
	if me:
		_copy_for_draw(me, me_draw)
		# draw between the last two physics steps so motion is smooth at any refresh rate
		var drawn := _me_prev.lerp(Vector2(me.x, me.y), frac) if _me_prev.distance_to(Vector2(me.x, me.y)) < 64.0 else Vector2(me.x, me.y)
		me_draw.x = drawn.x + render_offset.x
		me_draw.y = drawn.y + render_offset.y
		view.act = CFSim.find_interaction(world, me)
		var a: Dictionary = view.act
		view.hold_frac = 0.0
		if a.get("hold", false):
			view.hold_frac = world.mech["bridge"]["repair"] / CF.SAB["bridge"]["repair"] if a["kind"] == "repair_bridge" else world.mech["lift"]["repair"] / CF.SAB["lift"]["repair"]
	if me:
		var area := world.area_at(me.x, me.y)
		if area != _area and area != "":
			_area = area
			ui.area_banner(area)
	_hud_t += delta
	if _hud_t > 0.08:
		_hud_t = 0.0
		ui.update_hud(world, me, view.act if me else {}, rtt, guile, info)
		if ui.current_screen() == "meeting":
			ui.refresh_meeting(world, my_id)


func _interpolate_remotes() -> void:
	if not has_offset:
		return
	var rt := Time.get_ticks_msec() / 1000.0 + time_offset - CF.INTERP_DELAY
	for id in remotes:
		var r: Dictionary = remotes[id]
		var buf: Array = r["buf"]
		if buf.is_empty():
			continue
		var p: CFPlayer = r["p"]
		var a: Array = buf[0]
		var b: Array = buf[buf.size() - 1]
		for i in buf.size() - 1:
			if buf[i][0] <= rt and buf[i + 1][0] >= rt:
				a = buf[i]
				b = buf[i + 1]
				break
		var k := 1.0
		if b[0] > a[0]:
			k = clampf((rt - a[0]) / (b[0] - a[0]), 0.0, 1.0)
		var wa: Array = a[1]
		var wb: Array = b[1]
		var prev_x := p.x
		p.x = lerpf(wa[1], wb[1], k)
		p.y = lerpf(wa[2], wb[2], k)
		p.vx = wb[3]; p.vy = wb[4]; p.facing = wb[5]; p.recover_t = wb[7]; p.dash_t = wb[8]; p.on_ground = wb[9]
		p.climbing = wb[21]; p.stun_t = wb[22]; p.invuln_t = wb[23]
		if p.on_ground:
			p.run_ph += absf(p.x - prev_x) * 0.05


func _copy_for_draw(src: CFPlayer, dst: CFPlayer) -> void:
	dst.id = src.id; dst.name = src.name; dst.color = src.color; dst.connected = src.connected
	dst.hat = src.hat; dst.face = src.face
	dst.copy_motion_from(src)
	dst.carried = src.carried; dst.capacity = src.capacity; dst.aboard = src.aboard; dst.coop_item = src.coop_item
	dst.w = src.w; dst.h = src.h


# ---------------------------------------------------------------- events from the server

func _name_of(pid) -> String:
	var p: CFPlayer = world.find_player(str(pid)) if world else null
	return p.name if p else "Someone"


func _on_events(list: Array) -> void:
	if world == null:
		return
	var vault: Vector2 = world.spots["vault"]
	for e in list:
		var mine: bool = e.get("id", "") == my_id
		match e["type"]:
			"jump":
				if not mine:
					view.burst(Vector2(e["x"], e["y"]), 4, Color("#d9c39a"), true, 60.0, 0.3, 200.0)
			"pickup":
				view.burst(Vector2(e["x"], e["y"]), 6 if e["kind"] == "coin" else 14, Color("#ffb347"))
				if mine:
					view.float_text(Vector2(e["x"], e["y"] - 14), "+%d" % e["amt"], Color("#ffe08a"))
			"load":
				view.burst(vault + Vector2(0, -28), 30, Color("#ffb347"), true, 260.0, 0.9)
				view.float_text(vault + Vector2(0, -100), "+%d charge" % e["n"], Color("#a8f28f"))
				if not mine:
					ui.toast("%s loaded %d Sunstone%s" % [e["by"], e["n"], " (the Heartstone!)" if e.get("coop", false) else ""], "good")
			"hurt":
				if not mine:
					view.burst(Vector2(e["x"], e["y"]), 12, Color("#ff8a6a"), false, 160.0)
				if e["lose"] > 0:
					view.float_text(Vector2(e["x"], e["y"] - 20), "-%d" % e["lose"], Color("#ff9a8a"))
				if mine and e["lose"] > 0:
					ui.toast("Ouch! You spilled %d Sunstone on the last safe ground." % e["lose"], "bad")
			"door_open":
				view.shake = 3.0
				ui.toast("Shortcut opened!" if mine else "%s opened a shortcut." % e["by"], "good")
			"strike":
				view.burst(Vector2(e["x"], e["y"]), 8 if e["counts"] else 4, Color("#9fe8ff") if e["counts"] else Color("#d9c39a"), false, 150.0, 0.4)
				if mine:
					view.shake = maxf(view.shake, 2.0)
			"crack":
				view.shake = maxf(view.shake, 5.0 if e["great"] else 3.0)
				view.burst(Vector2(e["x"], e["y"]), 30 if e["great"] else 16, Color("#ffb347"), true, 260.0, 0.8)
				if e["great"] or e["surge"]:
					ui.toast("%s cracked a %s!" % ["You" if mine else e["by"], "surging vein" if e["surge"] else "great vein"], "good")
			"surge":
				ui.toast("Sunstone surge in the %s! Check the map." % e["area"], "good")
			"bounty_done":
				ui.toast("Bounty complete: %s (+%d charge)" % [e["text"], e["reward"]], "good")
			"fools":
				view.shake = 4.0
				ui.toast(("Fool's stone! %d of your Sunstone was worthless. Someone tainted a vein." if mine else "%s's load fizzled: fool's stone from a tainted vein.") % (e["n"] if mine else e["by"]), "vio")
			"cp":
				ui.toast("Checkpoint reached")
			"toast":
				ui.toast(e["msg"], e.get("tone", ""))
			"escape":
				ui.toast("Fully charged! The skyship is lifting off. Everyone get aboard!", "good")
			"aboard":
				ui.toast("You are aboard! Waiting for the others…" if mine else "%s is aboard" % e["name"], "good")
			"idol_waiting":
				if not mine:
					ui.toast("%s needs a second carrier at the Heartstone!" % e["name"], "vio")
			"idol_lift":
				ui.toast("%s lifted the Heartstone. Stay close together!" % e["by"], "vio")
			"sab":
				ui.toast(e["msg"], "vio")
				view.shake = 3.0
			"bridge_down":
				view.shake = 6.0
				ui.toast("The bridge collapsed! Repair it at the lever on its west end. More hands repair faster.", "bad")
			"repaired":
				var by: Array = e.get("by", [])
				ui.toast(e["what"] + (" Thanks, %s." % " and ".join(PackedStringArray(by)) if by.size() > 0 else ""), "good")
			"breach":
				ui.toast("Engine breach! Close all three valves around camp.", "bad")
			"valve":
				ui.toast("%s closed valve %d" % [e["by"], e["i"] + 1])
			"breach_fixed":
				ui.toast("Breach sealed. The charge is safe.", "good")
			"breach_fail":
				view.shake = 8.0
				ui.toast("The furnace vented %d Sunstone. Gather more!" % e["loss"], "bad")
			"left":
				ui.toast("%s left the expedition" % e["name"])
			"meeting":
				view.shake = 5.0
				world.meeting["active"] = true
				world.meeting["by"] = e["id"]
				world.meeting["left"] = CF.MEETING_TIME
				world.meeting["votes"] = {}
				ui.open_meeting(world, my_id)
			"voted":
				world.meeting["votes"][e["id"]] = "?"
			"meeting_end":
				world.meeting["active"] = false
				var out: CFPlayer = world.find_player(e["exiled"]) if e["exiled"] != "" else null
				if out:
					out.exiled = true
					out.role = e["role"]
				ui.meeting_result(world, e, my_id)
