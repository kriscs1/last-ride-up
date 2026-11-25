class_name CFTalkUI
extends Node
## Talking to each other, and staying safe doing it:
## - quick-chat: a panel of set phrases (no free typing, so nothing to filter), a feed and bubbles;
## - the "Players & voice" screen: voice mode, mute one or all, report, and the host's room controls.

signal chat_requested(idx: int, target: String)
signal voice_mode_requested(mode: String)
signal mute_changed(id: String, on: bool)
signal mute_all_changed(on: bool)
signal report_requested(id: String, reason: int)
signal kick_requested(id: String)
signal room_voice_requested(on: bool)

const MODE_LABELS := {"off": "Off", "listen": "Listen only", "push": "Push to talk", "open": "Open mic"}
const MODE_HELP := {
	"off": "Voice is off. You hear no one and no one hears you. Quick-chat still works.",
	"listen": "You hear players near you. Your microphone stays off.",
	"push": "Hold V (or the Talk button) to speak to players near you.",
	"open": "Your microphone is on whenever you speak. Use headphones, or others may hear an echo.",
}
const FEED_KEEP := 6
const FEED_LIFE := 9.0
const BUBBLE_LIFE := 4.0

var ui: CFUI
var roster: Array = []
var my_id := ""
var is_host := false
var voice_allowed := true
var muted := {}                 # mirrors CFVoice.muted; hides chat from them too
var mode := "off"
var bubbles := {}               # id → [text, until]

var _feed: VBoxContainer
var _panel: PanelContainer
var _phrases: GridContainer
var _pick_box: VBoxContainer
var _pick_title: Label
var _pick_list: GridContainer
var _pick_idx := -1
var _chat_ready_at := 0.0
var _people_box: VBoxContainer
var _people_list: VBoxContainer
var _mode_btns := {}
var _mode_help: Label
var _mute_all: CheckBox
var _room_voice: CheckBox
var _voice_vol: HSlider
var _report_box: PanelContainer
var _report_title: Label
var _report_target := ""
var _confirm: ConfirmationDialog
var _confirm_mode := ""
var _rows := {}                 # id → {name, mute, report, kick, dot}
var _return_to := "lobby"
var _sig := ""


func build(owner_ui: CFUI) -> void:
	ui = owner_ui
	_build_people()
	_build_feed()
	_build_panel()
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Turn on voice chat?"
	_confirm.dialog_text = ("Players near you in the game will hear you.\n\n"
		+ "Be kind. Never say your full name, address, school or other personal details.\n"
		+ "Anyone can mute you, and reports are sent to the people who run the server.\n\n"
		+ "Voice chat is for players aged 13 and over.")
	_confirm.ok_button_text = "Turn on"
	_confirm.dialog_autowrap = true
	_confirm.min_size = Vector2i(420, 0)
	_confirm.confirmed.connect(func(): _set_mode(_confirm_mode, true))
	ui.add_child(_confirm)


# ---------------------------------------------------------------- quick-chat

func _build_feed() -> void:
	_feed = VBoxContainer.new()
	_feed.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_feed.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_feed.offset_left = 12
	_feed.offset_right = 560
	_feed.offset_top = -230
	_feed.offset_bottom = -12
	_feed.alignment = BoxContainer.ALIGNMENT_END
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_theme_constant_override("separation", 2)
	ui.add_child(_feed)


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", ui._style(Color(0.035, 0.11, 0.12, 0.95), Color(CFUI.GOLD, 0.6), 14))
	_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_bottom = -14
	ui.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := ui._label(head, "Quick chat", 15, CFUI.GOLD, true)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var close := _small(head, "Close")
	close.pressed.connect(close_chat)
	_phrases = GridContainer.new()
	_phrases.columns = 4
	_phrases.add_theme_constant_override("h_separation", 4)
	_phrases.add_theme_constant_override("v_separation", 4)
	v.add_child(_phrases)
	for i in CF.CHAT.size():
		var b := _small(_phrases, CF.chat_text(i, "(player)"))
		b.custom_minimum_size = Vector2(150, 34)
		b.pressed.connect(_on_phrase.bind(i))
	_pick_box = VBoxContainer.new()
	v.add_child(_pick_box)
	_pick_title = ui._label(_pick_box, "", 13, Color(CFUI.INK, 0.85))
	_pick_list = GridContainer.new()
	_pick_list.columns = 4
	_pick_list.add_theme_constant_override("h_separation", 4)
	_pick_list.add_theme_constant_override("v_separation", 4)
	_pick_box.add_child(_pick_list)
	_pick_box.visible = false
	_panel.visible = false


func _small(parent: Node, text: String) -> Button:
	var b := ui._button(parent, text, false)
	b.custom_minimum_size = Vector2(0, 34)
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	return b


func chat_open() -> bool:
	return _panel.visible


func toggle_chat() -> void:
	if _panel.visible:
		close_chat()
	else:
		_pick_box.visible = false
		_phrases.visible = true
		_panel.visible = true


func close_chat() -> void:
	_panel.visible = false


