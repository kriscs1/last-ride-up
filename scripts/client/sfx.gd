extends Node
## Sfx (autoload): sound effects and music, all synthesised in code at start-up (no audio files).
##
##   Sfx.play("jump")                       a one-shot effect
##   Sfx.play_at("strike", pos, listener)   quieter the further it is from the listener
##   Sfx.music("verdant")                   switch the music mood ("" for silence); repeated calls are free
##   Sfx.set_volumes(music, sound)          0..1, from the player's settings
##
## Music is a little step sequencer: each mood has a key, tempo, chord loop and instruments,
## and a seeded melody that repeats every 8 bars. Instruments are single synthesised notes,
## re-pitched with pitch_scale. Off on the dedicated server and in headless runs.

const RATE := 22050
const C4 := 261.63
const POOL := 14
const MUSIC_VOICES := 16

## Moods. Notes are semitones from C4; chords are relative to the key.
const SONGS := {
	"menu": {"bpm": 76, "key": 0, "scale": [0, 2, 4, 7, 9], "chords": [[0, 4, 7], [-3, 0, 4], [-7, -3, 0], [-5, -1, 2]],
		"lead": "pluck", "lead_oct": 12, "density": 0.3, "pad": 0.5, "bass": "half", "drums": ""},
	"verdant": {"bpm": 96, "key": 2, "scale": [0, 2, 4, 7, 9], "chords": [[0, 4, 7], [-5, -1, 2], [-3, 0, 4], [-7, -3, 0]],
		"lead": "pluck", "lead_oct": 12, "density": 0.45, "pad": 0.35, "bass": "half", "drums": "shaker"},
	"mines": {"bpm": 84, "key": -3, "scale": [0, 2, 3, 5, 7, 9, 10], "chords": [[0, 3, 7], [-2, 2, 5], [-4, 0, 3], [-2, 2, 5]],
		"lead": "mallet", "lead_oct": 12, "density": 0.3, "pad": 0.3, "bass": "half", "drums": "drip"},
	"marsh": {"bpm": 70, "key": 4, "scale": [0, 2, 3, 7, 8], "chords": [[0, 3, 7], [5, 8, 12], [0, 3, 7], [-5, -1, 2]],
		"lead": "pluck", "lead_oct": 0, "density": 0.25, "pad": 0.55, "bass": "whole", "drums": "frog"},
	"escape": {"bpm": 134, "key": 0, "scale": [0, 2, 3, 5, 7, 8, 10], "chords": [[0, 3, 7], [-4, 0, 3], [-2, 2, 5], [0, 3, 7]],
		"lead": "arp", "lead_oct": 12, "density": 1.0, "pad": 0.0, "bass": "eighths", "drums": "kick", "gain": 0.5},
}

var enabled := false
var music_volume := 0.6
var sound_volume := 0.8
var _sounds := {}           # name → AudioStreamWAV
var _inst := {}             # instrument → AudioStreamWAV (pitched at C4, bass at C2)
var _pool: Array = []
var _voices: Array = []
var _next := 0
var _next_voice := 0
var _song := ""
var _step := 0
var _step_t := 0.0
var _lead_at := 0           # melody's position on the scale, as a scale index
var _rng := RandomNumberGenerator.new()
var _synth := RandomNumberGenerator.new()   # used only by the build thread
var _task := -1
var _sfx_bus := 0
var _music_bus := 0


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--server") or DisplayServer.get_name() == "headless":
		return
	enabled = true
	_music_bus = _bus("Music", true)
	_sfx_bus = _bus("Sfx", false)
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Sfx"
		add_child(p)
		_pool.append(p)
	for i in MUSIC_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "Music"
		add_child(p)
		_voices.append(p)
	set_volumes(music_volume, sound_volume)
	# ~0.5 s of synthesis: off the main thread, so start-up isn't held up
	_task = WorkerThreadPool.add_task(_build_all)


func _build_all() -> void:
	var built := {"sounds": _build_sounds(), "inst": _build_instruments()}
	_finish_build.call_deferred(built)


func _finish_build(built: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_sounds = built["sounds"]
	_inst = built["inst"]
	_task = -1


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _bus(bus_name: String, reverb: bool) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, "Master")
		if reverb:
			var r := AudioEffectReverb.new()
			r.room_size = 0.7
			r.damping = 0.6
			r.wet = 0.22
			r.dry = 0.9
			AudioServer.add_bus_effect(i, r)
	return i


