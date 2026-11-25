class_name CFVeins
## Crystal veins, surges and camp bounties.
## - Strike a vein to crack it; Sunstone bursts out onto the floor nearby. Veins regrow.
## - Great veins only crack when two explorers strike together (within CF.TOGETHER_WINDOW).
## - Every minute or so a vein SURGES: twice the yield, half the strikes, shown on the map.
## - Traitors can secretly TAINT a vein: it bursts into fool's stone, worthless at the furnace.
## - The camp board posts shared bounties that add a bonus to the skyship's charge.

const T := CF.T


static func setup(m: CFMatch, marks_small: Array, marks_great: Array) -> void:
	m.veins.clear()
	var id := 0
	for list in [[marks_small, false], [marks_great, true]]:
		for p in list[0]:
			var pos := Vector2(p.x * T + 16, (p.y + 1) * T)
			var hp: int = CF.GREAT_VEIN_HP if list[1] else CF.VEIN_HP
			m.veins.append({"id": id, "pos": pos, "great": list[1], "hp": hp, "max_hp": hp, "broken_until": 0.0,
				"surge_until": 0.0, "tainted": false, "hits": {}, "area": m.area_at(pos.x, pos.y - 16)})
			id += 1


static func first_yield_total(m: CFMatch) -> int:
	var total := 0
	for v in m.veins:
		for n in (CF.GREAT_VEIN_YIELD if v["great"] else CF.VEIN_YIELD):
			total += n
	return total


static func intact(m: CFMatch, v: Dictionary) -> bool:
	return v["broken_until"] <= m.t


static func surging(m: CFMatch, v: Dictionary) -> bool:
	return v["surge_until"] > m.t and intact(m, v)


static func vein_near(m: CFMatch, c: Vector2) -> Dictionary:
	for v in m.veins:
		if intact(m, v) and absf(c.x - v["pos"].x) < (44 if v["great"] else 34) and absf(c.y - (v["pos"].y - 20)) < 48:
			return v
	return {}


## One step of vein upkeep: regrowth and surges.
static func step(m: CFMatch) -> void:
	for v in m.veins:
		if v["broken_until"] > 0.0 and v["broken_until"] <= m.t:
			v["broken_until"] = 0.0
			v["hp"] = v["max_hp"]
			v["tainted"] = false
			v["hits"] = {}
			m.emit("vein_regrown", {"id": v["id"]})
	if m.t >= m.next_surge_at and m.phase == "running":
		var choices := m.veins.filter(func(v): return intact(m, v) and v["surge_until"] <= m.t)
		if choices.size() > 0:
			var v: Dictionary = choices[m.world_rng.randi_range(0, choices.size() - 1)]
			v["surge_until"] = m.t + CF.SURGE_TIME
			v["hp"] = mini(v["hp"], maxi(1, ceili(v["max_hp"] / 2.0)))   # halves the strikes, never heals
			m.emit("surge", {"id": v["id"], "area": v["area"]})
		m.next_surge_at = m.t + m.world_rng.randf_range(CF.SURGE_EVERY_MIN, CF.SURGE_EVERY_MAX)


## An explorer strikes a vein (interact). Returns true if it cracked.
static func strike(m: CFMatch, p: CFPlayer, v: Dictionary) -> bool:
	if p.strike_cd > 0.0 or not intact(m, v):
		return false
	p.strike_cd = CF.STRIKE_COOLDOWN
	var counts := true
	if v["great"]:
		v["hits"][p.id] = m.t
		var together := 0
		for pid in v["hits"]:
			if m.t - v["hits"][pid] <= CF.TOGETHER_WINDOW:
				together += 1
		counts = together >= 2
		if not counts:
			m.emit("toast", {"to": p.id, "msg": "A great vein needs two of you striking together.", "tone": "vio"})
	if counts:
		v["hp"] -= 1
	m.emit("strike", {"id": p.id, "vein": v["id"], "x": v["pos"].x, "y": v["pos"].y - 20, "counts": counts})
	if v["hp"] <= 0:
		_crack(m, v, p)
		return true
	return false


