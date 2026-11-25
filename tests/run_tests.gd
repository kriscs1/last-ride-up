extends SceneTree
## Rule tests for the shared simulation. Run headless:
##   godot --headless --path . --script res://tests/run_tests.gd
## Map reachability is proven separately by tools/check_map.py.

var _failures := 0
var _passes := 0


func _init() -> void:
	_test("every map loads, has its mechanisms and runs", _t_map_size)
	_test("same seed and inputs give the same state", _t_determinism)
	_test("target scales with player count", _t_target)
	_test("a pickup is gone for everyone", _t_pickup)
	_test("loading at the skyship adds to the shared charge", _t_load)
	_test("the Heartstone needs two carriers and loads at the skyship", _t_heartstone)
	_test("two players repair twice as fast", _t_repair)
	_test("escape: half aboard is enough at departure", _t_escape_win)
	_test("escape fails if fewer than half get aboard", _t_escape_lose)
	_test("disconnected players freeze; leavers drop their Sunstone", _t_disconnect)
	_test("client prediction matches the server for movement", _t_prediction)
	_test("input wire format round-trips and clamps", _t_input_wire)
	_test("spikes knock you back; no teleport", _t_spike_knockback)
	_test("falling into a pit glides you back to your last ledge", _t_pit_recovery)
	_test("ladders: climb down from the top and back up", _t_ladder)
	_test("a lever opens its shortcut door", _t_door)
	_test("a great vein only cracks when two strike together", _t_great_vein)
	_test("a small vein cracks and Sunstone bursts out", _t_small_vein)
	_test("a tainted vein yields worthless fool's stone", _t_taint)
	_test("a finished bounty adds its reward to the charge", _t_bounty)
	_test("a surge never heals a struck vein", _t_surge_no_heal)
	_test("traitors: the right number get the role", _t_roles)
	_test("traitors: shared snapshots never reveal a role", _t_role_secrecy)
	_test("traitors: sabotage spends Guile and respects the lockout", _t_traitor_sabotage)
	_test("meeting: exiling the last traitor wins for the explorers", _t_meeting_exile)
	_test("meeting: a tie exiles nobody", _t_meeting_tie)
	_test("traitors: only explorers count towards boarding", _t_escape_traitor)
	_test("the meeting bell stands on solid floor on every map", _t_bell_floor)
	_test("packed snapshots round-trip and reject garbage", _t_snapshot_pack)
	_test("a 10-player snapshot fits in one UDP packet on every map", _t_snapshot_size)
	_test("cosmetics: you get your animal if it is free, otherwise the next free one", _t_look_join)
	_test("cosmetics: switching animal only in the lobby and only to a free one", _t_look_switch)
	_test("shop: free and paid items, product ids and Steam item ids", _t_shop_catalogue)
	_test("shop: buying, saving and a refund through the store record", _t_shop_owned)
	print("\n%d passed, %d failed" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)


func _test(name: String, fn: Callable) -> void:
	var res: Variant = fn.call()
	# A test that hits a script error returns null instead of a String: that is a failure too.
	var err: String = res if res is String else "crashed (script error, see above)"
	if err == "":
		_passes += 1
		print("ok   - " + name)
	else:
		_failures += 1
		print("FAIL - %s: %s" % [name, err])


func _frame(seq := 0) -> CFInput:
	var f := CFInput.new()
	f.seq = seq
	return f


func _run(m: CFMatch, ticks: int, script := Callable()) -> void:
	for k in ticks:
		var inputs := {}
		for p in m.players:
			var f := _frame(k)
			if script.is_valid():
				script.call(p.id, k, f)
			inputs[p.id] = f
		CFSim.step_match(m, inputs, CF.DT)
		m.events.clear()


## Stand a player with their feet at (x, feet_y).
func _place(p: CFPlayer, x: float, feet_y: float) -> void:
	p.x = x - p.w / 2
	p.y = feet_y - p.h
	p.vx = 0.0
	p.vy = 0.0


func _tile_feet(tx: float, row: int) -> Vector2:
	## Centre of tile column tx, feet on top of the tile below row `row`.
	return Vector2(tx * CF.T + 16, (row + 1) * CF.T)


