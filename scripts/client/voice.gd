class_name CFVoice
extends Node
## Proximity voice chat, relayed by the game server (which decides who can hear whom).
##
## Sending: microphone → "Mic" bus (capture, then silenced so you never hear yourself) → mono 16 kHz
## → 40 ms ADPCM packets → Net.send_voice. Push-to-talk (V / the Talk button) or open mic with a
## level gate.
## Receiving: one AudioStreamGenerator per speaker on the "Voice" bus, volume set from distance by
## the client each frame. Muted players are dropped here, before decoding.
##
## Voice is off until the player turns it on, and only reaches the server while they are talking.

const GATE := 0.018          # open-mic loudness that counts as talking
const HANGOVER := 0.35       # seconds the open mic stays open after you stop
const MAX_BUFFERED := 0.25   # seconds of a speaker's audio we hold before dropping packets (keeps latency down)
const LEAD_IN := 960         # 60 ms of silence before each burst, to ride out network jitter

var mode := "off"            # CF.VOICE_MODES
var room_allowed := true     # the host's room switch
var self_muted := false      # muted by reports in this room
var push_held := false       # V / Talk button
var muted := {}              # id → true: players I've muted
var mute_all := false
var voice_volume := 1.0
var volume_for := Callable() # (id) → 0..1 from distance; set by the client
var test_tone := false       # feed a 220 Hz tone instead of the microphone (tests, no hardware)
var packets_sent := 0
var packets_heard := 0

var _codec := CFVoiceCodec.new()
var _mic: AudioStreamPlayer
var _capture: AudioEffectCapture
var _acc := 0.0
var _sum := 0.0
var _cnt := 0
var _pending := PackedFloat32Array()
var _seq := 0
var _open_until := 0.0
var _tone_ph := 0.0
var _tone_t := 0.0
var _sending := false
var _speakers := {}          # id → {player, playback, heard_at, level}


func _ready() -> void:
	_ensure_bus("Voice", 0.0)


func _ensure_bus(bus_name: String, db: float) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, "Master")
		AudioServer.set_bus_volume_db(i, db)
	return i


# ---------------------------------------------------------------- state

func can_send() -> bool:
	return (mode == "push" or mode == "open") and room_allowed and not self_muted


func can_hear() -> bool:
	return mode != "off" and not mute_all


func transmitting() -> bool:
	return _sending


func speaking(id: String) -> bool:
	var s: Dictionary = _speakers.get(id, {})
	return not s.is_empty() and Time.get_ticks_msec() / 1000.0 - s["heard_at"] < 0.25 and s["level"] > GATE * 0.6


func set_mode(m: String) -> void:
	if not CF.VOICE_MODES.has(m):
		m = "off"
	mode = m
	_update_mic()
	if not can_hear():
		_drop_speakers()


func set_mute(id: String, on: bool) -> void:
	if on:
		muted[id] = true
		_drop_speaker(id)
	else:
		muted.erase(id)


func set_mute_all(on: bool) -> void:
	mute_all = on
	if on:
		_drop_speakers()


func reset_room() -> void:
	## New room: mutes are per room, people are strangers again.
	muted.clear()
	self_muted = false
	room_allowed = true
	_drop_speakers()
	_update_mic()


func _update_mic() -> void:
	var want := can_send() and not test_tone
	if want and _mic == null:
		_start_mic()
	elif not want and _mic != null:
		_stop_mic()


func _start_mic() -> void:
	if OS.get_name() == "Android" and not OS.request_permission("android.permission.RECORD_AUDIO"):
		return   # asked; the next press tries again once they allow it
	var bus := _ensure_bus("Mic", 0.0)
	if AudioServer.get_bus_effect_count(bus) == 0:
		_capture = AudioEffectCapture.new()
		_capture.buffer_length = 0.5
		AudioServer.add_bus_effect(bus, _capture)
		var quiet := AudioEffectAmplify.new()
		quiet.volume_db = -80.0   # after the capture: you never hear your own mic
		AudioServer.add_bus_effect(bus, quiet)
		AudioServer.set_bus_send(bus, "Master")
	else:
		_capture = AudioServer.get_bus_effect(bus, 0)
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = "Mic"
	add_child(_mic)
	_mic.play()
	_capture.clear_buffer()


func _stop_mic() -> void:
	_mic.stop()
	_mic.queue_free()
	_mic = null
	_capture = null
	_pending.clear()


