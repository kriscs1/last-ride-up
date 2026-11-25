class_name CFSim
## Last Ride Up shared rules. Pure: no nodes, no network, no wall clock, no global randomness.
## The server runs step_match(); clients run step_movement() on their own player to predict.

const T := CF.T


static func create_match(seed_value: int, sabotage: bool, expected_players: int, map_id := "verdant") -> CFMatch:
	var m := CFMatch.new()
	m.match_seed = seed_value
	m.world_rng.seed = seed_value ^ 0xbeef
	CFLevel.build(m, seed_value, map_id)
	var available := m.total + CFVeins.first_yield_total(m) * CF.VEIN_ROUNDS
	m.target = int(round(available * CF.target_share(maxi(1, expected_players)) / 10.0)) * 10
	CFVeins.setup_bounties(m)
	m.director["enabled"] = sabotage
	m.director_rng.seed = seed_value ^ 0x5eed
	return m


static func add_player(m: CFMatch, pid: String, pname: String, color: Color) -> CFPlayer:
	var i := m.players.size()
	var sp: Vector2 = m.spots["spawn"]
	var p := CFPlayer.new()
	p.id = pid
	p.name = pname
	p.color = color
	p.x = sp.x - 40 + (i % 5) * 22
	p.y = sp.y - p.h
	m.players.append(p)
	return p


static func remove_player(m: CFMatch, pid: String) -> void:
	## Leaving for good drops what you carry where you stand.
	var p := m.find_player(pid)
	if p == null:
		return
	_release_coop(m, p)
	if p.carried > 0:
		_drop_loot(m, p.carried, Vector2(p.x + p.w / 2, p.y + p.h))
	m.players.erase(p)
	m.meeting["votes"].erase(pid)
	m.emit("left", {"id": pid, "name": p.name})
	_check_traitors_gone(m)


# ---------------------------------------------------------------- match step (server)

static func step_match(m: CFMatch, inputs: Dictionary, dt: float) -> void:
	if m.phase == "won" or m.phase == "lost":
		return
	if m.meeting["active"]:
		# The world stands still during a meeting: no clock, no movement, no sabotage.
		_step_meeting(m, dt)
		return
	m.t += dt
	m.time_left = maxf(0.0, m.time_left - dt)
	for mv in m.movers:
		mv.step(dt)
	_step_mech(m)
	CFVeins.step(m)
	for p in m.players:
		if not p.connected or p.out_of_play():
			continue   # disconnected players freeze in place
		var inp: CFInput = inputs.get(p.id, CFInput.new())
		_step_player(m, p, inp, dt)
	_step_coop_items(m)
	_step_repairs(m, inputs, dt)
	_step_director(m, dt)
	for p in m.players:
		if p.role == "traitor" and not p.exiled:
			p.guile = minf(CF.GUILE_MAX, p.guile + CF.GUILE_REGEN * dt)
	_step_escape(m)
	if m.time_left <= 0.0:
		_end(m, "lost", "The skyship was charged, but too few got aboard in time." if m.phase == "escape" else "Time ran out before the skyship was charged. The expedition is stranded.")


static func _end(m: CFMatch, result: String, reason: String) -> void:
	if m.phase == "won" or m.phase == "lost":
		return
	m.phase = result
	m.end_reason = reason
	m.winner = "explorers" if result == "won" else "traitors"
	m.stats["sabotages"] += m.taints   # secret taints are revealed with everything else
	m.taints = 0
	m.emit("win" if result == "won" else "lose")


static func _step_escape(m: CFMatch) -> void:
	if m.phase == "running" and m.deposited >= m.target:
		m.phase = "escape"
		m.depart_at = m.t + CF.DEPART_WINDOW
		m.emit("escape", {"depart_at": m.depart_at})
	elif m.phase == "escape" and m.deposited < m.target:
		m.phase = "running"
		for p in m.players:
			p.aboard = false
		m.emit("toast", {"msg": "The charge dropped below full. The skyship settles back down!", "tone": "bad"})
	if m.phase != "escape":
		return
	# Only explorers count towards "enough aboard": a traitor boarding (or refusing to) proves nothing.
	var active := m.players.filter(func(q): return q.connected and not q.exiled)
	var crew := active.filter(func(q): return q.role != "traitor")
	var aboard := crew.filter(func(q): return q.aboard).size()
	var need := maxi(1, ceili(crew.size() * CF.BOARD_SHARE))
	var everyone_aboard := active.size() > 0 and active.all(func(q): return q.aboard)
	if everyone_aboard or m.t >= m.depart_at:
		if aboard >= need:
			_end(m, "won", "Everyone got aboard. The expedition flew home." if aboard == crew.size() else "The skyship left with %d of %d explorers aboard. Enough made it home." % [aboard, crew.size()])
		else:
			_end(m, "lost", "The skyship left with only %d of %d explorers aboard. The expedition is stranded." % [aboard, crew.size()])


