class_name CFWorldView
extends Node2D
## Draws a CFMatch: procedural placeholder art in the target palette (final art replaces it later).
## Layers, back to front: sky (CanvasLayer), ship, tile chunks (drawn once), room props (drawn once),
## world, additive glows, front (water, false walls, labels).

const T := CF.T
const CHUNK := 8

const C_EARTH := Color("#3d2b22")
const C_EARTH2 := Color("#33241d")
const C_SOIL := Color("#4a3428")
const C_GRASS := Color("#5fae4a")
const C_GRASS_D := Color("#3f7d33")
const C_GRASS2 := Color("#86d45c")
const C_STONE := Color("#56606e")
const C_STONE2 := Color("#465060")
const C_MOSS := Color("#4f8a46")
const C_PLANK := Color("#9a6b3f")
const C_PLANK2 := Color("#6e4a29")
const C_GOLD := Color("#f2c14e")
const C_AMBER := Color("#ffb347")
const C_VIOLET := Color("#9b6bff")
const C_RED := Color("#ff5d4a")
const C_INK := Color("#fff6df")


var m: CFMatch
var me: CFPlayer
var act := {}
var hold_frac := 0.0
var shake := 0.0
var parts: Array = []
var glows: Array = []      # [pos, radius, color, alpha]

var cam: Camera2D
var _sky_layer: CanvasLayer
var _sky: Node2D
var _ship: Node2D
var _chunks: Node2D
var _world: Node2D
var _glow: Node2D
var _front: Node2D
var _glow_tex: GradientTexture2D
var _font: Font
var _ship_k := 0.0
var _won_t := -1.0
var _now := 0.0
var _flies: Array = []
var mover_draw := {}       # mover id → Vector2 (interpolated by the client)
var _anchor_y := 0.0       # camera's vertical anchor: follows the ground you stand on, not every jump
var _back := {}            # Vector2i → true for cave/indoor cells that get a back wall
var _decor: Node2D
var _decor_glows: Array = []   # [pos, radius, colour, alpha, flicker]
var _water: Array = []         # [Rect2] flooded strips


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_glow_tex = GradientTexture2D.new()
	_glow_tex.width = 64
	_glow_tex.height = 64
	_glow_tex.fill = GradientTexture2D.FILL_RADIAL
	_glow_tex.fill_from = Vector2(0.5, 0.5)
	_glow_tex.fill_to = Vector2(1.0, 0.5)
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 1))
	gr.set_color(1, Color(1, 1, 1, 0))
	gr.add_point(0.3, Color(1, 1, 1, 0.35))
	_glow_tex.gradient = gr

	_sky_layer = CanvasLayer.new()
	_sky_layer.layer = -10
	add_child(_sky_layer)
	_sky = _layer(_sky_layer, _draw_sky)
	_ship = _layer(self, _draw_ship)
	_chunks = Node2D.new()
	add_child(_chunks)
	_decor = _layer(self, _draw_decor)
	_world = _layer(self, _draw_world)
	_glow = _layer(self, _draw_glows)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = mat
	_front = _layer(self, _draw_front)

	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	for i in 36:
		_flies.append([_h(i, 7), _h(i, 9), 0.3 + _h(i, 3) * 0.7, _h(i, 5) * TAU])


func _layer(parent: Node, fn: Callable) -> Node2D:
	var n := Node2D.new()
	parent.add_child(n)
	n.draw.connect(fn.bind(n))
	return n


## Deterministic visual hash in 0..1 (art variation only).
static func _h(a: int, b: int) -> float:
	var x := (a * 374761393 + b * 668265263) & 0xffffffff
	x = ((x ^ (x >> 13)) * 1274126177) & 0xffffffff
	return float((x ^ (x >> 16)) & 0xffff) / 65535.0


func set_match(match_view: CFMatch) -> void:
	m = match_view
	_ship_k = 0.0
	_won_t = -1.0
	parts.clear()
	mover_draw.clear()
	for c in _chunks.get_children():
		c.queue_free()
	if m == null:
		return
	# cells that show a cave wall behind them: underground, or under a roof
	_back.clear()
	for ty in CF.GH:
		for tx in CF.GW:
			if m.tile_at(tx, ty) == CF.Tile.SOLID:
				continue
			var roofed := ty >= CF.SURFACE
			for k in range(1, 5):
				if m.tile_at(tx, ty - k) == CF.Tile.SOLID:
					roofed = true
					break
			if roofed:
				_back[Vector2i(tx, ty)] = true
	for cy in ceili(CF.GH / float(CHUNK)):
		for cx in ceili(CF.GW / float(CHUNK)):
			var n := Node2D.new()
			n.position = Vector2(cx * CHUNK * T, cy * CHUNK * T)
			_chunks.add_child(n)
			n.draw.connect(_draw_chunk.bind(n, cx, cy))
			n.queue_redraw()
	_prepare_decor()
	_decor.queue_redraw()
	if me:
		_anchor_y = me.y
		cam.position = Vector2(me.x, me.y - 84)
	cam.reset_smoothing()


func _process(delta: float) -> void:
	_now += delta
	if m == null:
		return
	var vp := get_viewport_rect().size
	var z := minf(vp.y / (15.0 * T), vp.x / (21.0 * T))
	cam.zoom = Vector2(z, z)
	var focus: CFPlayer = me if me else (m.players[0] if m.players.size() > 0 else null)
	if focus:
		# Vertical: follow the ledge you stand on, so jumps don't bob the screen; follow falls and climbs.
		if focus.on_ground or focus.climbing or focus.recover_t > 0.0 or focus.y > _anchor_y + 0.5 * T:
			_anchor_y = focus.y
		elif focus.y < _anchor_y - 4.5 * T:
			_anchor_y = focus.y + 4.5 * T
		var look := clampf(focus.vx * 0.35, -110, 110)
		var target := Vector2(focus.x + focus.w / 2 + look, _anchor_y - 84)
		# frame-rate independent smoothing
		cam.position.x += (target.x - cam.position.x) * (1.0 - exp(-delta * 6.0))
		cam.position.y += (target.y - cam.position.y) * (1.0 - exp(-delta * 4.0))
	var half := vp / z / 2.0
	cam.position.x = clampf(cam.position.x, half.x, CF.GW * T - half.x)
	cam.position.y = clampf(cam.position.y, half.y - 96, CF.GH * T - half.y)
	shake = maxf(0.0, shake - delta * 30.0)
	cam.offset = Vector2(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5)) * shake if shake > 0.0 else Vector2.ZERO
	var flying := m.phase == "escape" or m.phase == "won"
	_ship_k = move_toward(_ship_k, 1.0 if flying else 0.0, delta * 0.6)
	if m.phase == "won" and _won_t < 0:
		_won_t = _now
	for i in range(parts.size() - 1, -1, -1):
		var q: Dictionary = parts[i]
		q["life"] -= delta
		if q["life"] <= 0:
			parts.remove_at(i)
			continue
		q["vel"].y += q["grav"] * delta
		q["pos"] += q["vel"] * delta
	_collect_glows()
	_sky.queue_redraw()
	_ship.queue_redraw()
	_world.queue_redraw()
	_glow.queue_redraw()
	_front.queue_redraw()


func redraw_tiles() -> void:
	for c in _chunks.get_children():
		c.queue_redraw()


# ---------------------------------------------------------------- effects API

func burst(pos: Vector2, n: int, col: Color, up := false, speed := 120.0, life := 0.6, grav := 400.0) -> void:
	for i in n:
		var a := -PI / 2 + randf_range(-1.0, 1.0) if up else randf() * TAU
		var sp := speed * randf_range(0.4, 1.2)
		parts.append({"pos": pos, "vel": Vector2(cos(a), sin(a)) * sp, "life": life, "max": life, "col": col, "size": 3.0, "grav": grav, "text": ""})


func float_text(pos: Vector2, text: String, col: Color) -> void:
	parts.append({"pos": pos, "vel": Vector2(0, -50), "life": 1.1, "max": 1.1, "col": col, "size": 14.0, "grav": 0.0, "text": text})


# ---------------------------------------------------------------- helpers

func _ell(n: CanvasItem, c: Vector2, rx: float, ry: float, col: Color, rot := 0.0) -> void:
	rx = maxf(rx, 0.8)
	ry = maxf(ry, 0.8)
	var pts := PackedVector2Array()
	for i in 18:
		var a := TAU * i / 18.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry).rotated(rot))
	n.draw_colored_polygon(pts, col)


func _tri(n: CanvasItem, a: Vector2, b: Vector2, c: Vector2, col: Color) -> void:
	if absf((b - a).cross(c - a)) < 0.01:
		return
	n.draw_colored_polygon(PackedVector2Array([a, b, c]), col)


func _poly(n: CanvasItem, pts: Array, col: Color) -> void:
	n.draw_colored_polygon(PackedVector2Array(pts), col)


func _bez(p0: Vector2, p1: Vector2, p2: Vector2, steps := 10) -> Array:
	var out: Array = []
	for i in steps + 1:
		var t := i / float(steps)
		out.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))
	return out


func _text(n: CanvasItem, pos: Vector2, s: String, size: int, col: Color, outline := 0) -> void:
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var p := pos - Vector2(w / 2.0, 0)
	if outline > 0:
		n.draw_string_outline(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(0, 0, 0, 0.65))
	n.draw_string(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _glow_at(pos: Vector2, r: float, col: Color, a := 1.0) -> void:
	glows.append([pos, r, col, a])


# ---------------------------------------------------------------- sky (screen space)

func _draw_sky(n: Node2D) -> void:
	var vp := get_viewport_rect().size
	var z := cam.zoom.x
	var left := cam.position.x - vp.x / z / 2.0
	# Far layers barely move vertically (tiny parallax), so jumping and lifts never jerk the backdrop.
	var lift := clampf((CF.SURFACE * T - cam.position.y) * z * 0.06, -vp.y * 0.25, vp.y * 0.25)
	var th: Dictionary = m.theme if m else {}
	var sky: Array = th.get("sky", ["#0c2b3a", "#245a57", "#c98f4e", "#f0c46a"])
	var hills: Array = th.get("hills", ["#1d4a4e", "#16393b", "#10302f"])
	var cols := [Color(sky[0]), Color(sky[1]), Color(sky[2]), Color(sky[3])]
	var stops := [0.0, 0.45, 0.78, 1.0]
	for i in 3:
		var y0: float = vp.y * stops[i]
		var y1: float = vp.y * stops[i + 1]
		n.draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(vp.x, y0), Vector2(vp.x, y1), Vector2(0, y1)]),
			PackedColorArray([cols[i], cols[i], cols[i + 1], cols[i + 1]]))
	n.draw_texture_rect(_glow_tex, Rect2(vp.x * 0.72 - vp.y * 0.5, vp.y * 0.62 - vp.y * 0.5 + lift, vp.y, vp.y), false, Color(Color(th.get("sun", "#ffd38a")), 0.5))
	var skyline: String = th.get("skyline", "ruins")
	_hills(n, vp, left * 0.12, vp.y * 0.58 + lift * 0.5, 70 * z, Color(hills[0]), 24.0, z, "")
	_hills(n, vp, left * 0.25, vp.y * 0.70 + lift * 0.8, 120 * z, Color(hills[1]), 12.0 if skyline != "ruins" else 30.0, z, skyline)
	_hills(n, vp, left * 0.45, vp.y * 0.84 + lift, 60 * z, Color(hills[2]), 20.0, z, "")
	for f in _flies:
		var x := fposmod(f[0] * vp.x - left * z * 0.6 * f[2] + sin(_now * 0.5 + f[3]) * 30, vp.x)
		var y: float = f[1] * vp.y * 0.8 + sin(_now * 0.7 + f[3] * 2) * 20
		var a := 0.35 + 0.35 * sin(_now * 3 + f[3])
		n.draw_texture_rect(_glow_tex, Rect2(x - 7 * f[2] * 2, y - 7 * f[2] * 2, 28 * f[2], 28 * f[2]), false, Color(Color(th.get("flies", "#d8ff8a")), a * 0.6))


