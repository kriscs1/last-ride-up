class_name CFUI
extends CanvasLayer
## Every screen and the in-game HUD, built in code.

signal quick_requested
signal create_requested
signal join_requested(code: String)
signal start_requested
signal leave_requested
signal options_changed(mode: String, map: String)
signal sabotage_requested(what: String)
signal vote_requested(target: String)
signal lobby_requested
signal settings_changed
signal map_requested
signal look_changed

const GOLD := Color("#f2c14e")
const INK := Color("#fff6df")
const VIOLET := Color("#c9a8ff")
const RED := Color("#ff5d4a")
const GOOD := Color("#7bdc6a")
const SAB_ORDER := ["spikes", "bridge", "lift", "taint", "breach"]   # also keys 1-5
const SAB_NAMES := {"spikes": "Spikes", "bridge": "Bridge", "lift": "Lift", "taint": "Taint", "breach": "Breach"}
const MODE_NAMES := {"none": "No sabotage", "bot": "Test bot", "traitors": "Hidden traitors"}
const MODE_BLURBS := {
	"none": "Pure co-op: just you, the ruins and the clock.",
	"bot": "A hidden bot sabotages the expedition. Good for learning the mechanisms.",
	"traitors": "1 hidden traitor (2 from 7 players) is secretly working against you. Ring the bell at camp to vote someone out.",
}

var touch: CFTouchControls
var map: CFMapOverlay
var _area_label: Label
var _area_t := 0.0
var _bounty_box: VBoxContainer
var _bounty_sig := ""
var name_edit: LineEdit
var address_edit: LineEdit
var code_edit: LineEdit
var status_label: Label

var _screens := {}
var _hud: Control
var _lobby_code: Label
var _lobby_roster: GridContainer
var _mode_buttons := {}
var _mode_choice := "none"
var _mode_blurb: Label
var _lobby_info: Label
var _lobby_start: Button
var _map_buttons := {}
var _map_thumb: TextureRect
var _map_blurb: Label
var _map_choice := "verdant"
var _thumbs := {}
var _carry_num: Label
var _carry_bar: ProgressBar
var _weight_tag: Label
var _vault_num: Label
var _vault_bar: ProgressBar
var _vault_rem: Label
var _objective: Label
var _alert: PanelContainer
var _alert_text: Label
var _toasts: VBoxContainer
var _timer: Label
var _ping: Label
var _guile_panel: PanelContainer
var _guile_num: Label
var _guile_bar: ProgressBar
var _guile_log: Label
var _guile_title: Label
var _sab_box: GridContainer
var _sab_btns := {}
var _role_box: VBoxContainer
var _role_title: Label
var _role_sub: Label
var _role_t := 0.0
var _meet_title: Label
var _meet_sub: Label
var _meet_list: VBoxContainer
var _meet_skip: Button
var _meet_rows := {}          # player id → {"btn": Button, "mark": Label}
var _meet_voted := false
var _end_title: Label
var _end_reason: Label
var _end_reveal: Label
var _end_stats: GridContainer
var _end_players: GridContainer
var _btn_slider: HSlider
var _lefty: CheckBox
var settings := {"button_scale": 1.0, "left_handed": false, "name": "", "address": "127.0.0.1", "animal": "fox", "hat": "none", "face": "none"}
var _look_preview: LookPreview
var _look_values := {}
var _look_return := "menu"


func _ready() -> void:
	_load_settings()
	_build_hud()
	touch = CFTouchControls.new()
	add_child(touch)
	touch.visible = false
	map = CFMapOverlay.new()
	add_child(map)
	_build_menu()
	_build_lobby()
	_build_pause()
	_build_end()
	_build_meeting()
	_build_look()
	_apply_settings()
	show_screen("menu")


# ---------------------------------------------------------------- building blocks

func _style(bg := Color(0.035, 0.11, 0.12, 0.82), border := Color(GOLD, 0.35), radius := 14) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _panel(parent: Node, border := Color(GOLD, 0.35)) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(Color(0.035, 0.11, 0.12, 0.82), border))
	parent.add_child(p)
	return p