# ---------------------------------------------------------------- public

func set_volumes(music_v: float, sound_v: float) -> void:
	music_volume = clampf(music_v, 0.0, 1.0)
	sound_volume = clampf(sound_v, 0.0, 1.0)
	if not enabled:
		return
	AudioServer.set_bus_volume_db(_music_bus, linear_to_db(music_volume * 0.55))
	AudioServer.set_bus_mute(_music_bus, music_volume < 0.01)
	AudioServer.set_bus_volume_db(_sfx_bus, linear_to_db(sound_volume))
	AudioServer.set_bus_mute(_sfx_bus, sound_volume < 0.01)


func play(sound: String, volume := 1.0, pitch_jitter := 0.04) -> void:
	if not enabled or not _sounds.has(sound) or volume <= 0.01:
		return
	var p: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % POOL
	p.stream = _sounds[sound]
	p.volume_db = linear_to_db(volume)
	p.pitch_scale = 1.0 + _rng.randf_range(-pitch_jitter, pitch_jitter)
	p.play()


func play_at(sound: String, pos: Vector2, listener: Vector2, volume := 1.0) -> void:
	## Full volume within ~250 px, silent beyond ~1100 px.
	var k := clampf(1.0 - (pos.distance_to(listener) - 250.0) / 850.0, 0.0, 1.0)
	play(sound, volume * k * k)


func music(song: String) -> void:
	if song == _song or not enabled:
		return
	_song = song if SONGS.has(song) else ""
	_step = 0
	_step_t = 0.0
	_lead_at = 0


func current_music() -> String:
	return _song


# ---------------------------------------------------------------- sequencer

func _process(delta: float) -> void:
	if _song == "" or not enabled or _inst.is_empty():
		return
	var s: Dictionary = SONGS[_song]
	var step_len := 60.0 / float(s["bpm"]) / 2.0   # eighth notes
	_step_t -= delta
	var guard := 0
	while _step_t <= 0.0 and guard < 4:
		_play_step(s, step_len)
		_step_t += step_len
		_step += 1
		guard += 1
	if _step_t < -step_len:
		_step_t = 0.0   # we fell behind (a hitch): skip ahead rather than burst


func _play_step(s: Dictionary, step_len: float) -> void:
	var bar := _step / 8
	var beat := _step % 8
	var key: int = s["key"]
	var chords: Array = s["chords"]
	var chord: Array = chords[bar % chords.size()]
	var scale: Array = s["scale"]
	# pad: the chord, held for the bar
	if beat == 0 and float(s["pad"]) > 0.0:
		for n in chord:
			_note("pad", key + int(n), float(s["pad"]) * 0.45)
	# bass
	var bass: String = s["bass"]
	if (bass == "whole" and beat == 0) or (bass == "half" and beat % 4 == 0) or bass == "eighths":
		var bn: int = key + int(chord[0]) - 12
		if bass == "eighths" and beat % 2 == 1:
			bn += 12 if beat == 7 else 0
		_note("bass", bn, 0.8 if beat % 4 == 0 else 0.55)
	# lead: a melody seeded by the bar, so every 8 bars it comes round again
	var oct: int = s["lead_oct"]
	if s["lead"] == "arp":
		var tone: int = int(chord[[0, 1, 2, 1][beat % 4]]) + (12 if beat >= 4 else 0)
		_note("pluck", key + tone + oct - 12, 0.5 if beat % 2 == 0 else 0.35)
	else:
		if beat == 0:
			_rng.seed = hash([_song, bar % 8])
			_lead_at = scale.find(posmod(int(chord[_rng.randi_range(0, chord.size() - 1)]), 12))
			if _lead_at < 0:
				_lead_at = 0
		var chance: float = float(s["density"]) * (1.6 if beat % 2 == 0 else 0.7)
		if _rng.randf() < chance:
			_lead_at += [-2, -1, -1, 1, 1, 2][_rng.randi_range(0, 5)]
			_lead_at = clampi(_lead_at, -scale.size(), scale.size() * 2 - 1)
			var octave := floori(float(_lead_at) / scale.size())
			var n: int = int(scale[posmod(_lead_at, scale.size())]) + octave * 12
			_note(s["lead"], key + n + oct, 0.5 if beat % 4 == 0 else 0.38)
	# percussion
	match s["drums"]:
		"kick":
			if beat % 2 == 0:
				_note("kick", 0, 0.9 if beat % 4 == 0 else 0.6)
			else:
				_note("shaker", 0, 0.35)
		"shaker":
			if beat % 2 == 1:
				_note("shaker", 0, 0.22 + (0.1 if beat == 3 or beat == 7 else 0.0))
		"drip":
			if _rng.randf() < 0.12:
				_note("drip", _rng.randi_range(0, 7), 0.35)
		"frog":
			if beat == 6 and bar % 2 == 1:
				_note("frog", _rng.randi_range(-2, 2), 0.4)


