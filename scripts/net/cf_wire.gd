class_name CFWire
## Encoding of snapshots and items for the network. Positions are rounded to 1/64 px, and the
## frequent unreliable snapshot is deflate-compressed so it fits in one UDP packet (see pack_snapshot).

const PS_FIELDS := 28
const SNAP_MAX_BYTES := 1 << 20   # refuse to inflate anything bigger than this


static func r2(v: float) -> float:
	## Snap to 1/64: as fine as 0.01 px, but exactly representable as a 32-bit float, so Godot sends
	## 4 bytes instead of 8 and the low bits compress away.
	return roundf(v * 64.0) / 64.0


static func encode_item(it: CFItem) -> Array:
	## Fool's stone is NOT flagged on the wire: it looks identical until it reaches the furnace.
	var flags := (1 if it.gone else 0) | (2 if it.opened else 0) | (4 if it.empty else 0) | (8 if it.dropped else 0) | (16 if it.waiting_id != "" else 0)
	return [it.id, it.kind, r2(it.x), r2(it.y), it.value, flags, r2(it.born), r2(it.from.x), r2(it.from.y)]


static func apply_item(m: CFMatch, w: Array) -> void:
	var it := m.find_item(int(w[0]))
	if it == null:
		it = CFItem.new()
		it.id = int(w[0])
		it.max_value = int(w[4])
		it.ph = float(it.id % 7)
		m.items.append(it)
	it.kind = str(w[1])
	it.x = float(w[2])
	it.y = float(w[3])
	it.value = int(w[4])
	var flags := int(w[5])
	it.gone = flags & 1 != 0
	it.opened = flags & 2 != 0
	it.empty = flags & 4 != 0
	it.dropped = flags & 8 != 0
	if w.size() >= 9:
		it.born = float(w[6])
		it.from = Vector2(float(w[7]), float(w[8]))


static func encode_player(p: CFPlayer, ack: int, ended := false, shared := false) -> Array:
	## [0 id, 1 x, 2 y, 3 vx, 4 vy, 5 facing, 6 carried, 7 recover_t, 8 dash_t, 9 on_ground, 10 ability_cd, 11 jump_buf,
	##  12 coyote, 13 drop_t, 14 ride_id, 15 aboard, 16 coop_item, 17 cp, 18 connected, 19 ack, 20 stats,
	##  21 climbing, 22 stun_t, 23 invuln_t, 24 rec_from, 25 rec_to, 26 exiled, 27 public role]
	## The role is only filled in once it is public: the player was exiled, or the match is over.
	## Stats are only shown on the end screen, so they are sent (non-empty) only once the match is over.
	## shared: the copy everyone gets. The fields only needed to predict your own movement are blanked
	## there and sent to the player alone in encode_private (see encode_self / with_self).
	var public_role := p.role if (p.exiled or ended) else ""
	if shared:
		return [p.id, r2(p.x), r2(p.y), r2(p.vx), r2(p.vy), p.facing, p.carried, r2(p.recover_t), r2(p.dash_t), p.on_ground,
			0.0, 0.0, 0.0, 0.0, p.ride_id, p.aboard, p.coop_item, p.cp, p.connected, 0, p.stats if ended else {},
			p.climbing, r2(p.stun_t), r2(p.invuln_t), Vector2.ZERO, Vector2.ZERO, p.exiled, public_role]
	return [p.id, r2(p.x), r2(p.y), r2(p.vx), r2(p.vy), p.facing, p.carried, r2(p.recover_t), r2(p.dash_t), p.on_ground,
		r2(p.ability_cd), r2(p.jump_buf), r2(p.coyote), r2(p.drop_t), p.ride_id, p.aboard, p.coop_item, p.cp, p.connected, ack, p.stats if ended else {},
		p.climbing, r2(p.stun_t), r2(p.invuln_t), p.rec_from, p.rec_to, p.exiled, public_role]


static func encode_self(p: CFPlayer, ack: int) -> Array:
	## The prediction-only fields left out of the shared copy: [ability_cd, jump_buf, coyote, drop_t, ack, rec_from, rec_to].
	return [r2(p.ability_cd), r2(p.jump_buf), r2(p.coyote), r2(p.drop_t), ack, p.rec_from, p.rec_to]


static func with_self(w: Array, s: Array) -> Array:
	## The shared player record with this player's own prediction fields put back.
	if s.size() < 7:
		return w
	var out := w.duplicate()
	out[10] = s[0]; out[11] = s[1]; out[12] = s[2]; out[13] = s[3]; out[19] = s[4]; out[24] = s[5]; out[25] = s[6]
	return out


## Copies authoritative fields onto a local player.
static func apply_player(p: CFPlayer, w: Array) -> void:
	p.x = w[1]; p.y = w[2]; p.vx = w[3]; p.vy = w[4]; p.facing = w[5]; p.carried = w[6]; p.recover_t = w[7]; p.dash_t = w[8]
	p.on_ground = w[9]; p.ability_cd = w[10]; p.jump_buf = w[11]; p.coyote = w[12]; p.drop_t = w[13]; p.ride_id = w[14]
	p.aboard = w[15]; p.coop_item = w[16]; p.cp = w[17]; p.connected = w[18]
	if not (w[20] as Dictionary).is_empty():
		p.stats = w[20]
	p.climbing = w[21]; p.stun_t = w[22]; p.invuln_t = w[23]; p.rec_from = w[24]; p.rec_to = w[25]
	if w.size() >= PS_FIELDS:
		p.exiled = w[26]
		if str(w[27]) != "":
			p.role = w[27]