static func _step_mech(m: CFMatch) -> void:
	var sp: Dictionary = m.mech["spikes"]
	if sp["state"] == "warn" and m.t >= sp["until"]:
		sp["state"] = "active"
		sp["until"] = m.t + CF.SAB["spikes"]["dur"]
		m.emit("spikes_up")
	elif sp["state"] == "active" and m.t >= sp["until"]:
		sp["state"] = "idle"
		sp["available_at"] = m.t + CF.SAB["spikes"]["cd"]
	var br: Dictionary = m.mech["bridge"]
	if br["state"] == "warn" and m.t >= br["warn_until"]:
		br["state"] = "down"
		br["down_at"] = m.t
		br["repair"] = 0.0
		m.emit("bridge_down")
	var bx: Dictionary = m.mech["breach"]
	if bx["active"]:
		if bx["sw"].all(func(v): return v):
			bx["active"] = false
			bx["available_at"] = m.t + CF.SAB["breach"]["cd"]
			m.stats["breaches_stopped"] += 1
			m.stats["repairs"] += 1
			m.emit("breach_fixed")
		elif m.t >= bx["ends_at"]:
			var loss := int(round(m.deposited * CF.SAB["breach"]["loss"]))
			m.deposited -= loss
			m.stats["lost_breach"] += loss
			bx["active"] = false
			bx["available_at"] = m.t + CF.SAB["breach"]["cd"]
			m.emit("breach_fail", {"loss": loss})


static func _step_repairs(m: CFMatch, inputs: Dictionary, dt: float) -> void:
	## Repairs are shared: every player holding interact at the same mechanism adds progress.
	var bridge_holders: Array = []
	var lift_holders: Array = []
	for p in m.players:
		if not p.connected or p.busy() or p.out_of_play():
			continue
		var inp: CFInput = inputs.get(p.id)
		if inp == null or not inp.act_held:
			continue
		var a := find_interaction(m, p)
		if a.is_empty() or not a.get("hold", false):
			continue
		if a["kind"] == "repair_bridge":
			bridge_holders.append(p)
		else:
			lift_holders.append(p)
	var br: Dictionary = m.mech["bridge"]
	if br["state"] == "down":
		br["repair"] = br["repair"] + dt * bridge_holders.size() if bridge_holders.size() > 0 else maxf(0.0, br["repair"] - dt)
		if br["repair"] >= CF.SAB["bridge"]["repair"]:
			br["state"] = "ok"
			br["repair"] = 0.0
			br["available_at"] = m.t + CF.SAB["bridge"]["cd"]
			m.stats["repairs"] += 1
			for p in bridge_holders:
				p.stats["repairs"] += 1
			CFVeins.bounty_event(m, "repair", {})
			m.emit("repaired", {"what": "The bridge is back up.", "by": bridge_holders.map(func(q): return q.name)})
	var lift: CFMover = m.find_mover("lift")
	var lr: Dictionary = m.mech["lift"]
	if lift.jammed:
		lr["repair"] = lr["repair"] + dt * lift_holders.size() if lift_holders.size() > 0 else maxf(0.0, lr["repair"] - dt)
		if lr["repair"] >= CF.SAB["lift"]["repair"]:
			lift.jammed = false
			lr["repair"] = 0.0
			lr["available_at"] = m.t + CF.SAB["lift"]["cd"]
			m.stats["repairs"] += 1
			for p in lift_holders:
				p.stats["repairs"] += 1
			CFVeins.bounty_event(m, "repair", {})
			m.emit("repaired", {"what": "The lift is running again.", "by": lift_holders.map(func(q): return q.name)})


# ---------------------------------------------------------------- movement (server and client prediction)

static func _standing_on_plank(m: CFMatch, p: CFPlayer) -> bool:
	var ty := int(floor((p.y + p.h + 1) / T))
	var plank := false
	for tx in range(int(floor(p.x / T)), int(floor((p.x + p.w - 0.01) / T)) + 1):
		var c := m.tile_at(tx, ty)
		if m.is_solid(c):
			return false
		if c == CF.Tile.PLANK:
			plank = true
	return plank


static func _collide(m: CFMatch, p: CFPlayer, dt: float) -> void:
	p.x += p.vx * dt
	var y0 := int(floor(p.y / T))
	var y1 := int(floor((p.y + p.h - 0.01) / T))
	if p.vx > 0:
		var tx := int(floor((p.x + p.w - 0.01) / T))
		for ty in range(y0, y1 + 1):
			if m.is_solid(m.tile_at(tx, ty)):
				p.x = tx * T - p.w
				p.vx = 0.0
				p.dash_t = 0.0
				break
	elif p.vx < 0:
		var tx := int(floor(p.x / T))
		for ty in range(y0, y1 + 1):
			if m.is_solid(m.tile_at(tx, ty)):
				p.x = (tx + 1) * T
				p.vx = 0.0
				p.dash_t = 0.0
				break
	var prev_bottom := p.y + p.h
	p.y += p.vy * dt
	p.on_ground = false
	p.ride_id = ""
	var x0 := int(floor(p.x / T))
	var x1 := int(floor((p.x + p.w - 0.01) / T))
	if p.vy >= 0:
		var ta := maxi(0, int(floor((prev_bottom - 0.01) / T)))
		var tb := int(floor((p.y + p.h - 0.01) / T))
		var landed := false
		for ty in range(ta, tb + 1):
			for tx in range(x0, x1 + 1):
				var c := m.tile_at(tx, ty)
				var one_way := c == CF.Tile.PLANK or (not p.climbing and m.is_ladder_top(tx, ty))
				if m.is_solid(c) or (one_way and p.drop_t <= 0.0 and prev_bottom <= ty * T + 0.5):
					p.y = ty * T - p.h
					p.vy = 0.0
					p.on_ground = true
					landed = true
					break
			if landed:
				break
		for mv in m.movers:
			if p.x + p.w > mv.x + 3 and p.x < mv.x + mv.w - 3 and prev_bottom <= mv.y + 3 and p.y + p.h >= mv.y:
				p.y = mv.y - p.h
				p.vy = 0.0
				p.on_ground = true
				p.ride_id = mv.id
	else:
		var ty := int(floor(p.y / T))
		for tx in range(x0, x1 + 1):
			if m.is_solid(m.tile_at(tx, ty)):
				p.y = (ty + 1) * T
				p.vy = 0.0
				break