func _note(inst: String, semis: int, vol: float) -> void:
	vol *= float(SONGS[_song].get("gain", 1.0))
	var p: AudioStreamPlayer = _voices[_next_voice]
	_next_voice = (_next_voice + 1) % MUSIC_VOICES
	p.stream = _inst[inst]
	p.pitch_scale = pow(2.0, semis / 12.0)
	p.volume_db = linear_to_db(vol)
	p.play()


# ---------------------------------------------------------------- synthesis

func _buf(sec: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(sec * RATE))
	return b


static func _osc(wave: String, ph: float) -> float:
	## ph in cycles
	var f := ph - floorf(ph)
	match wave:
		"square": return 1.0 if f < 0.5 else -1.0
		"tri": return 4.0 * absf(f - 0.5) - 1.0
		"saw": return 2.0 * f - 1.0
	return sin(TAU * f)


func _tone(b: PackedFloat32Array, start: float, dur: float, f0: float, f1: float, wave := "sine", vol := 0.5, attack := 0.004, curve := 1.0) -> void:
	## A tone sliding (exponentially) from f0 to f1, decaying to silence over dur.
	var i0 := int(start * RATE)
	var n := mini(int(dur * RATE), b.size() - i0)
	var ph := 0.0
	var f := f0 / RATE
	var glide := pow(f1 / f0, 1.0 / (dur * RATE))
	var att := attack * RATE
	var total := dur * RATE
	for i in n:
		var k := 1.0 - i / total
		ph += f
		f *= glide
		var env := (k if curve == 1.0 else (k * k if curve == 2.0 else pow(k, curve))) * minf(1.0, i / att)
		b[i0 + i] += _osc(wave, ph) * env * vol


func _noise(b: PackedFloat32Array, start: float, dur: float, vol := 0.5, smooth := 0.3, curve := 1.0, attack := 0.002) -> void:
	## Noise through a one-pole low-pass: smooth near 0 is a rumble, 1 is a hiss.
	var i0 := int(start * RATE)
	var n := mini(int(dur * RATE), b.size() - i0)
	var y := 0.0
	for i in n:
		var k := float(i) / (dur * RATE)
		y += smooth * (_synth.randf_range(-1.0, 1.0) - y)
		b[i0 + i] += y * vol * minf(1.0, i / (attack * RATE)) * pow(1.0 - k, curve)


func _bell(b: PackedFloat32Array, start: float, dur: float, f: float, vol := 0.4) -> void:
	## Inharmonic partials, the high ones dying first.
	for pr in [[1.0, 1.0, 1.0], [2.76, 0.45, 1.8], [5.40, 0.25, 3.0], [8.93, 0.12, 4.5]]:
		_tone(b, start, dur / pr[2], f * pr[0], f * pr[0], "sine", vol * pr[1], 0.002, 2.0)


func _pluck(b: PackedFloat32Array, f: float, dur: float, vol := 0.5, bright := 0.5) -> void:
	## Karplus-Strong string.
	var period := maxi(2, int(RATE / f))
	var ring := PackedFloat32Array()
	ring.resize(period)
	for i in period:
		ring[i] = _synth.randf_range(-1.0, 1.0)
	var n := mini(int(dur * RATE), b.size())
	var idx := 0
	var decay := 0.996 + 0.0035 * bright
	for i in n:
		var a := ring[idx]
		var nx := ring[(idx + 1) % period]
		ring[idx] = (a + nx) * 0.5 * decay
		b[i] += a * vol * (1.0 - float(i) / n)
		idx = (idx + 1) % period


