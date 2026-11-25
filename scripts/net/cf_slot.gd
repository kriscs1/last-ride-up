class_name CFSlot
extends RefCounted
## A player's seat on the server. Survives disconnects for CF.RECONNECT_GRACE seconds.

var id := ""
var token := ""
var name := "Explorer"
var color := Color.WHITE
var animal := ""            # preferred animal ("" = any); the colour decides the actual one
var hat := "none"
var face := "none"
var peer := 0               # 0 while disconnected
var connected := true
var last_seen := 0          # msec
var room_code := ""
var inputs: Array = []      # queued CFInput, oldest first
var last_input := CFInput.new()
var ack := 0                # last input seq the server has applied