func _hills(n: Node2D, vp: Vector2, off: float, base: float, amp: float, col: Color, step: float, z: float, style: String) -> void:
	## style: "" rolling hills, "ruins" broken walls, "mine" headframes and spoil heaps, "trees" dead trees
	var pts := PackedVector2Array([Vector2(0, vp.y)])
	var sx := -step
	while sx <= vp.x / z + step:
		var wx := sx + off
		var y: float
		if style == "ruins":
			var i := int(floor(wx / 90.0))
			y = base - (amp * (0.6 + _h(i, 13)) if _h(i, 11) > 0.62 else amp * 0.25 * _h(i, 17))
		elif style == "mine":
			var i := int(floor(wx / 160.0))
			var fx := fposmod(wx, 160.0) / 160.0
			var heap := amp * 0.45 * maxf(0.0, 1.0 - absf(fx - 0.5) * 2.2) * (0.5 + _h(i, 5))
			var tower := amp * (1.3 + 0.4 * _h(i, 9)) if _h(i, 7) > 0.55 and absf(fx - 0.3) < 0.035 else 0.0
			y = base - maxf(heap, tower) - amp * 0.08
		elif style == "trees":
			var i := int(floor(wx / 46.0))
			var fx := fposmod(wx, 46.0) / 46.0
			var tall := amp * (0.5 + 0.9 * _h(i, 3)) if _h(i, 4) > 0.35 else 0.0
			y = base - amp * 0.18 - tall * maxf(0.0, 1.0 - absf(fx - 0.5) * 5.0)
		else:
			y = base - amp * (0.55 * sin(wx * 0.004) + 0.3 * sin(wx * 0.011 + 1) + 0.15 * sin(wx * 0.031))
		pts.append(Vector2(sx * z, y))
		sx += step
	pts.append(Vector2(vp.x, vp.y))
	n.draw_colored_polygon(pts, col)


# ---------------------------------------------------------------- tiles (drawn once per chunk)

func _draw_chunk(n: Node2D, cx: int, cy: int) -> void:
	if m == null:
		return
	var o := Vector2(cx * CHUNK * T, cy * CHUNK * T)
	for ty in range(cy * CHUNK, mini((cy + 1) * CHUNK, CF.GH)):
		for tx in range(cx * CHUNK, mini((cx + 1) * CHUNK, CF.GW)):
			var p := Vector2(tx * T, ty * T) - o
			if _back.has(Vector2i(tx, ty)):
				_back_wall(n, tx, ty, p)
			var c := m.tile_at(tx, ty)
			if c == CF.Tile.SOLID or c == CF.Tile.PLANK or c == CF.Tile.SPIKE or c == CF.Tile.LADDER:
				_tile(n, c, tx, ty, p)


func _back_wall(n: CanvasItem, tx: int, ty: int, p: Vector2) -> void:
	var a := m.area_of_tile(tx, ty)
	var base: Color = Color(a[6]) if a.size() > 6 else Color("#22201c")
	var pattern: String = a[7] if a.size() > 7 else "rock"
	var h := _h(tx, ty)
	var dark := base.darkened(0.25)
	var lite := base.lightened(0.08)
	n.draw_rect(Rect2(p, Vector2(T, T)), base)
	match pattern:
		"brick", "gold":
			var line := Color("#a07a2a", 0.55) if pattern == "gold" else dark
			n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 2)), line)
			n.draw_rect(Rect2(p + Vector2(0, 31), Vector2(T, 1)), line)
			n.draw_rect(Rect2(p + Vector2(8 if ty % 2 else 24, 0), Vector2(2, 15)), line)
			n.draw_rect(Rect2(p + Vector2(24 if ty % 2 else 8, 17), Vector2(2, 14)), line)
			if h > 0.8:
				n.draw_rect(Rect2(p + Vector2(11, 3), Vector2(10, 10)), lite)
		"plank":
			for bx in [0, 11, 22]:
				n.draw_rect(Rect2(p + Vector2(bx, 0), Vector2(1, T)), dark)
			n.draw_rect(Rect2(p + Vector2(4 + int(h * 3) * 11, 6), Vector2(2, 2)), lite.lightened(0.15))
			if h > 0.85:
				n.draw_rect(Rect2(p + Vector2(0, 20), Vector2(T, 3)), dark)
		"tile":
			var chk := (tx + ty) % 2 == 0
			n.draw_rect(Rect2(p, Vector2(16, 16)), lite if chk else base)
			n.draw_rect(Rect2(p + Vector2(16, 16), Vector2(16, 16)), lite if chk else base)
			n.draw_rect(Rect2(p, Vector2(T, 1)), dark)
			n.draw_rect(Rect2(p, Vector2(1, T)), dark)
		"glass":
			n.draw_rect(Rect2(p + Vector2(2, 2), Vector2(T - 4, T - 4)), Color(0.55, 0.85, 0.7, 0.10))
			n.draw_rect(Rect2(p, Vector2(T, 2)), dark)
			n.draw_rect(Rect2(p, Vector2(2, T)), dark)
			if h > 0.7:
				n.draw_line(p + Vector2(6, 26), p + Vector2(16, 8), Color(1, 1, 1, 0.12), 2.0)
		"skulls":
			n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 1)), dark)
			if h > 0.72:
				var c := p + Vector2(10 + h * 12, 12 + h * 8)
				n.draw_circle(c, 5, Color("#cfc6b0", 0.35))
				n.draw_rect(Rect2(c + Vector2(-3, -1), Vector2(2, 2)), Color(0, 0, 0, 0.5))
				n.draw_rect(Rect2(c + Vector2(1, -1), Vector2(2, 2)), Color(0, 0, 0, 0.5))
		"crystal":
			n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 1)), dark)
			if h > 0.82:
				_tri(n, p + Vector2(10, 24), p + Vector2(14, 8), p + Vector2(18, 24), Color("#5fd0e8", 0.45))
				_tri(n, p + Vector2(15, 24), p + Vector2(19, 14), p + Vector2(22, 24), Color("#a98bff", 0.35))
		"moss":
			n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 1)), dark)
			if h > 0.55:
				_ell(n, p + Vector2(8 + h * 16, 24), 7, 4, Color("#4f8a46", 0.35))
			if h > 0.9:
				n.draw_circle(p + Vector2(20, 10), 2, Color("#9fffd0", 0.4))
		"roots":
			if h > 0.45:
				var x0 := p.x + 4 + h * 22
				n.draw_polyline(PackedVector2Array(_bez(Vector2(x0, p.y), Vector2(x0 - 8, p.y + 14), Vector2(x0 + 2, p.y + T))), Color("#4a3a22", 0.7), 2.0)
			if h > 0.85:
				_ell(n, p + Vector2(16, 20), 4, 2, Color("#7ad06a", 0.3))
		"bark":
			for bx in [3, 13, 24]:
				n.draw_rect(Rect2(p + Vector2(bx + int(h * 3), 0), Vector2(2, T)), dark)
			if h > 0.8:
				_ell(n, p + Vector2(16, 16), 5, 7, dark.darkened(0.2))
		_:
			n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 1)), dark)
			if h > 0.6:
				n.draw_rect(Rect2(p + Vector2(4 + h * 14, 4 + h * 10), Vector2(6, 3)), lite)


func _tile(n: CanvasItem, c: int, tx: int, ty: int, p: Vector2) -> void:
	var h := _h(tx, ty)
	var above := m.tile_at(tx, ty - 1)
	var open_above := above != CF.Tile.SOLID and above != CF.Tile.FAKE and above < CF.Tile.DOOR1
	if c == CF.Tile.SOLID:
		if ty >= CF.SURFACE or not _back.has(Vector2i(tx, ty + 1)) and ty >= CF.SURFACE - 1:
			var ar := m.area_of_tile(tx, ty)
			var rock: Color = Color(ar[5]) if ar.size() > 5 else C_EARTH
			n.draw_rect(Rect2(p, Vector2(T, T)), C_SOIL if (ty == CF.SURFACE and open_above) else rock)
			n.draw_rect(Rect2(p + Vector2(int(h * 20), 8 + int(h * 13)), Vector2(6, 4)), rock.darkened(0.2))
			if h > 0.7:
				_ell(n, p + Vector2(10 + h * 10, 18), 4, 3, rock.lightened(0.12))
			if ar.size() > 7 and ar[7] == "crystal" and h > 0.82:
				_tri(n, p + Vector2(8, 24), p + Vector2(12, 8), p + Vector2(16, 24), Color("#5fd0e8"))
		else:
			n.draw_rect(Rect2(p, Vector2(T, T)), C_STONE)
			n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 2)), C_STONE2)
			n.draw_rect(Rect2(p + Vector2(8 if ty % 2 else 22, 0), Vector2(2, 15)), C_STONE2)
			n.draw_rect(Rect2(p + Vector2(22 if ty % 2 else 8, 17), Vector2(2, 15)), C_STONE2)
			if h > 0.55:
				n.draw_rect(Rect2(p + Vector2(h * 14, 26), Vector2(12, 6)), C_MOSS)
		if open_above:
			var underground := ty > CF.SURFACE
			var gr: Array = m.theme.get("grass", ["#3f7d33", "#5fae4a", "#86d45c"])
			n.draw_rect(Rect2(p, Vector2(T, 8)), Color(gr[0]).darkened(0.35) if underground else Color(gr[0]))
			n.draw_rect(Rect2(p, Vector2(T, 6)), Color(gr[1]).darkened(0.25) if underground else Color(gr[1]))
			if not underground:
				for i in 3:
					var gx := p.x + 4 + i * 10 + h * 4
					_tri(n, Vector2(gx, p.y), Vector2(gx + 2, p.y - 5 - h * 4), Vector2(gx + 4, p.y), Color(gr[2]))
		if m.tile_at(tx, ty + 1) != CF.Tile.SOLID and h > 0.4 and ty < CF.SURFACE + 30:
			n.draw_polyline(PackedVector2Array(_bez(p + Vector2(6 + h * 18, T), p + Vector2(2 + h * 18, T + 14), p + Vector2(8 + h * 18, T + 20 + h * 14))), Color("#3f8a3a"), 2.0)
	elif c == CF.Tile.PLANK:
		n.draw_rect(Rect2(p + Vector2(0, 2), Vector2(T, 10)), C_PLANK2)
		n.draw_rect(Rect2(p, Vector2(T, 8)), C_PLANK)
		n.draw_rect(Rect2(p + Vector2(4, 3), Vector2(2, 2)), Color("#d9b27a"))
		n.draw_rect(Rect2(p + Vector2(T - 7, 3), Vector2(2, 2)), Color("#d9b27a"))
		var l := m.tile_at(tx - 1, ty)
		var r := m.tile_at(tx + 1, ty)
		if l != CF.Tile.PLANK or r != CF.Tile.PLANK:
			n.draw_rect(Rect2(p + Vector2(4 if l != CF.Tile.PLANK else T - 8, 10), Vector2(4, 14)), C_PLANK2)
	elif c == CF.Tile.SPIKE:
		n.draw_rect(Rect2(p + Vector2(0, 28), Vector2(T, 4)), Color("#2c2f38"))
		for i in 4:
			_tri(n, p + Vector2(i * 8, 30), p + Vector2(i * 8 + 4, 14), p + Vector2(i * 8 + 8, 30), Color("#c9d1dc"))
	elif c == CF.Tile.LADDER:
		_ladder(n, p, m.tile_at(tx, ty - 1) != CF.Tile.LADDER)


