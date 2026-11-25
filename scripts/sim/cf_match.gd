class_name CFMatch
extends RefCounted
## The whole state of one match. The server holds the real one; clients hold a view of it.

var match_seed := 0
var map_id := "verdant"
var map_name := ""
var areas: Array = []      # [name, x0, y0, x1, y1, rock colour, wall colour, back-wall pattern]; rooms first
var decor: Array = []      # scenery props [kind, tx, ty, extra] (client only draws them)
var theme := {}
var t := 0.0
var time_left := CF.MATCH_TIME
var phase := "running"     # running, escape, won, lost
var end_reason := ""
var depart_at := 0.0

var grid := PackedByteArray()
var items: Array = []      # CFItem
var next_item_id := 0
var movers: Array = []     # CFMover
var spots := {}            # name → Vector2 or Array[Vector2]
var total := 0
var bridge_tiles: Array = []   # Vector2i
var trap_tiles: Array = []
var fake_tiles: Array = []
var door_tiles: Array = []     # [Vector2i, door index]

var players: Array = []    # CFPlayer
var veins: Array = []      # {id, pos, great, hp, max_hp, broken_until, surge_until, tainted, hits, area}
var bounties: Array = []   # active: {id, kind, area, need, have, reward, text}
var bounty_pool: Array = []
var next_surge_at := CF.SURGE_FIRST
var world_rng := RandomNumberGenerator.new()
var deposited := 0
var target := 0
var recent: Array = []     # [{n, by}]
var cps: Array = []        # [{pos: Vector2, on: bool}]

var mech := {
	"spikes": {"state": "idle", "until": 0.0, "available_at": 0.0},
	"bridge": {"state": "ok", "warn_until": 0.0, "down_at": 0.0, "repair": 0.0, "available_at": 0.0},
	"lift": {"repair": 0.0, "available_at": 0.0},
	"taint": {"available_at": 0.0},
	"breach": {"active": false, "ends_at": 0.0, "sw": [false, false, false], "available_at": 0.0},
	"doors": [false, false, false],   # shortcut doors, opened from their far side
}
var director := {"enabled": false, "guile": CF.GUILE_START, "lock_until": 0.0, "next_think": CF.DIRECTOR_FIRST_AT, "log": []}
var mode := "none"         # none, bot, traitors (see CF.MODES)
var winner := ""           # explorers or traitors, once the match ends
var taints := 0            # secret until the end: added to stats["sabotages"] then
# Meetings: the bell at camp freezes play while everyone votes. Votes stay secret until the result.
var meeting := {"active": false, "by": "", "left": 0.0, "votes": {}, "next_at": CF.MEETING_FIRST_AT}
var director_rng := RandomNumberGenerator.new()
var stats := {"collected": 0, "deposited": 0, "lost_hazard": 0, "lost_breach": 0, "sabotages": 0, "repairs": 0, "breaches_stopped": 0}

var events: Array = []         # [{type, to?, ...}]
var dirty_items := {}          # id → true


func tile_at(tx: int, ty: int) -> int:
	if tx < 0 or tx >= CF.GW or ty >= CF.GH:
		return CF.Tile.SOLID
	if ty < 0:
		return CF.Tile.E
	return grid[ty * CF.GW + tx]


func is_solid(c: int) -> bool:
	if c == CF.Tile.SOLID:
		return true
	if c == CF.Tile.BRIDGE:
		return mech["bridge"]["state"] != "down"
	if c >= CF.Tile.DOOR1:
		return not mech["doors"][c - CF.Tile.DOOR1]
	return false


func is_ladder(tx: int, ty: int) -> bool:
	var c := tile_at(tx, ty)
	if c == CF.Tile.LADDER:
		return true
	# an open hatch in a ladder shaft is part of the ladder
	return c >= CF.Tile.DOOR1 and not is_solid(c) and (tile_at(tx, ty + 1) == CF.Tile.LADDER or tile_at(tx, ty - 1) == CF.Tile.LADDER)


func is_ladder_top(tx: int, ty: int) -> bool:
	return is_ladder(tx, ty) and not is_ladder(tx, ty - 1)


func area_at(x: float, y: float) -> String:
	var tx := int(x / CF.T)
	var ty := int(y / CF.T)
	for a in areas:
		if tx >= a[1] and ty >= a[2] and tx <= a[3] and ty <= a[4]:
			return a[0]
	return ""


func area_of_tile(tx: int, ty: int) -> Array:
	## The area row covering a tile (rooms come first in the list), or [] if none.
	for a in areas:
		if tx >= a[1] and ty >= a[2] and tx <= a[3] and ty <= a[4]:
			return a
	return []


func area_colors(name: String) -> Array:
	## [rock, cave wall] for an area
	for a in areas:
		if a[0] == name:
			return [Color(a[5]), Color(a[6])]
	return [Color("#3d2b22"), Color("#22201c")]


func find_player(pid: String) -> CFPlayer:
	for p in players:
		if p.id == pid:
			return p
	return null


func find_item(iid: int) -> CFItem:
	for it in items:
		if it.id == iid:
			return it
	return null


func find_mover(mid: String) -> CFMover:
	for m in movers:
		if m.id == mid:
			return m
	return null


func emit(type: String, data: Dictionary = {}) -> void:
	var e := data.duplicate()
	e["type"] = type
	events.append(e)
