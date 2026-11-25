extends Node
## Entry point. A dedicated server (started with -- --server) needs no visuals;
## everything else is a game client.


func _ready() -> void:
	if Net.role == "server":
		print("Last Ride Up dedicated server ready. Press Ctrl+C to stop.")
		return
	add_child(CFGameClient.new())
