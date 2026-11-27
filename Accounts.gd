extends RefCounted
## Server-side account store for the official (dedicated) server.
##
## Saved as JSON in $BONKFISH_DATA_DIR (a Railway Volume, e.g. /data) or user:// when unset.
## Passwords are never stored: only a per-user random salt and an iterated SHA-256 of
## salt + password. Login tokens are random and only their SHA-256 is stored.

const ITERATIONS := 3000      # slow enough to resist guessing, fast enough not to stall matches
const MAX_TOKENS := 5
const NAME_RE := "^[A-Za-z0-9_]{3,14}$"

# --- progression -------------------------------------------------------------
const MAX_LEVEL := 30
## Fish index (Fish.LINEUP order) -> level that unlocks it.
const FISH_UNLOCK := {0: 1, 5: 1, 1: 2, 2: 3, 4: 4, 3: 6, 6: 8}  # Koi, Tuna | Sword, Puffer, Tetra, Shark, Angler
const XP_ROUND := 10
const XP_KNOCKOUT := 15
const XP_ROUND_WIN := 25
const XP_MATCH_WIN := 60

var users := {}            # lowercase name -> {name, salt, hash, xp, tokens:[sha256], created}
var _path := ""
var _dirty := false
var _name_re := RegEx.create_from_string(NAME_RE)
var _fails := {}           # lowercase name -> [count, last_time]


func _init() -> void:
	var dir := OS.get_environment("BONKFISH_DATA_DIR")
	if dir == "":
		dir = "user://"
		print("Accounts: BONKFISH_DATA_DIR not set - saving to user:// (lost on redeploy!)")
	DirAccess.make_dir_recursive_absolute(dir)
	_path = dir.path_join("accounts.json")
	if FileAccess.file_exists(_path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(_path))
		if typeof(data) == TYPE_DICTIONARY:
			users = data.get("users", {})
	print("Accounts: %d loaded from %s" % [users.size(), _path])


## Write to disk if anything changed (Net calls this every few seconds).
func flush() -> void:
	if not _dirty:
		return
	_dirty = false
	var tmp := _path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Accounts: can't write %s" % tmp)
		return
	f.store_string(JSON.stringify({"users": users}))
	f.close()
	DirAccess.rename_absolute(tmp, _path)   # replace atomically so a crash can't corrupt it


static func level_for(xp: int) -> int:
	var lvl := 1
	var need := 100
	while xp >= need and lvl < MAX_LEVEL:
		xp -= need
		lvl += 1
		need = 100 + 50 * (lvl - 1)
	return lvl


## [xp into current level, xp needed for next level]
static func level_progress(xp: int) -> Array:
	var lvl := 1
	var need := 100
	while xp >= need and lvl < MAX_LEVEL:
		xp -= need
		lvl += 1
		need = 100 + 50 * (lvl - 1)
	return [xp, need]


static func fish_unlocked(fish: int, level: int) -> bool:
	return level >= FISH_UNLOCK.get(fish, 99)


func _hash(password: String, salt: String) -> String:
	var digest := (salt + password).to_utf8_buffer()
	for i in ITERATIONS:
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		h.update(digest)
		h.update(salt.to_utf8_buffer())
		digest = h.finish()
	return digest.hex_encode()


func _random_hex(n: int) -> String:
	return Crypto.new().generate_random_bytes(n).hex_encode()


func _new_token(key: String) -> String:
	var token := _random_hex(32)
	var toks: Array = users[key]["tokens"]
	toks.append(token.sha256_text())
	while toks.size() > MAX_TOKENS:
		toks.pop_front()
	_dirty = true
	return token


func _locked_out(key: String) -> bool:
	var f: Array = _fails.get(key, [0, 0.0])
	return f[0] >= 5 and Time.get_ticks_msec() / 1000.0 - f[1] < 30.0


func _fail(key: String) -> void:
	var f: Array = _fails.get(key, [0, 0.0])
	_fails[key] = [f[0] + 1, Time.get_ticks_msec() / 1000.0]


## Returns {ok, key, token, error}
func register(name: String, password: String) -> Dictionary:
	if _name_re.search(name) == null:
		return {"ok": false, "error": "Username must be 3-14 letters, numbers or _."}
	if password.length() < 6 or password.length() > 64:
		return {"ok": false, "error": "Password must be 6-64 characters."}
	var key := name.to_lower()
	if users.has(key):
		return {"ok": false, "error": "That username is taken."}
	var salt := _random_hex(16)
	users[key] = {"name": name, "salt": salt, "hash": _hash(password, salt), "xp": 0, "tokens": [],
		"created": Time.get_unix_time_from_system()}
	_dirty = true
	return {"ok": true, "key": key, "token": _new_token(key)}


func login(name: String, password: String) -> Dictionary:
	var key := name.strip_edges().to_lower()
	if _locked_out(key):
		return {"ok": false, "error": "Too many attempts. Wait 30 seconds."}
	if not users.has(key) or _hash(password, users[key]["salt"]) != users[key]["hash"]:
		_fail(key)
		return {"ok": false, "error": "Wrong username or password."}
	_fails.erase(key)
	return {"ok": true, "key": key, "token": _new_token(key)}


func resume(token: String) -> Dictionary:
	var h := token.sha256_text()
	for key in users:
		if h in users[key]["tokens"]:
			return {"ok": true, "key": key, "token": token}
	return {"ok": false, "error": "Session expired, please log in again."}


func logout(key: String, token: String) -> void:
	if users.has(key):
		users[key]["tokens"].erase(token.sha256_text())
		_dirty = true


func add_xp(key: String, amount: int) -> Array:
	## Returns [old_level, new_level, total_xp]
	if not users.has(key):
		return [0, 0, 0]
	var old := level_for(users[key]["xp"])
	users[key]["xp"] = int(users[key]["xp"]) + amount
	_dirty = true
	return [old, level_for(users[key]["xp"]), users[key]["xp"]]


func profile(key: String) -> Dictionary:
	if not users.has(key):
		return {}
	var xp: int = users[key]["xp"]
	var p := level_progress(xp)
	return {"name": users[key]["name"], "xp": xp, "level": level_for(xp), "into": p[0], "need": p[1]}


func is_taken(name: String) -> bool:
	return users.has(name.strip_edges().to_lower())