static func _ladder_column(m: CFMatch, p: CFPlayer) -> int:
	## The ladder column the player's body overlaps, or -1.
	var tx := int(floor((p.x + p.w / 2) / T))
	if m.is_ladder(tx, int(floor((p.y + p.h - 2) / T))) or m.is_ladder(tx, int(floor((p.y + p.h / 2) / T))):
		return tx
	return -1


static func touching_hazard(m: CFMatch, p: CFPlayer) -> bool:
	var ax := p.x + 3
	var ay := p.y + 3
	var bx := p.x + p.w - 3
	var by := p.y + p.h
	var spikes_up: bool = m.mech["spikes"]["state"] == "active"
	for ty in range(int(floor(ay / T)), int(floor(by / T)) + 1):
		for tx in range(int(floor(ax / T)), int(floor(bx / T)) + 1):
			var c := m.tile_at(tx, ty)
			if c == CF.Tile.SPIKE or (c == CF.Tile.TRAP and spikes_up):
				if bx > tx * T + 4 and ax < tx * T + 28 and by > ty * T + 14 and ay < ty * T + 32:
					return true
	return p.y > CF.GH * T


## Physics only: run, jump, climb, dash, collide, and what happens when you touch spikes.
## Deterministic, so clients run it to predict their own player. Returns true when the player got hurt
## this step (the server then drops some of their Sunstone). fx gets (type, data) for local effects.
static func step_movement(m: CFMatch, p: CFPlayer, inp: CFInput, dt: float, fx: Callable = Callable()) -> bool:
	if p.out_of_play():
		return false
	p.invuln_t = maxf(0.0, p.invuln_t - dt)
	# Being lifted out of a pit: a visible glide back to the last safe ledge, never a teleport.
	if p.recover_t > 0.0:
		p.recover_t = maxf(0.0, p.recover_t - dt)
		var k := 1.0 - p.recover_t / CF.RECOVER_TIME
		var e := k * k * (3.0 - 2.0 * k)
		var pos := p.rec_from.lerp(p.rec_to, e) - Vector2(0, sin(k * PI) * CF.RECOVER_ARC)
		p.x = pos.x
		p.y = pos.y
		p.vx = 0.0
		p.vy = 0.0
		if p.recover_t <= 0.0:
			p.x = p.rec_to.x
			p.y = p.rec_to.y
		return false
	var W: Array = CF.weight_of(float(p.carried) / p.capacity)
	var coop_speed := CF.COOP_SPEED if p.coop_item >= 0 else 1.0
	var coop_jump := CF.COOP_JUMP if p.coop_item >= 0 else 1.0
	var stunned := p.stun_t > 0.0
	p.stun_t = maxf(0.0, p.stun_t - dt)
	var move_x := 0.0 if stunned else inp.move_x
	p.ability_cd = maxf(0.0, p.ability_cd - dt)
	if inp.ability and not stunned and p.ability_cd <= 0.0 and p.coop_item < 0 and not p.climbing:
		p.dash_t = CF.DASH_TIME
		p.ability_cd = CF.DASH_COOLDOWN
		p.vx = p.facing * CF.DASH_SPEED * W[3]
		p.vy = minf(p.vy, 0.0) * 0.3
		if fx.is_valid():
			fx.call("dash", {"id": p.id, "x": p.x, "y": p.y})
	p.jump_buf = CF.JUMP_BUFFER if (inp.jump and not stunned) else p.jump_buf - dt
	p.coyote = CF.COYOTE if (p.on_ground or p.climbing) else p.coyote - dt
	p.drop_t -= dt

	# Ladders: press up (or down from the top) to grab; jump or walk off to let go.
	var lad := _ladder_column(m, p)
	var feet_tx := int(floor((p.x + p.w / 2) / T))
	var feet_ty := int(floor((p.y + p.h + 1) / T))
	if not p.climbing and not stunned and p.dash_t <= 0.0:
		if lad >= 0 and inp.up:
			p.climbing = true
		elif inp.down and p.on_ground and m.is_ladder_top(feet_tx, feet_ty):
			p.climbing = true
			lad = feet_tx
			p.y += 4.0
			p.on_ground = false
	if p.climbing and (lad < 0 and not m.is_ladder(feet_tx, feet_ty)):
		p.climbing = false
	if p.climbing:
		var col := lad if lad >= 0 else feet_tx
		p.x = move_toward(p.x, col * T + T / 2.0 - p.w / 2.0, 400.0 * dt)
		p.vx = move_x * CF.CLIMB_SIDE
		p.vy = ((1.0 if inp.down else 0.0) - (1.0 if inp.up else 0.0)) * CF.CLIMB_SPEED
		if absf(move_x) > 0.05:
			p.facing = 1 if move_x > 0 else -1
		if p.on_ground and not inp.up:
			p.climbing = false
	elif p.dash_t > 0.0:
		p.dash_t -= dt
		p.vy = 0.0
	else:
		var target: float = move_x * CF.SPEED * W[3] * coop_speed
		if absf(move_x) > 0.05:
			p.vx = move_toward(p.vx, target, (CF.ACCEL_GROUND if p.on_ground else CF.ACCEL_AIR) * W[2] * dt)
			p.facing = 1 if move_x > 0 else -1
		elif not stunned:
			p.vx = move_toward(p.vx, 0.0, (CF.DECEL_GROUND if p.on_ground else CF.ACCEL_AIR * 0.6) * dt)
		var g := CF.GRAVITY * (CF.LOW_JUMP_GRAV if (p.vy < 0 and not inp.jump_held and not stunned) else 1.0)
		p.vy = minf(p.vy + g * dt, CF.MAX_FALL)
	if p.jump_buf > 0.0 and p.coyote > 0.0 and not stunned:
		if inp.down and not p.climbing and _standing_on_plank(m, p):
			p.drop_t = 0.25
			p.jump_buf = 0.0
			p.y += 2
		else:
			if p.climbing and absf(move_x) > 0.05:
				p.vx = move_x * CF.SPEED * W[3] * coop_speed   # leap sideways off a ladder
			p.climbing = false
			p.vy = -CF.JUMP_V * W[4] * coop_jump
			p.jump_buf = 0.0
			p.coyote = 0.0
			p.on_ground = false
			p.ride_id = ""
			if fx.is_valid():
				fx.call("jump", {"id": p.id, "x": p.x + p.w / 2, "y": p.y + p.h})
	if p.ride_id != "" and p.on_ground:
		var mv := m.find_mover(p.ride_id)
		if mv:
			p.x += mv.dx
			p.y += mv.dy
	var was_ground := p.on_ground
	var vy_before := p.vy
	_collide(m, p, dt)
	if not was_ground and p.on_ground:
		p.land_t = 0.12
		if vy_before > 380 and fx.is_valid():
			fx.call("land", {"id": p.id, "x": p.x + p.w / 2, "y": p.y + p.h, "hard": vy_before > 750})
	p.land_t = maxf(0.0, p.land_t - dt)
	if p.on_ground:
		p.run_ph += absf(p.vx) * dt * 0.05
	if p.on_ground and p.ride_id == "" and p.stun_t <= 0.0:
		var tc := m.tile_at(int(floor((p.x + p.w / 2) / T)), int(floor((p.y + p.h + 1) / T)))
		if tc == CF.Tile.SOLID or tc == CF.Tile.PLANK or tc == CF.Tile.BRIDGE or m.is_ladder_top(int(floor((p.x + p.w / 2) / T)), int(floor((p.y + p.h + 1) / T))):
			p.last_safe = Vector2(p.x + p.w / 2, p.y + p.h)
	if p.invuln_t <= 0.0 and touching_hazard(m, p):
		_on_hit(m, p)
		if fx.is_valid():
			fx.call("hit", {"id": p.id, "x": p.x + p.w / 2, "y": p.y + p.h / 2, "recover": p.recover_t > 0.0})
		return true
	return false


