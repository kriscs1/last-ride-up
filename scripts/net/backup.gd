extends Node
## Daily backup of the server's records to a Backblaze B2 bucket (child of Net on the server).
##
## Once a day, at B2_BACKUP_HOUR (UTC), the server zips its record files and uploads the zip to
## <bucket>/<B2_PREFIX><date>.zip with the B2 native API. It uploads as soon as it can after that
## hour, so a server that was down at backup time catches up when it starts. A failed upload is
## retried every 30 minutes. Old backups are removed by the bucket's lifecycle rules, not here.
##
## Environment:
##   B2_KEY_ID, B2_APPLICATION_KEY  an application key (best: limited to this bucket, with
##                                  listBuckets + writeFiles only)
##   B2_BUCKET                      bucket name (keep the bucket private)
##   B2_PREFIX                      optional, default "last-ride-up/"
##   B2_BACKUP_HOUR                 optional UTC hour, default 3
##   B2_API_BASE                    optional, for testing (default https://api.backblazeb2.com)
## Command line: -- --server --backup-now   also backs up straight away.

const FILES := ["accounts.json", "bans.txt", "steam_purchases.json", "reports.jsonl"]
const RETRY_SEC := 30 * 60

var key_id := OS.get_environment("B2_KEY_ID")
var app_key := OS.get_environment("B2_APPLICATION_KEY")
var bucket := OS.get_environment("B2_BUCKET")
var prefix := OS.get_environment("B2_PREFIX") if OS.get_environment("B2_PREFIX") != "" else "last-ride-up/"
var hour := int(OS.get_environment("B2_BACKUP_HOUR")) if OS.get_environment("B2_BACKUP_HOUR").is_valid_int() else 3
var api_base := OS.get_environment("B2_API_BASE") if OS.get_environment("B2_API_BASE") != "" else "https://api.backblazeb2.com"
var dir := "user://"
var state_path := "user://backup_state.json"

var last_day := ""        # UTC date of the last good backup
var busy := false
var _next_try := 0.0      # unix time; no attempt before this
var _check_t := 0.0

signal finished(ok: bool, message: String)


func _ready() -> void:
	var st = JSON.parse_string(FileAccess.get_file_as_string(state_path)) if FileAccess.file_exists(state_path) else null
	if st is Dictionary:
		last_day = str(st.get("last_day", ""))
	if not enabled():
		print("Backups to B2: off (B2_KEY_ID, B2_APPLICATION_KEY and B2_BUCKET not set)")
		return
	print("Backups to B2: daily at %02d:00 UTC to %s/%s (last: %s)" % [hour, bucket, prefix, last_day if last_day != "" else "never"])
	if OS.get_cmdline_user_args().has("--backup-now"):
		run()


func enabled() -> bool:
	return key_id != "" and app_key != "" and bucket != ""


static func today() -> String:
	return Time.get_date_string_from_system(true)


func due(now_unix: float) -> bool:
	## A backup is due once a day, from the backup hour on.
	if not enabled() or busy or now_unix < _next_try:
		return false
	var d := Time.get_datetime_dict_from_unix_time(int(now_unix))
	var day := "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]
	return day != last_day and int(d["hour"]) >= hour


func poll(delta: float) -> void:
	## Called by Net once a second.
	_check_t += delta
	if _check_t < 60.0:
		return
	_check_t = 0.0
	if due(Time.get_unix_time_from_system()):
		run()


# ---------------------------------------------------------------- making the zip

func make_zip(path: String) -> Array:
	## Zips whichever record files exist; returns the names that went in.
	var zp := ZIPPacker.new()
	if zp.open(path) != OK:
		return []
	var put := []
	for f in FILES:
		var src: String = dir.path_join(f)
		if FileAccess.file_exists(src):
			zp.start_file(f)
			zp.write_file(FileAccess.get_file_as_bytes(src))
			zp.close_file()
			put.append(f)
	zp.close()
	return put


static func sha1_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(data)
	return ctx.finish().hex_encode()


# ---------------------------------------------------------------- uploading (B2 native API v2)