func _ladder(n: CanvasItem, p: Vector2, top: bool) -> void:
	var wood := Color("#b0814a")
	n.draw_rect(Rect2(p + Vector2(6, -4 if top else 0), Vector2(4, T + (4 if top else 0))), wood.darkened(0.2))
	n.draw_rect(Rect2(p + Vector2(22, -4 if top else 0), Vector2(4, T + (4 if top else 0))), wood.darkened(0.2))
	for k in 4:
		n.draw_rect(Rect2(p + Vector2(8, 3 + k * 8), Vector2(16, 3)), wood)


# ---------------------------------------------------------------- skyship (behind tiles)

func _ship_geometry() -> Array:
	var v: Vector2 = m.spots["vault"]
	var deck: Vector2 = m.spots["deck"]
	var e := _ship_k * _ship_k * (3 - 2 * _ship_k)
	var ground_deck := v.y - 56.0
	var cx := lerpf(v.x, deck.x, e)
	var dy := lerpf(ground_deck, deck.y, e) + sin(_now * 2) * 3 * _ship_k
	if _won_t >= 0:
		dy -= pow(_now - _won_t, 2) * 60
	return [cx, dy, e]


func _draw_ship(n: Node2D) -> void:
	if m == null:
		return
	var g := _ship_geometry()
	var cx: float = g[0]
	var deck_y: float = g[1]
	var e: float = g[2]
	var frac := minf(1.0, m.deposited / float(maxi(1, m.target)))
	var breach: bool = m.mech["breach"]["active"]
	var inflate := maxf(frac * 0.85, e)
	var ry := 14 + 44 * inflate
	var rx := 92 + 30 * inflate
	var ecy := deck_y - 24 - ry - 20 * inflate
	for k in [-80, -30, 30, 80]:
		n.draw_line(Vector2(cx + k, deck_y), Vector2(cx + k * 0.7, ecy + ry * 0.75), Color("#4b3424"), 2.0)
	var cols := [Color("#a8402f"), Color("#d9a23c"), Color("#c9473b"), Color("#f2c14e"), Color("#c9473b")]
	for i in 5:
		var c: Color = cols[i]
		c.a = 0.55 + 0.45 * inflate
		_ell(n, Vector2(cx, ecy), maxf(4.0, rx - i * rx / 5.0), ry, c)
	_ell(n, Vector2(cx - rx * 0.35, ecy - ry * 0.4), rx * 0.25, ry * 0.25, Color(1, 1, 1, 0.12), -0.4)
	# propeller
	n.draw_set_transform(Vector2(cx - 120, deck_y + 22), _now * (20.0 if _ship_k > 0 else 0.6), Vector2.ONE)
	n.draw_rect(Rect2(-3, -18, 6, 36), Color("#9aa3ad"))
	n.draw_rect(Rect2(-18, -3, 36, 6), Color("#9aa3ad"))
	n.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	# hull
	var hull: Array = [Vector2(cx - 114, deck_y), Vector2(cx + 118, deck_y)]
	hull.append_array(_bez(Vector2(cx + 118, deck_y), Vector2(cx + 104, deck_y + 56), Vector2(cx + 40, deck_y + 56), 6))
	hull.append(Vector2(cx - 64, deck_y + 56))
	hull.append_array(_bez(Vector2(cx - 64, deck_y + 56), Vector2(cx - 114, deck_y + 50), Vector2(cx - 114, deck_y + 1), 6))
	_poly(n, hull, Color("#6e4325"))
	n.draw_line(Vector2(cx - 110, deck_y + 18), Vector2(cx + 112, deck_y + 18), Color("#563520"), 2.0)
	n.draw_line(Vector2(cx - 100, deck_y + 37), Vector2(cx + 100, deck_y + 37), Color("#563520"), 2.0)
	n.draw_rect(Rect2(cx - 116, deck_y - 4, 236, 5), Color("#c99a3c"))
	n.draw_rect(Rect2(cx - 116, deck_y - 16, 236, 3), Color("#c99a3c"))
	for i in range(-100, 101, 25):
		n.draw_rect(Rect2(cx + i, deck_y - 14, 3, 12), Color("#c99a3c"))
	# furnace: the loading point, brighter as the charge rises
	var fy := deck_y + 28
	n.draw_circle(Vector2(cx, fy), 18, Color("#2a2e38"))
	var fc := C_RED if breach else C_AMBER
	fc.a = 0.35 + 0.65 * frac
	n.draw_circle(Vector2(cx, fy), 12, fc)
	n.draw_arc(Vector2(cx, fy), 18, 0, TAU, 32, C_RED if breach else C_GOLD, 3.0)
	if frac > 0:
		n.draw_arc(Vector2(cx, fy), 24, -PI / 2, -PI / 2 + TAU * frac, 48, C_GOLD, 4.0)
	# crown on the bow
	var bx := cx + 92
	var by := deck_y + 30
	_poly(n, [Vector2(bx - 10, by + 6), Vector2(bx - 10, by - 4), Vector2(bx - 5, by + 1), Vector2(bx, by - 7), Vector2(bx + 5, by + 1), Vector2(bx + 10, by - 4), Vector2(bx + 10, by + 6)], C_GOLD)
	if m.phase == "escape":
		_text(n, Vector2(cx, ecy - ry - 12), "ALL ABOARD!", 14, C_INK, 4)


# ---------------------------------------------------------------- world layer

func _draw_world(n: Node2D) -> void:
	if m == null:
		return
	_draw_camp(n)
	_draw_mechanisms(n)
	_draw_veins(n)
	_draw_items(n)
	for p in m.players:
		if me == null or p.id != me.id:
			_draw_player(n, p, false)
	if me:
		_draw_player(n, me, true)


func _draw_camp(n: Node2D) -> void:
	var v: Vector2 = m.spots["vault"]
	var gy := v.y
	for tent in [[v.x - 9 * T, Color("#a2553a")], [v.x + 14 * T, Color("#3f6e8c")]]:
		var x: float = tent[0]
		_tri(n, Vector2(x - 60, gy), Vector2(x, gy - 70), Vector2(x + 60, gy), tent[1])
		_tri(n, Vector2(x - 12, gy), Vector2(x, gy - 40), Vector2(x + 12, gy), Color(0, 0, 0, 0.35))
		n.draw_line(Vector2(x, gy - 70), Vector2(x, gy - 82), Color("#3b2a1c"), 3.0)
		n.draw_rect(Rect2(x, gy - 82, 14, 8), C_GOLD)
	var fx := v.x - 4.5 * T
	n.draw_rect(Rect2(fx - 14, gy - 5, 28, 5), Color("#5a3a22"))
	for i in 3:
		var hgt := 18 - i * 4 + sin(_now * 12 + i) * 3
		var flame := [Vector2(fx - 8 + i * 2, gy - 4)]
		flame.append_array(_bez(Vector2(fx - 8 + i * 2, gy - 4), Vector2(fx + sin(_now * 8 + i) * 3, gy - 4 - hgt * 2), Vector2(fx + 8 - i * 2, gy - 4), 6))
		_poly(n, flame, [Color("#ffcf5a"), Color("#ff8a2a"), Color("#ff5d2a")][i])
	# ledger board
	var b: Vector2 = m.spots["board"]
	n.draw_rect(Rect2(b.x - 4, b.y - 40, 8, 40), Color("#4b3424"))
	n.draw_rect(Rect2(b.x - 56, b.y - 104, 112, 68), Color("#6b4a30"))
	n.draw_rect(Rect2(b.x - 50, b.y - 98, 100, 56), Color("#2c3a33"))
	var rem := maxi(0, m.target - m.deposited)
	n.draw_string(_font, Vector2(b.x - 46, b.y - 85), "Charge %d / %d" % [m.deposited, m.target], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_INK)
	n.draw_string(_font, Vector2(b.x - 46, b.y - 72), "To go %d  ·  %s" % [rem, CFFormat.clock(m.time_left)], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_INK)
	for i in mini(2, m.recent.size()):
		var r: Dictionary = m.recent[i]
		n.draw_string(_font, Vector2(b.x - 46, b.y - 59 + i * 11), "%s +%d" % [str(r["by"]).substr(0, 12), r["n"]], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("#c8d6c0"))
	# valves
	var breach: bool = m.mech["breach"]["active"]
	for i in m.spots["valves"].size():
		var sw: Vector2 = m.spots["valves"][i]
		var on: bool = m.mech["breach"]["sw"][i]
		n.draw_rect(Rect2(sw.x - 10, sw.y - 22, 20, 22), Color("#3c4250"))
		var col := Color("#6a7380") if not breach else (Color("#7bdc6a") if on else C_RED)
		_poly(n, [Vector2(sw.x, sw.y - 44), Vector2(sw.x + 8, sw.y - 32), Vector2(sw.x, sw.y - 22), Vector2(sw.x - 8, sw.y - 32)], col)
		if breach:
			_text(n, Vector2(sw.x, sw.y - 50), str(i + 1), 11, Color.WHITE)
	if m.mode == "traitors":
		_draw_bell(n)


func _draw_bell(n: Node2D) -> void:
	## The meeting bell: a post with a brass bell that swings while a meeting is on.
	var bp: Vector2 = m.spots["bell"]
	var wood := Color("#4b3424")
	n.draw_rect(Rect2(bp.x - 3, bp.y - 58, 6, 58), wood)
	n.draw_rect(Rect2(bp.x - 3, bp.y - 58, 22, 5), wood)
	var swing := sin(_now * 14) * 0.5 if m.meeting["active"] else sin(_now * 1.5) * 0.06
	var pivot := Vector2(bp.x + 14, bp.y - 53)
	var body := []
	for pt in [Vector2(-5, 0), Vector2(5, 0), Vector2(10, 18), Vector2(-10, 18)]:
		body.append(pivot + pt.rotated(swing))
	_poly(n, body, Color("#d9a441"))
	n.draw_circle(pivot + Vector2(0, 20).rotated(swing), 3.0, Color("#8a5a1c"))
	if m.meeting["active"]:
		_glow_at(pivot + Vector2(0, 10), 40, Color("#ffd27a"), 0.6)