static func _on_hit(m: CFMatch, p: CFPlayer) -> void:
	p.climbing = false
	p.dash_t = 0.0
	var safe: Vector2 = p.last_safe
	if safe == Vector2.INF or safe.distance_to(Vector2(p.x + p.w / 2, p.y + p.h)) > 25 * T:
		safe = m.cps[p.cp]["pos"]
	var fell_in := p.y > CF.GH * T or (p.y + p.h) - safe.y > 1.5 * T
	if fell_in:
		# lifted out of the pit and floated back to the last safe ledge
		p.rec_from = Vector2(p.x, p.y)
		p.rec_to = Vector2(safe.x - p.w / 2, safe.y - p.h)
		p.recover_t = CF.RECOVER_TIME
		p.invuln_t = CF.RECOVER_TIME + CF.INVULN_TIME
		p.vx = 0.0
		p.vy = 0.0
	else:
		# knocked back off the spikes, briefly stunned
		var dir := -signf(p.vx) if absf(p.vx) > 10.0 else -float(p.facing)
		p.vx = dir * CF.KNOCK_VX
		p.vy = -CF.KNOCK_VY
		p.stun_t = CF.STUN_TIME
		p.invuln_t = CF.INVULN_TIME
		p.on_ground = false


# ---------------------------------------------------------------- world interaction (server only)

static func _new_item(m: CFMatch, kind: String, x: float, y: float, value: int, fake := false) -> CFItem:
	var it := CFItem.new()
	it.id = m.next_item_id
	m.next_item_id += 1
	it.kind = kind; it.x = x; it.y = y; it.value = value; it.max_value = value; it.dropped = true; it.ph = float(it.id % 7); it.fake = fake
	m.items.append(it)
	m.dirty_items[it.id] = true
	return it


static func _drop_loot(m: CFMatch, amount: int, at: Vector2, fake := false, spilled_by := "") -> void:
	var n_before := m.items.size()
	var left := amount
	var k := 0
	while left > 0 and k < 12:
		var v := 15 if left > 30 else mini(5, left)
		_new_item(m, "bag" if v == 15 else "coin", at.x + (1 if k % 2 == 1 else -1) * (8 + 6 * k), at.y - 18, v, fake)
		left -= v
		k += 1
	if left > 0:
		_new_item(m, "bag", at.x, at.y - 18, left, fake)
	for i in range(n_before, m.items.size()):
		m.items[i].spilled_by = spilled_by