func _label(parent: Node, text := "", size := 15, color := INK, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_constant_override("outline_size", 1)
		l.add_theme_color_override("font_outline_color", color)
	parent.add_child(l)
	return l


func _bar(parent: Node, fill: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.custom_minimum_size = Vector2(0, 8)
	b.add_theme_stylebox_override("background", _style(Color(1, 1, 1, 0.12), Color(0, 0, 0, 0), 5))
	var f := _style(fill, Color(0, 0, 0, 0), 5)
	f.content_margin_top = 0
	f.content_margin_bottom = 0
	b.add_theme_stylebox_override("fill", f)
	parent.add_child(b)
	return b


func _button(parent: Node, text: String, primary := true) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_size_override("font_size", 16)
	var normal := _style(GOLD if primary else Color(0.035, 0.11, 0.12, 0.82), Color("#b9862a") if primary else Color(GOLD, 0.35), 12)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = normal.bg_color.lightened(0.1)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", _style(Color(0, 0, 0, 0), INK, 12))
	b.add_theme_color_override("font_color", Color("#2a1a05") if primary else INK)
	b.add_theme_color_override("font_hover_color", Color("#2a1a05") if primary else INK)
	parent.add_child(b)
	return b


func _line_edit(parent: Node, placeholder: String, max_len: int) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.max_length = max_len
	e.custom_minimum_size = Vector2(0, 44)
	e.add_theme_font_size_override("font_size", 16)
	e.add_theme_stylebox_override("normal", _style(Color(0, 0, 0, 0.35), Color(GOLD, 0.35), 12))
	parent.add_child(e)
	return e


func _screen(screen_name: String) -> VBoxContainer:
	var root := ColorRect.new()
	root.color = Color(0.03, 0.1, 0.11, 0.94)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)
	_screens[screen_name] = root
	return box


func show_screen(screen_name: String) -> void:
	## "menu", "lobby", "pause", "end" or "" for the game itself.
	for k in _screens:
		_screens[k].visible = k == screen_name
	_hud.visible = screen_name == "" or screen_name == "pause"
	if screen_name != "":
		map.close()
	touch.visible = screen_name == "" and DisplayServer.is_touchscreen_available()
	if not touch.visible:
		touch.release_all()


func current_screen() -> String:
	for k in _screens:
		if _screens[k].visible:
			return k
	return ""


# ---------------------------------------------------------------- screens

func _build_menu() -> void:
	var box := _screen("menu")
	var title := _label(box, "LAST RIDE UP", 52, GOLD, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var tag := _label(box, "Stranded in the Verdant Reach. Gather enough Sunstone to power the skyship and escape together. Trust no one completely.", 15)
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit = _line_edit(box, "Your name", 14)
	name_edit.text = settings["name"]
	address_edit = _line_edit(box, "Server address, e.g. 192.168.1.20", 64)
	address_edit.text = settings["address"]
	_button(box, "Quick play").pressed.connect(_on_quick)
	_button(box, "Create private room", false).pressed.connect(_on_create)
	var row := HBoxContainer.new()
	box.add_child(row)
	code_edit = _line_edit(row, "Room code", 6)
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var join := _button(row, "Join", false)
	join.custom_minimum_size.x = 100
	join.pressed.connect(_on_join)
	code_edit.text_submitted.connect(func(_t): _on_join())
	_button(box, "Customize explorer", false).pressed.connect(open_look)
	status_label = _label(box, "", 13)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var note := _label(box, "Online prototype (Milestone 3). Start a server with: godot --headless --path . -- --server", 12, Color(INK, 0.7))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _on_quick() -> void:
	_remember()
	quick_requested.emit()


func _on_create() -> void:
	_remember()
	create_requested.emit()


func _on_button_scale(v: float) -> void:
	settings["button_scale"] = v
	_apply_settings()
	_save_settings()


func _on_lefty(on: bool) -> void:
	settings["left_handed"] = on
	_apply_settings()
	_save_settings()


func _free_if_valid(node: Node) -> void:
	if is_instance_valid(node):
		node.queue_free()


func _on_join() -> void:
	var code := code_edit.text.strip_edges().to_upper()
	if code.length() != 6:
		set_status("Room codes have 6 characters.", true)
		return
	_remember()
	join_requested.emit(code)


func _remember() -> void:
	settings["name"] = name_edit.text.strip_edges()
	settings["address"] = address_edit.text.strip_edges()
	_save_settings()


func player_name() -> String:
	var n := name_edit.text.strip_edges()
	return n if n != "" else "Explorer"


func server_address() -> Array:
	## "host" or "host:port" → [host, port]
	var a := address_edit.text.strip_edges()
	if a == "":
		a = "127.0.0.1"
	var port := CF.DEFAULT_PORT
	var i := a.rfind(":")
	if i > 0 and a.count(":") == 1:
		port = int(a.substr(i + 1))
		a = a.substr(0, i)
	return [a, port]


func set_status(text: String, is_error := false) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", Color("#ffb0a6") if is_error else INK)


func _build_lobby() -> void:
	var box := _screen("lobby")
	var l := _label(box, "Room code: share it with your expedition", 13, Color(INK, 0.8))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_code = _label(box, "------", 44, GOLD, true)
	_lobby_code.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_roster = GridContainer.new()
	_lobby_roster.columns = 2
	_lobby_roster.add_theme_constant_override("h_separation", 8)
	_lobby_roster.add_theme_constant_override("v_separation", 6)
	box.add_child(_lobby_roster)
	# map choice
	var map_lbl := _label(box, "Map", 13, Color(INK, 0.8))
	map_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var maps_row := HBoxContainer.new()
	maps_row.alignment = BoxContainer.ALIGNMENT_CENTER
	maps_row.add_theme_constant_override("separation", 6)
	box.add_child(maps_row)
	for id in CFMaps.IDS + ["random"]:
		var b := _button(maps_row, CFMaps.data(id)["name"] if id != "random" else "Random", false)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 40)
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(_on_map_picked.bind(id))
		_map_buttons[id] = b
	_map_thumb = TextureRect.new()
	_map_thumb.custom_minimum_size = Vector2(420, 180)
	_map_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_map_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.add_child(_map_thumb)
	_map_blurb = _label(box, "", 13, Color(INK, 0.85))
	_map_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var mode_lbl := _label(box, "Sabotage", 13, Color(INK, 0.8))
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var modes_row := HBoxContainer.new()
	modes_row.alignment = BoxContainer.ALIGNMENT_CENTER
	modes_row.add_theme_constant_override("separation", 6)
	box.add_child(modes_row)
	for id in CF.MODES:
		var b := _button(modes_row, MODE_NAMES[id], false)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 40)
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(_on_mode_picked.bind(id))
		_mode_buttons[id] = b
	_mode_blurb = _label(box, "", 13, Color(INK, 0.85))
	_mode_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_info = _label(box, "", 13, Color(INK, 0.8))
	_lobby_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	_lobby_start = _button(row, "Start expedition")
	_lobby_start.pressed.connect(func(): start_requested.emit())
	_button(row, "Customize", false).pressed.connect(open_look)
	_button(row, "Leave", false).pressed.connect(func(): leave_requested.emit())


