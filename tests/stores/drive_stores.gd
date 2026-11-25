extends SceneTree
## Client side of the mock-store test: talks to a real game server that talks to mock_stores.py.
## Run from the project folder (bash), with OUT a scratch folder:
##   python tests/stores/mock_stores.py . $OUT &
##   STEAM_PUBLISHER_KEY=testkey STEAM_APP_ID=480 STEAM_API_BASE=http://127.0.0.1:8765/ ##   APPLE_PRIVATE_KEY_PATH=res://tests/fixtures/test_apple_key.p8 APPLE_KEY_ID=K1 APPLE_ISSUER_ID=I1 ##   APPLE_BUNDLE_ID=com.test.lru APPLE_API_BASES=http://127.0.0.1:8765/apple,http://127.0.0.1:8765/applesb ##   GOOGLE_PLAY_PACKAGE=com.test.lru GOOGLE_PLAY_PUBLIC_KEY=<"pub" from $OUT/google.json> ##   godot --headless --path . -- --server --test-purchases &
##   GOOGLE_JSON=$OUT/google.json godot --headless --path . --script res://tests/stores/drive_stores.gd
## Every line should start with PASS. The server records the test purchase in user://steam_purchases.json; delete it afterwards.
var gc
var net
var got := {"prices": {}, "owned": [], "order": "", "error": ""}

func _initialize() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	_run.call_deferred()

func _wait(sec: float) -> void:
	await create_timer(sec).timeout

func _me() -> Dictionary:
	for e in gc.room.get("roster", []):
		if e["id"] == gc.my_id:
			return e
	return {}

func _check(name: String, ok: bool, detail = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])

func _run() -> void:
	await _wait(0.5)
	gc = current_scene.get_child(0)
	net = root.get_node("Net")
	net.steam_prices.connect(func(p): got["prices"] = p)
	net.steam_owned.connect(func(o): got["owned"] = o)
	net.steam_order.connect(func(_p, oid, err): got["order"] = oid; got["error"] = err)
	gc.ui._on_quick()
	var t := 0.0
	while gc.room.get("roster", []).is_empty() and t < 10.0:
		await _wait(0.25); t += 0.25
	var g = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GOOGLE_JSON")))

	# 1. wearing paid items before any proof: hidden from the room
	net.send_look("fox", "crown", "shades")
	await _wait(0.5)
	_check("unbought crown hidden", _me().get("hat") == "none", _me())

	# 2. Steam: bad ticket ignored; good ticket → prices in EUR + (empty) records
	net.send_steam_auth("ffff")
	net.send_steam_buy("hat_crown")
	await _wait(0.8)
	_check("buying before Steam sign-in is refused", got["order"] == "" and got["error"] != "", got["error"])
	net.send_steam_auth("abcd1234")
	await _wait(1.0)
	_check("Steam prices in the player's currency", got["prices"].get("hat_crown") == "€1.99" and got["prices"].get("hat_chef") == "€0.99", got["prices"])
	got["error"] = ""
	net.send_steam_buy("hat_crown")
	await _wait(1.0)
	_check("InitTxn order created", got["order"] != "" and got["error"] == "", [got["order"], got["error"]])
	net.send_steam_finalize(got["order"])
	await _wait(1.0)
	_check("FinalizeTxn records the crown", got["owned"] == ["hat_crown"], got["owned"])
	_check("crown now shown to the room", _me().get("hat") == "crown", _me())

	# 3. Google Play: forged purchase rejected, signed one accepted
	net.send_look("fox", "crown", "eyepatch")
	net.send_proofs([g["forged"]])
	await _wait(0.8)
	_check("forged Google purchase rejected", _me().get("face") == "none", _me())
	net.send_look("fox", "crown", "shades")
	net.send_proofs([g["good"]])
	await _wait(0.8)
	_check("signed Google purchase accepted", _me().get("face") == "shades", _me())

	# 4. App Store: transaction found in sandbox after production says 404; unknown id rejected
	net.send_look("fox", "crown", "monocle")
	net.send_proofs([{"store": "app_store", "transaction_id": "1999"}])
	await _wait(1.5)
	_check("unknown App Store transaction rejected", _me().get("face") == "none", _me())
	net.send_proofs([{"store": "app_store", "transaction_id": "2000"}])
	await _wait(1.5)
	_check("App Store transaction accepted (sandbox)", _me().get("face") == "monocle", _me())

	# 5. test-store proof (server runs with --test-purchases)
	net.send_look("fox", "chef", "monocle")
	net.send_proofs([{"store": "test", "product": "hat_chef"}])
	await _wait(0.6)
	_check("test-store proof accepted with --test-purchases", _me().get("hat") == "chef", _me())

	# 6. a reconnecting Steam player gets their records back
	got["owned"] = []
	net.send_steam_owned()
	await _wait(0.6)
	_check("Steam restore returns records", got["owned"] == ["hat_crown"], got["owned"])
	quit()