static func find_interaction(m: CFMatch, p: CFPlayer) -> Dictionary:
	if p.busy() or p.out_of_play() or m.meeting["active"]:
		return {}
	var c := p.centre()
	if p.coop_item >= 0:
		return {"kind": "drop_idol", "label": "Let go"}
	var near := func(o: Vector2, rx: float, ry: float) -> bool: return absf(c.x - o.x) < rx and absf(c.y - (o.y - 20)) < ry
	if m.mech["breach"]["active"]:
		for i in 3:
			if not m.mech["breach"]["sw"][i] and near.call(m.spots["valves"][i], 34.0, 48.0):
				return {"kind": "valve", "i": i, "label": "Valve"}
	if m.mech["bridge"]["state"] == "down" and near.call(m.spots["lever"], 40.0, 48.0):
		return {"kind": "repair_bridge", "label": "Repair", "hold": true}
	if m.find_mover("lift").jammed and near.call(m.spots["gear"], 40.0, 48.0):
		return {"kind": "repair_lift", "label": "Repair", "hold": true}
	for i in 3:
		if not m.mech["doors"][i] and near.call(m.spots["levers"][i], 34.0, 48.0):
			return {"kind": "lever", "i": i, "label": "Open"}
	if near.call(m.spots["vault"], 64.0, 48.0):
		return {"kind": "load", "label": "Load", "ok": p.carried > 0}
	if m.mode == "traitors" and near.call(m.spots["bell"], CF.BELL_RANGE, 48.0):
		return {"kind": "meeting", "label": "Ring bell", "ok": can_call_meeting(m, p)}
	var vein := CFVeins.vein_near(m, c)
	if not vein.is_empty():
		return {"kind": "strike", "vein": vein["id"], "label": "Strike"}
	for it in m.items:
		if not it.gone and not it.empty and (it.kind == "chest" or it.kind == "idol") and absf(c.x - it.x) < 40 and absf(c.y - it.y) < 40:
			if it.kind == "chest":
				return {"kind": "chest", "item": it.id, "label": "Open"}
			return {"kind": "idol", "item": it.id, "label": "Lift"}
	return {}


static func _lose_some(m: CFMatch, p: CFPlayer) -> void:
	## Getting hurt spills some Sunstone onto the last safe ground, where it can be picked up again.
	_release_coop(m, p)
	var lose := int(round(p.carried * CF.HAZARD_LOSS / 5.0)) * 5
	if lose == 0 and p.carried > 0:
		lose = mini(5, p.carried)
	lose = mini(lose, p.carried)
	var fake_lose := 0
	if p.carried > 0:
		fake_lose = int(round(float(lose) * p.fake_carried / p.carried))
	p.carried -= lose
	p.fake_carried -= fake_lose
	m.stats["lost_hazard"] += lose - fake_lose
	p.stats["falls"] += 1
	p.stats["lost"] += lose
	var at: Vector2 = p.last_safe if p.last_safe != Vector2.INF else m.cps[p.cp]["pos"]
	if lose > 0:
		_drop_loot(m, lose - fake_lose, at, false, p.id)
	if fake_lose > 0:
		_drop_loot(m, fake_lose, at + Vector2(12, 0), true, p.id)
	m.emit("hurt", {"id": p.id, "x": p.x + p.w / 2, "y": p.y + p.h / 2, "lose": lose, "recover": p.recover_t > 0.0})


static func _take(m: CFMatch, p: CFPlayer, it: CFItem) -> int:
	var room := p.capacity - p.carried
	if room <= 0:
		if m.t > p.full_msg_t:
			m.emit("toast", {"to": p.id, "msg": "Your sack is full. Load it into the skyship at camp.", "tone": "bad"})
			p.full_msg_t = m.t + 2.5
		return 0
	var n := mini(room, it.value)
	it.value -= n
	p.carried += n
	if it.fake:
		p.fake_carried += n
	else:
		m.stats["collected"] += n
		p.stats["collected"] += n
	it.opened = true
	if it.value <= 0:
		if it.kind == "chest":
			it.empty = true
		else:
			it.gone = true
	m.dirty_items[it.id] = true
	m.emit("pickup", {"id": p.id, "x": it.x, "y": it.y, "amt": n, "kind": it.kind})
	return n


static func _release_coop(m: CFMatch, p: CFPlayer) -> void:
	if p.coop_item < 0:
		return
	var item_id := p.coop_item
	var it := m.find_item(item_id)
	var feet := p.y + p.h
	for q in m.players:
		if q.coop_item == item_id:
			feet = maxf(feet, q.y + q.h)
			q.coop_item = -1
	if it and not it.gone:
		it.y = feet - 16
		it.carriers = []
		m.dirty_items[it.id] = true
		m.emit("idol_drop", {"x": it.x, "y": it.y})