func update_lobby(info: Dictionary, my_id: String) -> void:
	_lobby_code.text = info["code"]
	for c in _lobby_roster.get_children():
		c.queue_free()
	var host_name := "the host"
	var is_host := false
	var online := 0
	for r in info["roster"]:
		var cell := _panel(_lobby_roster)
		cell.custom_minimum_size = Vector2(200, 0)
		cell.modulate.a = 1.0 if r["connected"] else 0.45
		var hb := HBoxContainer.new()
		cell.add_child(hb)
		var dot := ColorRect.new()
		dot.color = Color(r["color"])
		dot.custom_minimum_size = Vector2(14, 14)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(dot)
		var nm := _label(hb, str(r["name"]) + (" (you)" if r["id"] == my_id else ""), 15)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_label(hb, CF.animal_of(Color(r["color"])).capitalize(), 12, Color(INK, 0.7))
		if r["host"] or not r["connected"]:
			_label(hb, "offline" if not r["connected"] else "host", 12, Color(INK, 0.7))
		if r["host"]:
			host_name = r["name"]
			is_host = r["id"] == my_id
		if r["connected"]:
			online += 1
	_show_mode_choice(str(info.get("mode", "none")), is_host)
	_show_map_choice(str(info.get("map", "verdant")), is_host)
	_lobby_start.visible = is_host
	if info["state"] == "playing":
		_lobby_info.text = "A match is in progress. Joining it…"
	elif is_host:
		_lobby_info.text = "%d player%s here. Best with 6 to 10; you can start with fewer to test." % [online, "" if online == 1 else "s"]
	else:
		_lobby_info.text = "Waiting for %s to start…" % host_name


func _on_map_picked(id: String) -> void:
	_map_choice = id
	options_changed.emit(_mode_choice, id)
	_show_map_choice(id, true)


func _on_mode_picked(id: String) -> void:
	_mode_choice = id
	options_changed.emit(id, _map_choice)
	_show_mode_choice(id, true)


func _show_mode_choice(id: String, is_host: bool) -> void:
	_mode_choice = id
	for k in _mode_buttons:
		var b: Button = _mode_buttons[k]
		b.set_pressed_no_signal(k == id)
		b.disabled = not is_host and k != id
		b.modulate = Color.WHITE if k == id else Color(1, 1, 1, 0.75)
	_mode_blurb.text = MODE_BLURBS.get(id, "")


func _show_map_choice(id: String, is_host: bool) -> void:
	_map_choice = id
	for k in _map_buttons:
		var b: Button = _map_buttons[k]
		b.set_pressed_no_signal(k == id)
		b.disabled = not is_host and k != id
		b.modulate = Color.WHITE if k == id else Color(1, 1, 1, 0.75)
	if id == "random":
		_map_thumb.texture = null
		_map_blurb.text = "A different map each round, chosen when the expedition starts."
	else:
		_map_thumb.texture = _thumb(id)
		_map_blurb.text = CFMaps.data(id)["blurb"]


func _thumb(id: String) -> ImageTexture:
	## One pixel per tile from the map's ASCII: a quick look at the layout.
	if _thumbs.has(id):
		return _thumbs[id]
	var d := CFMaps.data(id)
	var rows: PackedStringArray = str(d["map"]).split("\n")
	var sky := Color(d["theme"]["sky"][1])
	var img := Image.create(CF.GW, CF.GH, false, Image.FORMAT_RGBA8)
	for y in CF.GH:
		for x in CF.GW:
			var ch: String = rows[y][x]
			var col := sky if y < CF.SURFACE else Color("#1b2124")
			match ch:
				"#": col = Color("#4a5a4a") if y < CF.SURFACE else Color("#3a3f44")
				"=", "B": col = Color("#c08a50")
				"H": col = Color("#e0c48a")
				"^": col = Color("#d9483b")
				"1", "2", "3": col = Color("#ff8a3a")
				"X", "W": col = Color("#5fd0e8")
				"V", "E": col = Color("#f2c14e")
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_thumbs[id] = tex
	return tex