func _draw_mechanisms(n: Node2D) -> void:
	# rope bridge (tiles come from the map)
	var B: Dictionary = m.mech["bridge"]
	var bx0 := 1 << 30
	var bx1 := -1
	var by := 0
	for i in m.bridge_tiles.size():
		var bt: Vector2i = m.bridge_tiles[i]
		bx0 = mini(bx0, bt.x)
		bx1 = maxi(bx1, bt.x)
		by = bt.y
		var x := bt.x * T + 16.0
		var y := bt.y * T + 5.0
		var rot := 0.0
		var a := 1.0
		if B["state"] == "warn":
			y += sin(_now * 40 + i) * 2
		if B["state"] == "down":
			var dt: float = m.t - B["down_at"]
			if dt > 2.2:
				continue
			y += 0.5 * 1400 * dt * dt * (0.8 + _h(i, 1) * 0.4)
			rot = dt * (_h(i, 2) - 0.5) * 6
			a = maxf(0.0, 1 - dt / 2.2)
		n.draw_set_transform(Vector2(x, y), rot, Vector2.ONE)
		n.draw_rect(Rect2(-15, -3, 30, 10), Color(C_PLANK2, a))
		n.draw_rect(Rect2(-15, -5, 30, 8), Color(Color("#a77749") if i % 2 else C_PLANK, a))
	n.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	if bx1 >= 0:
		var l := Vector2(bx0 * T, by * T)
		var r := Vector2((bx1 + 1) * T, by * T)
		var rope := Color("#d9c39a")
		if B["state"] != "down":
			n.draw_polyline(PackedVector2Array(_bez(l + Vector2(0, -22), (l + r) / 2 + Vector2(0, -4), r + Vector2(0, -22))), rope, 2.0)
		else:
			n.draw_line(l + Vector2(0, -22), l + Vector2(6, 30), rope, 2.0)
			n.draw_line(r + Vector2(0, -22), r + Vector2(-6, 30), rope, 2.0)
		n.draw_rect(Rect2(l + Vector2(-4, -28), Vector2(6, 28)), Color("#5a3a22"))
		n.draw_rect(Rect2(r + Vector2(-2, -28), Vector2(6, 28)), Color("#5a3a22"))
	# bridge repair lever
	var lv: Vector2 = m.spots["lever"]
	var broken: bool = B["state"] == "down"
	_lever(n, lv, broken, C_RED if broken else C_GOLD)
	if broken:
		_rune(n, lv + Vector2(16, -30))
		_warn(n, lv + Vector2(0, -58))
		if B["repair"] > 0:
			n.draw_arc(lv + Vector2(0, -80), 8, -PI / 2, -PI / 2 + TAU * B["repair"] / CF.SAB["bridge"]["repair"], 24, C_GOLD, 3.0)
	# hidden trap plate
	var sp: Dictionary = m.mech["spikes"]
	for tt in m.trap_tiles:
		var p := Vector2(tt.x * T, tt.y * T)
		for k in 4:
			n.draw_rect(Rect2(p + Vector2(3 + k * 8, 30), Vector2(4, 2)), Color("#2b2f36"))
		if sp["state"] == "active":
			var rise := minf(1.0, (CF.SAB["spikes"]["dur"] - (sp["until"] - m.t)) * 8.0)
			for k in 4:
				_tri(n, p + Vector2(k * 8, 32), p + Vector2(k * 8 + 4, 32 - 18 * rise), p + Vector2(k * 8 + 8, 32), Color("#d0c4ff"))
	if sp["state"] == "active" and m.trap_tiles.size() > 0:
		var mid: Vector2i = m.trap_tiles[m.trap_tiles.size() / 2]
		_rune(n, Vector2(mid.x * T, mid.y * T - 12))
	# shortcut doors and their levers
	for d in m.door_tiles:
		var dp := Vector2(d[0].x * T, d[0].y * T)
		var open: bool = m.mech["doors"][d[1]]
		if open:
			n.draw_rect(Rect2(dp, Vector2(T, 4)), Color("#4b5563"))
			n.draw_rect(Rect2(dp + Vector2(0, T - 4), Vector2(T, 4)), Color("#4b5563"))
		else:
			n.draw_rect(Rect2(dp, Vector2(T, T)), Color("#4b5563"))
			n.draw_rect(Rect2(dp + Vector2(2, 2), Vector2(T - 4, T - 4)), Color("#6b7280"))
			for k in 4:
				n.draw_circle(dp + Vector2(6 + (k % 2) * 20, 6 + (k / 2) * 20), 2, Color("#9aa3ad"))
			n.draw_circle(dp + Vector2(16, 16), 5, Color("#c9473b"))
	for i in m.spots["levers"].size():
		var open2: bool = m.mech["doors"][i]
		_lever(n, m.spots["levers"][i], not open2, Color("#7bdc6a") if open2 else C_GOLD)
	# lift: chains to a frame above the shaft, and the repair gear
	var lift := m.find_mover("lift")
	var ld: Vector2 = mover_draw.get("lift", Vector2(lift.x, lift.y))
	var top_y := lift.min_pos - 2 * T
	n.draw_line(Vector2(ld.x + 10, top_y), Vector2(ld.x + 10, ld.y), Color("#7a6a52"), 2.0)
	n.draw_line(Vector2(ld.x + lift.w - 10, top_y), Vector2(ld.x + lift.w - 10, ld.y), Color("#7a6a52"), 2.0)
	n.draw_rect(Rect2(lift.x - 6, top_y - 10, lift.w + 12, 10), Color("#4b3424"))
	n.draw_rect(Rect2(lift.x - 6, top_y - 10, 6, 2 * T + 10), Color("#4b3424"))
	n.draw_rect(Rect2(lift.x + lift.w, top_y - 10, 6, 2 * T + 10), Color("#4b3424"))
	var gr: Vector2 = m.spots["gear"]
	n.draw_set_transform(gr + Vector2(0, -18), 0.2 if lift.jammed else _now * 2 * (0 if lift.paused > 0 else lift.dir), Vector2.ONE)
	var gc := Color("#7a6f88") if lift.jammed else Color("#b89a5a")
	for i in 8:
		n.draw_rect(Rect2(Vector2(-3, -16).rotated(i * PI / 4) - Vector2(3, 3), Vector2(6, 6)), gc)
	n.draw_circle(Vector2.ZERO, 12, gc)
	n.draw_circle(Vector2.ZERO, 4, Color("#3c2a1c"))
	n.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	if lift.jammed:
		_rune(n, gr + Vector2(22, -30))
		_warn(n, gr + Vector2(0, -50))
		var lr: float = m.mech["lift"]["repair"]
		if lr > 0:
			n.draw_arc(gr + Vector2(0, -72), 8, -PI / 2, -PI / 2 + TAU * lr / CF.SAB["lift"]["repair"], 24, C_GOLD, 3.0)
	# movers, at their interpolated positions
	for mv in m.movers:
		var md: Vector2 = mover_draw.get(mv.id, Vector2(mv.x, mv.y))
		if mv.kind == "h":
			n.draw_rect(Rect2(md, Vector2(mv.w, mv.h)), C_STONE2)
			n.draw_rect(Rect2(md, Vector2(mv.w, 6)), C_STONE)
			n.draw_rect(Rect2(md + Vector2(8, 0), Vector2(22, 4)), C_MOSS)
		else:
			n.draw_rect(Rect2(md, Vector2(mv.w, mv.h)), Color("#5b4a36"))
			n.draw_rect(Rect2(md, Vector2(mv.w, 4)), Color("#9aa3ad"))
	# checkpoints
	for cp in m.cps:
		var pos: Vector2 = cp["pos"]
		n.draw_rect(Rect2(pos.x - 2, pos.y - 56, 4, 56), Color("#5a3a22"))
		var wv := sin(_now * 5 + pos.x) * 3
		var flag := [Vector2(pos.x + 2, pos.y - 56)]
		flag.append_array(_bez(Vector2(pos.x + 2, pos.y - 56), Vector2(pos.x + 14, pos.y - 52 + wv), Vector2(pos.x + 26, pos.y - 50 + wv), 5))
		flag.append(Vector2(pos.x + 2, pos.y - 40))
		_poly(n, flag, C_GOLD if cp["on"] else Color("#8a8f96"))


func _lever(n: CanvasItem, at: Vector2, up: bool, knob: Color) -> void:
	n.draw_rect(Rect2(at.x - 10, at.y - 14, 20, 14), Color("#3c4250"))
	n.draw_set_transform(Vector2(at.x, at.y - 12), -0.5 if up else 0.9, Vector2.ONE)
	n.draw_rect(Rect2(-2, -26, 4, 26), Color("#9aa3ad"))
	n.draw_circle(Vector2(0, -27), 5, knob)
	n.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


func _rune(n: CanvasItem, p: Vector2) -> void:
	var c := Color("#d6c2ff")
	n.draw_line(p + Vector2(-5, 6), p + Vector2(0, -7), c, 1.5)
	n.draw_line(p + Vector2(0, -7), p + Vector2(5, 6), c, 1.5)
	n.draw_line(p + Vector2(-6, 0), p + Vector2(6, 0), c, 1.5)


func _warn(n: CanvasItem, p: Vector2) -> void:
	var s := 1 + 0.1 * sin(_now * 8)
	_tri(n, p + Vector2(0, -12) * s, p + Vector2(11, 8) * s, p + Vector2(-11, 8) * s, C_RED)
	n.draw_rect(Rect2(p + Vector2(-1.5, -5), Vector2(3, 8)), Color.WHITE)
	n.draw_rect(Rect2(p + Vector2(-1.5, 4), Vector2(3, 2.5)), Color.WHITE)


func _shard(n: CanvasItem, c: Vector2, sc: float, rot: float, c1: Color, c2: Color) -> void:
	var pts := [Vector2(0, -9), Vector2(5, -2), Vector2(3, 8), Vector2(-3, 8), Vector2(-5, -2)]
	var hi := [Vector2(0, -9), Vector2(2, -2), Vector2(0, 6), Vector2(-5, -2)]
	_poly(n, pts.map(func(v): return c + (v * sc).rotated(rot)), c1)
	_poly(n, hi.map(func(v): return c + (v * sc).rotated(rot)), c2)


