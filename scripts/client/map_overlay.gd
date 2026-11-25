class_name CFMapOverlay
extends Control
## Full-screen expedition map: the maze layout, area names, you, the skyship, shortcuts,
## active sabotage, surging veins and bounty targets. Other explorers are NOT shown:
## if you want to know where someone is, you have to go and look.

var m: CFMatch
var me: CFPlayer
var bounty_areas: Array = []   # area names a bounty points at
var _tex: ImageTexture
var _font: Font
var _now := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font = ThemeDB.fallback_font
	visible = false


func open(match_view: CFMatch, player: CFPlayer) -> void:
	m = match_view
	me = player
	_build_texture()
	visible = true
	queue_redraw()


func close() -> void:
	visible = false


func _gui_input(event: InputEvent) -> void:
	if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed):
		close()
		accept_event()


func _process(delta: float) -> void:
	if visible:
		_now += delta
		queue_redraw()


func _build_texture() -> void:
	## One pixel per tile, scaled up with nearest filtering for a crisp schematic look.
	var img := Image.create(CF.GW, CF.GH, false, Image.FORMAT_RGBA8)
	for ty in CF.GH:
		for tx in CF.GW:
			var c := m.tile_at(tx, ty)
			var col := Color(0, 0, 0, 0)
			match c:
				CF.Tile.SOLID:
					col = Color("#3a3f44") if ty >= CF.SURFACE else Color("#4a5a4a")
				CF.Tile.PLANK, CF.Tile.BRIDGE:
					col = Color("#c08a50")
				CF.Tile.LADDER:
					col = Color("#e0c48a")
				CF.Tile.SPIKE, CF.Tile.TRAP:
					col = Color("#d9483b")
				CF.Tile.FAKE:
					col = Color("#3a3f44")   # false walls look like rock on the map too
				_:
					if c >= CF.Tile.DOOR1:
						col = Color("#7bdc6a") if not m.is_solid(c) else Color("#ff8a3a")
					elif ty >= CF.SURFACE:
						var a := m.area_of_tile(tx, ty)
						col = Color(a[6]).lightened(0.12) if a.size() > 6 and a[0] != "" else Color("#1b2124")
					else:
						col = Color(m.theme["sky"][1]).darkened(0.2)
			img.set_pixel(tx, ty, col)
	_tex = ImageTexture.create_from_image(img)


func _map_rect() -> Rect2:
	var pad := Vector2(24, 56)
	var avail := size - pad * 2
	var k := minf(avail.x / CF.GW, avail.y / CF.GH)
	var sz := Vector2(CF.GW, CF.GH) * k
	return Rect2((size - sz) / 2 + Vector2(0, 16), sz)


func _to_screen(r: Rect2, world: Vector2) -> Vector2:
	return r.position + world / CF.T * (r.size.x / CF.GW)


func _draw() -> void:
	if m == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.06, 0.07, 0.92))
	var r := _map_rect()
	draw_rect(r.grow(6), Color("#0e2f33"))
	draw_texture_rect(_tex, r, false)
	draw_rect(r.grow(6), Color("#f2c14e", 0.5), false, 2.0)
	_text(Vector2(size.x / 2, 34), m.map_name, 22, Color("#f2c14e"))
	# areas
	for a in m.areas:
		if a[0] == "":
			continue
		var c := _to_screen(r, Vector2((a[1] + a[3] + 1) / 2.0, (a[2] + a[4] + 1) / 2.0) * CF.T)
		var hl: bool = bounty_areas.has(a[0])
		_text(c, a[0], 15 if a[4] < CF.SURFACE else 11, Color("#ffe08a") if hl else Color("#fff6df", 0.8), 4)
		if hl:
			_text(c + Vector2(0, 16), "bounty", 11, Color("#ffe08a"), 3)
	var pulse := 0.5 + 0.5 * sin(_now * 6)
	# skyship and checkpoints
	var ship := _to_screen(r, m.spots["vault"])
	draw_circle(ship + Vector2(0, -6), 7, Color("#f2c14e"))
	_text(ship + Vector2(0, -16), "Skyship", 11, Color("#f2c14e"), 3)
	for cp in m.cps:
		var p := _to_screen(r, cp["pos"])
		draw_rect(Rect2(p + Vector2(-1, -9), Vector2(2, 9)), Color("#fff6df", 0.8))
		draw_rect(Rect2(p + Vector2(1, -9), Vector2(6, 4)), Color("#f2c14e") if cp["on"] else Color("#8a8f96"))
	# shortcut levers not yet pulled
	for i in m.spots["levers"].size():
		if not m.mech["doors"][i]:
			var lp := _to_screen(r, m.spots["levers"][i])
			draw_circle(lp + Vector2(0, -4), 4, Color("#ff8a3a"))
	# big Sunstone still out there
	for it in m.items:
		if it.gone or it.empty or not (it.kind in ["relic", "cache", "idol"]):
			continue
		var ip := _to_screen(r, Vector2(it.x, it.y))
		var s := 5.0 if it.kind != "idol" else 7.0
		draw_colored_polygon(PackedVector2Array([ip + Vector2(0, -s), ip + Vector2(s, 0), ip + Vector2(0, s), ip + Vector2(-s, 0)]), Color("#ffb347"))
	# veins: surging ones pulse
	for v in m.veins:
		if v["broken_until"] > m.t:
			continue
		var vp := _to_screen(r, v["pos"])
		if v["surge_until"] > m.t:
			draw_circle(vp + Vector2(0, -4), 6 + 4 * pulse, Color("#ffe08a", 0.6))
			_text(vp + Vector2(0, -14), "SURGE", 11, Color("#ffe08a"), 3)
		draw_circle(vp + Vector2(0, -4), 3.5 if v["great"] else 2.5, Color("#5fd0e8"))
	# active sabotage
	var red := Color("#ff5d4a")
	if m.mech["breach"]["active"]:
		for i in m.spots["valves"].size():
			if not m.mech["breach"]["sw"][i]:
				draw_circle(_to_screen(r, m.spots["valves"][i]) + Vector2(0, -4), 5 + 3 * pulse, red)
	if m.mech["bridge"]["state"] == "down":
		_text(_to_screen(r, m.spots["lever"]) + Vector2(0, -8), "!", 18, red, 3)
	if m.find_mover("lift").jammed:
		_text(_to_screen(r, m.spots["gear"]) + Vector2(0, -8), "!", 18, red, 3)
	# you
	if me:
		var mp := _to_screen(r, Vector2(me.x + me.w / 2, me.y + me.h / 2))
		draw_circle(mp, 9 + 3 * pulse, Color(me.color, 0.35))
		draw_circle(mp, 5, me.color)
		draw_arc(mp, 5, 0, TAU, 16, Color.WHITE, 1.5)
		_text(mp + Vector2(0, -12), "You", 12, Color.WHITE, 3)
	_text(Vector2(size.x / 2, size.y - 16), "Other explorers aren't shown. Tap anywhere or press M to close.", 13, Color("#fff6df", 0.7))


func _text(pos: Vector2, s: String, sz: int, col: Color, outline := 0) -> void:
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var p := pos - Vector2(w / 2.0, 0)
	if outline > 0:
		draw_string_outline(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, outline, Color(0, 0, 0, 0.8))
	draw_string(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)