func _build_pause() -> void:
	var box := _screen("pause")
	var t := _label(box, "Menu", 32, GOLD, true)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var r1 := HBoxContainer.new()
	box.add_child(r1)
	var l1 := _label(r1, "Button size", 15)
	l1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_slider = HSlider.new()
	_btn_slider.min_value = 0.8
	_btn_slider.max_value = 1.4
	_btn_slider.step = 0.05
	_btn_slider.custom_minimum_size = Vector2(180, 32)
	_btn_slider.value_changed.connect(_on_button_scale)
	r1.add_child(_btn_slider)
	_lefty = CheckBox.new()
	_lefty.text = "Left-handed layout"
	_lefty.toggled.connect(_on_lefty)
	box.add_child(_lefty)
	var n := _label(box, "The match keeps running while this menu is open.", 12, Color(INK, 0.7))
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	_button(row, "Back to game").pressed.connect(func(): show_screen(""))
	_button(row, "Leave room", false).pressed.connect(func(): leave_requested.emit())


func _build_end() -> void:
	var box := _screen("end")
	_end_title = _label(box, "", 34, GOLD, true)
	_end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_reason = _label(box, "", 15)
	_end_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_end_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_reveal = _label(box, "", 13, VIOLET)
	_end_reveal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_end_reveal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_stats = GridContainer.new()
	_end_stats.columns = 4
	_end_stats.add_theme_constant_override("h_separation", 18)
	box.add_child(_end_stats)
	_end_players = GridContainer.new()
	_end_players.columns = 7
	_end_players.add_theme_constant_override("h_separation", 14)
	box.add_child(_end_players)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	_button(row, "Back to lobby").pressed.connect(func(): lobby_requested.emit())


func show_end(m: CFMatch, my_id: String, had_bot: bool) -> void:
	var hidden := m.mode == "traitors"
	if hidden:
		var mine: String = "explorers"
		for q in m.players:
			if q.id == my_id and q.role == "traitor":
				mine = "traitors"
		var won := m.winner == mine
		_end_title.text = ("Explorers win!" if m.winner == "explorers" else "Traitors win!") + ("  You won." if won else "  You lost.")
		var names: Array = m.players.filter(func(q): return q.role == "traitor").map(func(q): return q.name)
		_end_reveal.text = "The traitor%s: %s · %d sabotages in all" % ["" if names.size() == 1 else "s", ", ".join(PackedStringArray(names)) if names.size() > 0 else "(left the match)", m.stats["sabotages"]]
	else:
		_end_title.text = "Expedition escaped!" if m.phase == "won" else "Expedition stranded"
		_end_reveal.text = ("Role reveal: the test traitor bot sabotaged %d times." % m.stats["sabotages"]) if had_bot else ""
	_end_reason.text = m.end_reason
	for c in _end_stats.get_children():
		c.queue_free()
	for kv in [["Time left", CFFormat.clock(m.time_left)], ["Skyship charge", "%d / %d" % [m.deposited, m.target]], ["Sunstone gathered", str(m.stats["collected"])],
			["Lost to hazards", str(m.stats["lost_hazard"])], ["Lost to engine breaches", str(m.stats["lost_breach"])], ["Repairs", str(m.stats["repairs"])]]:
		_label(_end_stats, kv[0], 13, Color(INK, 0.8))
		_label(_end_stats, kv[1], 14, INK, true)
	for c in _end_players.get_children():
		c.queue_free()
	for h in ["Explorer", "Role", "Gathered", "Loaded", "Repairs", "Falls", "Aboard"]:
		_label(_end_players, h, 12, Color(INK, 0.7), true)
	var ps := m.players.duplicate()
	ps.sort_custom(func(a, b): return a.stats["deposited"] > b.stats["deposited"])
	var best: float = ps[0].stats["deposited"] if ps.size() > 0 else 0.0
	for p in ps:
		var star := " ★" if best > 0 and p.stats["deposited"] == best else ""
		_label(_end_players, p.name + (" (you)" if p.id == my_id else "") + star, 13, p.color)
		var is_traitor: bool = hidden and p.role == "traitor"
		_label(_end_players, "Traitor" if is_traitor else ("Explorer" if hidden else "-"), 13, VIOLET if is_traitor else INK, is_traitor)
		for v in [p.stats["collected"], int(p.stats["deposited"]), p.stats["repairs"], p.stats["falls"], "exiled" if p.exiled else ("yes" if p.aboard else "no")]:
			_label(_end_players, str(v), 13)
	show_screen("end")


# ---------------------------------------------------------------- meeting