func _solo(seed_value := 1) -> Array:
	var m := CFSim.create_match(seed_value, false, 1)
	var p := CFSim.add_player(m, "a", "A", Color.WHITE)
	return [m, p]


# ---------------------------------------------------------------- tests (return "" on success)

func _t_map_size() -> String:
	for id in CFMaps.IDS:
		var d := CFMaps.data(id)
		var rows: PackedStringArray = str(d["map"]).split("\n")
		if rows.size() != CF.GH or rows[0].length() != CF.GW:
			return "%s is %dx%d, expected %dx%d" % [id, rows[0].length(), rows.size(), CF.GW, CF.GH]
		var m := CFSim.create_match(1, true, 4, id)
		if m.map_id != id or m.veins.size() < 9 or m.bounties.size() != CF.BOUNTY_SLOTS:
			return "%s: veins %d, bounties %d" % [id, m.veins.size(), m.bounties.size()]
		if m.door_tiles.size() < 3 or m.bridge_tiles.is_empty() or m.trap_tiles.is_empty() or m.spots["valves"].size() != 3:
			return "%s is missing a mechanism" % id
		# a short bot run on every map must not crash
		for pid in ["a", "b", "c", "d"]:
			CFSim.add_player(m, pid, pid, Color.WHITE)
		_run(m, 600, _wander)
	return ""


func _wander(pid: String, k: int, f: CFInput) -> void:
	f.move_x = sin(k / 40.0 + pid.unicode_at(0))
	f.jump = k % 37 == 0
	f.act = k % 23 == 0
	f.up = k % 150 < 60


func _t_determinism() -> String:
	var mk := func() -> CFMatch:
		var m := CFSim.create_match(99, true, 3)
		for id in ["a", "b", "c"]:
			CFSim.add_player(m, id, id, Color.WHITE)
		return m
	var A: CFMatch = mk.call()
	var B: CFMatch = mk.call()
	var drive := func(id: String, k: int, f: CFInput) -> void:
		f.move_x = sin(k / 30.0 + id.unicode_at(0))
		f.jump = k % 47 == 0
		f.jump_held = k % 47 < 20
		f.act = k % 90 == 0
		f.up = k % 200 < 40
	_run(A, 3600, drive)
	_run(B, 3600, drive)
	for i in 3:
		if A.players[i].x != B.players[i].x or A.players[i].y != B.players[i].y or A.players[i].carried != B.players[i].carried:
			return "player %d diverged" % i
	if A.deposited != B.deposited or A.stats["sabotages"] != B.stats["sabotages"]:
		return "match state diverged"
	return ""


func _t_target() -> String:
	var one := CFSim.create_match(5, false, 1)
	var six := CFSim.create_match(5, false, 6)
	if six.target <= one.target:
		return "6-player target %d not above solo %d" % [six.target, one.target]
	return ""


func _t_pickup() -> String:
	var m := CFSim.create_match(1, false, 2)
	var a := CFSim.add_player(m, "a", "A", Color.WHITE)
	CFSim.add_player(m, "b", "B", Color.WHITE)
	var coin: CFItem = null
	for it in m.items:
		if it.kind == "coin":
			coin = it
			break
	a.x = coin.x - a.w / 2
	a.y = coin.y - a.h / 2
	_run(m, 1)
	if not coin.gone or a.carried != 5 or not m.dirty_items.has(coin.id):
		return "coin not taken (carried %d)" % a.carried
	return ""


func _t_load() -> String:
	var s := _solo()
	var m: CFMatch = s[0]
	var a: CFPlayer = s[1]
	a.carried = 60
	_place(a, m.spots["vault"].x, m.spots["vault"].y)
	_run(m, 2)
	_run(m, 1, func(_id, _k, f): f.act = true)
	if m.deposited != 60 or a.carried != 0:
		return "deposited %d, carried %d" % [m.deposited, a.carried]
	return ""