func _draw_veins(n: Node2D) -> void:
	for v in m.veins:
		var base: Vector2 = v["pos"]
		var great: bool = v["great"]
		var sc := 1.6 if great else 1.0
		if not CFVeins.intact(m, v):
			# rubble, slowly regrowing
			var grow := clampf(1.0 - (v["broken_until"] - m.t) / CF.VEIN_REGROW, 0.0, 1.0)
			_ell(n, base + Vector2(0, -3), 14 * sc, 4, Color("#4a4f5a"))
			_shard(n, base + Vector2(-4, -6), 0.5 + 0.6 * grow, -0.3, Color("#3f8fa3", 0.6), Color("#9fe8ff", 0.6))
			continue
		var surge := CFVeins.surging(m, v)
		var crack: float = 1.0 - float(v["hp"]) / v["max_hp"]
		var c1 := Color("#2f9ec0")
		var c2 := Color("#bff3ff")
		if surge:
			var pulse := 0.5 + 0.5 * sin(_now * 8)
			c1 = Color("#ffb347").lerp(Color("#ffe08a"), pulse)
			c2 = Color("#fffbe8")
			for i in 10:
				var a := i * TAU / 10 + _now
				n.draw_line(base + Vector2(0, -22 * sc) + Vector2(cos(a), sin(a)) * 20 * sc, base + Vector2(0, -22 * sc) + Vector2(cos(a), sin(a)) * 30 * sc, Color("#ffe08a", 0.7), 2.0)
		# rock socket
		_ell(n, base + Vector2(0, -4), 16 * sc, 6, Color("#3c4250"))
		# crystals
		var shake_x := sin(_now * 60) * 1.5 if crack > 0 and fmod(_now, 0.6) < 0.08 else 0.0
		_shard(n, base + Vector2(-9 * sc + shake_x, -12 * sc), 1.2 * sc, -0.45, c1, c2)
		_shard(n, base + Vector2(9 * sc + shake_x, -11 * sc), 1.1 * sc, 0.4, c1, c2)
		_shard(n, base + Vector2(shake_x, -20 * sc), 1.6 * sc, 0.0, c1, c2)
		if v["tainted"]:
			# the only clue: a faint violet sheen and the odd violet glint
			_ell(n, base + Vector2(0, -16 * sc), 14 * sc, 16 * sc, Color("#9b6bff", 0.16))
			if fmod(_now + v["id"], 2.3) < 0.12:
				n.draw_circle(base + Vector2(5 * sc, -24 * sc), 2.0, Color("#d6c2ff"))
		# cracks grow as it's struck
		if crack > 0:
			var cc := Color("#1b1f2a", 0.9)
			n.draw_polyline(PackedVector2Array([base + Vector2(-2, -32 * sc), base + Vector2(2, -24 * sc), base + Vector2(-3, -16 * sc)]), cc, 1.5)
			if crack > 0.4:
				n.draw_polyline(PackedVector2Array([base + Vector2(-12 * sc, -18 * sc), base + Vector2(-8 * sc, -12 * sc), base + Vector2(-11 * sc, -6 * sc)]), cc, 1.5)
			if crack > 0.7:
				n.draw_polyline(PackedVector2Array([base + Vector2(11 * sc, -16 * sc), base + Vector2(7 * sc, -10 * sc), base + Vector2(10 * sc, -5 * sc)]), cc, 1.5)
		if great:
			_text(n, base + Vector2(16 * sc, -34 * sc), "x2", 10, C_INK, 3)


func _draw_items(n: Node2D) -> void:
	for it in m.items:
		if it.gone:
			continue
		var bob := sin(_now * 3 + it.ph) * 3
		var p := Vector2(it.x, it.y + bob)
		var age: float = m.t - it.born
		if age >= 0.0 and age < 0.5:
			# bursting out of a vein: an arc from the vein to where it lands
			var k: float = age / 0.5
			p = it.from.lerp(Vector2(it.x, it.y), k) - Vector2(0, sin(k * PI) * 40)
		match it.kind:
			"coin":
				_shard(n, p, 0.85, sin(_now * 2 + it.ph) * 0.25, Color("#e8892b"), Color("#ffd38a"))
			"bag":
				_ell(n, p + Vector2(0, 9), 12, 4, Color("#5b6372"))
				_shard(n, p + Vector2(-7, 2), 0.8, -0.4, Color("#d9792a"), Color("#ffc77a"))
				_shard(n, p + Vector2(7, 2), 0.8, 0.4, Color("#d9792a"), Color("#ffc77a"))
				_shard(n, p + Vector2(0, -2), 1.05, 0.0, Color("#e8892b"), Color("#ffd38a"))
				if it.value < it.max_value:
					_text(n, p + Vector2(0, -14), str(it.value), 9, C_INK)
			"chest":
				var q := Vector2(it.x, it.y + 2)
				n.draw_rect(Rect2(q + Vector2(-16, -6), Vector2(32, 20)), Color("#6e4325"))
				n.draw_rect(Rect2(q + Vector2(-16, 1), Vector2(32, 3)), Color("#c99a3c"))
				n.draw_rect(Rect2(q + Vector2(-2, -2), Vector2(4, 8)), Color("#c99a3c"))
				if it.opened:
					n.draw_rect(Rect2(q + Vector2(-16, -18), Vector2(32, 8)), Color("#8a5530"))
					if not it.empty:
						_ell(n, q + Vector2(0, -6), 12, 4, C_AMBER)
				else:
					var lid := [q + Vector2(-16, -6)]
					lid.append_array(_bez(q + Vector2(-16, -6), q + Vector2(0, -18), q + Vector2(16, -6), 6))
					_poly(n, lid, Color("#8a5530"))
				if not it.empty:
					_text(n, q + Vector2(0, -22), str(it.value), 9, C_INK)
			"relic":
				for i in 8:
					var a := i * PI / 4 + _now
					n.draw_line(p + Vector2(cos(a), sin(a)) * 15, p + Vector2(cos(a), sin(a)) * 21, Color(1, 0.83, 0.54, 0.6), 2.0)
				_poly(n, [p + Vector2(0, -13), p + Vector2(10, 0), p + Vector2(0, 13), p + Vector2(-10, 0)], Color("#e8892b"))
				_poly(n, [p + Vector2(0, -13), p + Vector2(4, 0), p + Vector2(0, 4), p + Vector2(-5, 0)], Color("#ffe3a8"))
			"cache":
				_ell(n, p + Vector2(0, 4), 11, 11, Color("#3e7f78"))
				n.draw_rect(Rect2(p + Vector2(-6, -12), Vector2(12, 6)), Color("#3e7f78"))
				n.draw_rect(Rect2(p + Vector2(-11, 1), Vector2(22, 3)), C_GOLD)
			"idol":
				var q := Vector2(it.x, it.y + 2)
				if it.carriers.is_empty():
					n.draw_rect(Rect2(q + Vector2(-18, 6), Vector2(36, 8)), Color("#5b6372"))
				_shard(n, q + Vector2(0, -14), 2.3, 0.0, Color("#d95a2a"), Color("#ffb37a"))
				n.draw_circle(q + Vector2(22, -32), 8, Color("#0e2f33"))
				_text(n, q + Vector2(22, -28), "x2", 10, C_INK)


func _draw_player(n: Node2D, p: CFPlayer, is_me: bool) -> void:
	if p.aboard:
		return
	var alpha := 1.0 if p.connected else 0.4
	if p.exiled:
		alpha *= 0.3   # voted out: a faint ghost where they stood
	if p.recover_t > 0.0:
		alpha *= 0.55
	elif p.invuln_t > 0.0 and int(_now * 14) % 2 == 1:
		alpha *= 0.35
	var cx := p.x + p.w / 2
	var by := p.y + p.h
	var running := p.on_ground and absf(p.vx) > 20 and not p.climbing
	var ph := p.run_ph * 6
	var s := Vector2(p.facing, 1)
	if p.land_t > 0:
		s *= Vector2(1.15, 0.85)
	elif not p.on_ground and not p.climbing:
		s *= Vector2(0.92, 1.08)
	var bob := absf(sin(ph)) * 2 if running else sin(_now * 3) * 0.6
	if p.climbing:
		bob = sin(p.y * 0.25) * 1.5
	if p.recover_t <= 0.0:
		_ell(n, Vector2(cx, by), 12, 3, Color(0, 0, 0, 0.25 * alpha))
	var kind := CF.animal_of(p.color)
	var pal: Array = ANIMAL_PALETTES[kind]
	var fur := Color(pal[0], alpha)
	var belly := Color(pal[1], alpha)
	var dark := Color(pal[2], alpha)
	n.draw_set_transform(Vector2(cx, by - bob), 0, s)
	var wag := sin(_now * (14.0 if running else 4.0)) * 0.25
	_animal_tail(n, kind, wag, fur, belly, dark)
	if p.carried > 0:
		var r := 5 + 9 * float(p.carried) / p.capacity
		_ell(n, Vector2(-8, -18 - r * 0.3), r, r * 0.9, Color("#8a5a34", alpha))
		n.draw_circle(Vector2(-8, -18 - r * 0.3), r * 0.35, Color(C_AMBER, alpha))
		n.draw_line(Vector2(-6, -24), Vector2(5, -14), Color("#4b3424", alpha), 2.0)
	var l1 := sin(ph) * 5 if running else (sin(p.y * 0.3) * 4 if p.climbing else 0.0)
	n.draw_line(Vector2(-4, -8), Vector2(-4 + l1, -1), dark, 4.0)
	n.draw_line(Vector2(4, -8), Vector2(4 - l1, -1), dark, 4.0)
	_ell(n, Vector2(0, -14), 10, 9, fur)
	_ell(n, Vector2(4, -12), 5, 6, belly)
	if kind == "owl":
		_ell(n, Vector2(-3, -15), 6, 7, dark, 0.3)   # folded wing
	n.draw_rect(Rect2(-6, -22, 14, 4), Color(p.color, alpha))
	_tri(n, Vector2(-6, -21), Vector2(-13, -16 + sin(_now * 9) * 2), Vector2(-6, -18), Color(p.color, alpha))
	_animal_head(n, kind, p.stun_t > 0.0, fur, belly, dark, alpha)
	n.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	if p.stun_t > 0.0:
		for i in 3:
			var a := _now * 6 + i * TAU / 3
			n.draw_circle(Vector2(cx + cos(a) * 12, p.y - 18 + sin(a) * 4), 2.5, C_GOLD)


# ---------------------------------------------------------------- animals
# Drawn facing right with the feet at (0, 0); _draw_player mirrors them for facing left.

## fur, belly/muzzle, dark (legs, markings)
const ANIMAL_PALETTES := {
	"fox": ["#e8762b", "#fff1df", "#3b2216"],
	"rabbit": ["#d8c8b4", "#fff8ee", "#8a7560"],
	"frog": ["#5daa4a", "#d8eba0", "#2f6b2a"],
	"bear": ["#8a5a3c", "#d9b48a", "#3e2618"],
	"cat": ["#8d8f99", "#ece9e3", "#3a3b42"],
	"panda": ["#f4f3ee", "#ffffff", "#24242a"],
	"raccoon": ["#8a8c94", "#dcd8d0", "#2e2f35"],
	"owl": ["#9a6b43", "#e8d2a8", "#5a3a22"],
	"mouse": ["#b8aaa6", "#efe4e0", "#6d5f5b"],
	"pig": ["#f2a7ae", "#ffd3d6", "#b0626c"],
}