# ---------------------------------------------------------------- sending

func _process(delta: float) -> void:
	_send(delta)
	for id in _speakers:
		var s: Dictionary = _speakers[id]
		var v := 1.0
		if volume_for.is_valid():
			v = volume_for.call(id)
		s["player"].volume_db = linear_to_db(maxf(0.0001, v * voice_volume))


func _send(delta: float) -> void:
	_sending = false
	if not can_send():
		_pending.clear()
		return
	var fresh := PackedFloat32Array()
	if test_tone:
		_tone_t += delta
		var n := int(_tone_t * CF.VOICE_RATE)
		_tone_t -= n / float(CF.VOICE_RATE)
		fresh.resize(n)
		for i in n:
			_tone_ph += TAU * 220.0 / CF.VOICE_RATE
			fresh[i] = sin(_tone_ph) * 0.3
	elif _capture:
		var frames := _capture.get_frames_available()
		if frames > 0:
			fresh = _downsample(_capture.get_buffer(frames))
	if fresh.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var talking := push_held if mode == "push" else false
	if mode == "open":
		if CFVoiceCodec.level(fresh) > GATE:
			_open_until = now + HANGOVER
		talking = now < _open_until
	if not talking:
		_pending.clear()
		return
	_sending = true
	_pending.append_array(fresh)
	while _pending.size() >= CF.VOICE_CHUNK:
		var chunk := _pending.slice(0, CF.VOICE_CHUNK)
		_pending = _pending.slice(CF.VOICE_CHUNK)
		_seq = (_seq + 1) & 0xffff
		if Net.is_online():
			Net.send_voice(_seq, _codec.encode(chunk))
			packets_sent += 1


func _downsample(frames: PackedVector2Array) -> PackedFloat32Array:
	## Mix rate → 16 kHz mono, averaging the input samples that fall in each output sample.
	var ratio := AudioServer.get_mix_rate() / CF.VOICE_RATE
	var out := PackedFloat32Array()
	out.resize(int(frames.size() / ratio) + 2)
	var k := 0
	for f in frames:
		_sum += (f.x + f.y) * 0.5
		_cnt += 1
		_acc += 1.0
		if _acc >= ratio:
			_acc -= ratio
			out[k] = _sum / _cnt
			k += 1
			_sum = 0.0
			_cnt = 0
	out.resize(k)
	return out


# ---------------------------------------------------------------- receiving

func receive(from: String, _seq_no: int, data: PackedByteArray) -> void:
	if not can_hear() or muted.has(from):
		return
	var pcm := CFVoiceCodec.decode(data)
	if pcm.is_empty():
		return
	packets_heard += 1
	var s := _speaker(from)
	var pb: AudioStreamGeneratorPlayback = s["playback"]
	var now := Time.get_ticks_msec() / 1000.0
	var cap := int((s["player"].stream as AudioStreamGenerator).buffer_length * CF.VOICE_RATE)
	var buffered := cap - pb.get_frames_available()
	if buffered > MAX_BUFFERED * CF.VOICE_RATE:
		return   # running behind: skip ahead rather than lag
	if now - s["heard_at"] > 0.2:
		var lead := PackedVector2Array()
		lead.resize(LEAD_IN)
		pb.push_buffer(lead)
	s["heard_at"] = now
	s["level"] = CFVoiceCodec.level(pcm)
	var st := PackedVector2Array()
	st.resize(pcm.size())
	for i in pcm.size():
		st[i] = Vector2(pcm[i], pcm[i])
	if pb.get_frames_available() >= st.size():
		pb.push_buffer(st)


func _speaker(id: String) -> Dictionary:
	if _speakers.has(id):
		return _speakers[id]
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = CF.VOICE_RATE
	gen.buffer_length = 0.5
	var p := AudioStreamPlayer.new()
	p.stream = gen
	p.bus = "Voice"
	add_child(p)
	p.play()
	var s := {"player": p, "playback": p.get_stream_playback(), "heard_at": -10.0, "level": 0.0}
	_speakers[id] = s
	return s


func _drop_speaker(id: String) -> void:
	if _speakers.has(id):
		_speakers[id]["player"].queue_free()
		_speakers.erase(id)


func _drop_speakers() -> void:
	for id in _speakers.keys():
		_drop_speaker(id)