func _t_heartstone() -> String:
	var m := CFSim.create_match(1, false, 2)
	var a := CFSim.add_player(m, "a", "A", Color.WHITE)
	var b := CFSim.add_player(m, "b", "B", Color.WHITE)
	var idol: CFItem = null
	for it in m.items:
		if it.kind == "idol":
			idol = it
	var feet := idol.y + 18
	_place(a, idol.x - 10, feet)
	_place(b, idol.x + 10, feet)
	_run(m, 2)
	_run(m, 1, func(id, _k, f): f.act = id == "a")
	if idol.waiting_id != "a" or a.coop_item != -1:
		return "first carrier should wait"
	_run(m, 1, func(id, _k, f): f.act = id == "b")
	if idol.carriers != ["a", "b"] or a.coop_item != idol.id:
		return "two carriers should lift"
	var v: Vector2 = m.spots["vault"]
	_place(a, v.x - 24, v.y)
	_place(b, v.x, v.y)
	_run(m, 2)
	if not idol.gone or m.deposited < 150 or a.coop_item != -1:
		return "should load at the skyship (deposited %d)" % m.deposited
	return ""


func _t_repair() -> String:
	var m := CFSim.create_match(1, false, 2)
	var a := CFSim.add_player(m, "a", "A", Color.WHITE)
	var b := CFSim.add_player(m, "b", "B", Color.WHITE)
	m.mech["bridge"]["state"] = "down"
	var lv: Vector2 = m.spots["lever"]
	_place(a, lv.x, lv.y)
	_place(b, lv.x, lv.y)
	_run(m, int(ceil(CF.SAB["bridge"]["repair"] / 2.0 * 60)) + 2, func(_id, _k, f): f.act_held = true)
	if m.mech["bridge"]["state"] != "ok" or a.stats["repairs"] != 1 or b.stats["repairs"] != 1:
		return "bridge state %s" % m.mech["bridge"]["state"]
	return ""


func _escape_setup(aboard_count: int) -> CFMatch:
	var m := CFSim.create_match(1, false, 4)
	for id in ["a", "b", "c", "d"]:
		CFSim.add_player(m, id, id, Color.WHITE)
	m.deposited = m.target
	_run(m, 1)
	var deck: Vector2 = m.spots["deck"]
	for i in aboard_count:
		_place(m.players[i], deck.x, deck.y)
	return m


func _t_escape_win() -> String:
	var m := _escape_setup(2)
	_run(m, 2)
	if not m.players[0].aboard or m.phase != "escape":
		return "should be boarding (phase %s)" % m.phase
	_run(m, int(CF.DEPART_WINDOW * 60) + 5)
	return "" if m.phase == "won" else "phase %s" % m.phase


func _t_escape_lose() -> String:
	var m := _escape_setup(1)
	_run(m, int(CF.DEPART_WINDOW * 60) + 5)
	return "" if m.phase == "lost" else "phase %s" % m.phase


func _t_disconnect() -> String:
	var m := CFSim.create_match(1, false, 2)
	var a := CFSim.add_player(m, "a", "A", Color.WHITE)
	CFSim.add_player(m, "b", "B", Color.WHITE)
	_run(m, 10)
	a.connected = false
	var x := a.x
	_run(m, 30, func(_id, _k, f): f.move_x = 1.0)
	if a.x != x:
		return "disconnected player moved"
	a.carried = 40
	var before := m.items.size()
	CFSim.remove_player(m, "a")
	if m.items.size() <= before or m.players.size() != 1:
		return "leaver should drop loot"
	return ""


func _t_prediction() -> String:
	var s := _solo(3)
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var ghost := CFPlayer.new()
	ghost.copy_motion_from(p)
	for k in 240:
		var f := _frame(k + 1)
		f.move_x = 1.0 if k < 120 else -0.6
		f.jump = k == 30 or k == 150
		f.jump_held = (k > 30 and k < 50) or (k > 150 and k < 160)
		CFSim.step_match(m, {"a": f}, CF.DT)
		m.events.clear()
		CFSim.step_movement(m, ghost, f, CF.DT)
	if absf(ghost.x - p.x) > 0.001 or absf(ghost.y - p.y) > 0.001:
		return "ghost %.2f,%.2f vs server %.2f,%.2f" % [ghost.x, ghost.y, p.x, p.y]
	return ""


