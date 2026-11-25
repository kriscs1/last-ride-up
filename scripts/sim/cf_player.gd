class_name CFPlayer
extends RefCounted

var id := ""
var name := "Explorer"
var color := Color("#2f8f86")
var connected := true

var x := 0.0
var y := 0.0
var w := 22.0
var h := 28.0
var vx := 0.0
var vy := 0.0
var on_ground := false
var coyote := 0.0
var jump_buf := 0.0
var drop_t := 0.0
var facing := 1
var dash_t := 0.0
var ability_cd := 0.0
var carried := 0
var capacity := CF.CAPACITY
var climbing := false
var stun_t := 0.0
var invuln_t := 0.0
var recover_t := 0.0        # > 0 while being lifted out of a pit
var rec_from := Vector2.ZERO
var rec_to := Vector2.ZERO
var cp := 0
var ride_id := ""
var last_safe := Vector2.INF
var full_msg_t := 0.0
var land_t := 0.0
var run_ph := 0.0
var aboard := false
var coop_item := -1
var fake_carried := 0        # how much of `carried` is fool's stone (server only)
var strike_cd := 0.0
var stats := {"collected": 0, "deposited": 0, "trips": 0, "falls": 0, "repairs": 0, "lost": 0}

# Hidden roles. On the server these are the truth. A client knows only its own role, its fellow
# traitors (if it is one), and the roles of exiled players. Everyone learns every role at the end.
var role := "explorer"       # explorer or traitor
var guile := 0.0             # traitors only (server and that traitor's own client)
var sab_lock := 0.0          # a traitor can't sabotage again until this match time
var sab_count := 0           # server only, revealed at the end
var exiled := false          # voted out at a meeting: out of play for the rest of the match
var meetings_left := CF.MEETINGS_EACH


func busy() -> bool:
	## True while being lifted out of a pit: no control, no interaction.
	return recover_t > 0.0


func out_of_play() -> bool:
	return aboard or exiled


func centre() -> Vector2:
	return Vector2(x + w / 2.0, y + h / 2.0)


func copy_motion_from(o: CFPlayer) -> void:
	x = o.x; y = o.y; vx = o.vx; vy = o.vy; on_ground = o.on_ground; coyote = o.coyote
	jump_buf = o.jump_buf; drop_t = o.drop_t; facing = o.facing; dash_t = o.dash_t
	ability_cd = o.ability_cd; ride_id = o.ride_id; land_t = o.land_t; run_ph = o.run_ph
	climbing = o.climbing; stun_t = o.stun_t; invuln_t = o.invuln_t; recover_t = o.recover_t; rec_from = o.rec_from; rec_to = o.rec_to