func _wav(b: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var peak := 0.0
	for v in b:
		peak = maxf(peak, absf(v))
	var g := 0.9 / peak if peak > 0.9 else 1.0
	var bytes := PackedByteArray()
	bytes.resize(b.size() * 2)
	for i in b.size():
		bytes.encode_s16(i * 2, int(clampf(b[i] * g, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = b.size()
	return w


func _build_sounds() -> Dictionary:
	_synth.seed = 7
	var snd := {}
	var b: PackedFloat32Array
	# movement
	b = _buf(0.14); _tone(b, 0, 0.14, 260, 640, "square", 0.12, 0.003, 1.4); _tone(b, 0, 0.12, 260, 640, "sine", 0.3)
	snd["jump"] = _wav(b)
	b = _buf(0.12); _noise(b, 0, 0.09, 0.45, 0.12, 2.0); _tone(b, 0, 0.1, 150, 60, "sine", 0.4, 0.002, 1.5)
	snd["land"] = _wav(b)
	b = _buf(0.3); _noise(b, 0, 0.25, 0.8, 0.08, 2.0); _tone(b, 0, 0.28, 120, 38, "sine", 0.7, 0.002, 1.2)
	snd["land_hard"] = _wav(b)
	b = _buf(0.05); _noise(b, 0, 0.045, 0.35, 0.25, 3.0)
	snd["step"] = _wav(b)
	# gathering
	b = _buf(0.22); _tone(b, 0, 0.07, 1175, 1175, "tri", 0.3); _tone(b, 0.06, 0.16, 1568, 1568, "tri", 0.3, 0.002, 1.5)
	snd["coin"] = _wav(b)
	b = _buf(0.5)
	for i in 4:
		_bell(b, i * 0.05, 0.4, [1047.0, 1319.0, 1568.0, 2093.0][i], 0.22)
	snd["gem"] = _wav(b)
	b = _buf(0.18); _bell(b, 0, 0.18, 1850, 0.35); _noise(b, 0, 0.025, 0.6, 0.9, 1.0)
	snd["strike"] = _wav(b)
	b = _buf(0.12); _noise(b, 0, 0.1, 0.6, 0.2, 2.0); _tone(b, 0, 0.08, 300, 180, "tri", 0.25)
	snd["strike_dull"] = _wav(b)
	b = _buf(0.7); _noise(b, 0, 0.45, 0.9, 0.15, 2.5); _tone(b, 0, 0.4, 110, 40, "sine", 0.7, 0.002, 1.2)
	_bell(b, 0.08, 0.5, 1568, 0.18); _bell(b, 0.16, 0.5, 2093, 0.14)
	snd["crack"] = _wav(b)
	b = _buf(1.3); _noise(b, 0, 0.7, 1.0, 0.1, 2.5); _tone(b, 0, 0.6, 90, 32, "sine", 0.8, 0.002, 1.2)
	for i in 6:
		_bell(b, 0.1 + i * 0.07, 0.6, [1319.0, 1568.0, 1760.0, 2093.0, 2349.0, 2637.0][i], 0.15)
	snd["crack_great"] = _wav(b)
	b = _buf(0.9)
	for i in 4:
		_tone(b, i * 0.08, 0.35, [523.0, 659.0, 784.0, 1047.0][i], [523.0, 659.0, 784.0, 1047.0][i], "tri", 0.25, 0.004, 1.5)
	_bell(b, 0.32, 0.55, 2093, 0.2)
	snd["load"] = _wav(b)
	# trouble
	b = _buf(0.3); _tone(b, 0, 0.28, 420, 110, "saw", 0.22, 0.002, 1.3); _noise(b, 0, 0.08, 0.4, 0.4, 2.0)
	snd["hurt"] = _wav(b)
	b = _buf(0.5); _tone(b, 0, 0.22, 392, 392, "tri", 0.35, 0.004, 0.8); _tone(b, 0.2, 0.3, 294, 277, "tri", 0.35, 0.004, 1.2)
	snd["bad"] = _wav(b)
	b = _buf(0.75)
	for i in 4:
		_tone(b, i * 0.17, 0.16, 660.0 if i % 2 == 0 else 880.0, 660.0 if i % 2 == 0 else 880.0, "square", 0.14, 0.004, 0.3)
	snd["alarm"] = _wav(b)
	b = _buf(0.5); _tone(b, 0, 0.45, 180, 90, "saw", 0.15, 0.01, 1.0); _noise(b, 0, 0.4, 0.35, 0.05, 1.5, 0.05)
	snd["sab"] = _wav(b)
	# the world
	b = _buf(1.0); _noise(b, 0, 0.95, 0.9, 0.03, 1.2, 0.1); _tone(b, 0, 0.9, 55, 90, "sine", 0.4, 0.1, 1.0)
	snd["door"] = _wav(b)
	b = _buf(0.6); _bell(b, 0, 0.6, 1319, 0.25); _bell(b, 0.09, 0.5, 1760, 0.2)
	snd["chime"] = _wav(b)
	b = _buf(2.2); _bell(b, 0, 2.2, 440, 0.45); _bell(b, 0.0, 1.6, 880, 0.12)
	snd["bell"] = _wav(b)
	b = _buf(1.2)
	for i in 3:
		_tone(b, i * 0.1, 1.0 - i * 0.1, [523.0, 659.0, 784.0][i], [523.0, 659.0, 784.0][i], "tri", 0.22, 0.01, 1.0)
	_tone(b, 0.3, 0.9, 1047, 1047, "square", 0.06, 0.01, 1.0)
	snd["fanfare"] = _wav(b)
	b = _buf(2.0)
	for i in 5:
		var f: float = [523.0, 659.0, 784.0, 1047.0, 1319.0][i]
		_tone(b, i * 0.11, 1.9 - i * 0.11, f, f, "tri", 0.2, 0.005, 1.6)
	_bell(b, 0.55, 1.4, 2093, 0.18)
	snd["win"] = _wav(b)
	b = _buf(2.0)
	for i in 4:
		var f: float = [392.0, 349.0, 311.0, 262.0][i]
		_tone(b, i * 0.28, 0.9 if i < 3 else 1.1, f, f * 0.99, "tri", 0.25, 0.01, 1.3)
	snd["lose"] = _wav(b)
	# interface
	b = _buf(0.04); _tone(b, 0, 0.035, 1400, 1100, "sine", 0.35, 0.001, 2.0)
	snd["click"] = _wav(b)
	b = _buf(0.25); _tone(b, 0, 0.2, 880, 1320, "tri", 0.25, 0.003, 1.5)
	snd["buy"] = _wav(b)
	return snd


func _build_instruments() -> Dictionary:
	_synth.seed = 11
	var ins := {}
	var b: PackedFloat32Array
	b = _buf(1.6); _pluck(b, C4, 1.6, 0.55, 0.6)
	ins["pluck"] = _wav(b)
	b = _buf(1.4); _bell(b, 0, 1.4, C4, 0.5)
	ins["mallet"] = _wav(b)
	b = _buf(3.4)
	for d in [0.997, 1.0, 1.004]:
		_tone(b, 0, 3.4, C4 * d, C4 * d, "tri", 0.16, 0.6, 0.8)
	_tone(b, 0, 3.4, C4 * 0.5, C4 * 0.5, "sine", 0.18, 0.6, 0.8)
	ins["pad"] = _wav(b)
	b = _buf(1.2); _tone(b, 0, 1.2, C4 / 2, C4 / 2, "sine", 0.65, 0.01, 1.3); _tone(b, 0, 0.5, C4 / 2, C4 / 2, "tri", 0.2, 0.01, 2.0)
	ins["bass"] = _wav(b)
	b = _buf(0.3); _tone(b, 0, 0.28, 130, 45, "sine", 0.9, 0.002, 1.5)
	ins["kick"] = _wav(b)
	b = _buf(0.08); _noise(b, 0, 0.07, 0.5, 0.85, 2.5, 0.01)
	ins["shaker"] = _wav(b)
	b = _buf(0.4); _tone(b, 0, 0.35, 1600, 2600, "sine", 0.35, 0.002, 2.5)
	ins["drip"] = _wav(b)
	b = _buf(0.35)
	for i in 3:
		_tone(b, i * 0.07, 0.09, 180, 120, "square", 0.12, 0.004, 1.0)
	ins["frog"] = _wav(b)
	return ins