func _t_input_wire() -> String:
	var f := CFInput.new()
	f.seq = 42; f.move_x = -0.73; f.jump = true; f.act_held = true; f.up = true
	var g := CFInput.from_wire(f.to_wire())
	if g.seq != 42 or absf(g.move_x + 0.73) > 0.001 or not g.jump or not g.act_held or g.act or not g.up:
		return "round trip failed"
	var bad := CFInput.from_wire([1, 99999, 0])
	if bad.move_x != 1.0:
		return "move_x not clamped"
	if CFInput.from_wire("junk") != null:
		return "junk accepted"
	return ""


func _t_spike_knockback() -> String:
	# ground spikes in the Verdant Ruins at tiles 29..30, row 21
	var s := _solo()
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var start := _tile_feet(26, 21)
	_place(p, start.x, start.y)
	_run(m, 5)
	var hit_tick := -1
	var last := Vector2(p.x, p.y)
	for k in 85:   # stop before invulnerability runs out and we'd walk back in
		var f := _frame(k)
		f.move_x = 1.0
		CFSim.step_match(m, {"a": f}, CF.DT)
		m.events.clear()
		if Vector2(p.x, p.y).distance_to(last) > 20.0:
			return "moved %.0f px in one tick (teleport)" % Vector2(p.x, p.y).distance_to(last)
		last = Vector2(p.x, p.y)
		if p.stun_t > 0.0 and hit_tick < 0:
			hit_tick = k
			if p.vx >= 0 or p.vy >= 0:
				return "knockback should push back and up (vx %.0f vy %.0f)" % [p.vx, p.vy]
			if p.recover_t > 0.0:
				return "ground spikes should knock back, not recover"
	if hit_tick < 0:
		return "never touched the spikes"
	if p.stats["falls"] != 1:
		return "expected one hurt, got %d (invulnerability should stop repeats)" % p.stats["falls"]
	return ""


func _t_pit_recovery() -> String:
	# the slab pit in the Verdant Ruins: tiles 51..58, spikes on row 25
	var s := _solo()
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var ledge := _tile_feet(49, 21)
	_place(p, ledge.x, ledge.y)
	_run(m, 3)
	m.find_mover("slab").x = 56 * CF.T   # move the slab out of the way
	m.find_mover("slab").jammed = true
	p.carried = 40
	var last := Vector2(p.x, p.y)
	var recovered := false
	for k in 240:
		var f := _frame(k)
		f.move_x = 1.0 if k < 20 else 0.0
		CFSim.step_match(m, {"a": f}, CF.DT)
		m.events.clear()
		var d := Vector2(p.x, p.y).distance_to(last)
		if d > 24.0:
			return "moved %.0f px in one tick (teleport)" % d
		last = Vector2(p.x, p.y)
		if p.recover_t > 0.0:
			recovered = true
	if not recovered:
		return "never entered recovery"
	if absf(p.x + p.w / 2 - ledge.x) > 2 * CF.T or absf(p.y + p.h - ledge.y) > 4:
		return "should end on the last safe ledge (at %.0f,%.0f)" % [p.x, p.y]
	if p.carried >= 40:
		return "should have spilled some Sunstone"
	return ""


func _t_ladder() -> String:
	# ladder shaft from the Ruins surface (tile 34) down into the Old Library
	var s := _solo()
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var top := _tile_feet(34, 21)
	_place(p, top.x, top.y)
	_run(m, 5)
	if not p.on_ground:
		return "should stand on the ladder top"
	var y0 := p.y
	_run(m, 60, func(_id, _k, f): f.down = true)
	if not p.climbing or p.y < y0 + 4 * CF.T:
		return "should climb down (climbing %s, moved %.0f)" % [p.climbing, p.y - y0]
	var y1 := p.y
	_run(m, 30, func(_id, _k, f): f.up = true)
	if p.y > y1 - 2 * CF.T:
		return "should climb back up"
	return ""


func _t_door() -> String:
	var s := _solo()
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var lever: Vector2 = m.spots["levers"][0]
	if not m.is_solid(CF.Tile.DOOR1):
		return "door 1 should start closed"
	_place(p, lever.x, lever.y)
	_run(m, 2)
	_run(m, 1, func(_id, _k, f): f.act = true)
	if m.is_solid(CF.Tile.DOOR1) or not m.mech["doors"][0]:
		return "lever should open door 1"
	return ""


func _vein(m: CFMatch, great: bool) -> Dictionary:
	for v in m.veins:
		if v["great"] == great:
			return v
	return {}