func _animal_tail(n: Node2D, kind: String, wag: float, fur: Color, belly: Color, dark: Color) -> void:
	var base := Vector2(-9, -12)
	var dir := Vector2(-1, 0).rotated(-0.6 + wag)
	match kind:
		"fox":
			_ell(n, base + dir * 10, 13, 6, fur, -0.4 + wag)
			_ell(n, base + dir * 20 + Vector2(0, 1), 5, 4, belly)
		"raccoon":
			for i in 4:
				_ell(n, base + dir * (5 + i * 5), 6.0 - i * 0.3, 5.0 - i * 0.3, dark if i % 2 == 1 else fur, -0.4 + wag)
		"cat":
			var pts := _bez(base, base + Vector2(-14, 2), base + Vector2(-12, -16 + wag * 10), 8)
			n.draw_polyline(PackedVector2Array(pts), fur, 3.5)
		"mouse":
			var pts := _bez(base + Vector2(0, 2), base + Vector2(-14, 8), base + Vector2(-22, -2 + wag * 10), 8)
			n.draw_polyline(PackedVector2Array(pts), Color("#e6a3a8", fur.a), 2.0)
		"rabbit":
			n.draw_circle(base + Vector2(-1, -1), 4.5, belly)
		"bear":
			n.draw_circle(base + Vector2(-1, -1), 3.5, fur)
		"panda":
			n.draw_circle(base + Vector2(-1, -1), 3.5, dark)
		"owl":
			_tri(n, base + Vector2(2, 2), base + Vector2(-9, 6 + wag * 6), base + Vector2(-7, -3), dark)
		"pig":
			n.draw_arc(base + Vector2(-3, -2), 3.0, 0.0, TAU * 0.8, 10, dark, 2.0)
		_:
			pass   # frogs have no tail


func _animal_head(n: Node2D, kind: String, stunned: bool, fur: Color, belly: Color, dark: Color, alpha: float) -> void:
	var ink := Color("#1b1210", alpha)
	var pink := Color("#f0a0a8", alpha)
	var white := Color(1, 1, 1, alpha)
	var eye := Vector2(7, -30)
	# ears, behind the head
	match kind:
		"fox":
			_tri(n, Vector2(-3, -33), Vector2(-4, -44), Vector2(3, -36), fur)
			_tri(n, Vector2(4, -35), Vector2(9, -45), Vector2(11, -33), fur)
		"cat":
			_tri(n, Vector2(-3, -33), Vector2(-3, -42), Vector2(3, -36), fur)
			_tri(n, Vector2(5, -36), Vector2(10, -43), Vector2(11, -33), fur)
			_tri(n, Vector2(6, -36), Vector2(9.5, -41), Vector2(10, -35), pink)
		"rabbit":
			_ell(n, Vector2(-1, -43), 3.2, 10, fur, -0.25)
			_ell(n, Vector2(6, -44), 3.2, 10, fur, 0.15)
			_ell(n, Vector2(6, -44), 1.6, 7, pink, 0.15)
		"bear":
			n.draw_circle(Vector2(-3, -35), 4, fur)
			n.draw_circle(Vector2(8, -36), 4, fur)
			n.draw_circle(Vector2(8, -36), 2, belly)
		"panda":
			n.draw_circle(Vector2(-3, -35), 4, dark)
			n.draw_circle(Vector2(8, -36), 4, dark)
		"raccoon":
			_tri(n, Vector2(-4, -33), Vector2(-3, -41), Vector2(3, -36), fur)
			_tri(n, Vector2(5, -36), Vector2(9, -42), Vector2(11, -34), fur)
			_tri(n, Vector2(6, -36), Vector2(8.5, -40), Vector2(10, -35), dark)
		"mouse":
			n.draw_circle(Vector2(-4, -35), 6, fur)
			n.draw_circle(Vector2(8, -37), 6, fur)
			n.draw_circle(Vector2(8, -37), 3.5, pink)
		"owl":
			_tri(n, Vector2(-4, -33), Vector2(-6, -42), Vector2(1, -36), dark)
			_tri(n, Vector2(6, -36), Vector2(11, -43), Vector2(11, -33), dark)
		"pig":
			_tri(n, Vector2(-3, -34), Vector2(-6, -41), Vector2(2, -37), fur)
			_tri(n, Vector2(5, -36), Vector2(12, -40), Vector2(10, -32), fur)
	# head
	if kind == "frog":
		_ell(n, Vector2(4, -27), 11, 8, fur)
		n.draw_circle(Vector2(0, -34), 4.5, fur)
		n.draw_circle(Vector2(8, -35), 4.5, fur)
		n.draw_circle(Vector2(8, -35), 3, white)
		eye = Vector2(9, -35)
	else:
		n.draw_circle(Vector2(3, -28), 9, fur)
	# face
	match kind:
		"fox":
			_tri(n, Vector2(6, -28), Vector2(16, -26), Vector2(7, -22), belly)
			n.draw_circle(Vector2(16, -26), 2, ink)
		"rabbit":
			_ell(n, Vector2(9, -24), 4, 3, belly)
			n.draw_circle(Vector2(12, -27), 1.5, pink)
		"frog":
			_ell(n, Vector2(5, -22), 6, 2.5, belly)
			n.draw_line(Vector2(5, -24), Vector2(14, -25), dark, 1.5)
		"bear":
			_ell(n, Vector2(10, -25), 5, 4, belly)
			n.draw_circle(Vector2(14, -27), 2, ink)
		"cat":
			_ell(n, Vector2(10, -25), 4, 3, belly)
			_tri(n, Vector2(12, -28), Vector2(15, -28), Vector2(13.5, -26), pink)
			for k in [-1.0, 1.0]:
				n.draw_line(Vector2(13, -25), Vector2(20, -26 + k * 2.5), Color(ink, 0.6 * alpha), 1.0)
		"panda":
			_ell(n, Vector2(7, -29.5), 3.5, 4.5, dark, 0.3)
			_ell(n, Vector2(10, -25), 4, 3, belly)
			n.draw_circle(Vector2(14, -27), 1.8, ink)
		"raccoon":
			_ell(n, Vector2(6, -30), 8, 3.5, dark)
			_tri(n, Vector2(6, -27), Vector2(16, -25), Vector2(7, -21), belly)
			n.draw_circle(Vector2(16, -25), 2, ink)
		"owl":
			n.draw_circle(Vector2(6, -29), 6.5, belly)
			n.draw_circle(eye, 3.2, Color("#f2c14e", alpha))
			_tri(n, Vector2(10, -28), Vector2(14, -26), Vector2(10, -23), Color("#e08a2a", alpha))
		"mouse":
			_tri(n, Vector2(7, -28), Vector2(17, -26), Vector2(8, -22), fur)
			n.draw_circle(Vector2(17, -26), 1.8, pink)
			for k in [-1.0, 1.0]:
				n.draw_line(Vector2(14, -25), Vector2(21, -25 + k * 2.5), Color(ink, 0.6 * alpha), 1.0)
		"pig":
			_ell(n, Vector2(13, -26), 3.5, 4.5, dark.lightened(0.35))
			n.draw_circle(Vector2(13.5, -27.5), 0.9, ink)
			n.draw_circle(Vector2(13.5, -24.5), 0.9, ink)
	# eye: an X while stunned
	if stunned:
		var x_col := white if kind == "panda" or kind == "raccoon" else ink   # visible on the dark eye markings
		n.draw_line(eye + Vector2(-2, -2), eye + Vector2(2, 2), x_col, 2.0)
		n.draw_line(eye + Vector2(2, -2), eye + Vector2(-2, 2), x_col, 2.0)
	elif kind == "panda":
		n.draw_circle(eye, 1.4, white)
	elif kind == "raccoon":
		n.draw_circle(eye, 1.8, white)
		n.draw_circle(eye, 1.0, ink)
	else:
		n.draw_circle(eye, 1.8, ink)


func _collect_glows() -> void:
	glows.clear()
	if m == null:
		return
	var frac := minf(1.0, m.deposited / float(maxi(1, m.target)))
	var g := _ship_geometry()
	var breach: bool = m.mech["breach"]["active"]
	var vault: Vector2 = m.spots["vault"]
	_glow_at(Vector2(g[0], g[1] + 28), 30 + 60 * frac, C_RED if breach else C_AMBER, (0.6 + 0.3 * sin(_now * 12)) if breach else 0.35 + 0.5 * frac)
	_glow_at(Vector2(vault.x - 4.5 * T, vault.y - 14), 70 + sin(_now * 9) * 6, Color("#ff9a3c"), 0.55)
	for it in m.items:
		if it.gone or it.empty:
			continue
		var p := Vector2(it.x, it.y + sin(_now * 3 + it.ph) * 3)
		match it.kind:
			"coin": _glow_at(p, 16, C_AMBER, 0.55)
			"bag": _glow_at(p, 24, C_AMBER, 0.55)
			"chest": _glow_at(p, 30, C_AMBER, 0.4)
			"relic": _glow_at(p, 40, C_AMBER, 0.75)
			"cache": _glow_at(p, 30, Color("#7fe0d0"), 0.6)
			"idol": _glow_at(p + Vector2(0, -12), 50, Color("#ff8a4a"), 0.6 + 0.15 * sin(_now * 3))
	for v in m.veins:
		if CFVeins.intact(m, v):
			var surge := CFVeins.surging(m, v)
			_glow_at(v["pos"] + Vector2(0, -20), (60.0 if surge else 34.0) * (1.4 if v["great"] else 1.0), Color("#ffd38a") if surge else Color("#5fd0e8"), 0.8 if surge else 0.45)
	if breach:
		for i in m.spots["valves"].size():
			if not m.mech["breach"]["sw"][i]:
				_glow_at(m.spots["valves"][i] + Vector2(0, -32), 26 + 6 * sin(_now * 10), C_RED, 0.7)
	if m.mech["spikes"]["state"] == "warn":
		for tt in m.trap_tiles:
			_glow_at(Vector2(tt.x * T + 16, tt.y * T + 30), 22, C_VIOLET, 0.6)
	for cp in m.cps:
		if cp["on"]:
			_glow_at(cp["pos"] + Vector2(12, -50), 16, Color("#ffd38a"), 0.5)
	for i in m.spots["levers"].size():
		if not m.mech["doors"][i]:
			_glow_at(m.spots["levers"][i] + Vector2(0, -38), 14, C_GOLD, 0.35 + 0.15 * sin(_now * 4))
	var view := _view_rect().grow(160)
	for dg in _decor_glows:
		if view.has_point(dg[0]):
			var fl: float = dg[4]
			_glow_at(dg[0], dg[1] * (1.0 + fl * 0.08 * sin(_now * 9.0 + dg[0].x)), dg[2], dg[3] * (1.0 - fl * 0.15 + fl * 0.15 * sin(_now * 13.0 + dg[0].y)))
	var slab := m.find_mover("slab")
	var sd: Vector2 = mover_draw.get("slab", Vector2(slab.x, slab.y))
	_glow_at(sd + Vector2(slab.w / 2, 10), 18, Color("#7fe0d0"), 0.4)
	for p in m.players:
		if p.recover_t > 0.0 and not p.aboard:
			_glow_at(Vector2(p.x + p.w / 2, p.y + p.h / 2), 34, Color("#bfe9ff"), 0.8)


