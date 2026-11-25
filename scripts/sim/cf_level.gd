class_name CFLevel
## Loads a map's ASCII (see CFMaps; legend in tools/build_maps.py).
## Same seed → same map and Sunstone placement on the server and every client.

const T := CF.T

const TILE_OF := {
	"#": CF.Tile.SOLID, "=": CF.Tile.PLANK, "^": CF.Tile.SPIKE, "H": CF.Tile.LADDER, "B": CF.Tile.BRIDGE,
	"t": CF.Tile.TRAP, "F": CF.Tile.FAKE, "1": CF.Tile.DOOR1, "2": CF.Tile.DOOR2, "3": CF.Tile.DOOR3,
}
const ITEM_OF := {"C": "chest", "R": "relic", "K": "cache", "I": "idol"}
const SHARD_CHANCE := 0.45     # loose shards are a small extra; veins are the main source
const CLUSTER_CHANCE := 0.5


static func build(m: CFMatch, seed_value: int, map_id: String) -> void:
	var data := CFMaps.data(map_id)
	m.map_id = data["id"]
	m.map_name = data["name"]
	m.areas = data["areas"]
	m.theme = data["theme"]
	m.decor = data["decor"]
	var rows: PackedStringArray = str(data["map"]).split("\n")
	assert(rows.size() == CF.GH and rows[0].length() == CF.GW, "every map must be CF.GW x CF.GH")
	var grid: Array = []
	grid.resize(CF.GW * CF.GH)
	grid.fill(CF.Tile.E)
	var marks := {}   # marker char → Array[Vector2i]
	for y in CF.GH:
		var row: String = rows[y]
		for x in CF.GW:
			var ch: String = row[x]
			if TILE_OF.has(ch):
				grid[y * CF.GW + x] = TILE_OF[ch]
			elif ch != ".":
				if not marks.has(ch):
					marks[ch] = []
				marks[ch].append(Vector2i(x, y))
	m.grid = PackedByteArray(grid)

	m.bridge_tiles.clear(); m.trap_tiles.clear(); m.fake_tiles.clear(); m.door_tiles.clear()
	for y in CF.GH:
		for x in CF.GW:
			var c: int = grid[y * CF.GW + x]
			match c:
				CF.Tile.BRIDGE: m.bridge_tiles.append(Vector2i(x, y))
				CF.Tile.TRAP: m.trap_tiles.append(Vector2i(x, y))
				CF.Tile.FAKE: m.fake_tiles.append(Vector2i(x, y))
				CF.Tile.DOOR1, CF.Tile.DOOR2, CF.Tile.DOOR3: m.door_tiles.append([Vector2i(x, y), c - CF.Tile.DOOR1])

	# Sunstone: shards and clusters are candidates chosen by the seed; big pieces are fixed
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	m.items.clear()
	for p in marks.get("o", []):
		if rng.randf() < SHARD_CHANCE:
			_add(m, rng, "coin", p)
	for p in marks.get("O", []):
		if rng.randf() < CLUSTER_CHANCE:
			_add(m, rng, "bag", p)
	for ch in ITEM_OF:
		for p in marks.get(ch, []):
			_add(m, rng, ITEM_OF[ch], p)
	m.next_item_id = m.items.size()
	m.total = 0
	for it in m.items:
		m.total += it.value

	# Moving slab (M → m) and lift (U top → u bottom)
	m.movers.clear()
	var ms: Vector2i = marks["M"][0]
	var me: Vector2i = marks["m"][0]
	m.movers.append(_mover("slab", "h", ms.x * T, ms.y * T, 80, ms.x * T, me.x * T, 70.0, 1, 0.0))
	var lu: Vector2i = marks["U"][0]
	var ld: Vector2i = marks["u"][0]
	m.movers.append(_mover("lift", "v", lu.x * T, lu.y * T, 96, lu.y * T, ld.y * T, 95.0, 1, 1.2))

	var spawn := _feet(marks["S"][0])
	var cps: Array = []
	for p in marks.get("k", []):
		cps.append(_feet(p))
	cps.sort_custom(func(a, b): return a.distance_to(spawn) < b.distance_to(spawn))   # camp first
	var valves: Array = []
	for p in marks.get("v", []):
		valves.append(_feet(p))
	valves.sort_custom(func(a, b): return a.x < b.x)
	m.spots = {
		"spawn": spawn,
		"bell": spawn + Vector2(-3 * T, 0),   # meeting bell, just west of the spawn (tests check it stands on floor)
		"vault": _feet(marks["V"][0]),       # the skyship's furnace: where Sunstone is loaded
		"board": _feet(marks["N"][0]),
		"deck": _feet(marks["E"][0]),        # where the skyship hovers for boarding
		"lever": _feet(marks["Y"][0]),       # bridge repair lever
		"gear": _feet(marks["G"][0]),        # lift repair gear
		"valves": valves,
		"levers": [_feet(marks["p"][0]), _feet(marks["q"][0]), _feet(marks["r"][0])],   # open doors 1, 2, 3
		"checkpoints": cps,
	}
	m.cps.clear()
	for i in cps.size():
		m.cps.append({"pos": cps[i], "on": i == 0})
	CFVeins.setup(m, marks.get("X", []), marks.get("W", []))


## A point marker's position: centre of its tile, at the player's feet (top of the tile below).
static func _feet(p: Vector2i) -> Vector2:
	return Vector2(p.x * T + 16, (p.y + 1) * T)


static func _add(m: CFMatch, rng: RandomNumberGenerator, kind: String, p: Vector2i) -> void:
	var it := CFItem.new()
	it.id = m.items.size()
	it.kind = kind
	it.x = p.x * T + 16
	it.y = p.y * T + 14
	it.value = CF.VALUES[kind]
	it.max_value = it.value
	it.ph = rng.randf() * TAU
	m.items.append(it)


static func _mover(id: String, kind: String, x: float, y: float, w: float, mn: float, mx: float, speed: float, dir: int, wait: float) -> CFMover:
	var mv := CFMover.new()
	mv.id = id; mv.kind = kind; mv.x = x; mv.y = y; mv.w = w; mv.min_pos = mn; mv.max_pos = mx
	mv.speed = speed; mv.dir = dir; mv.wait = wait
	return mv
