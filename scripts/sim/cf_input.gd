class_name CFInput
extends RefCounted
## One frame of player intent. Clients send only this; the server decides what happens.

var seq := 0
var move_x := 0.0
var up := false
var down := false
var jump := false       # pressed this frame
var jump_held := false
var act := false        # pressed this frame
var act_held := false
var ability := false    # pressed this frame


func duplicate_held() -> CFInput:
	## Same held state, no presses: used when a frame is missing.
	var f := CFInput.new()
	f.seq = seq
	f.move_x = move_x
	f.up = up
	f.down = down
	f.jump_held = jump_held
	f.act_held = act_held
	return f


func to_wire() -> Array:
	var flags := (1 if down else 0) | (2 if jump else 0) | (4 if jump_held else 0) | (8 if act else 0) | (16 if act_held else 0) | (32 if ability else 0) | (64 if up else 0)
	return [seq, int(round(move_x * 100.0)), flags]


static func from_wire(a: Variant) -> CFInput:
	## Sanitises untrusted input: clamps everything, rejects malformed frames.
	if typeof(a) != TYPE_ARRAY or a.size() != 3:
		return null
	var f := CFInput.new()
	f.seq = int(a[0])
	f.move_x = clampf(float(a[1]) / 100.0, -1.0, 1.0)
	var flags := int(a[2])
	f.down = flags & 1 != 0
	f.jump = flags & 2 != 0
	f.jump_held = flags & 4 != 0
	f.act = flags & 8 != 0
	f.act_held = flags & 16 != 0
	f.ability = flags & 32 != 0
	f.up = flags & 64 != 0
	return f
