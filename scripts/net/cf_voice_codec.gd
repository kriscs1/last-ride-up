class_name CFVoiceCodec
extends RefCounted
## Voice codec: IMA ADPCM, 4 bits a sample (16 kHz mono → 64 kbit/s). Pure GDScript, so it runs on
## every platform with no native plugin. Opus would be ~3x smaller; this class is the only thing to
## swap if that is ever added.
##
## Packet: [predictor int16][step index u8][samples, two per byte, low nibble first].
## The encoder carries its state from packet to packet and writes it into each header, so every
## packet decodes on its own and a lost packet only loses its own 40 ms.

const STEPS := [
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
	107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
	876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
	4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
	22385, 24623, 27086, 29794, 32767,
]
const INDEX_ADJ := [-1, -1, -1, -1, 2, 4, 6, 8]

var _pred := 0
var _index := 0


func encode(samples: PackedFloat32Array) -> PackedByteArray:
	var n := samples.size()
	var out := PackedByteArray()
	out.resize(3 + (n + 1) / 2)
	out.encode_s16(0, _pred)
	out[2] = _index
	var pred := _pred
	var index := _index
	var byte := 0
	for i in n:
		var s := clampi(int(samples[i] * 32767.0), -32768, 32767)
		var step: int = STEPS[index]
		var diff := s - pred
		var code := 0
		if diff < 0:
			code = 8
			diff = -diff
		var delta := step >> 3
		if diff >= step:
			code |= 4
			diff -= step
			delta += step
		if diff >= (step >> 1):
			code |= 2
			diff -= step >> 1
			delta += step >> 1
		if diff >= (step >> 2):
			code |= 1
			delta += step >> 2
		pred = clampi(pred - delta if code & 8 else pred + delta, -32768, 32767)
		index = clampi(index + INDEX_ADJ[code & 7], 0, 88)
		if i % 2 == 0:
			byte = code
		else:
			out[3 + i / 2] = byte | (code << 4)
	if n % 2 == 1:
		out[3 + n / 2] = byte
	_pred = pred
	_index = index
	return out


static func decode(packet: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if packet.size() < 4:
		return out
	var pred := packet.decode_s16(0)
	var index := clampi(packet[2], 0, 88)
	var n := (packet.size() - 3) * 2
	out.resize(n)
	for i in n:
		var b: int = packet[3 + i / 2]
		var code := (b & 15) if i % 2 == 0 else (b >> 4)
		var step: int = STEPS[index]
		var delta := step >> 3
		if code & 4:
			delta += step
		if code & 2:
			delta += step >> 1
		if code & 1:
			delta += step >> 2
		pred = clampi(pred - delta if code & 8 else pred + delta, -32768, 32767)
		index = clampi(index + INDEX_ADJ[code & 7], 0, 88)
		out[i] = pred / 32768.0
	return out


static func level(samples: PackedFloat32Array) -> float:
	## RMS loudness, for the open-mic gate and the speaking indicator.
	if samples.is_empty():
		return 0.0
	var sum := 0.0
	for v in samples:
		sum += v * v
	return sqrt(sum / samples.size())