func _draw_glows(n: Node2D) -> void:
	for gl in glows:
		var r: float = gl[1]
		var c: Color = gl[2]
		c.a = gl[3]
		n.draw_texture_rect(_glow_tex, Rect2(gl[0] - Vector2(r, r), Vector2(r * 2, r * 2)), false, c)


# ---------------------------------------------------------------- front layer: false walls, prompts, names, particles

func _draw_front(n: Node2D) -> void:
	if m == null:
		return
	var view := _view_rect()
	for wr in _water:
		var r: Rect2 = wr
		if not r.intersects(view):
			continue
		n.draw_rect(r, Color(0.16, 0.42, 0.52, 0.38))
		var pts := PackedVector2Array()
		var x := maxf(r.position.x, view.position.x - 16)
		while x <= minf(r.end.x, view.end.x + 16):
			pts.append(Vector2(x, r.position.y + sin(x * 0.05 + _now * 2.0) * 1.5))
			x += 8
		if pts.size() > 1:
			n.draw_polyline(pts, Color(0.75, 0.95, 1.0, 0.45), 1.5)
	var focus: CFPlayer = me if me else (m.players[0] if m.players.size() > 0 else null)
	var inside := false
	if focus:
		for ft in m.fake_tiles:
			if focus.x + focus.w > ft.x * T and focus.x < (ft.x + 1) * T and focus.y + focus.h > ft.y * T and focus.y < (ft.y + 1) * T:
				inside = true
				break
	for ft in m.fake_tiles:
		var p := Vector2(ft.x * T, ft.y * T)
		var c := Color(C_STONE, 0.3 if inside else 1.0)
		n.draw_rect(Rect2(p, Vector2(T, T)), c)
		n.draw_rect(Rect2(p + Vector2(0, 15), Vector2(T, 2)), Color(C_STONE2, c.a))
		n.draw_polyline(PackedVector2Array([p + Vector2(20, 3), p + Vector2(14, 14), p + Vector2(19, 24)]), Color(0.08, 0.09, 0.12, 0.6 * c.a), 1.0)
	for p in m.players:
		if p.aboard or (me and p.id == me.id):
			continue
		var tag := " (offline)" if not p.connected else ""
		if p.exiled:
			tag = " (voted out)"
		# A traitor sees fellow traitors' names in violet. Explorers' clients never know anyone's role.
		var ally: bool = me != null and me.role == "traitor" and p.role == "traitor" and not p.exiled
		_text(n, Vector2(p.x + p.w / 2, p.y - 22), p.name + tag, 10, Color("#c9a8ff") if ally else p.color, 3)
	if me and not act.is_empty() and not me.busy():
		var label: String = act["label"]
		if not act.get("ok", true):
			label = ""
		if label != "":
			var cx := me.x + me.w / 2
			var yy := me.y - 30
			var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 14
			n.draw_rect(Rect2(cx - w / 2, yy - 12, w, 17), Color(0.035, 0.11, 0.12, 0.85))
			_text(n, Vector2(cx, yy + 1), label, 11, Color("#ffb0a6") if act["kind"] == "valve" else C_INK)
			if act.get("hold", false) and hold_frac > 0:
				n.draw_arc(Vector2(cx, yy - 20), 7, -PI / 2, -PI / 2 + TAU * hold_frac, 24, C_GOLD, 3.0)
	for q in parts:
		var a := minf(1.0, q["life"] / q["max"] * 1.5)
		var c2: Color = q["col"]
		c2.a = a
		if q["text"] != "":
			_text(n, q["pos"], q["text"], 14, c2, 3)
		else:
			n.draw_rect(Rect2(q["pos"] - Vector2(1.5, 1.5), Vector2(3, 3)), c2)




# ---------------------------------------------------------------- room props (scenery, drawn once)

func _view_rect() -> Rect2:
	var vp := get_viewport_rect().size / cam.zoom
	return Rect2(cam.position - vp / 2.0, vp)


func _prepare_decor() -> void:
	_decor_glows.clear()
	_water.clear()
	for d in m.decor:
		var kind: String = d[0]
		var foot := Vector2(d[1] * T + 16, (d[2] + 1) * T)
		var top := Vector2(d[1] * T + 16, d[2] * T)
		match kind:
			"water":
				_water.append(Rect2(d[1] * T, (d[2] + 1) * T - 13, (d[3] - d[1] + 1) * T, 13))
			"lantern": _decor_glows.append([top + Vector2(0, 30), 46.0, Color("#ffb347"), 0.55, 1.0])
			"chandelier": _decor_glows.append([top + Vector2(0, 34), 70.0, Color("#ffd38a"), 0.5, 1.0])
			"candles": _decor_glows.append([foot + Vector2(0, -12), 34.0, Color("#ffcf7a"), 0.55, 1.0])
			"brazier": _decor_glows.append([foot + Vector2(0, -26), 64.0, Color("#ff8a3a"), 0.7, 1.0])
			"torch": _decor_glows.append([foot + Vector2(0, -70), 50.0, Color("#ff9a4a"), 0.6, 1.0])
			"mushroom": _decor_glows.append([foot + Vector2(0, -12), 30.0, Color("#7fe0c0"), 0.5, 0.0])
			"crystal": _decor_glows.append([foot + Vector2(0, -16), 40.0, Color("#5fd0e8"), 0.5, 0.0])
			"glowworm": _decor_glows.append([top + Vector2(0, 26), 44.0, Color("#9fe8ff"), 0.45, 0.0])
			"window": _decor_glows.append([foot + Vector2(0, -56), 80.0, Color("#ffe9a8"), 0.25, 0.0])