func run() -> void:
	if busy or not enabled():
		return
	busy = true
	var tmp := "user://backup_upload.zip"
	var put := make_zip(tmp)
	var data := FileAccess.get_file_as_bytes(tmp)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	if put.is_empty() or data.is_empty():
		_end(false, "nothing to back up yet")
		return
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	var name := "%s%sZ.zip" % [prefix, stamp]
	var basic := Marshalls.utf8_to_base64(key_id + ":" + app_key)
	_req(api_base + "/b2api/v2/b2_authorize_account", ["Authorization: Basic " + basic], HTTPClient.METHOD_GET, PackedByteArray(),
		func(code: int, auth: Dictionary):
			if code != 200:
				_end(false, "authorize failed (%d %s)" % [code, auth.get("code", "")])
				return
			var api_url := str(auth.get("apiUrl", ""))
			var token := str(auth.get("authorizationToken", ""))
			var allowed = auth.get("allowed", {})
			var with_bucket := func(bucket_id: String):
				_req(api_url + "/b2api/v2/b2_get_upload_url", ["Authorization: " + token, "Content-Type: application/json"],
					HTTPClient.METHOD_POST, JSON.stringify({"bucketId": bucket_id}).to_utf8_buffer(),
					func(c2: int, up: Dictionary):
						if c2 != 200:
							_end(false, "get_upload_url failed (%d %s)" % [c2, up.get("code", "")])
							return
						_upload(str(up["uploadUrl"]), str(up["authorizationToken"]), name, data, put))
			if allowed is Dictionary and str(allowed.get("bucketName", "")) == bucket and str(allowed.get("bucketId", "")) != "":
				with_bucket.call(str(allowed["bucketId"]))
				return
			_req(api_url + "/b2api/v2/b2_list_buckets", ["Authorization: " + token, "Content-Type: application/json"],
				HTTPClient.METHOD_POST, JSON.stringify({"accountId": str(auth.get("accountId", "")), "bucketName": bucket}).to_utf8_buffer(),
				func(c3: int, lb: Dictionary):
					var bs = lb.get("buckets", [])
					if c3 != 200 or not bs is Array or bs.is_empty():
						_end(false, "bucket %s not found (%d %s)" % [bucket, c3, lb.get("code", "")])
						return
					with_bucket.call(str(bs[0]["bucketId"]))))


func _upload(url: String, token: String, name: String, data: PackedByteArray, put: Array) -> void:
	var headers := ["Authorization: " + token, "X-Bz-File-Name: " + name.uri_encode().replace("%2F", "/"),
		"Content-Type: application/zip", "X-Bz-Content-Sha1: " + sha1_hex(data),
		"X-Bz-Server-Side-Encryption: AES256", "X-Bz-Info-files: " + ",".join(put).uri_encode()]
	_req(url, headers, HTTPClient.METHOD_POST, data, func(code: int, resp: Dictionary):
		if code != 200:
			_end(false, "upload failed (%d %s)" % [code, resp.get("code", "")])
			return
		last_day = today()
		var f := FileAccess.open(state_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"last_day": last_day, "last_file": name}))
		_end(true, "%s (%d bytes: %s)" % [name, data.size(), ", ".join(put)]))


func _end(ok: bool, message: String) -> void:
	busy = false
	if ok:
		print("Backup uploaded to B2: " + message)
	else:
		_next_try = Time.get_unix_time_from_system() + RETRY_SEC
		push_warning("Backup to B2 failed, retrying in 30 minutes: " + message)
	finished.emit(ok, message)


func _req(url: String, headers: Array, method: int, body: PackedByteArray, done: Callable) -> void:
	var h := HTTPRequest.new()
	h.timeout = 120.0
	add_child(h)
	h.request_completed.connect(func(_r: int, code: int, _hd: PackedStringArray, b: PackedByteArray):
		h.queue_free()
		var j = JSON.parse_string(b.get_string_from_utf8())
		done.call(code, j if j is Dictionary else {}))
	if h.request_raw(url, PackedStringArray(headers), method, body) != OK:
		h.queue_free()
		done.call(0, {})