func _build_meeting() -> void:
	var box := _screen("meeting")
	_meet_title = _label(box, "Emergency meeting", 32, GOLD, true)
	_meet_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_meet_sub = _label(box, "", 14, Color(INK, 0.85))
	_meet_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_meet_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_meet_list = VBoxContainer.new()
	_meet_list.add_theme_constant_override("separation", 6)
	box.add_child(_meet_list)
	_meet_skip = _button(box, "Skip vote", false)
	_meet_skip.pressed.connect(_vote.bind("skip"))
	var n := _label(box, "Most votes is voted out, if it beats Skip and isn't a tie. Their role is revealed.", 12, Color(INK, 0.7))
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func open_meeting(m: CFMatch, my_id: String) -> void:
	for c in _meet_list.get_children():
		c.queue_free()
	_meet_rows.clear()
	_meet_voted = m.meeting["votes"].has(my_id)
	var caller := m.find_player(m.meeting["by"])
	_meet_title.text = "%s rang the bell!" % (caller.name if caller else "Someone")
	var me_out := true
	for p in m.players:
		if p.id == my_id:
			me_out = p.exiled or not p.connected
		var row := _panel(_meet_list)
		row.modulate.a = 0.4 if (p.exiled or not p.connected) else 1.0
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		row.add_child(hb)
		var dot := ColorRect.new()
		dot.color = p.color
		dot.custom_minimum_size = Vector2(14, 14)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(dot)
		var tag := ""
		if p.exiled:
			tag = "  (exiled: %s)" % p.role
		elif p.role == "traitor" and p.id != my_id:
			tag = "  (ally)"   # only ever set on a traitor's own client
		var nm := _label(hb, p.name + (" (you)" if p.id == my_id else "") + tag, 15, p.color if not p.exiled else Color(INK, 0.6))
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mark := _label(hb, "", 12, GOOD, true)
		var btn := _button(hb, "Vote", false)
		btn.custom_minimum_size = Vector2(80, 36)
		btn.visible = not p.exiled
		btn.pressed.connect(_vote.bind(p.id))
		_meet_rows[p.id] = {"btn": btn, "mark": mark}
	_meet_skip.visible = true
	_set_vote_buttons(not _meet_voted and not me_out)
	refresh_meeting(m, my_id)
	show_screen("meeting")


func _vote(target: String) -> void:
	if _meet_voted:
		return
	_meet_voted = true
	_set_vote_buttons(false)
	vote_requested.emit(target)


func _set_vote_buttons(on: bool) -> void:
	for id in _meet_rows:
		_meet_rows[id]["btn"].disabled = not on
	_meet_skip.disabled = not on


func refresh_meeting(m: CFMatch, my_id: String) -> void:
	var votes: Dictionary = m.meeting["votes"]
	var eligible := CFSim.voters(m)
	var n_in := eligible.filter(func(q): return votes.has(q.id)).size()
	var me := m.find_player(my_id)
	var me_out := me == null or me.exiled
	_meet_sub.text = "%ds left · %d of %d have voted%s" % [ceili(m.meeting["left"]), n_in, eligible.size(),
		" · you were voted out, so you can only watch" if (me and me.exiled) else (" · your vote is in" if _meet_voted else " · who is the traitor?")]
	for id in _meet_rows:
		_meet_rows[id]["mark"].text = "voted" if votes.has(id) else ""
	if me_out:
		_set_vote_buttons(false)


func meeting_result(m: CFMatch, e: Dictionary, my_id: String) -> void:
	show_screen("")
	var votes: Dictionary = e.get("votes", {})
	var against := 0
	if e["exiled"] != "":
		for v in votes:
			if votes[v] == e["exiled"]:
				against += 1
		var traitor: bool = e["role"] == "traitor"
		var who: String = "You were" if e["exiled"] == my_id else "%s was" % e["name"]
		role_banner("%s voted out" % who, ("%d votes. They were a TRAITOR!" if traitor else "%d votes. They were an innocent explorer.") % against, traitor)
	else:
		var why := {"tie": "It was a tie.", "skip": "Skip won the vote.", "silence": "Nobody voted."}
		role_banner("Nobody was voted out", why.get(e.get("reason", ""), ""), false)
	# who voted for whom: the drama is in the receipts
	var lines: Array = []
	for v in votes:
		var a := m.find_player(v)
		var t: String = votes[v]
		var b := m.find_player(t) if t != "skip" else null
		lines.append("%s → %s" % [a.name if a else "?", b.name if b else "skip"])
	if lines.size() > 0:
		toast("Votes: " + ", ".join(PackedStringArray(lines)), "vio")


# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	_hud = MarginContainer.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		_hud.add_theme_constant_override("margin_" + side, 10)
	add_child(_hud)
	var top := HBoxContainer.new()
	top.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(top)
	# left column: carrying + test traitor bot
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(left)
	var carry := _panel(left)
	carry.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	carry.custom_minimum_size = Vector2(190, 0)
	var cv := VBoxContainer.new()
	carry.add_child(cv)
	var ch := HBoxContainer.new()
	cv.add_child(ch)
	var cl := _label(ch, "Carrying", 12, Color(INK, 0.8))
	cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weight_tag = _label(ch, "Light", 12, GOOD, true)
	_carry_num = _label(cv, "0 / 100 Sunstone", 17, INK, true)
	_carry_bar = _bar(cv, GOLD)
	_guile_panel = _panel(left, Color(VIOLET, 0.5))
	_guile_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_guile_panel.custom_minimum_size = Vector2(190, 0)
	var gv := VBoxContainer.new()
	_guile_panel.add_child(gv)
	_guile_title = _label(gv, "Test traitor bot", 12, VIOLET, true)
	_guile_num = _label(gv, "Guile 25 / 100", 15, INK, true)
	_guile_bar = _bar(gv, Color("#9b6bff"))
	_guile_log = _label(gv, "", 11, Color(INK, 0.85))
	_sab_box = GridContainer.new()
	_sab_box.columns = 3
	_sab_box.add_theme_constant_override("h_separation", 4)
	_sab_box.add_theme_constant_override("v_separation", 4)
	gv.add_child(_sab_box)
	for i in SAB_ORDER.size():
		var what: String = SAB_ORDER[i]
		var b := _button(_sab_box, "%d %s %d" % [i + 1, SAB_NAMES[what], int(CF.SAB[what]["cost"])], false)
		b.custom_minimum_size = Vector2(0, 36)
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_stylebox_override("normal", _style(Color(0.2, 0.08, 0.3, 0.85), Color(VIOLET, 0.6), 10))
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): sabotage_requested.emit(what))
		_sab_btns[what] = b
	_sab_box.visible = false
	_guile_panel.visible = false
	# middle: skyship charge, objective, alert, toasts
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.3
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(mid)
	var vault := _panel(mid)
	vault.custom_minimum_size = Vector2(300, 0)
	vault.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var vv := VBoxContainer.new()
	vault.add_child(vv)
	var vh := HBoxContainer.new()
	vv.add_child(vh)
	var vl := _label(vh, "Skyship charge", 12, Color(INK, 0.8))
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vault_num = _label(vh, "0 / 0", 17, INK, true)
	_vault_bar = _bar(vv, Color("#8fe07b"))
	_vault_rem = _label(vv, "", 12, Color(INK, 0.8))
	_vault_rem.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_objective = _label(mid, "", 14, INK, true)
	_objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_objective.add_theme_constant_override("outline_size", 4)
	_objective.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_alert = PanelContainer.new()
	_alert.add_theme_stylebox_override("panel", _style(Color(0.47, 0.05, 0.04, 0.9), RED, 12))
	_alert.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mid.add_child(_alert)
	var av := VBoxContainer.new()
	_alert.add_child(av)
	var at := _label(av, "ENGINE BREACH", 14, INK, true)
	at.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_text = _label(av, "", 13)
	_alert.visible = false
	_toasts = VBoxContainer.new()
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(_toasts)
	# right column: timer, menu, ping
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_BEGIN
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(right)
	var rt := HBoxContainer.new()
	rt.alignment = BoxContainer.ALIGNMENT_END
	right.add_child(rt)
	var tp := _panel(rt)
	_timer = _label(tp, "5:00", 22, INK, true)
	var map_btn := _button(rt, "Map", false)
	map_btn.custom_minimum_size = Vector2(56, 44)
	map_btn.pressed.connect(func(): map_requested.emit())
	var menu := _button(rt, "Menu", false)
	menu.custom_minimum_size = Vector2(64, 44)
	menu.pressed.connect(func(): show_screen("pause"))
	_ping = _label(right, "", 11, Color(INK, 0.75))
	_ping.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# camp bounties: shared goals worth a charge bonus
	var bp := _panel(right)
	bp.size_flags_horizontal = Control.SIZE_SHRINK_END
	_bounty_box = VBoxContainer.new()
	_bounty_box.add_theme_constant_override("separation", 2)
	bp.add_child(_bounty_box)
	_label(_bounty_box, "Camp bounties", 12, GOLD, true)
	# area name banner (fades)
	_area_label = _label(mid, "", 20, Color(INK, 0.0), true)
	_area_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_area_label.add_theme_constant_override("outline_size", 6)
	_area_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	# role reveal at the start of a hidden-traitor match, and meeting verdicts
	_role_box = VBoxContainer.new()
	_role_box.set_anchors_preset(Control.PRESET_CENTER)
	_role_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_role_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_role_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_role_box)
	_role_title = _label(_role_box, "", 44, INK, true)
	_role_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_role_title.add_theme_constant_override("outline_size", 8)
	_role_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	_role_sub = _label(_role_box, "", 16, INK)
	_role_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_role_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_role_sub.custom_minimum_size = Vector2(560, 0)
	_role_sub.add_theme_constant_override("outline_size", 6)
	_role_sub.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	_role_box.visible = false


func area_banner(area_name: String) -> void:
	_area_label.text = area_name
	_area_t = 2.5


func role_banner(title: String, sub: String, traitor: bool) -> void:
	## A big centred announcement that fades: your role at the start, a verdict after a meeting.
	_role_title.text = title
	_role_title.add_theme_color_override("font_color", VIOLET if traitor else GOLD)
	_role_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	_role_sub.text = sub
	_role_t = 5.0
	_role_box.visible = true
	_role_box.modulate.a = 1.0
	_role_box.reset_size()


func _process(delta: float) -> void:
	if _area_t > 0.0:
		_area_t -= delta
		_area_label.add_theme_color_override("font_color", Color(INK, clampf(_area_t, 0.0, 1.0)))
	if _role_t > 0.0:
		_role_t -= delta
		_role_box.modulate.a = clampf(_role_t, 0.0, 1.0)
		_role_box.visible = _role_t > 0.0