func _t_great_vein() -> String:
	var m := CFSim.create_match(1, false, 2)
	var a := CFSim.add_player(m, "a", "A", Color.WHITE)
	var b := CFSim.add_player(m, "b", "B", Color.WHITE)
	var v := _vein(m, true)
	_place(a, v["pos"].x - 6, v["pos"].y)
	_place(b, v["pos"].x + 6, v["pos"].y)
	_run(m, 2)
	var hp: int = v["hp"]
	for k in 5:
		_run(m, 1, func(id, _k, f): f.act = id == "a")
		_run(m, 30)
	if v["hp"] != hp:
		return "one explorer alone should not crack a great vein"
	for k in CF.GREAT_VEIN_HP + 2:
		_run(m, 1, func(id, _k, f): f.act = id == "a")
		_run(m, 1, func(id, _k, f): f.act = id == "b")
		_run(m, 20)
	if CFVeins.intact(m, v):
		return "two explorers together should crack it (hp %d)" % v["hp"]
	return ""


func _t_small_vein() -> String:
	var s := _solo()
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var v := _vein(m, false)
	_place(p, v["pos"].x, v["pos"].y)
	_run(m, 2)
	var before := m.items.size()
	for k in CF.VEIN_HP:
		_run(m, 1, func(_id, _k, f): f.act = true)
		_run(m, 25)
	if CFVeins.intact(m, v):
		return "should crack after %d strikes" % CF.VEIN_HP
	var spawned := m.items.size() - before
	if spawned != CF.VEIN_YIELD.size():
		return "expected %d pieces, got %d" % [CF.VEIN_YIELD.size(), spawned]
	for i in range(before, m.items.size()):
		var it: CFItem = m.items[i]
		if CFSim.touching_hazard(m, _dummy_at(it.x, it.y)):
			return "a piece landed in spikes"
	_run(m, int(CF.VEIN_REGROW * 60) + 5)
	if not CFVeins.intact(m, v):
		return "vein should regrow"
	return ""


func _dummy_at(x: float, y: float) -> CFPlayer:
	var d := CFPlayer.new()
	d.x = x - d.w / 2
	d.y = y - d.h / 2
	return d


func _t_taint() -> String:
	var s := _solo()
	var m: CFMatch = s[0]
	var p: CFPlayer = s[1]
	var v := _vein(m, false)
	v["tainted"] = true
	_place(p, v["pos"].x, v["pos"].y)
	_run(m, 2)
	var before := m.items.size()
	for k in CF.VEIN_HP:
		_run(m, 1, func(_id, _k, f): f.act = true)
		_run(m, 25)
	for i in range(before, m.items.size()):
		if not m.items[i].fake:
			return "tainted vein produced real Sunstone"
	p.carried = 25
	p.fake_carried = 25
	var dep := m.deposited
	_place(p, m.spots["vault"].x, m.spots["vault"].y)
	_run(m, 2)
	_run(m, 1, func(_id, _k, f): f.act = true)
	if m.deposited != dep or p.carried != 0:
		return "fool's stone should be worth nothing (deposited %d → %d)" % [dep, m.deposited]
	return ""


func _t_bounty() -> String:
	var m := CFSim.create_match(1, false, 1)
	m.bounties = [{"id": 99, "kind": "repair", "area": "", "need": 1, "have": 0, "reward": 30, "text": "Repair"}]
	var dep := m.deposited
	CFVeins.bounty_event(m, "repair", {})
	if m.deposited != dep + 30:
		return "reward not added"
	if m.bounties.size() != 1 or m.bounties[0]["id"] == 99:
		return "a new bounty should replace the finished one"
	return ""


func _t_surge_no_heal() -> String:
	var m := CFSim.create_match(3, false, 1)
	for v in m.veins:
		v["hp"] = 1
	m.next_surge_at = m.t
	CFVeins.step(m)
	var surged := m.veins.filter(func(v): return v["surge_until"] > m.t)
	if surged.size() != 1:
		return "expected one surging vein, got %d" % surged.size()
	if surged[0]["hp"] != 1:
		return "surge raised a struck vein's hp to %d" % surged[0]["hp"]
	return ""


