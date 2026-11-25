class_name CFTouchControls
extends Control
## Multitouch controls: a floating joystick on one side, Jump / Interact / Quickstep on the other.
## Handles raw screen touches so the joystick and a button can be held at the same time.

var move_x := 0.0
var up := false
var down := false
var jump_held := false
var act_held := false
var jump_pressed := false     # latched until the client consumes them
var act_pressed := false
var ability_pressed := false

var act_label := "Use"
var act_enabled := false
var ability_cd := 0.0         # 0..1 of the cooldown remaining
var button_scale := 1.0
var left_handed := false

var _stick_touch := -1
var _stick_origin := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _button_touch := {}       # touch index → button name
var _font: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func consume_presses() -> void:
	jump_pressed = false
	act_pressed = false
	ability_pressed = false


func release_all() -> void:
	_stick_touch = -1
	_button_touch.clear()
	move_x = 0.0
	up = false
	down = false
	jump_held = false
	act_held = false
	queue_redraw()


func _buttons() -> Dictionary:
	## name → [centre, radius] in screen pixels
	var s := button_scale * clampf(size.y / 390.0, 0.8, 1.6)
	var margin := Vector2(18, 18) * s
	var jump_c := Vector2(size.x - margin.x - 43 * s, size.y - margin.y - 43 * s)
	var act_c := jump_c + Vector2(-98, 10) * s
	var abil_c := jump_c + Vector2(-14, -100) * s
	var b := {"jump": [jump_c, 43 * s], "act": [act_c, 33 * s], "ability": [abil_c, 30 * s]}
	if left_handed:
		for k in b:
			var c: Vector2 = b[k][0]
			c.x = size.x - c.x
			b[k][0] = c
	return b


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed:
			var hit := ""
			for k in _buttons():
				var b: Array = _buttons()[k]
				if e.position.distance_to(b[0]) <= b[1] * 1.15:
					hit = k
			if hit != "":
				_button_touch[e.index] = hit
				match hit:
					"jump":
						jump_held = true
						jump_pressed = true
					"act":
						act_held = true
						act_pressed = true
					"ability":
						ability_pressed = true
			elif _in_stick_zone(e.position) and _stick_touch < 0:
				_stick_touch = e.index
				_stick_origin = e.position
				_stick_pos = e.position
		else:
			if e.index == _stick_touch:
				_stick_touch = -1
				move_x = 0.0
				up = false
				down = false
			elif _button_touch.has(e.index):
				var k: String = _button_touch[e.index]
				_button_touch.erase(e.index)
				if k == "jump":
					jump_held = false
				elif k == "act":
					act_held = false
		queue_redraw()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _stick_touch:
			var v := d.position - _stick_origin
			var r := 50.0 * button_scale
			if v.length() > r:
				v = v.normalized() * r
			_stick_pos = _stick_origin + v
			var nx := v.x / (40.0 * button_scale)
			move_x = 0.0 if absf(nx) < 0.2 else clampf(nx, -1.0, 1.0)
			down = v.y > 30.0 * button_scale
			up = v.y < -30.0 * button_scale
			queue_redraw()


func _in_stick_zone(p: Vector2) -> bool:
	if p.y < size.y * 0.25:
		return false
	return p.x > size.x * 0.55 if left_handed else p.x < size.x * 0.45


func _draw() -> void:
	var ink := Color("#fff6df")
	var panel := Color(0.035, 0.11, 0.12, 0.55)
	if _stick_touch >= 0:
		draw_circle(_stick_origin, 60 * button_scale, Color(0.035, 0.11, 0.12, 0.35))
		draw_arc(_stick_origin, 60 * button_scale, 0, TAU, 48, Color(ink, 0.35), 2.0)
		draw_circle(_stick_pos, 26 * button_scale, Color("#f2c14e", 0.85))
	var held := _button_touch.values()
	for k in _buttons():
		var b: Array = _buttons()[k]
		var c: Vector2 = b[0]
		var r: float = b[1]
		var on := held.has(k)
		var alpha := 0.35 if (k == "act" and not act_enabled) else 1.0
		draw_circle(c, r, Color("#f2c14e", 0.6) if on else Color(panel, panel.a * alpha))
		draw_arc(c, r, 0, TAU, 48, Color(ink, 0.4 * alpha), 2.0)
		var col := Color(ink, alpha)
		match k:
			"jump":
				draw_line(c + Vector2(0, r * 0.35), c + Vector2(0, -r * 0.35), col, 3.0)
				draw_polyline(PackedVector2Array([c + Vector2(-r * 0.28, -r * 0.08), c + Vector2(0, -r * 0.38), c + Vector2(r * 0.28, -r * 0.08)]), col, 3.0)
			"act":
				var w := _font.get_string_size(act_label, HORIZONTAL_ALIGNMENT_LEFT, -1, int(13 * button_scale)).x
				draw_string(_font, c + Vector2(-w / 2, 5 * button_scale), act_label, HORIZONTAL_ALIGNMENT_LEFT, -1, int(13 * button_scale), col)
			"ability":
				for dx in [-0.22, 0.12]:
					draw_polyline(PackedVector2Array([c + Vector2(r * dx - r * 0.1, -r * 0.3), c + Vector2(r * dx + r * 0.18, 0), c + Vector2(r * dx - r * 0.1, r * 0.3)]), col, 3.0)
				if ability_cd > 0:
					draw_arc(c, r - 3, -PI / 2, -PI / 2 + TAU * ability_cd, 32, Color(0, 0, 0, 0.6), 6.0)