func _on_phrase(idx: int) -> void:
	if CF.chat_needs_player(idx):
		_pick_idx = idx
		_pick_title.text = CF.chat_text(idx, "(player)") + "  Who?"
		for c in _pick_list.get_children():
			c.queue_free()
		for r in roster:
			if r["id"] == my_id:
				continue
			var b := _small(_pick_list, str(r["name"]))
			b.add_theme_color_override("font_color", Color(r["color"]))
			b.pressed.connect(_send.bind(idx, r["id"]))
		var back := _small(_pick_list, "Back")
		back.pressed.connect(_pick_back)
		_phrases.visible = false
		_pick_box.visible = true
	else:
		_send(idx, "")


func _send(idx: int, target: String) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _chat_ready_at:
		return
	_chat_ready_at = now + CF.CHAT_COOLDOWN
	chat_requested.emit(idx, target)
	close_chat()


func show_chat(from: String, idx: int, target: String) -> void:
	if muted.has(from) or idx < 0 or idx >= CF.CHAT.size():
		return
	var r := _entry(from)
	var text := CF.chat_text(idx, str(_entry(target).get("name", "someone")))
	bubbles[from] = [text, Time.get_ticks_msec() / 1000.0 + BUBBLE_LIFE]
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", ui._style(Color(0.02, 0.07, 0.08, 0.72), Color(0, 0, 0, 0), 8))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(p)
	var hb := HBoxContainer.new()
	p.add_child(hb)
	ui._label(hb, str(r.get("name", "?")) + ":", 13, Color(r.get("color", "#fff6df")), true)
	ui._label(hb, text, 13)
	_feed.add_child(line)
	while _feed.get_child_count() > FEED_KEEP:
		var old := _feed.get_child(0)
		_feed.remove_child(old)
		old.queue_free()
	var tw := line.create_tween()
	tw.tween_interval(FEED_LIFE)
	tw.tween_property(line, "modulate:a", 0.0, 1.0)
	tw.tween_callback(line.queue_free)
	Sfx.play("click", 0.5, 0.1)


func bubble(id: String) -> String:
	var b: Array = bubbles.get(id, [])
	if b.is_empty() or Time.get_ticks_msec() / 1000.0 > b[1]:
		return ""
	return b[0]


func clear_feed() -> void:
	for c in _feed.get_children():
		c.queue_free()
	bubbles.clear()


# ---------------------------------------------------------------- players & voice

func _build_people() -> void:
	_people_box = ui._screen("people")
	var t := ui._label(_people_box, "Players & voice", 30, CFUI.GOLD, true)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui._label(_people_box, "Voice chat", 13, Color(CFUI.INK, 0.8))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_people_box.add_child(row)
	for m in CF.VOICE_MODES:
		var b := _small(row, MODE_LABELS[m])
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _set_mode(m, false))
		_mode_btns[m] = b
	_mode_help = ui._label(_people_box, "", 13, Color(CFUI.INK, 0.85))
	_mode_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_help.custom_minimum_size = Vector2(560, 0)
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 12)
	_people_box.add_child(r2)
	_mute_all = CheckBox.new()
	_mute_all.text = "Mute all voices"
	_mute_all.toggled.connect(func(on): mute_all_changed.emit(on))
	r2.add_child(_mute_all)
	ui._label(r2, "Voice volume", 14, Color(CFUI.INK, 0.85))
	_voice_vol = HSlider.new()
	_voice_vol.min_value = 0.0
	_voice_vol.max_value = 1.5
	_voice_vol.step = 0.05
	_voice_vol.custom_minimum_size = Vector2(150, 32)
	_voice_vol.value = ui.settings["voice_volume"]
	_voice_vol.value_changed.connect(func(v):
		ui.settings["voice_volume"] = v
		ui._save_settings()
		ui.settings_changed.emit())
	r2.add_child(_voice_vol)
	_room_voice = CheckBox.new()
	_room_voice.text = "Allow voice chat in this room (host)"
	_room_voice.toggled.connect(func(on): room_voice_requested.emit(on))
	_people_box.add_child(_room_voice)
	ui._label(_people_box, "Players in this room", 13, Color(CFUI.INK, 0.8))
	_people_list = VBoxContainer.new()
	_people_list.add_theme_constant_override("separation", 4)
	_people_box.add_child(_people_list)
	# report reasons, shown in place when Report is pressed
	_report_box = PanelContainer.new()
	_report_box.add_theme_stylebox_override("panel", ui._style(Color(0.18, 0.05, 0.05, 0.9), CFUI.RED, 12))
	_people_box.add_child(_report_box)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 4)
	_report_box.add_child(rv)
	_report_title = ui._label(rv, "", 15, CFUI.INK, true)
	var rg := GridContainer.new()
	rg.columns = 2
	rg.add_theme_constant_override("h_separation", 4)
	rg.add_theme_constant_override("v_separation", 4)
	rv.add_child(rg)
	for i in CF.REPORT_REASONS.size():
		var b := _small(rg, CF.REPORT_REASONS[i])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_report.bind(i))
	_small(rv, "Cancel").pressed.connect(func(): _report_box.visible = false)
	_report_box.visible = false
	var note := ui._label(_people_box, "Muting is just for you. A report also mutes them for you and is sent with this room's recent chat to the people who run the server. If several players report someone, their voice and chat are turned off for the room.", 12, Color(CFUI.INK, 0.7))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(560, 0)
	var back := ui._button(_people_box, "Back")
	back.pressed.connect(func(): ui.show_screen(_return_to))