func _draw_decor(n: Node2D) -> void:
	if m == null:
		return
	for d in m.decor:
		var kind: String = d[0]
		var foot := Vector2(d[1] * T + 16, (d[2] + 1) * T)
		var top := Vector2(d[1] * T + 16, d[2] * T)
		var h := _h(d[1], d[2])
		match kind:
			"rails":
				var y: float = (d[2] + 1) * T - 3.0
				for x in range(d[1] * T, (d[3] + 1) * T, 16):
					n.draw_rect(Rect2(x + 2, y - 2, 6, 5), Color("#4a3624"))
				n.draw_rect(Rect2(d[1] * T, y - 4, (d[3] - d[1] + 1) * T, 2), Color("#8a8f96"))
			"barrel":
				n.draw_rect(Rect2(foot + Vector2(-11, -28), Vector2(22, 28)), Color("#7a5230"))
				n.draw_rect(Rect2(foot + Vector2(-11, -22), Vector2(22, 3)), Color("#3a3438"))
				n.draw_rect(Rect2(foot + Vector2(-11, -8), Vector2(22, 3)), Color("#3a3438"))
			"crate":
				n.draw_rect(Rect2(foot + Vector2(-13, -26), Vector2(26, 26)), Color("#8a6238"))
				n.draw_rect(Rect2(foot + Vector2(-13, -26), Vector2(26, 26)), Color("#5a3e22"), false, 2.0)
				n.draw_line(foot + Vector2(-12, -25), foot + Vector2(12, -1), Color("#5a3e22"), 2.0)
			"bookshelf":
				n.draw_rect(Rect2(foot + Vector2(-16, -60), Vector2(32, 60)), Color("#4a3020"))
				for row in 3:
					var yy := -56 + row * 19
					var bx := -13.0
					while bx < 12:
						var bw := 3 + int(_h(int(bx), row + d[1]) * 4)
						n.draw_rect(Rect2(foot + Vector2(bx, yy), Vector2(bw, 15)), Color.from_hsv(_h(d[1], int(bx) + row), 0.45, 0.55))
						bx += bw + 1
			"desk":
				n.draw_rect(Rect2(foot + Vector2(-20, -18), Vector2(40, 4)), Color("#6e4a29"))
				n.draw_rect(Rect2(foot + Vector2(-18, -14), Vector2(3, 14)), Color("#4a3020"))
				n.draw_rect(Rect2(foot + Vector2(15, -14), Vector2(3, 14)), Color("#4a3020"))
				n.draw_rect(Rect2(foot + Vector2(-8, -22), Vector2(12, 4)), Color("#e8dcc0"))
			"candles":
				for i in 3:
					var cx := -8 + i * 8
					var ch := 8 + (i % 2) * 5
					n.draw_rect(Rect2(foot + Vector2(cx - 2, -ch), Vector2(4, ch)), Color("#efe4c8"))
					_ell(n, foot + Vector2(cx, -ch - 3), 2, 3, Color("#ffcf5a"))
			"pillar":
				var ph := float(d[3]) * T
				n.draw_rect(Rect2(foot + Vector2(-12, -ph), Vector2(24, ph)), Color("#6a6670", 0.85))
				n.draw_rect(Rect2(foot + Vector2(-16, -8), Vector2(32, 8)), Color("#5a5660"))
				n.draw_rect(Rect2(foot + Vector2(-16, -ph), Vector2(32, 8)), Color("#5a5660"))
				for fx in [-6, 0, 6]:
					n.draw_rect(Rect2(foot + Vector2(fx - 1, -ph + 8), Vector2(2, ph - 16)), Color("#57535c"))
			"statue":
				n.draw_rect(Rect2(foot + Vector2(-14, -12), Vector2(28, 12)), Color("#5a5660"))
				_ell(n, foot + Vector2(0, -34), 10, 20, Color("#7a7680"))
				n.draw_circle(foot + Vector2(0, -60), 8, Color("#7a7680"))
				n.draw_rect(Rect2(foot + Vector2(4, -62), Vector2(8, 3)), Color("#4f8a46", 0.8))
			"urn":
				_ell(n, foot + Vector2(0, -11), 9, 11, Color("#8a5a3a"))
				n.draw_rect(Rect2(foot + Vector2(-5, -26), Vector2(10, 5)), Color("#8a5a3a"))
				n.draw_rect(Rect2(foot + Vector2(-9, -13), Vector2(18, 2)), Color("#c9a14e"))
			"bones":
				_ell(n, foot + Vector2(-6, -4), 6, 4, Color("#d8d0b8"))
				n.draw_rect(Rect2(foot + Vector2(-2, -5), Vector2(14, 3)), Color("#cfc6b0"))
				n.draw_circle(foot + Vector2(-7, -6), 1.5, Color(0, 0, 0, 0.6))
			"brazier":
				n.draw_rect(Rect2(foot + Vector2(-3, -18), Vector2(6, 18)), Color("#3a3438"))
				n.draw_rect(Rect2(foot + Vector2(-12, -24), Vector2(24, 7)), Color("#4a4448"))
				_tri(n, foot + Vector2(-9, -24), foot + Vector2(0, -42 - h * 6), foot + Vector2(9, -24), Color("#ff8a3a"))
				_tri(n, foot + Vector2(-4, -24), foot + Vector2(0, -34), foot + Vector2(4, -24), Color("#ffe08a"))
			"planter":
				n.draw_rect(Rect2(foot + Vector2(-14, -12), Vector2(28, 12)), Color("#7a4a30"))
				for i in 4:
					_ell(n, foot + Vector2(-9 + i * 6, -18 - (i % 2) * 5), 5, 8, Color("#4f9a46"))
				n.draw_circle(foot + Vector2(-3, -26), 3, Color("#f2a0c0"))
			"mushroom":
				n.draw_rect(Rect2(foot + Vector2(-2, -12), Vector2(4, 12)), Color("#d8d0c0"))
				_ell(n, foot + Vector2(0, -13), 10, 5, Color("#5fd0b0"))
				n.draw_rect(Rect2(foot + Vector2(8, -6), Vector2(3, 6)), Color("#d8d0c0"))
				_ell(n, foot + Vector2(9, -7), 5, 3, Color("#7fe0c0"))
			"reeds":
				for i in 5:
					var rx := -10 + i * 5
					var rh := 22 + _h(d[1] + i, 3) * 18
					n.draw_line(foot + Vector2(rx, 0), foot + Vector2(rx + 2, -rh), Color("#5a7a3a"), 2.0)
					if i % 2 == 0:
						_ell(n, foot + Vector2(rx + 2, -rh + 4), 2, 5, Color("#6a4a2a"))
			"crystal":
				_tri(n, foot + Vector2(-10, 0), foot + Vector2(-5, -26), foot + Vector2(0, 0), Color("#5fd0e8"))
				_tri(n, foot + Vector2(-2, 0), foot + Vector2(4, -36), foot + Vector2(9, 0), Color("#7fe6f5"))
				_tri(n, foot + Vector2(6, 0), foot + Vector2(11, -18), foot + Vector2(14, 0), Color("#a98bff"))
			"cart":
				n.draw_colored_polygon(PackedVector2Array([foot + Vector2(-18, -24), foot + Vector2(18, -24), foot + Vector2(14, -6), foot + Vector2(-14, -6)]), Color("#5a5a62"))
				n.draw_circle(foot + Vector2(-9, -4), 4, Color("#2a2a30"))
				n.draw_circle(foot + Vector2(9, -4), 4, Color("#2a2a30"))
				_tri(n, foot + Vector2(-12, -24), foot + Vector2(-4, -32), foot + Vector2(4, -24), Color("#5fd0e8"))
			"beam":
				var bh := float(d[3]) * T
				n.draw_rect(Rect2(foot + Vector2(-22, -bh), Vector2(6, bh)), Color("#6e4a29"))
				n.draw_rect(Rect2(foot + Vector2(16, -bh), Vector2(6, bh)), Color("#6e4a29"))
				n.draw_rect(Rect2(foot + Vector2(-26, -bh), Vector2(52, 7)), Color("#7e5a34"))
			"tnt":
				for i in 3:
					n.draw_rect(Rect2(foot + Vector2(-10 + i * 7, -20), Vector2(6, 20)), Color("#c0392b"))
				n.draw_rect(Rect2(foot + Vector2(-11, -13), Vector2(22, 3)), Color("#3a3438"))
				n.draw_line(foot + Vector2(0, -20), foot + Vector2(4, -27), Color("#d8d0c0"), 1.0)
			"boat":
				n.draw_colored_polygon(PackedVector2Array([foot + Vector2(-28, -14), foot + Vector2(28, -14), foot + Vector2(20, 0), foot + Vector2(-20, 0)]), Color("#6e4a29"))
				n.draw_rect(Rect2(foot + Vector2(-28, -16), Vector2(56, 3)), Color("#8a6238"))
			"totem":
				for i in 3:
					n.draw_rect(Rect2(foot + Vector2(-9, -22 - i * 22), Vector2(18, 20)), Color("#5a4028").lightened(i * 0.08))
					n.draw_rect(Rect2(foot + Vector2(-5, -16 - i * 22), Vector2(3, 3)), Color("#9fffd0"))
					n.draw_rect(Rect2(foot + Vector2(2, -16 - i * 22), Vector2(3, 3)), Color("#9fffd0"))
			"lantern":
				var ll := 14 + h * 12
				n.draw_line(top, top + Vector2(0, ll), Color("#3a3438"), 1.5)
				n.draw_rect(Rect2(top + Vector2(-6, ll), Vector2(12, 14)), Color("#3a3438"))
				n.draw_rect(Rect2(top + Vector2(-4, ll + 2), Vector2(8, 10)), Color("#ffcf5a"))
			"chandelier":
				n.draw_line(top, top + Vector2(0, 22), Color("#5a4a30"), 2.0)
				n.draw_rect(Rect2(top + Vector2(-22, 22), Vector2(44, 4)), Color("#a07a2a"))
				for cx in [-18, -6, 6, 18]:
					n.draw_rect(Rect2(top + Vector2(cx - 1.5, 14), Vector2(3, 8)), Color("#efe4c8"))
					_ell(n, top + Vector2(cx, 11), 2, 3, Color("#ffcf5a"))
			"vine":
				var vl := 40 + h * 50
				n.draw_polyline(PackedVector2Array(_bez(top + Vector2(-4, 0), top + Vector2(10, vl * 0.5), top + Vector2(-2, vl))), Color("#3f8a3a"), 2.5)
				for i in 4:
					_ell(n, top + Vector2(2 + (i % 2) * 6 - 3, 10 + i * vl / 4.0), 4, 2, Color("#5fae4a"))
			"roots":
				var rl := 30 + h * 40
				for i in 3:
					n.draw_polyline(PackedVector2Array(_bez(top + Vector2(-8 + i * 8, 0), top + Vector2(-14 + i * 10, rl * 0.6), top + Vector2(-6 + i * 7, rl - i * 8))), Color("#5a4028"), 2.0)
			"chain":
				var cl := 30 + h * 50
				var yy := 0.0
				while yy < cl:
					n.draw_rect(Rect2(top + Vector2(-2, yy), Vector2(4, 6)), Color("#6a6670"), false, 1.0)
					yy += 7
			"glowworm":
				for i in 4:
					var gl := 16 + _h(d[1] + i, 9) * 40
					n.draw_line(top + Vector2(-12 + i * 8, 0), top + Vector2(-12 + i * 8, gl), Color("#9fe8ff", 0.5), 1.0)
					n.draw_circle(top + Vector2(-12 + i * 8, gl), 2, Color("#c8f6ff"))
			"banner":
				n.draw_rect(Rect2(foot + Vector2(-12, -2 * T - 8), Vector2(24, 2)), Color("#5a4a30"))
				n.draw_colored_polygon(PackedVector2Array([foot + Vector2(-10, -2 * T - 6), foot + Vector2(10, -2 * T - 6), foot + Vector2(10, -T + 6), foot + Vector2(0, -T - 2), foot + Vector2(-10, -T + 6)]), Color.from_hsv(_h(d[1], 2), 0.6, 0.55))
				n.draw_circle(foot + Vector2(0, -T - 32), 4, Color("#f2c14e"))
			"window":
				var wc := foot + Vector2(0, -2 * T)
				n.draw_rect(Rect2(wc + Vector2(-12, -10), Vector2(24, 34)), Color("#ffe9a8", 0.35))
				_ell(n, wc + Vector2(0, -10), 12, 10, Color("#ffe9a8", 0.35))
				n.draw_rect(Rect2(wc + Vector2(-1, -18), Vector2(2, 42)), Color("#3a3430"))
				n.draw_rect(Rect2(wc + Vector2(-12, 6), Vector2(24, 2)), Color("#3a3430"))
			"torch":
				var tc := foot + Vector2(0, -2 * T - 2)
				n.draw_rect(Rect2(tc + Vector2(-2, 0), Vector2(4, 14)), Color("#6e4a29"))
				_tri(n, tc + Vector2(-5, 0), tc + Vector2(0, -12 - h * 4), tc + Vector2(5, 0), Color("#ff8a3a"))
			"pickaxe":
				var pc := foot + Vector2(0, -2 * T)
				n.draw_line(pc + Vector2(-8, 12), pc + Vector2(8, -8), Color("#6e4a29"), 3.0)
				n.draw_polyline(PackedVector2Array([pc + Vector2(-2, -12), pc + Vector2(8, -8), pc + Vector2(14, 2)]), Color("#9aa3ad"), 3.0)
			"pipe":
				var py := foot.y - 2 * T - 10
				n.draw_rect(Rect2(Vector2(foot.x - 48, py), Vector2(96, 8)), Color("#6a6670"))
				n.draw_rect(Rect2(Vector2(foot.x - 4, py - 4), Vector2(10, 16)), Color("#8a8690"))
				n.draw_circle(Vector2(foot.x + 1, py + 4), 3, Color("#c0392b"))
			"net":
				var nc := foot + Vector2(0, -2 * T - 8)
				for i in 5:
					n.draw_line(nc + Vector2(-20 + i * 10, 0), nc + Vector2(-16 + i * 8, 30), Color("#a89a7a", 0.6), 1.0)
				for j in 3:
					n.draw_line(nc + Vector2(-20 + j * 1.5, j * 10), nc + Vector2(20 - j * 1.5, j * 10), Color("#a89a7a", 0.6), 1.0)
			"headframe":
				n.draw_line(foot + Vector2(-30, 0), foot + Vector2(-6, -150), Color("#3a3438"), 5.0)
				n.draw_line(foot + Vector2(30, 0), foot + Vector2(6, -150), Color("#3a3438"), 5.0)
				for k in 4:
					var yk := -30.0 - k * 30
					n.draw_line(foot + Vector2(-26 + k * 4.8, yk), foot + Vector2(26 - k * 4.8, yk), Color("#3a3438"), 3.0)
				n.draw_arc(foot + Vector2(0, -156), 18, 0, TAU, 20, Color("#4a4448"), 4.0)
			"heap":
				n.draw_colored_polygon(PackedVector2Array([foot + Vector2(-70, 0), foot + Vector2(-20, -50), foot + Vector2(10, -56), foot + Vector2(70, 0)]), Color("#2c2a30"))
			"deadtree":
				n.draw_line(foot, foot + Vector2(4, -120), Color("#2a2418"), 8.0)
				n.draw_line(foot + Vector2(3, -70), foot + Vector2(-30, -100), Color("#2a2418"), 4.0)
				n.draw_line(foot + Vector2(4, -95), foot + Vector2(32, -125), Color("#2a2418"), 4.0)
				n.draw_line(foot + Vector2(-18, -86), foot + Vector2(-24, -60), Color("#2a2418"), 2.0)
			"hut":
				n.draw_rect(Rect2(foot + Vector2(-26, -14), Vector2(4, 14)), Color("#4a3020"))
				n.draw_rect(Rect2(foot + Vector2(22, -14), Vector2(4, 14)), Color("#4a3020"))
				n.draw_rect(Rect2(foot + Vector2(-30, -50), Vector2(60, 36)), Color("#5a4028"))
				_tri(n, foot + Vector2(-38, -48), foot + Vector2(0, -78), foot + Vector2(38, -48), Color("#7a6a3a"))
				n.draw_rect(Rect2(foot + Vector2(-8, -40), Vector2(12, 12)), Color("#ffcf5a", 0.8))