static func _step_coop_items(m: CFMatch) -> void:
	## The Heartstone follows its two carriers, drops if they split up, and loads itself at the skyship.
	for it in m.items:
		if it.kind != "idol" or it.gone:
			continue
		if it.waiting_id != "" and m.t > it.waiting_until:
			it.waiting_id = ""
			m.dirty_items[it.id] = true
		if it.carriers.size() < 2:
			continue
		var a := m.find_player(it.carriers[0])
		var b := m.find_player(it.carriers[1])
		if a == null or b == null or not a.connected or not b.connected or a.busy() or b.busy():
			var holder: CFPlayer = a if a and a.coop_item == it.id else b
			if holder:
				_release_coop(m, holder)
			else:
				it.carriers = []
			continue
		if absf(a.x - b.x) > CF.COOP_MAX_APART or absf(a.y - b.y) > CF.COOP_MAX_APART:
			_release_coop(m, a)
			m.emit("toast", {"msg": "The Heartstone slipped! Stay close together.", "tone": "bad"})
			continue
		it.x = (a.x + b.x) / 2 + a.w / 2
		it.y = minf(a.y, b.y) - 18
		var v: Vector2 = m.spots["vault"]
		if absf(it.x - v.x) < 80 and absf(it.y + 40 - v.y) < 90:
			it.gone = true
			m.dirty_items[it.id] = true
			a.coop_item = -1
			b.coop_item = -1
			it.carriers = []
			m.deposited += it.value
			m.stats["deposited"] += it.value
			m.stats["collected"] += it.value
			for q in [a, b]:
				q.stats["deposited"] += it.value / 2.0
				q.stats["collected"] += it.value / 2.0
			_add_recent(m, it.value, "%s + %s" % [a.name, b.name])
			m.emit("load", {"n": it.value, "by": "%s and %s" % [a.name, b.name], "coop": true})
			CFVeins.bounty_event(m, "heartstone", {})


static func _add_recent(m: CFMatch, n: int, by: String) -> void:
	m.recent.push_front({"n": n, "by": by})
	if m.recent.size() > 4:
		m.recent.resize(4)


static func _step_player(m: CFMatch, p: CFPlayer, inp: CFInput, dt: float) -> void:
	p.strike_cd = maxf(0.0, p.strike_cd - dt)
	var hit := step_movement(m, p, inp, dt, func(type: String, data: Dictionary): m.emit(type, data))
	if hit:
		_lose_some(m, p)
	if p.busy():
		return
	var c := p.centre()
	for i in m.cps.size():
		var cp: Dictionary = m.cps[i]
		if absf(c.x - cp["pos"].x) < 26 and absf(c.y - (cp["pos"].y - 30)) < 40:
			if not cp["on"]:
				cp["on"] = true
				m.emit("checkpoint", {"x": cp["pos"].x, "y": cp["pos"].y})
			if p.cp != i:
				p.cp = i
				m.emit("cp", {"to": p.id})
	for it in m.items:
		if it.gone or it.kind == "chest" or it.kind == "idol":
			continue
		var touching := absf(c.x - it.x) < 20 and absf(c.y - it.y) < 24
		if it.spilled_by == p.id:
			# just spilled by this player: they have to walk away from it before taking it back
			if not touching:
				it.spilled_by = ""
			continue
		if touching:
			_take(m, p, it)
	var a := find_interaction(m, p)
	if not a.is_empty() and inp.act:
		match a["kind"]:
			"valve":
				m.mech["breach"]["sw"][a["i"]] = true
				m.emit("valve", {"i": a["i"], "by": p.name})
			"lever":
				m.mech["doors"][a["i"]] = true
				m.emit("door_open", {"i": a["i"], "by": p.name, "id": p.id})
			"load":
				if p.carried > 0:
					var fake := p.fake_carried
					var n := p.carried - fake
					var sack := p.carried
					p.carried = 0
					p.fake_carried = 0
					m.deposited += n
					m.stats["deposited"] += n
					p.stats["deposited"] += n
					p.stats["trips"] += 1
					_add_recent(m, n, p.name)
					m.emit("load", {"n": n, "by": p.name, "id": p.id, "fools": fake})
					if fake > 0:
						m.emit("fools", {"n": fake, "by": p.name, "id": p.id})
					CFVeins.bounty_event(m, "load", {"n": sack - fake})
				else:
					m.emit("toast", {"to": p.id, "msg": "Your sack is empty. Go find Sunstone."})
			"strike":
				for v in m.veins:
					if v["id"] == a["vein"]:
						CFVeins.strike(m, p, v)
						break
			"chest":
				var it := m.find_item(a["item"])
				if it and it.value > 0:
					_take(m, p, it)
			"idol":
				_lift_idol(m, p, m.find_item(a["item"]))
			"drop_idol":
				_release_coop(m, p)
			"meeting":
				if a["ok"]:
					call_meeting(m, p)
				elif p.meetings_left <= 0:
					m.emit("toast", {"to": p.id, "msg": "You have already rung the bell this match."})
				else:
					m.emit("toast", {"to": p.id, "msg": "The bell needs a moment. Try again in %ds." % ceili(m.meeting["next_at"] - m.t)})
	if m.phase == "escape":
		var deck: Vector2 = m.spots["deck"]
		if absf(c.x - deck.x) < 52 and c.y > deck.y - 90 and c.y < deck.y + 4:
			p.aboard = true
			_release_coop(m, p)
			m.emit("aboard", {"id": p.id, "name": p.name})


static func _lift_idol(m: CFMatch, p: CFPlayer, it: CFItem) -> void:
	if it == null or it.carriers.size() >= 2:
		return
	if p.carried > 0:
		m.emit("toast", {"to": p.id, "msg": "Load your sack first: the Heartstone needs both hands."})
		return
	var partner: CFPlayer = m.find_player(it.waiting_id) if it.waiting_id != "" else null
	if partner and partner != p and m.t <= it.waiting_until and partner.carried == 0 and not partner.busy():
		it.carriers = [partner.id, p.id]
		it.waiting_id = ""
		partner.coop_item = it.id
		p.coop_item = it.id
		m.dirty_items[it.id] = true
		m.emit("idol_lift", {"by": "%s and %s" % [partner.name, p.name]})
	else:
		it.waiting_id = p.id
		it.waiting_until = m.t + CF.COOP_JOIN_WINDOW
		m.dirty_items[it.id] = true
		m.emit("toast", {"to": p.id, "msg": "The Heartstone needs two carriers. Someone else press Lift within 3 seconds!", "tone": "vio"})
		m.emit("idol_waiting", {"id": p.id, "name": p.name})


