class_name CFMover
extends RefCounted

var id := ""
var kind := "h"   # h: horizontal, v: vertical lift
var x := 0.0
var y := 0.0
var w := 80.0
var h := 14.0
var min_pos := 0.0
var max_pos := 0.0
var speed := 70.0
var dir := 1
var wait := 0.0
var paused := 0.0
var dx := 0.0
var dy := 0.0
var jammed := false


func step(dt: float) -> void:
	var ox := x
	var oy := y
	if jammed:
		dx = 0.0
		dy = 0.0
		return
	if paused > 0.0:
		paused = maxf(0.0, paused - dt)
	else:
		var p := x if kind == "h" else y
		p += dir * speed * dt
		if p <= min_pos:
			p = min_pos
			dir = 1
			paused = wait
		if p >= max_pos:
			p = max_pos
			dir = -1
			paused = wait
		if kind == "h":
			x = p
		else:
			y = p
	dx = x - ox
	dy = y - oy
