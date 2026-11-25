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
var owned := {}             # paid product ids the server has checked for this player
var steamid := ""           # set once a Steam Web API ticket checks out
var steam_currency := ""
var peer := 0               # 0 while disconnected
var connected := true
var last_seen := 0          # msec
var room_code := ""
var inputs: Array = []      # queued CFInput, oldest first
var last_input := CFInput.new()
var ack := 0                # last input seq the server has applied
var voice_mode := "off"     # CF.VOICE_MODES; "off" neither sends nor receives voice
var chat_at := -100000      # msec of the last quick-chat line
var voice_tokens := float(CF.VOICE_MAX_PACKETS)
var voice_tokens_at := 0    # msec
var room_muted := false     # muted in the current room after enough reports