# ---------------------------------------------------------------- sabotage (shared by the test bot and real traitors)

static func sabotage_ready(m: CFMatch, what: String, guile: float) -> bool:
	## Can this sabotage happen now, for someone holding this much Guile? Clients use it to light up buttons.
	if not CF.SAB.has(what) or guile < CF.SAB[what]["cost"]:
		return false
	var M := m.mech
	match what:
		"spikes":
			return M["spikes"]["state"] == "idle" and m.t >= M["spikes"]["available_at"]
		"bridge":
			return M["bridge"]["state"] == "ok" and m.t >= M["bridge"]["available_at"]
		"lift":
			var lift := m.find_mover("lift")
			return lift != null and not lift.jammed and m.t >= M["lift"]["available_at"]
		"taint":
			return m.t >= M["taint"]["available_at"]
		"breach":
			var bx: Dictionary = M["breach"]
			return not bx["active"] and m.t >= CF.SAB["breach"]["min_t"] and m.t >= bx["available_at"] and m.deposited >= 60 and m.time_left > 50
	return false


static func _apply_sabotage(m: CFMatch, what: String, vein: Dictionary = {}) -> void:
	var M := m.mech
	if what == "taint":
		m.taints += 1   # secret: counted into stats only when the match ends
	else:
		m.stats["sabotages"] += 1
	match what:
		"spikes":
			M["spikes"]["state"] = "warn"
			M["spikes"]["until"] = m.t + CF.SAB["spikes"]["warn"]
			m.emit("sab", {"what": what, "msg": "Something clicks beneath the path east of camp…"})
		"bridge":
			M["bridge"]["state"] = "warn"
			M["bridge"]["warn_until"] = m.t + CF.SAB["bridge"]["warn"]
			m.emit("sab", {"what": what, "msg": "The rope bridge is groaning!"})
		"lift":
			m.find_mover("lift").jammed = true
			M["lift"]["repair"] = 0.0
			m.emit("sab", {"what": what, "msg": "The mine lift has jammed. Fix the gear at its base."})
		"taint":
			# secret: no announcement; only a faint violet sheen on the vein gives it away
			if vein.is_empty():
				CFVeins.taint_random(m, m.director_rng)
			else:
				vein["tainted"] = true
			M["taint"]["available_at"] = m.t + CF.SAB["taint"]["cd"]
		"breach":
			var bx: Dictionary = M["breach"]
			bx["active"] = true
			bx["ends_at"] = m.t + CF.SAB["breach"]["dur"]
			bx["sw"] = [false, false, false]
			m.emit("breach")


# ---------------------------------------------------------------- Sabotage Director (the test bot, lobby mode "bot")

static func _step_director(m: CFMatch, dt: float) -> void:
	var D := m.director
	if not D["enabled"]:
		return
	D["guile"] = minf(CF.GUILE_MAX, D["guile"] + CF.GUILE_REGEN * dt)
	if m.t < D["next_think"]:
		return
	D["next_think"] = m.t + CF.DIRECTOR_THINK
	if m.t < D["lock_until"] or m.director_rng.randf() > CF.DIRECTOR_CHANCE:
		return
	var opts: Array = []
	for w in [["spikes", 1.0], ["bridge", 1.0], ["lift", 0.8], ["taint", 1.2], ["breach", 3.0]]:
		if sabotage_ready(m, w[0], D["guile"]):
			opts.append(w)
	var bx: Dictionary = m.mech["breach"]
	var breach_soon: bool = not bx["active"] and m.t >= CF.SAB["breach"]["min_t"] - 15 and m.t >= bx["available_at"] - 15 and m.deposited >= 60 and m.time_left > 60
	if breach_soon and D["guile"] < CF.SAB["breach"]["cost"]:
		return   # traitors save up for the big play
	if opts.is_empty():
		return
	var total := 0.0
	for o in opts:
		total += o[1]
	var r := m.director_rng.randf() * total
	var pick: String = opts[0][0]
	for o in opts:
		r -= o[1]
		if r <= 0.0:
			pick = o[0]
			break
	D["guile"] -= CF.SAB[pick]["cost"]
	D["lock_until"] = m.t + CF.GUILE_LOCKOUT
	D["log"].push_front({"t": m.t, "what": pick})
	if D["log"].size() > 5:
		D["log"].resize(5)
	_apply_sabotage(m, pick)


# ---------------------------------------------------------------- hidden traitors (lobby mode "traitors")

static func assign_roles(m: CFMatch, rng: RandomNumberGenerator) -> void:
	## The server calls this with randomness the clients never see (never derived from the match seed,
	## which every client knows), so nobody can work out the roles.
	m.mode = "traitors"
	var order: Array = m.players.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp
	var n := CF.traitor_count(order.size())
	for i in order.size():
		var p: CFPlayer = order[i]
		p.role = "traitor" if i < n else "explorer"
		p.guile = CF.GUILE_START if i < n else 0.0


static func traitors(m: CFMatch, include_exiled := false) -> Array:
	return m.players.filter(func(q): return q.role == "traitor" and (include_exiled or not q.exiled))