static func _crack(m: CFMatch, v: Dictionary, p: CFPlayer) -> void:
	var was_surge := surging(m, v)
	var pieces: Array = (CF.GREAT_VEIN_YIELD if v["great"] else CF.VEIN_YIELD).duplicate()
	if was_surge:
		pieces.append_array(pieces.duplicate())
	var spots := _rest_spots(m, v["pos"], pieces.size())
	for i in pieces.size():
		var it := CFItem.new()
		it.id = m.next_item_id
		m.next_item_id += 1
		it.kind = "bag" if pieces[i] >= 15 else "coin"
		it.value = pieces[i]
		it.max_value = it.value
		it.x = spots[i].x
		it.y = spots[i].y
		it.dropped = true
		it.fake = v["tainted"]
		it.born = m.t
		it.from = v["pos"] + Vector2(0, -24)
		it.ph = float(it.id % 7)
		m.items.append(it)
		m.dirty_items[it.id] = true
	v["broken_until"] = m.t + CF.VEIN_REGROW
	v["surge_until"] = 0.0
	m.emit("crack", {"vein": v["id"], "by": p.name, "id": p.id, "x": v["pos"].x, "y": v["pos"].y - 20, "great": v["great"], "surge": was_surge})
	bounty_event(m, "crack", {"area": v["area"], "great": v["great"], "surge": was_surge})


static func _rest_spots(m: CFMatch, at: Vector2, n: int) -> Array:
	## Where shards land: floor positions spreading out from the vein, never in spikes or walls.
	var out: Array = []
	var tx0 := int(at.x / T)
	var row := int(at.y / T) - 1
	var offsets := [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6]
	var k := 0
	while out.size() < n and k < 60:
		var off: int = offsets[k % offsets.size()]
		var tx := tx0 + off
		var ty := row
		var ok := false
		# from the vein's row, look down up to 4 tiles for something to rest on
		for d in 5:
			var c := m.tile_at(tx, ty + d)
			if m.is_solid(c) or c == CF.Tile.SPIKE:
				break
			var below := m.tile_at(tx, ty + d + 1)
			if m.is_solid(below) or below == CF.Tile.PLANK or below == CF.Tile.BRIDGE:
				ty += d
				ok = true
				break
		if ok:
			var stack := k / offsets.size()
			out.append(Vector2(tx * T + 16 + (stack % 2) * 8 - 4, ty * T + 14 - stack * 10))
		k += 1
	while out.size() < n:
		out.append(at + Vector2(0, -18))
	return out


## Secret traitor sabotage: the next crack of this vein yields fool's stone.
static func taint_random(m: CFMatch, rng: RandomNumberGenerator) -> bool:
	var choices := m.veins.filter(func(v): return intact(m, v) and not v["tainted"])
	if choices.is_empty():
		return false
	var v: Dictionary = choices[rng.randi_range(0, choices.size() - 1)]
	v["tainted"] = true
	return true


# ---------------------------------------------------------------- bounties

static func setup_bounties(m: CFMatch) -> void:
	var areas := {}
	for v in m.veins:
		areas[v["area"]] = true
	var pool: Array = []
	for a in areas.keys():
		pool.append({"kind": "crack_area", "area": a, "need": 2, "reward": 40, "text": "Crack 2 veins in the %s" % a})
	pool.append({"kind": "crack_great", "area": "", "need": 1, "reward": 50, "text": "Crack a great vein together"})
	pool.append({"kind": "crack_surge", "area": "", "need": 1, "reward": 50, "text": "Crack a surging vein"})
	pool.append({"kind": "heartstone", "area": "", "need": 1, "reward": 60, "text": "Bring the Heartstone home"})
	pool.append({"kind": "big_load", "area": "", "need": 1, "reward": 30, "text": "Load 90 or more in one trip"})
	pool.append({"kind": "repair", "area": "", "need": 1, "reward": 30, "text": "Repair a sabotaged bridge or lift"})
	# shuffle with the match's seeded generator
	for i in range(pool.size() - 1, 0, -1):
		var j := m.world_rng.randi_range(0, i)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var bid := 0
	for b in pool:
		b["id"] = bid
		b["have"] = 0
		bid += 1
	m.bounty_pool = pool
	m.bounties.clear()
	while m.bounties.size() < CF.BOUNTY_SLOTS and m.bounty_pool.size() > 0:
		m.bounties.append(m.bounty_pool.pop_front())


static func bounty_event(m: CFMatch, kind: String, data: Dictionary) -> void:
	for b in m.bounties.duplicate():
		var hit := false
		match b["kind"]:
			"crack_area": hit = kind == "crack" and data["area"] == b["area"]
			"crack_great": hit = kind == "crack" and data["great"]
			"crack_surge": hit = kind == "crack" and data["surge"]
			"heartstone": hit = kind == "heartstone"
			"big_load": hit = kind == "load" and data["n"] >= 90
			"repair": hit = kind == "repair"
		if not hit:
			continue
		b["have"] += 1
		if b["have"] >= b["need"]:
			m.bounties.erase(b)
			m.deposited += b["reward"]
			m.stats["deposited"] += b["reward"]
			m.emit("bounty_done", {"text": b["text"], "reward": b["reward"]})
			if m.bounty_pool.size() > 0:
				m.bounties.append(m.bounty_pool.pop_front())