func open_people(from_screen: String) -> void:
	_return_to = from_screen
	_report_box.visible = false
	_sig = ""
	_refresh_people()
	ui.show_screen("people")


func returns_to() -> String:
	return _return_to


func set_return(screen_name: String) -> void:
	_return_to = screen_name


func _set_mode(m: String, confirmed: bool) -> void:
	var speaking := m == "push" or m == "open"
	if speaking and not confirmed and not ui.settings.get("voice_ok", false):
		_confirm_mode = m
		_show_mode(mode)   # undo the toggle until they agree
		_confirm.popup_centered()
		return
	if speaking:
		ui.settings["voice_ok"] = true
	voice_mode_requested.emit(m)


func set_mode(m: String) -> void:
	mode = m
	_show_mode(m)


func _show_mode(m: String) -> void:
	for k in _mode_btns:
		_mode_btns[k].set_pressed_no_signal(k == m)
	var help: String = MODE_HELP.get(m, "")
	if not voice_allowed and m != "off":
		help = "The host has turned voice chat off for this room."
	_mode_help.text = help


func set_room(info: Dictionary, id: String) -> void:
	roster = info.get("roster", [])
	my_id = id
	voice_allowed = info.get("voice_allowed", true)
	is_host = false
	for r in roster:
		if r["id"] == my_id and r.get("host", false):
			is_host = true
	_refresh_people()


func set_mute_all(on: bool) -> void:
	_mute_all.set_pressed_no_signal(on)


func set_voice_volume(v: float) -> void:
	_voice_vol.set_value_no_signal(v)


func _entry(id: String) -> Dictionary:
	for r in roster:
		if r["id"] == id:
			return r
	return {}


func _refresh_people() -> void:
	_room_voice.visible = is_host
	_room_voice.set_pressed_no_signal(voice_allowed)
	_show_mode(mode)
	var sig := str(roster) + str(muted) + str(is_host)
	if sig == _sig:
		return
	_sig = sig
	for c in _people_list.get_children():
		c.queue_free()
	_rows.clear()
	for r in roster:
		var id: String = r["id"]
		var row := ui._panel(_people_list)
		row.modulate.a = 1.0 if r["connected"] else 0.5
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		row.add_child(hb)
		var dot := ColorRect.new()
		dot.color = Color(r["color"])
		dot.custom_minimum_size = Vector2(14, 14)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(dot)
		var tags: Array = []
		if id == my_id:
			tags.append("you")
		if r.get("host", false):
			tags.append("host")
		if r.get("voice", false):
			tags.append("voice on")
		if r.get("muted", false):
			tags.append("muted by reports")
		var nm := ui._label(hb, str(r["name"]) + ("  (" + ", ".join(PackedStringArray(tags)) + ")" if tags.size() > 0 else ""), 15, Color(r["color"]))
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		nm.custom_minimum_size = Vector2(260, 0)
		var entry := {"name": nm}
		if id != my_id:
			var mute := _small(hb, "Unmute" if muted.has(id) else "Mute")
			mute.custom_minimum_size = Vector2(80, 34)
			mute.pressed.connect(_toggle_mute.bind(id))
			var rep := _small(hb, "Report")
			rep.custom_minimum_size = Vector2(80, 34)
			rep.pressed.connect(_open_report.bind(id))
			if is_host:
				var kick := _small(hb, "Remove")
				kick.custom_minimum_size = Vector2(80, 34)
				kick.pressed.connect(func(): kick_requested.emit(id))
		_rows[id] = entry


func _toggle_mute(id: String) -> void:
	var on := not muted.has(id)
	if on:
		muted[id] = true
	else:
		muted.erase(id)
	mute_changed.emit(id, on)
	_refresh_people()


func _open_report(id: String) -> void:
	_report_target = id
	_report_title.text = "Report %s: what happened?" % _entry(id).get("name", "this player")
	_report_box.visible = true


func _report(reason: int) -> void:
	_report_box.visible = false
	if _report_target == "":
		return
	if not muted.has(_report_target):
		_toggle_mute(_report_target)
	report_requested.emit(_report_target, reason)
	_report_target = ""


func show_speaking(speaking: Dictionary) -> void:
	## Names of the people talking light up in the list.
	for id in _rows:
		var r := _entry(id)
		_rows[id]["name"].add_theme_color_override("font_color", CFUI.GOOD if speaking.has(id) else Color(r.get("color", "#fff6df")))


func _pick_back() -> void:
	_pick_box.visible = false
	_phrases.visible = true