static func traitor_sabotage(m: CFMatch, pid: String, what: String) -> String:
	## A traitor asks to sabotage. Returns "" on success, or why not (shown only to them).
	var p := m.find_player(pid)
	if p == null or p.role != "traitor" or p.exiled or p.aboard or not p.connected:
		return "Only a hidden traitor can do that."
	if m.phase != "running" and m.phase != "escape":
		return "Too late for that."
	if m.meeting["active"]:
		return "Not during a meeting."
	if m.t < p.sab_lock:
		return "Lie low for %ds first." % ceili(p.sab_lock - m.t)
	if not sabotage_ready(m, what, p.guile):
		return "Not ready yet." if CF.SAB.has(what) and p.guile >= CF.SAB[what]["cost"] else "Not enough Guile."
	var vein := {}
	if what == "taint":
		vein = CFVeins.vein_near(m, p.centre())
		if vein.is_empty() or vein["tainted"]:
			return "Stand at an untainted vein to taint it."
	p.guile -= CF.SAB[what]["cost"]
	p.sab_lock = m.t + CF.GUILE_LOCKOUT
	p.sab_count += 1
	_apply_sabotage(m, what, vein)
	if what == "taint":
		m.emit("toast", {"to": pid, "msg": "Vein tainted. Whoever cracks it gets fool's stone.", "tone": "vio"})
	return ""


static func _check_traitors_gone(m: CFMatch) -> void:
	if m.mode != "traitors" or m.phase == "won" or m.phase == "lost":
		return
	if traitors(m).is_empty():
		_end(m, "won", "Every traitor was found out. The expedition flies home in peace.")


# ---------------------------------------------------------------- meetings

static func can_call_meeting(m: CFMatch, p: CFPlayer) -> bool:
	if m.mode != "traitors" or m.phase != "running" or m.meeting["active"]:
		return false
	return p.meetings_left > 0 and not p.out_of_play() and m.t >= m.meeting["next_at"]


static func call_meeting(m: CFMatch, p: CFPlayer) -> bool:
	if not can_call_meeting(m, p):
		return false
	p.meetings_left -= 1
	m.meeting["active"] = true
	m.meeting["by"] = p.id
	m.meeting["left"] = CF.MEETING_TIME
	m.meeting["votes"] = {}
	m.emit("meeting", {"id": p.id, "by": p.name})
	return true


static func voters(m: CFMatch) -> Array:
	return m.players.filter(func(q): return q.connected and not q.exiled)


static func cast_vote(m: CFMatch, voter_id: String, target: String) -> bool:
	## target is a player id or "skip". One vote each, no changing it.
	if not m.meeting["active"] or m.meeting["votes"].has(voter_id):
		return false
	var v := m.find_player(voter_id)
	if v == null or not v.connected or v.exiled:
		return false
	if target != "skip":
		var t := m.find_player(target)
		if t == null or t.exiled:
			return false
	m.meeting["votes"][voter_id] = target
	m.emit("voted", {"id": voter_id})
	return true


static func _step_meeting(m: CFMatch, dt: float) -> void:
	m.meeting["left"] = maxf(0.0, m.meeting["left"] - dt)
	var votes: Dictionary = m.meeting["votes"]
	var all_in := voters(m).all(func(q): return votes.has(q.id))
	if all_in or m.meeting["left"] <= 0.0:
		_resolve_meeting(m)


static func _resolve_meeting(m: CFMatch) -> void:
	## The most votes wins, but only if it beats "skip" and isn't tied. Otherwise nobody is exiled.
	var votes: Dictionary = m.meeting["votes"]
	var tally := {}
	for voter in votes:
		var t: String = votes[voter]
		tally[t] = tally.get(t, 0) + 1
	var skip: int = tally.get("skip", 0)
	var top := ""
	var top_n := 0
	var tied := false
	for t in tally:
		if t == "skip":
			continue
		if tally[t] > top_n:
			top = t
			top_n = tally[t]
			tied = false
		elif tally[t] == top_n:
			tied = true
	var exiled: CFPlayer = null
	if top != "" and not tied and top_n > skip:
		exiled = m.find_player(top)
	m.meeting["active"] = false
	m.meeting["next_at"] = m.t + CF.MEETING_COOLDOWN
	var e := {"votes": votes.duplicate(), "exiled": "", "name": "", "role": "", "reason": ""}
	if exiled:
		_exile(m, exiled)
		e["exiled"] = exiled.id
		e["name"] = exiled.name
		e["role"] = exiled.role
	elif tied:
		e["reason"] = "tie"
	elif votes.is_empty():
		e["reason"] = "silence"
	else:
		e["reason"] = "skip"
	m.meeting["votes"] = {}
	m.emit("meeting_end", e)
	_check_traitors_gone(m)


static func _exile(m: CFMatch, p: CFPlayer) -> void:
	## Voted out: drops what they carry where they stand and leaves play. Their role is revealed.
	_release_coop(m, p)
	if p.carried > 0:
		var fake := p.fake_carried
		var feet := Vector2(p.x + p.w / 2, p.y + p.h)
		if p.carried - fake > 0:
			_drop_loot(m, p.carried - fake, feet)
		if fake > 0:
			_drop_loot(m, fake, feet + Vector2(12, 0), true)
	p.carried = 0
	p.fake_carried = 0
	p.exiled = true
	p.vx = 0.0
	p.vy = 0.0