# ---------------------------------------------------------------- hidden traitors and meetings

func _traitor_match(n: int, traitor_ids: Array) -> CFMatch:
	## n players a, b, c...; the given ids are traitors (set by hand so tests don't depend on the shuffle).
	var m := CFSim.create_match(1, false, n)
	m.mode = "traitors"
	for i in n:
		var pid := String.chr(97 + i)
		var p := CFSim.add_player(m, pid, pid.to_upper(), Color.WHITE)
		p.role = "traitor" if traitor_ids.has(pid) else "explorer"
		p.guile = CF.GUILE_START if p.role == "traitor" else 0.0
	return m


func _t_roles() -> String:
	for n in [4, 6, 7, 8]:
		var m := CFSim.create_match(1, false, n)
		for i in n:
			CFSim.add_player(m, str(i), str(i), Color.WHITE)
		var rng := RandomNumberGenerator.new()
		rng.seed = 99
		CFSim.assign_roles(m, rng)
		var t := CFSim.traitors(m).size()
		if t != CF.traitor_count(n):
			return "%d players got %d traitors" % [n, t]
		if m.mode != "traitors":
			return "mode not set"
	return ""


func _t_role_secrecy() -> String:
	var m := _traitor_match(4, ["b"])
	var snap := CFWire.encode_snapshot(m, 1, {}, true)
	for w in snap["ps"]:
		if str(w[27]) != "":
			return "player %s's role is public mid-match" % w[0]
	if snap.has("dir"):
		return "the director block leaks in traitor mode"
	if snap["mech"].has("taint"):
		return "the taint cooldown is public"
	var mine := CFWire.encode_private(m, "a")
	if mine["role"] != "explorer" or mine.has("guile") or mine.has("allies"):
		return "an explorer's private part says too much: %s" % str(mine)
	var theirs := CFWire.encode_private(m, "b")
	if theirs["role"] != "traitor" or not theirs.has("guile") or theirs["allies"] != ["b"]:
		return "the traitor's private part is wrong: %s" % str(theirs)
	m.phase = "won"
	snap = CFWire.encode_snapshot(m, 2, {}, true)
	if snap["ps"][1][27] != "traitor":
		return "roles should be revealed once the match ends"
	return ""


func _t_traitor_sabotage() -> String:
	var m := _traitor_match(4, ["b"])
	_run(m, 1)
	if CFSim.traitor_sabotage(m, "a", "spikes") == "":
		return "an explorer could sabotage"
	var b := m.find_player("b")
	var before := b.guile
	var err := CFSim.traitor_sabotage(m, "b", "spikes")
	if err != "":
		return "spikes refused: " + err
	if not is_equal_approx(b.guile, before - CF.SAB["spikes"]["cost"]):
		return "guile %.1f after spending from %.1f" % [b.guile, before]
	b.guile = CF.GUILE_MAX
	if CFSim.traitor_sabotage(m, "b", "lift") == "":
		return "the lockout did not stop a second sabotage"
	m.t = b.sab_lock + 0.1
	if CFSim.traitor_sabotage(m, "b", "taint") == "":
		return "taint worked away from any vein"
	return ""


func _t_meeting_exile() -> String:
	var m := _traitor_match(4, ["c"])
	_run(m, 1)
	m.t = CF.MEETING_FIRST_AT + 1.0
	var a := m.find_player("a")
	if not CFSim.call_meeting(m, a):
		return "the bell would not ring"
	if CFSim.call_meeting(m, m.find_player("b")):
		return "a second meeting started during the first"
	var t0 := m.t
	CFSim.cast_vote(m, "a", "c")
	CFSim.cast_vote(m, "b", "c")
	CFSim.cast_vote(m, "c", "a")
	if CFSim.cast_vote(m, "a", "b"):
		return "a vote was changed"
	_run(m, 10)
	if not m.meeting["active"] or m.t != t0:
		return "the meeting should wait for the last voter with the clock frozen"
	CFSim.cast_vote(m, "d", "skip")
	_run(m, 1)
	if m.meeting["active"]:
		return "the meeting did not end once everyone voted"
	if not m.find_player("c").exiled:
		return "the traitor was not exiled"
	if m.phase != "won" or m.winner != "explorers":
		return "phase %s winner %s" % [m.phase, m.winner]
	return ""