static func encode_snapshot(m: CFMatch, tick: int, acks: Dictionary, include_director: bool) -> Dictionary:
	## The same for every player: nothing in here may reveal a hidden role (see encode_private).
	var ended := m.phase == "won" or m.phase == "lost"
	var ps: Array = []
	for p in m.players:
		ps.append(encode_player(p, 0, ended, true))
	var mv: Array = []
	for mvr in m.movers:
		mv.append([r2(mvr.x), r2(mvr.y), mvr.dir, r2(mvr.paused), mvr.jammed])
	var veins: Array = []
	for v in m.veins:
		veins.append([v["id"], v["hp"], r2(v["broken_until"]), r2(v["surge_until"]), v["tainted"]])
	var bounties: Array = []
	for b in m.bounties:
		bounties.append({"text": b["text"], "have": b["have"], "need": b["need"], "reward": b["reward"], "area": b["area"]})
	var idol: Array = []
	for it in m.items:
		if it.kind == "idol" and not it.gone and it.carriers.size() > 0:
			idol.append([it.id, r2(it.x), r2(it.y), it.carriers])
	var s := {
		"k": tick, "st": r2(m.t), "tl": r2(m.time_left), "ph": m.phase, "da": r2(m.depart_at), "er": m.end_reason,
		"v": [m.deposited, m.target], "rec": m.recent, "mech": _public_mech(m), "mv": mv, "ps": ps, "idol": idol, "stats": m.stats,
		"vn": veins, "bt": bounties, "ns": r2(m.next_surge_at), "mode": m.mode, "win": m.winner,
		# meeting: who has voted is public, what they voted is not (until the result event)
		"mt": [m.meeting["active"], m.meeting["by"], r2(m.meeting["left"]), m.meeting["votes"].keys(), r2(m.meeting["next_at"])],
	}
	if include_director and m.director["enabled"]:
		# Taints are secret: they never leave the server, and neither does the lockout a taint starts.
		var acts: Array = m.director["log"]
		var shown := acts.filter(func(e): return e["what"] != "taint")
		var lock_until: float = m.director["lock_until"] if (acts.size() > 0 and acts[0]["what"] != "taint") else 0.0
		s["dir"] = {"guile": r2(m.director["guile"]), "lock_until": lock_until, "log": shown}
	return s


static func pack_snapshot(s: Dictionary) -> PackedByteArray:
	## [4-byte uncompressed size][deflate data]. Compressed once per tick and shared by every player.
	var raw := var_to_bytes(s)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_DEFLATE))
	return out


static func unpack_snapshot(data: PackedByteArray) -> Dictionary:
	## Returns {} for anything malformed rather than erroring.
	if data.size() < 5:
		return {}
	var n := data.decode_u32(0)
	if n == 0 or n > SNAP_MAX_BYTES:
		return {}
	var raw := data.slice(4).decompress(n, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != n:
		return {}
	var v: Variant = bytes_to_var(raw)
	return v if v is Dictionary else {}


static func _public_mech(m: CFMatch) -> Dictionary:
	## Everything but the taint cooldown, which would show explorers when a secret taint happened.
	var out := m.mech.duplicate()
	out.erase("taint")
	return out


static func encode_private(m: CFMatch, pid: String, ack := 0) -> Dictionary:
	## What only this player may know: their own role and prediction state and, for a traitor, Guile and fellow traitors.
	var p := m.find_player(pid)
	if p == null:
		return {}
	var d := {"role": p.role, "meetings": p.meetings_left, "self": encode_self(p, ack)}
	if p.role == "traitor":
		d["guile"] = r2(p.guile)
		d["lock"] = r2(p.sab_lock)
		d["taint_at"] = r2(m.mech["taint"]["available_at"])
		d["allies"] = CFSim.traitors(m, true).map(func(q): return q.id)
	return d


static func apply_meeting(m: CFMatch, w: Array) -> void:
	m.meeting["active"] = w[0]
	m.meeting["by"] = w[1]
	m.meeting["left"] = w[2]
	var voted := {}
	for id in w[3]:
		voted[id] = "?"
	m.meeting["votes"] = voted
	m.meeting["next_at"] = w[4]


static func apply_veins(m: CFMatch, list: Array) -> void:
	for w in list:
		for v in m.veins:
			if v["id"] == w[0]:
				v["hp"] = w[1]; v["broken_until"] = w[2]; v["surge_until"] = w[3]; v["tainted"] = w[4]
				break


static func encode_items(m: CFMatch, ids: Array) -> Array:
	var out: Array = []
	for iid in ids:
		var it := m.find_item(iid)
		if it:
			out.append(encode_item(it))
	return out