func toast(text: String, tone := "") -> void:
	var p := PanelContainer.new()
	var border := Color(GOLD, 0.35)
	match tone:
		"bad": border = RED
		"good": border = GOOD
		"vio": border = VIOLET
	p.add_theme_stylebox_override("panel", _style(Color(0.035, 0.11, 0.12, 0.82), border, 10))
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(p, text, 13)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(minf(440.0, 7.5 * text.length() + 20), 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toasts.add_child(p)
	_toasts.move_child(p, 0)
	while _toasts.get_child_count() > 2:
		var last := _toasts.get_child(_toasts.get_child_count() - 1)
		_toasts.remove_child(last)
		last.queue_free()
	get_tree().create_timer(3.8).timeout.connect(_free_if_valid.bind(p))


func clear_toasts() -> void:
	for c in _toasts.get_children():
		c.queue_free()


func update_hud(m: CFMatch, me: CFPlayer, act: Dictionary, rtt: int, guile: Dictionary, info: Dictionary = {}) -> void:
	var p: CFPlayer = me if me else (m.players[0] if m.players.size() > 0 else null)
	if p == null:
		return
	var w: Array = CF.weight_of(float(p.carried) / p.capacity)
	_carry_num.text = "%d / %d Sunstone" % [p.carried, p.capacity]
	_carry_bar.max_value = p.capacity
	_carry_bar.value = p.carried
	_weight_tag.text = w[1]
	_weight_tag.add_theme_color_override("font_color", {"Light": Color("#a8f28f"), "Loaded": Color("#ffe08a"), "Heavy": Color("#ffb36b"), "Overloaded": Color("#ff8a7a")}[w[1]])
	_vault_num.text = "%d / %d" % [m.deposited, m.target]
	_vault_bar.max_value = maxi(1, m.target)
	_vault_bar.value = m.deposited
	var rem := maxi(0, m.target - m.deposited)
	_vault_rem.text = "%d Sunstone to go" % rem if rem > 0 else "Fully charged"
	_timer.text = CFFormat.clock(m.time_left)
	_timer.add_theme_color_override("font_color", RED if m.time_left < 45 else INK)
	var conn := m.players.filter(func(q): return q.connected)
	var aboard := conn.filter(func(q): return q.aboard).size()
	var obj := "Gather Sunstone and carry it to the skyship"
	if me == null:
		obj = "Watching: you will join the next match"
	elif p.coop_item >= 0:
		obj = "Carry the Heartstone to the skyship together. Stay close!"
	elif p.carried >= p.capacity:
		obj = "Sack full: load it into the skyship at camp"
	if m.phase == "escape":
		obj = "%s %d/%d aboard · leaving in %ds" % ["Aboard!" if p.aboard else "Get aboard!", aboard, conn.size(), maxi(0, ceili(m.depart_at - m.t))]
	if p.recover_t > 0:
		obj = "Climbing back out…"
	if me and me.exiled:
		obj = "You were voted out. Watch how it ends."
	elif me and info.get("role", "") == "traitor" and m.phase == "running" and p.carried < p.capacity and p.coop_item < 0:
		obj = "Traitor: blend in, sabotage, don't get caught"
	_objective.text = obj
	var bx: Dictionary = m.mech["breach"]
	_alert.visible = bx["active"]
	if bx["active"]:
		_alert_text.text = "Furnace venting · %ds · valves %d/3" % [maxi(0, ceili(bx["ends_at"] - m.t)), bx["sw"].filter(func(v): return v).size()]
	_ping.text = "%d ms · %d online" % [rtt, conn.size()] if rtt > 0 else ""
	var sig := str(m.bounties)
	if sig != _bounty_sig:
		_bounty_sig = sig
		_rebuild_bounties(m)
	touch.act_label = act.get("label", "Use")
	touch.act_enabled = not act.is_empty() and act.get("ok", true)
	touch.ability_cd = p.ability_cd / CF.DASH_COOLDOWN
	touch.queue_redraw()
	if info.get("role", "") == "traitor":
		_update_traitor_panel(m, me, info, act)
	else:
		_update_bot_panel(m, guile)


func _update_traitor_panel(m: CFMatch, me: CFPlayer, info: Dictionary, act: Dictionary) -> void:
	_guile_panel.visible = me != null and not me.exiled and (m.phase == "running" or m.phase == "escape")
	_guile_title.text = "Traitor"
	var g: float = info.get("guile", 0.0)
	_guile_num.text = "Guile %d / %d" % [int(g), int(CF.GUILE_MAX)]
	_guile_bar.max_value = CF.GUILE_MAX
	_guile_bar.value = g
	var lock := maxf(0.0, info.get("lock", 0.0) - m.t)
	var names: Array = []
	for id in info.get("allies", []):
		var q := m.find_player(id)
		if q and (me == null or q.id != me.id):
			names.append(q.name + (" (exiled)" if q.exiled else ""))
	if lock > 0:
		_guile_log.text = "Lie low: %ds" % ceili(lock)
	elif names.size() > 0:
		_guile_log.text = "Ally: " + ", ".join(PackedStringArray(names))
	else:
		_guile_log.text = "Acting alone"
	_sab_box.visible = true
	for what in SAB_ORDER:
		var b: Button = _sab_btns[what]
		var ok := lock <= 0.0 and CFSim.sabotage_ready(m, what, g)
		if what == "taint":
			ok = ok and act.get("kind", "") == "strike"   # stand at a vein to taint it
		b.disabled = not ok
		b.modulate.a = 1.0 if ok else 0.45


func _update_bot_panel(m: CFMatch, guile: Dictionary) -> void:
	_sab_box.visible = false
	_guile_title.text = "Test traitor bot"
	_guile_panel.visible = not guile.is_empty()
	if guile.is_empty():
		return
	_guile_num.text = "Guile %d / %d" % [int(guile["guile"]), int(CF.GUILE_MAX)]
	_guile_bar.max_value = CF.GUILE_MAX
	_guile_bar.value = guile["guile"]
	var names := {"spikes": "spikes −15", "bridge": "bridge −25", "lift": "lift −20", "taint": "taint −20", "breach": "engine breach −60"}
	var lock := maxf(0.0, guile["lock_until"] - m.t)
	if guile["log"].size() > 0:
		var what: String = guile["log"][0]["what"]
		_guile_log.text = "Last: %s%s" % [names.get(what, what), (" · wait %ds" % ceili(lock)) if lock > 0 else ""]
	elif m.t < CF.DIRECTOR_FIRST_AT:
		_guile_log.text = "Plotting… acts after %ds" % int(CF.DIRECTOR_FIRST_AT)
	else:
		_guile_log.text = "Watching…"


func _rebuild_bounties(m: CFMatch) -> void:
	var lines := _bounty_box.get_children()
	for i in range(1, lines.size()):
		lines[i].queue_free()
	for b in m.bounties:
		var t := _label(_bounty_box, "%s  +%d%s" % [b["text"], b["reward"], (" (%d/%d)" % [b["have"], b["need"]]) if b["need"] > 1 else ""], 11, Color(INK, 0.9))
		t.custom_minimum_size = Vector2(200, 0)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


# ---------------------------------------------------------------- settings (one viewer's conveniences)

func _apply_settings() -> void:
	touch.button_scale = settings["button_scale"]
	touch.left_handed = settings["left_handed"]
	touch.queue_redraw()
	if _btn_slider:
		_btn_slider.set_value_no_signal(settings["button_scale"])
		_lefty.set_pressed_no_signal(settings["left_handed"])
	settings_changed.emit()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		for k in settings:
			settings[k] = cfg.get_value("player", k, settings[k])
	if not CF.ANIMALS.has(settings["animal"]):
		settings["animal"] = "fox"
	if not CF.HATS.has(settings["hat"]):
		settings["hat"] = "none"
	if not CF.FACES.has(settings["face"]):
		settings["face"] = "none"


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in settings:
		cfg.set_value("player", k, settings[k])
	cfg.save("user://settings.cfg")


# ---------------------------------------------------------------- customize (cosmetics)

func _build_look() -> void:
	var box := _screen("look")
	var t := _label(box, "Your explorer", 30, GOLD, true)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_look_preview = LookPreview.new()
	_look_preview.custom_minimum_size = Vector2(420, 230)
	box.add_child(_look_preview)
	for part in ["animal", "hat", "face"]:
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		var what := _label(row, {"animal": "Animal", "hat": "Hat", "face": "Face"}[part], 14, Color(INK, 0.8))
		what.custom_minimum_size = Vector2(64, 0)
		var prev := _button(row, "<", false)
		prev.custom_minimum_size = Vector2(52, 44)
		prev.pressed.connect(_cycle_look.bind(part, -1))
		var val := _label(row, "", 17)
		val.custom_minimum_size = Vector2(190, 0)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_look_values[part] = val
		var next := _button(row, ">", false)
		next.custom_minimum_size = Vector2(52, 44)
		next.pressed.connect(_cycle_look.bind(part, 1))
	var note := _label(box, "Everyone in your room sees your look. If someone already has your animal, you get a free one; you can switch in the lobby.", 12, Color(INK, 0.7))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button(box, "Done").pressed.connect(func(): show_screen(_look_return))
	_refresh_look()


func open_look() -> void:
	var cur := current_screen()
	_look_return = cur if cur != "" and cur != "look" else "menu"
	_refresh_look()
	show_screen("look")


func _cycle_look(part: String, step: int) -> void:
	var options: Array = {"animal": CF.ANIMALS, "hat": CF.HATS, "face": CF.FACES}[part]
	settings[part] = options[posmod(options.find(settings[part]) + step, options.size())]
	_save_settings()
	_refresh_look()
	look_changed.emit()


func _refresh_look() -> void:
	if _look_preview == null:
		return
	_look_values["animal"].text = str(settings["animal"]).capitalize()
	_look_values["hat"].text = CF.HAT_NAMES[settings["hat"]]
	_look_values["face"].text = CF.FACE_NAMES[settings["face"]]
	_look_preview.set_look(settings["animal"], settings["hat"], settings["face"])


## A big, animated preview of the player's explorer, drawn with the game's own character code.
class LookPreview extends Control:
	var view := CFWorldView.new()   # used only for its drawing code; never added to the tree
	var p := CFPlayer.new()
	var stage := Node2D.new()

	func _ready() -> void:
		p.on_ground = true
		p.x = -p.w / 2
		p.y = -p.h
		stage.scale = Vector2(4, 4)
		stage.draw.connect(func(): view._draw_player(stage, p, true))
		add_child(stage)

	func _exit_tree() -> void:
		view.free()

	func set_look(animal: String, hat: String, face: String) -> void:
		p.color = CF.color_for_animal(animal)
		p.hat = hat
		p.face = face
		stage.queue_redraw()

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		view._now += delta
		stage.position = Vector2(size.x / 2, size.y - 28)
		stage.queue_redraw()