func _t_meeting_tie() -> String:
	var m := _traitor_match(4, ["c"])
	_run(m, 1)
	m.t = CF.MEETING_FIRST_AT + 1.0
	CFSim.call_meeting(m, m.find_player("a"))
	CFSim.cast_vote(m, "a", "c")
	CFSim.cast_vote(m, "b", "c")
	CFSim.cast_vote(m, "c", "a")
	CFSim.cast_vote(m, "d", "a")
	_run(m, 1)
	for p in m.players:
		if p.exiled:
			return "%s was exiled on a tie" % p.id
	if m.phase != "running":
		return "phase %s after a tie" % m.phase
	if CFSim.can_call_meeting(m, m.find_player("b")):
		return "the bell should be on cooldown"
	return ""


func _t_escape_traitor() -> String:
	## a (traitor) and b get aboard: only 1 of 3 explorers, short of half, so the expedition is stranded.
	var m := _escape_setup(2)
	m.mode = "traitors"
	m.players[0].role = "traitor"
	for i in range(1, 4):
		m.players[i].role = "explorer"
	_run(m, int(CF.DEPART_WINDOW * 60) + 5)
	return "" if m.phase == "lost" else "phase %s: a traitor counted as crew" % m.phase


func _t_bell_floor() -> String:
	for id in CFMaps.IDS:
		var m := CFSim.create_match(1, false, 4, id)
		var bp: Vector2 = m.spots["bell"]
		var tx := int(bp.x / CF.T)
		var ty := int((bp.y - 1.0) / CF.T)
		if m.is_solid(m.tile_at(tx, ty)):
			return "%s: the bell is inside a wall" % id
		if not m.is_solid(m.tile_at(tx, ty + 1)):
			return "%s: the bell floats with nothing under it" % id
	return ""


func _busy_match(map_id: String, n: int) -> CFMatch:
	## n players running, jumping and dashing in different patterns for 40 seconds.
	var m := CFSim.create_match(11, false, n, map_id)
	for i in n:
		CFSim.add_player(m, "p%d" % i, "Explorer %d" % i, Color.WHITE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	CFSim.assign_roles(m, rng)
	_run(m, 2400, func(id, k, f):
		var i := int(str(id).substr(1))
		f.move_x = 1.0 if ((k + i * 37) / (50 + i * 9)) % 2 == 0 else -1.0
		f.jump = (k + i * 13) % (35 + i) == 0
		f.ability = (k + i * 7) % 300 == 0
		f.act = k % 20 == i)
	return m


func _t_snapshot_pack() -> String:
	var m := _busy_match("verdant", 4)
	var s := CFWire.encode_snapshot(m, 123, {}, true)
	var back := CFWire.unpack_snapshot(CFWire.pack_snapshot(s))
	if var_to_bytes(back) != var_to_bytes(s):
		return "unpacked snapshot differs from the original"
	for junk in [PackedByteArray(), PackedByteArray([1, 2, 3, 4, 5, 6]), PackedByteArray([255, 255, 255, 255, 0, 0])]:
		if not CFWire.unpack_snapshot(junk).is_empty():
			return "garbage was accepted"
	if not (s["ps"][0][20] as Dictionary).is_empty():
		return "live snapshots should leave out player stats"
	m.phase = "won"
	if (CFWire.encode_snapshot(m, 124, {}, true)["ps"][0][20] as Dictionary).is_empty():
		return "the final snapshot must carry player stats for the end screen"
	return ""


func _t_snapshot_size() -> String:
	# ENet's MTU is 1392 bytes. Keep 100 bytes for the RPC header and some growth.
	const BUDGET := 1292
	for id in CFMaps.IDS:
		var m := _busy_match(id, CF.MAX_PLAYERS)
		var acks := {}
		for p in m.players:
			acks[p.id] = 2400
		var packed := CFWire.pack_snapshot(CFWire.encode_snapshot(m, 2400, acks, true))
		var mine := var_to_bytes(CFWire.encode_private(m, CFSim.traitors(m, true)[0].id)).size()
		print("     %s: %d players, packed %d bytes + private %d" % [id, m.players.size(), packed.size(), mine])
		if packed.size() + mine > BUDGET:
			return "%s: %d + %d bytes is over the %d-byte budget" % [id, packed.size(), mine, BUDGET]
	return ""


func _room_slot(r: CFRoom, id: String, animal: String) -> CFSlot:
	var s := CFSlot.new()
	s.id = id
	s.animal = animal
	s.peer = 0   # no socket: nothing is sent
	r.join(s)
	return s


func _t_look_join() -> String:
	var net: Node = load("res://scripts/net/net.gd").new()
	var r := CFRoom.new("TEST01", true, net)
	var a := _room_slot(r, "a", "owl")
	var b := _room_slot(r, "b", "owl")
	var c := _room_slot(r, "c", "")
	var out := ""
	if CF.animal_of(a.color) != "owl":
		out = "first owl got %s" % CF.animal_of(a.color)
	elif CF.animal_of(b.color) == "owl" or CF.animal_of(c.color) == CF.animal_of(b.color):
		out = "animals not unique: %s, %s, %s" % [CF.animal_of(a.color), CF.animal_of(b.color), CF.animal_of(c.color)]
	net.free()
	return out


func _t_look_switch() -> String:
	var net: Node = load("res://scripts/net/net.gd").new()
	var r := CFRoom.new("TEST02", true, net)
	var a := _room_slot(r, "a", "pig")
	var b := _room_slot(r, "b", "frog")
	var out := ""
	b.animal = "pig"   # taken by a: stays a frog
	r.look_changed(b)
	if CF.animal_of(b.color) != "frog":
		out = "switched to a taken animal"
	b.animal = "cat"
	r.look_changed(b)
	if out == "" and CF.animal_of(b.color) != "cat":
		out = "could not switch to a free animal"
	r.state = "playing"
	b.animal = "bear"
	b.hat = "crown"
	r.look_changed(b)
	if out == "" and CF.animal_of(b.color) != "cat":
		out = "animal changed during a match"
	var entry: Dictionary = r.roster().filter(func(e): return e["id"] == "b")[0]
	if out == "" and entry["hat"] != "crown":
		out = "the roster does not carry the hat"
	net.free()
	return out


func _t_shop_catalogue() -> String:
	var paid := CF.paid_products()
	if paid.size() != CF.HATS.size() + CF.FACES.size() - CF.FREE_HATS.size() - CF.FREE_FACES.size():
		return "wrong number of paid items: %d" % paid.size()
	var steam_ids := {}
	for pid in paid:
		var pi := CF.item_of_product(pid)
		if pi.is_empty() or CF.product_id(pi[0], pi[1]) != pid:
			return "product id does not round-trip: %s" % pid
		if CF.price_cents(pi[0], pi[1]) not in [99, 199]:
			return "odd price for %s" % pid
		var sid := CF.steam_item_id(pid)
		if sid <= 0 or steam_ids.has(sid):
			return "Steam item id clash for %s" % pid
		steam_ids[sid] = true
	if not CF.item_of_product("hat_explorer").is_empty() or not CF.item_of_product("hat_nonsense").is_empty():
		return "free or unknown items count as products"
	if not CF.is_free("animal", "pig") or CF.price_cents("hat", "beanie") != 0:
		return "animals and free hats must cost nothing"
	return ""


func _t_shop_owned() -> String:
	var store: Node = load("res://scripts/client/store.gd").new()
	store.save_path = "user://test_purchases.cfg"
	store.backend = "test"
	var out := ""
	if not store.owns("hat", "explorer") or store.owns("hat", "crown"):
		out = "fresh store owns the wrong things"
	store.buy("hat", "crown")
	if out == "" and not store.owns("hat", "crown"):
		out = "test purchase did not unlock"
	var again: Node = load("res://scripts/client/store.gd").new()
	again.save_path = store.save_path
	again.load_owned()
	if out == "" and not again.owns("hat", "crown"):
		out = "purchase not saved"
	again.replace_owned(["face_shades", "hat_explorer", "junk"])
	if out == "" and (again.owns("hat", "crown") or not again.owns("face", "shades") or again.owned.size() != 1):
		out = "store record did not replace the owned list: %s" % str(again.owned.keys())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.save_path))
	store.free()
	again.free()
	return out
