extends Node
## Autoload: networking + ROOMS for Bonkfish.
##
## Transports: ENet (LAN/IP), Steam (GodotSteam), WebSocket (browser + dedicated server).
## The server hosts any number of rooms. Each room has its own players, settings and match.
## - Dedicated/online server: players browse public rooms, create rooms, or join private ones by code.
## - LAN/Steam host: the host owns a single room; joining players drop straight into it.
##
## Message naming: _s_* run on the server (sent by clients), _c_* run on clients (sent by the server).
## _to_server()/_to_peer() call locally instead of over the network when the target is ourselves,
## so a listen-host (server + player in one) works through the exact same code.

signal players_changed          # my room's players/settings changed (or I joined/left a room)
signal status(msg: String)
signal player_left(code: String, id: int)
signal room_list(list: Array)
signal chat_line(line: String)
signal lobbies_found(list: Array)

var PORT := 7777
const MAX_PLAYERS := 8           # hard cap per room
const COLORS := [Color("ff6b6b"), Color("4dabf7"), Color("ffd43b"), Color("69db7c"),
	Color("da77f2"), Color("ff922b"), Color("3bc9db"), Color("f783ac")]
const TEAM_COLORS := [Color("ff5c5c"), Color("4d9dff")]
const TEAM_NAMES := ["Red", "Blue"]
const MODES := ["Free for all", "Teams"]
enum { MODE_FFA, MODE_TEAMS }
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

## Default server for "Play Online" (wss:// = TLS, which Railway provides).
const DEFAULT_SERVER_URL := "wss://bonkfish-production.up.railway.app"

var my_name := "Fish"
var pending_status := ""         # shown by the menu after a scene change

# --- client view: the room I'm in ---
var room := {}                   # {code, name, public, max, mode, wins, leader, in_game}
var players := {}                # id -> {name, color, score, fish, team, joined}
var chat_log: Array[String] = []

# --- server state ---
var dedicated := false
var rooms := {}                  # code -> {code, name, public, max, mode, wins, leader, in_game, players, game, joined}
var peer_room := {}              # peer id -> room code
var peer_names := {}             # peer id -> name

var _online_url := ""
var _retries := 0
var spectating := false          # client: watching a match in my room instead of playing

# --- server protection (anti-spam / anti-crash) ---
const MAX_CONNECTIONS := 200      # peers on one server
const MAX_ROOMS := 100
const HELLO_TIMEOUT := 10.0       # seconds a new connection gets to introduce itself
const RATE_PER_SEC := 12.0        # request budget refill per peer
const RATE_BURST := 30.0
const STRIKES_TO_KICK := 40       # requests refused for spamming before we disconnect the peer
var _connected_at := {}           # peer id -> time it connected (until hello)
var _bucket := {}                 # peer id -> [tokens, last_time]
var _strikes := {}                # peer id -> refused requests
var _ctrl_chars := RegEx.create_from_string("[\\x00-\\x1F\\x7F]")

# --- Steam (GodotSteam GDExtension, Spacewar test app 480) ---
const STEAM_APP_ID := 480
const LOBBY_TAG := "bonkfish"
var steam: Object = null
var steam_ok := false
var lobby_id := 0


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	if is_dedicated_launch():
		print("Bonkfish: starting in dedicated server mode (PORT env = '%s')" % OS.get_environment("PORT"))
		host_dedicated.call_deferred()
		return
	if OS.has_feature("web"):
		# Browsers run the game on one thread: half the physics rate (measured: the ragdoll
		# holds together the same at 60 as at 120). And if a slow frame falls behind, don't
		# catch up with a burst of physics steps - that turns one hitch into a long stutter.
		Engine.physics_ticks_per_second = 60
		Engine.max_physics_steps_per_frame = 4
	_init_steam()


# =============================================================================
# Connection helpers
# =============================================================================

func is_dedicated_launch() -> bool:
	return OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_user_args()


func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func in_room() -> bool:
	return not room.is_empty()


func my_id() -> int:
	return multiplayer.get_unique_id()


func leader_id() -> int:
	return room.get("leader", -1)


func am_leader() -> bool:
	return in_room() and leader_id() == my_id()


func is_teams() -> bool:
	return room.get("mode", MODE_FFA) == MODE_TEAMS


## Server: a dedicated WebSocket server on $PORT (Railway injects it).
func host_dedicated() -> void:
	var port := OS.get_environment("PORT").to_int()
	if port <= 0:
		port = PORT
	var peer := WebSocketMultiplayerPeer.new()
	# Cap what one connection can push at us (oversized/flooded messages get dropped, not buffered).
	peer.inbound_buffer_size = 64 * 1024
	peer.max_queued_packets = 512
	peer.handshake_timeout = 5.0
	var err := peer.create_server(port)
	if err != OK:
		push_error("Bonkfish server: couldn't listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	dedicated = true
	accounts = AccountsScript.new()
	# A headless server otherwise spins as fast as the CPU allows, starving itself (and costing
	# Railway usage). It only relays and runs round logic, so 60 fps / 30 physics ticks is plenty.
	Engine.max_fps = 60
	Engine.physics_ticks_per_second = 30
	multiplayer.multiplayer_peer = peer
	_harden_multiplayer()
	print("Bonkfish dedicated server listening on ws://0.0.0.0:%d" % port)


func _harden_multiplayer() -> void:
	var sm := multiplayer as SceneMultiplayer
	if sm:
		sm.allow_object_decoding = false      # never let clients send us Objects
		sm.max_sync_packet_size = 1350
		sm.max_delta_packet_size = 65535
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)


func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_peers().size() > MAX_CONNECTIONS:
		print("Refusing peer %d: server full" % id)
		_drop(id)
		return
	_connected_at[id] = Time.get_ticks_msec() / 1000.0


func _drop(id: int) -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.disconnect_peer(id)


## Rate limit for anything a client asks the server to do. Returns false (and counts a strike)
## when a peer is spamming; enough strikes and they're disconnected.
func allow(id: int, cost := 1.0) -> bool:
	if id == multiplayer.get_unique_id():
		return true
	if _strikes.get(id, 0) >= STRIKES_TO_KICK:
		return false   # already being disconnected: ignore whatever else it still has queued
	var now := Time.get_ticks_msec() / 1000.0
	var b: Array = _bucket.get(id, [RATE_BURST, now])
	b[0] = minf(RATE_BURST, b[0] + (now - b[1]) * RATE_PER_SEC)
	b[1] = now
	_bucket[id] = b
	if b[0] < cost:
		_strikes[id] = _strikes.get(id, 0) + 1
		if _strikes[id] >= STRIKES_TO_KICK:
			print("Disconnecting peer %d for spamming" % id)
			_drop(id)
		return false
	b[0] -= cost
	return true


## A request from a peer that introduced itself and isn't spamming.
func _ok(id: int, cost := 1.0) -> bool:
	return peer_names.has(id) and allow(id, cost)


## Round-trip time to the server in ms (-1 = unknown). Shown in the HUD and lobby.
var ping_ms := -1
var _ping_timer := 0.0


@rpc("any_peer", "unreliable")
func _s_ping(t: int) -> void:
	var id := _sender()
	if peer_names.has(id) and allow(id, 0.3):
		_to_peer(id, "_c_pong", [t])


@rpc("authority", "unreliable")
func _c_pong(t: int) -> void:
	ping_ms = Time.get_ticks_msec() - t


func _process(delta: float) -> void:
	if accounts:
		_save_timer -= delta
		if _save_timer <= 0.0:
			_save_timer = 5.0
			accounts.flush()
	if is_online() and not multiplayer.is_server():
		_ping_timer -= delta
		if _ping_timer <= 0.0:
			_ping_timer = 2.0
			_s_ping.rpc_id(1, Time.get_ticks_msec())
	elif not is_online():
		ping_ms = -1
	if _connected_at.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for id in _connected_at.keys():
		if now - _connected_at[id] > HELLO_TIMEOUT:
			_connected_at.erase(id)
			print("Disconnecting peer %d: never said hello" % id)
			_drop(id)


# --- Host on this PC (desktop app) ---------------------------------------------------
# Your PC becomes the game server (WebSocket, port 7777) and you play on it too.
# - Desktop friends on your network join  ws://<your LAN IP>:7777
# - Anyone (incl. the website) joins through a Cloudflare quick tunnel, which gives a free
#   https/wss address. If cloudflared is installed we start it and read the address it prints.

signal tunnel_ready(url: String)
const WEB_URL := "https://bonkfish.up.railway.app"
var hosting := false
var tunnel_url := ""           # e.g. https://abc-def.trycloudflare.com
var _tunnel_pid := -1
var _tunnel_thread: Thread
var _tunnel_pipe: FileAccess


func host_online(pname: String) -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = 64 * 1024
	peer.max_queued_packets = 512
	peer.handshake_timeout = 5.0
	if peer.create_server(PORT) != OK:
		status.emit("Couldn't host: port %d is in use." % PORT)
		return false
	multiplayer.multiplayer_peer = peer
	hosting = true
	_host_setup(pname)
	_start_tunnel()
	return true


func lan_ip() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
	return "127.0.0.1"


## Link that opens the website straight into this host's game.
func share_link() -> String:
	if tunnel_url == "":
		return ""
	return "%s/?server=%s" % [WEB_URL, tunnel_url.trim_prefix("https://")]


func _find_cloudflared() -> String:
	# Next to the game, or anywhere on PATH.
	for p in [OS.get_executable_path().get_base_dir().path_join("cloudflared.exe"),
			ProjectSettings.globalize_path("res://").path_join("cloudflared.exe"),
			"C:/Program Files (x86)/cloudflared/cloudflared.exe",   # winget / installer default
			"C:/Program Files/cloudflared/cloudflared.exe"]:
		if FileAccess.file_exists(p):
			return p
	var out := []
	var cmd := "where" if OS.get_name() == "Windows" else "which"
	if OS.execute(cmd, ["cloudflared"], out) == 0 and out.size() > 0:
		var first := String(out[0]).strip_edges().split("\n")[0].strip_edges()
		if first != "":
			return first
	return ""


func _start_tunnel() -> void:
	if OS.has_feature("web"):
		return
	var exe := _find_cloudflared()
	if exe == "":
		print("cloudflared not found - only LAN players can join (see DEPLOY.md)")
		return
	var info := OS.execute_with_pipe(exe, ["tunnel", "--no-autoupdate", "--url", "http://localhost:%d" % PORT], false)
	if info.is_empty():
		return
	_tunnel_pid = info["pid"]
	_tunnel_pipe = info["stderr"]   # cloudflared prints the address on stderr
	_tunnel_thread = Thread.new()
	_tunnel_thread.start(_read_tunnel)
	status.emit("Starting tunnel...")


func _read_tunnel() -> void:
	var re := RegEx.create_from_string("https://[a-z0-9-]+\\.trycloudflare\\.com")
	while _tunnel_pipe and _tunnel_pipe.is_open():
		var line := _tunnel_pipe.get_line()
		var m := re.search(line)
		if m:
			_on_tunnel_url.call_deferred(m.get_string())
		if _tunnel_pipe.eof_reached():
			break


func _on_tunnel_url(url: String) -> void:
	if tunnel_url != "":
		return
	tunnel_url = url
	print("Internet link: ", share_link())
	status.emit("")
	tunnel_ready.emit(url)
	players_changed.emit()


func _stop_tunnel() -> void:
	if _tunnel_pid > 0:
		OS.kill(_tunnel_pid)
		_tunnel_pid = -1
	if _tunnel_thread and _tunnel_thread.is_started():
		_tunnel_thread.wait_to_finish()
	_tunnel_thread = null
	_tunnel_pipe = null
	tunnel_url = ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_stop_tunnel()


## LAN host: ENet server + my own room that others drop into.
func host_game(pname: String) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, 32) != OK:
		status.emit("Couldn't host: port %d is in use." % PORT)
		return false
	multiplayer.multiplayer_peer = peer
	_host_setup(pname)
	return true


func _host_setup(pname: String) -> void:
	_harden_multiplayer()
	my_name = pname
	rooms.clear()
	peer_room.clear()
	peer_names.clear()
	peer_names[1] = _clean_name(pname)
	_create(1, {"name": "%s's room" % _clean_name(pname), "public": true, "max": MAX_PLAYERS,
		"mode": MODE_FFA, "wins": 3})


func join_game(ip: String, pname: String) -> bool:
	my_name = pname
	_online_url = ""
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(ip, PORT) != OK:
		status.emit("That address doesn't look right.")
		return false
	multiplayer.multiplayer_peer = peer
	status.emit("Connecting...")
	return true


## Browser / online play: connect to a dedicated WebSocket server.
func join_online(url: String, pname: String) -> void:
	my_name = pname
	_online_url = url
	_retries = 0
	_connect_ws()


func _connect_ws() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(_online_url) != OK:
		status.emit("Invalid server address.")
		return
	multiplayer.multiplayer_peer = peer
	status.emit("Connecting..." if _retries == 0 else "Connecting... (attempt %d)" % (_retries + 1))


## Disconnect completely.
func leave() -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if steam_ok and lobby_id != 0:
		steam.leaveLobby(lobby_id)
	lobby_id = 0
	if hosting:
		_stop_tunnel()
		hosting = false
	_online_url = ""
	account = {}
	accounts_enabled = false
	room = {}
	players = {}
	spectating = false
	chat_log.clear()
	rooms.clear()
	peer_room.clear()
	peer_names.clear()
	players_changed.emit()


func _on_connected() -> void:
	_retries = 0
	_to_server("_s_hello", [my_name])


func _on_failed() -> void:
	# A sleeping Railway service can refuse the first connection while it wakes: retry a few times.
	if _online_url != "" and _retries < 4:
		_retries += 1
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
		get_tree().create_timer(2.5).timeout.connect(_connect_ws)
		status.emit("Connecting...")
		return
	leave()
	status.emit("Couldn't connect.")


func _on_server_gone() -> void:
	var was_online := _online_url != ""
	leave()
	pending_status = "Disconnected from server." if was_online else "Host disconnected."
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		_leave(id)
		peer_names.erase(id)
		_connected_at.erase(id)
		_bucket.erase(id)
		_strikes.erase(id)
		peer_account.erase(id)


# =============================================================================
# Client API (works for clients and for a listen-host)
# =============================================================================

func refresh_rooms() -> void:            _to_server("_s_list")
func create_room(settings: Dictionary) -> void: _to_server("_s_create", [settings])
func join_room(code: String) -> void:    _to_server("_s_join", [code.strip_edges().to_upper()])
func leave_room() -> void:               _to_server("_s_leave")
func set_room_settings(s: Dictionary) -> void: _to_server("_s_settings", [s])
func choose_fish(i: int) -> void:        _to_server("_s_fish", [i])
func choose_team(t: int) -> void:        _to_server("_s_team", [t])
func kick(id: int) -> void:              _to_server("_s_kick", [id])
func send_chat(text: String) -> void:    _to_server("_s_chat", [text])
func request_start() -> void:            _to_server("_s_start")
func spectate_room(code: String) -> void: _to_server("_s_spectate", [code])
func request_end_match() -> void:        _to_server("_s_end_match")


## Leave the current match from the pause menu.
func leave_match() -> void:
	if spectating:
		spectating = false
		leave_room()
		room = {}
		players = {}
		get_tree().change_scene_to_file("res://Main.tscn")
	elif multiplayer.is_server():
		leave()   # host leaving ends it for everyone
		get_tree().change_scene_to_file("res://Main.tscn")
	else:
		leave_room()
		room = {}
		players = {}
		get_tree().change_scene_to_file("res://Main.tscn")


func _to_server(method: String, args := []) -> void:
	if multiplayer.is_server():
		callv(method, args)
	elif is_online():
		callv("rpc_id", [1, method] + args)


func _to_peer(id: int, method: String, args := []) -> void:
	if id == multiplayer.get_unique_id():
		callv(method, args)
	else:
		callv("rpc_id", [id, method] + args)


func _sender() -> int:
	var s := multiplayer.get_remote_sender_id()
	return s if s != 0 else 1


# =============================================================================
# Server: rooms
# =============================================================================

## Strip control characters and clamp length (names/chat/room names come from untrusted clients).
func _clean_text(s: String, max_len: int) -> String:
	return _ctrl_chars.sub(s.substr(0, max_len * 2), "", true).strip_edges().substr(0, max_len)


func _clean_name(n: String) -> String:
	n = _clean_text(n, 14)
	return n if n != "" else "Fish"


## Type-safe reads from a client-sent settings Dictionary.
func _get_int(d: Dictionary, k: String, def: int) -> int:
	var v = d.get(k, def)
	return int(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else def


func _get_bool(d: Dictionary, k: String, def: bool) -> bool:
	var v = d.get(k, def)
	return v if typeof(v) == TYPE_BOOL else def


func _get_str(d: Dictionary, k: String, def: String) -> String:
	var v = d.get(k, def)
	return v if typeof(v) == TYPE_STRING else def


func _new_code() -> String:
	while true:
		var c := ""
		for i in 4:
			c += CODE_CHARS[randi() % CODE_CHARS.length()]
		if not rooms.has(c):
			return c
	return ""


func _room_info(r: Dictionary) -> Dictionary:
	return {"code": r["code"], "name": r["name"], "public": r["public"], "max": r["max"],
		"mode": r["mode"], "wins": r["wins"], "leader": r["leader"], "in_game": r["in_game"],
		"spectators": r["spectators"].keys()}


## Everyone who should hear about a room: its players and its spectators.
func watchers(code: String) -> Array:
	if multiplayer.is_server() and rooms.has(code):
		return rooms[code]["players"].keys() + rooms[code]["spectators"].keys()
	return players.keys() + room.get("spectators", [])


func _push(code: String) -> void:
	if not rooms.has(code):
		return
	var r: Dictionary = rooms[code]
	var info := _room_info(r)
	for id in watchers(code):
		_to_peer(id, "_c_room", [info, r["players"]])


func _room_say(code: String, line: String) -> void:
	if rooms.has(code):
		for id in watchers(code):
			_to_peer(id, "_c_chat", [line])


func _recolor(r: Dictionary) -> void:
	var ids: Array = r["players"].keys()
	ids.sort_custom(func(a, b): return r["players"][a]["joined"] < r["players"][b]["joined"])
	var i := 0
	for id in ids:
		var p: Dictionary = r["players"][id]
		p["color"] = TEAM_COLORS[p["team"]] if r["mode"] == MODE_TEAMS else COLORS[i % COLORS.size()]
		i += 1


func _smaller_team(r: Dictionary) -> int:
	var n := [0, 0]
	for p in r["players"].values():
		n[p["team"]] += 1
	return 0 if n[0] <= n[1] else 1


func _create(id: int, s: Dictionary) -> void:
	if rooms.size() >= MAX_ROOMS:
		_to_peer(id, "_c_error", ["Room limit reached on this server."])
		return
	if peer_room.has(id):
		_leave(id)
	var code := _new_code()
	var rname := _clean_text(_get_str(s, "name", ""), 24)
	if rname == "":
		rname = "%s's room" % peer_names.get(id, "Fish")
	rooms[code] = {"code": code, "name": rname, "public": _get_bool(s, "public", true),
		"max": clampi(_get_int(s, "max", MAX_PLAYERS), 2, MAX_PLAYERS),
		"mode": clampi(_get_int(s, "mode", MODE_FFA), 0, MODES.size() - 1),
		"wins": clampi(_get_int(s, "wins", 3), 0, 9),   # 0 = endless
		"leader": id, "in_game": false, "players": {}, "spectators": {}, "game": null, "joined": 0}
	print("Room %s created (%s)" % [code, "public" if rooms[code]["public"] else "private"])
	_join(id, code)


func _join(id: int, code: String) -> void:
	if not rooms.has(code):
		_to_peer(id, "_c_error", ["Room %s not found." % code])
		return
	var r: Dictionary = rooms[code]
	if r["players"].has(id):
		return
	if r["in_game"]:
		_to_peer(id, "_c_error", ["Match in progress. You can spectate it."])
		return
	if r["players"].size() >= r["max"]:
		_to_peer(id, "_c_error", ["Room is full."])
		return
	if peer_room.has(id):
		_leave(id)
	r["joined"] += 1
	r["players"][id] = {"name": peer_names.get(id, "Fish"), "color": Color.WHITE, "score": 0,
		"fish": 0, "team": _smaller_team(r), "joined": r["joined"], "level": _peer_level(id)}
	peer_room[id] = code
	_recolor(r)
	_push(code)
	_room_say(code, "%s joined" % peer_names.get(id, "Fish"))


func _spectate(id: int, code: String) -> void:
	if not rooms.has(code):
		_to_peer(id, "_c_error", ["Room %s not found." % code])
		return
	var r: Dictionary = rooms[code]
	if not r["in_game"] or r["game"] == null:
		_to_peer(id, "_c_error", ["No match running in that room."])
		return
	if r["spectators"].size() >= 16:
		_to_peer(id, "_c_error", ["Spectator limit reached."])
		return
	if peer_room.has(id):
		_leave(id)
	r["spectators"][id] = peer_names.get(id, "Fish")
	peer_room[id] = code
	_push(code)
	_room_say(code, "%s is spectating" % peer_names.get(id, "Fish"))
	_to_peer(id, "_c_spectate", [code])


func _leave(id: int) -> void:
	if not peer_room.has(id):
		return
	var code: String = peer_room[id]
	peer_room.erase(id)
	if not rooms.has(code):
		return
	var r: Dictionary = rooms[code]
	if r["spectators"].has(id):
		r["spectators"].erase(id)
		_push(code)
		return
	var pname: String = r["players"].get(id, {}).get("name", "Someone")
	r["players"].erase(id)
	player_left.emit(code, id)  # the room's Game node on the server reacts
	if r["players"].is_empty():
		for sid in r["spectators"].keys():   # nobody left to watch
			peer_room.erase(sid)
			_to_peer(sid, "_c_go_browser", ["Match ended."])
		if r["game"] and is_instance_valid(r["game"]) and r["game"] != get_tree().current_scene:
			r["game"].queue_free()
		rooms.erase(code)
		print("Room %s closed" % code)
		return
	if r["leader"] == id:
		var best := -1
		for pid in r["players"]:
			if best == -1 or r["players"][pid]["joined"] < r["players"][best]["joined"]:
				best = pid
		r["leader"] = best
	_recolor(r)
	_push(code)
	_room_say(code, "%s left" % pname)


func _member_room(id: int) -> Dictionary:
	var code: String = peer_room.get(id, "")
	var r: Dictionary = rooms.get(code, {})
	return r if not r.is_empty() and r["players"].has(id) else {}


@rpc("any_peer", "reliable")
func _s_hello(pname: String) -> void:
	var id := _sender()
	if peer_names.has(id) or not allow(id):
		return
	_connected_at.erase(id)
	peer_names[id] = _clean_name(pname)
	_to_peer(id, "_c_server_info", [accounts != null])
	if not dedicated and not rooms.is_empty():
		_join(id, rooms.keys()[0])   # LAN/Steam: straight into the host's room
	else:
		_to_peer(id, "_c_welcome")


@rpc("any_peer", "reliable")
func _s_list() -> void:
	var id := _sender()
	if not _ok(id, 2.0):
		return
	var list := []
	for r in rooms.values():
		if r["public"]:
			list.append({"code": r["code"], "name": r["name"], "count": r["players"].size(),
				"max": r["max"], "mode": r["mode"], "wins": r["wins"], "in_game": r["in_game"],
				"watching": r["spectators"].size()})
		if list.size() >= 60:
			break
	_to_peer(id, "_c_list", [list])


@rpc("any_peer", "reliable")
func _s_create(s: Dictionary) -> void:
	var id := _sender()
	if _ok(id, 8.0) and s.size() <= 10:
		_create(id, s)


@rpc("any_peer", "reliable")
func _s_join(code: String) -> void:
	var id := _sender()
	if _ok(id, 2.0):
		_join(id, _clean_text(code, 4).to_upper())


@rpc("any_peer", "reliable")
func _s_spectate(code: String) -> void:
	var id := _sender()
	if _ok(id, 2.0):
		_spectate(id, _clean_text(code, 4).to_upper())


@rpc("any_peer", "reliable")
func _s_leave() -> void:
	var id := _sender()
	if not _ok(id):
		return
	_leave(id)
	_to_peer(id, "_c_room", [{}, {}])


@rpc("any_peer", "reliable")
func _s_settings(s: Dictionary) -> void:
	var id := _sender()
	if not _ok(id) or s.size() > 10:
		return
	var r := _member_room(id)
	if r.is_empty() or r["leader"] != id or r["in_game"]:
		return
	if s.has("name"):
		var n := _clean_text(_get_str(s, "name", ""), 24)
		if n != "":
			r["name"] = n
	if s.has("public"):
		r["public"] = _get_bool(s, "public", r["public"])
	if s.has("max"):
		r["max"] = clampi(_get_int(s, "max", r["max"]), maxi(2, r["players"].size()), MAX_PLAYERS)
	if s.has("wins"):
		r["wins"] = clampi(_get_int(s, "wins", r["wins"]), 0, 9)
	if s.has("mode"):
		var m := clampi(_get_int(s, "mode", r["mode"]), 0, MODES.size() - 1)
		if m != r["mode"]:
			r["mode"] = m
			if m == MODE_TEAMS:  # rebalance in join order
				var ids: Array = r["players"].keys()
				ids.sort_custom(func(a, b): return r["players"][a]["joined"] < r["players"][b]["joined"])
				for i in ids.size():
					r["players"][ids[i]]["team"] = i % 2
	_recolor(r)
	_push(r["code"])


@rpc("any_peer", "reliable")
func _s_fish(i: int) -> void:
	var id := _sender()
	if not _ok(id):
		return
	var r := _member_room(id)
	if r.is_empty() or r["in_game"]:
		return
	var fish := posmod(i, preload("res://Fish.gd").LINEUP.size())
	if accounts and not AccountsScript.fish_unlocked(fish, maxi(1, _peer_level(id))):
		_to_peer(id, "_c_error", ["That fish is locked."])
		return
	r["players"][id]["fish"] = fish
	_push(r["code"])


@rpc("any_peer", "reliable")
func _s_team(t: int) -> void:
	var id := _sender()
	if not _ok(id):
		return
	var r := _member_room(id)
	if r.is_empty() or r["in_game"] or r["mode"] != MODE_TEAMS:
		return
	r["players"][id]["team"] = clampi(t, 0, 1)
	_recolor(r)
	_push(r["code"])


@rpc("any_peer", "reliable")
func _s_kick(target: int) -> void:
	var id := _sender()
	if not _ok(id):
		return
	var r := _member_room(id)
	if r.is_empty() or r["leader"] != id or target == id or not r["players"].has(target):
		return
	_leave(target)
	_to_peer(target, "_c_kicked")


@rpc("any_peer", "reliable")
func _s_chat(text: String) -> void:
	var id := _sender()
	if not _ok(id, 4.0):   # ~3 messages/second sustained
		return
	var code: String = peer_room.get(id, "")
	text = _clean_text(text, 120)
	if not rooms.has(code) or text == "":
		return
	var watching: bool = rooms[code]["spectators"].has(id)
	_room_say(code, "%s%s: %s" % [peer_names.get(id, "Fish"), " (spectator)" if watching else "", text])


@rpc("any_peer", "reliable")
func _s_start() -> void:
	var id := _sender()
	if not _ok(id, 4.0):
		return
	var r := _member_room(id)
	if r.is_empty() or r["leader"] != id or r["in_game"]:
		return
	for p in r["players"].values():
		p["score"] = 0
	r["in_game"] = true
	_push(r["code"])
	_set_lobby_joinable(false)
	var code: String = r["code"]
	if not r["players"].has(multiplayer.get_unique_id()):
		# Dedicated server: run the room's match as its own node (same path as on the clients).
		var g := _make_game(code)
		get_tree().root.add_child(g)
		r["game"] = g
	for pid in r["players"]:
		_to_peer(pid, "_c_go_game", [code])


## Leader stops the match (e.g. an endless one) and takes everyone back to the room lobby.
@rpc("any_peer", "reliable")
func _s_end_match() -> void:
	var id := _sender()
	if not _ok(id, 2.0):
		return
	var r := _member_room(id)
	if not r.is_empty() and r["leader"] == id and r["in_game"]:
		end_match(r["code"])


func _make_game(code: String) -> Node:
	var g: Node = load("res://Game.tscn").instantiate()
	g.name = "Room_" + code
	g.room_code = code
	return g


## Called by a room's Game (server) when someone wins a round.
func add_score(code: String, ids: Array) -> void:
	if not rooms.has(code):
		return
	for id in ids:
		if rooms[code]["players"].has(id):
			rooms[code]["players"][id]["score"] += 1
	_push(code)


## Called by a room's Game (server) when the match is over.
func end_match(code: String) -> void:
	if not rooms.has(code):
		return
	var r: Dictionary = rooms[code]
	r["in_game"] = false
	_set_lobby_joinable(true)
	for sid in r["spectators"].keys():   # spectators go back to the room browser
		peer_room.erase(sid)
		_to_peer(sid, "_c_go_browser", ["Match ended."])
	r["spectators"].clear()
	_push(code)
	for pid in r["players"]:
		_to_peer(pid, "_c_go_lobby")
	if r["game"] and is_instance_valid(r["game"]) and r["game"] != get_tree().current_scene:
		r["game"].queue_free()
	r["game"] = null


## Game helpers: the roster / settings of a room (server: authoritative copy, client: my room).
func roster(code: String) -> Dictionary:
	if multiplayer.is_server() and rooms.has(code):
		return rooms[code]["players"]
	return players


func room_view(code: String) -> Dictionary:
	if multiplayer.is_server() and rooms.has(code):
		return rooms[code]
	return room


func is_spectator_of(code: String, id: int) -> bool:
	return rooms.has(code) and rooms[code]["spectators"].has(id)


# =============================================================================
# Client handlers
# =============================================================================

@rpc("authority", "reliable")
func _c_welcome() -> void:
	status.emit("")
	players_changed.emit()
	refresh_rooms()


@rpc("authority", "reliable")
func _c_list(list: Array) -> void:
	room_list.emit(list)


@rpc("authority", "reliable")
func _c_error(msg: String) -> void:
	status.emit(msg)


@rpc("authority", "reliable")
func _c_room(info: Dictionary, plist: Dictionary) -> void:
	var old_code: String = room.get("code", "")
	var old_ids := players.keys()
	if info.get("code", "") != old_code:
		chat_log.clear()
	room = info
	players = plist
	for id in old_ids:
		if not players.has(id):
			player_left.emit(old_code, id)
	if not info.is_empty():
		status.emit("")
	players_changed.emit()


@rpc("authority", "reliable")
func _c_chat(line: String) -> void:
	chat_log.append(line)
	while chat_log.size() > 40:
		chat_log.pop_front()
	chat_line.emit(line)


@rpc("authority", "reliable")
func _c_kicked() -> void:
	room = {}
	players = {}
	pending_status = "You were kicked."
	get_tree().change_scene_to_file("res://Main.tscn")


@rpc("authority", "reliable")
func _c_go_game(code: String) -> void:
	var g := _make_game(code)
	get_tree().change_scene_to_node(g)
	if multiplayer.is_server() and rooms.has(code):
		rooms[code]["game"] = g


@rpc("authority", "reliable")
func _c_spectate(code: String) -> void:
	spectating = true
	var g := _make_game(code)
	g.spectator = true
	get_tree().change_scene_to_node(g)


@rpc("authority", "reliable")
func _c_go_browser(msg: String) -> void:
	spectating = false
	room = {}
	players = {}
	pending_status = msg
	get_tree().change_scene_to_file("res://Main.tscn")


@rpc("authority", "reliable")
func _c_go_lobby() -> void:
	get_tree().change_scene_to_file("res://Main.tscn")


# =============================================================================
# Accounts + progression (official/dedicated server only)
# =============================================================================
# PC-hosted, LAN and Steam games have no accounts: everyone plays as a guest with every fish.

const AccountsScript := preload("res://Accounts.gd")
var session_file := "user://session.cfg"

signal account_changed
signal xp_gained(amount: int, reason: String, unlocked: Array)

# server
var accounts: RefCounted = null     # AccountsScript instance on the dedicated server
var peer_account := {}              # peer id -> account key (lowercase username)
var _save_timer := 5.0

# client
var accounts_enabled := false
var account := {}                   # {name, xp, level, into, need} when logged in


func is_logged_in() -> bool:
	return not account.is_empty()


## Level used for fish unlocks: guests are level 1; servers without accounts unlock everything.
func my_level() -> int:
	if not accounts_enabled:
		return AccountsScript.MAX_LEVEL
	return account.get("level", 1)


func register(uname: String, password: String) -> void: _to_server("_s_register", [uname, password])
func login(uname: String, password: String) -> void:    _to_server("_s_login", [uname, password])


func logout() -> void:
	_to_server("_s_logout", [_saved_token()])
	_save_token("")
	account = {}
	account_changed.emit()


func _saved_token() -> String:
	var cf := ConfigFile.new()
	return cf.get_value("s", "token", "") if cf.load(session_file) == OK else ""


func _save_token(token: String) -> void:
	var cf := ConfigFile.new()
	cf.set_value("s", "token", token)
	cf.save(session_file)


# --- server side ---

func _peer_level(id: int) -> int:
	if accounts and peer_account.has(id):
		return accounts.profile(peer_account[id]).get("level", 1)
	return 0


func _signed_in(id: int, res: Dictionary) -> void:
	if not res["ok"]:
		_to_peer(id, "_c_auth", [false, {}, "", res["error"]])
		return
	# One session per account: log out any other connection using it.
	for other in peer_account.keys():
		if other != id and peer_account[other] == res["key"]:
			peer_account.erase(other)
			_to_peer(other, "_c_auth", [false, {}, "", "Logged in somewhere else."])
	peer_account[id] = res["key"]
	var prof: Dictionary = accounts.profile(res["key"])
	peer_names[id] = prof["name"]
	_to_peer(id, "_c_auth", [true, prof, res["token"], ""])
	_refresh_member(id)


## Name/level changed (login, logout, level up): update the player's room entry.
func _refresh_member(id: int) -> void:
	var r := _member_room(id)
	if r.is_empty():
		return
	r["players"][id]["name"] = peer_names.get(id, "Fish")
	r["players"][id]["level"] = _peer_level(id)
	_push(r["code"])


@rpc("any_peer", "reliable")
func _s_register(uname: String, password: String) -> void:
	var id := _sender()
	if accounts == null or not _ok(id, 10.0):
		return
	_signed_in(id, accounts.register(_clean_text(uname, 14), password.substr(0, 64)))


@rpc("any_peer", "reliable")
func _s_login(uname: String, password: String) -> void:
	var id := _sender()
	if accounts == null or not _ok(id, 6.0):
		return
	_signed_in(id, accounts.login(_clean_text(uname, 14), password.substr(0, 64)))


@rpc("any_peer", "reliable")
func _s_resume(token: String) -> void:
	var id := _sender()
	if accounts == null or not _ok(id, 3.0) or token.length() != 64:
		return
	var res: Dictionary = accounts.resume(token)
	if res["ok"]:
		_signed_in(id, res)
	else:
		_to_peer(id, "_c_auth", [false, {}, "", ""])   # quietly drop the stale token


@rpc("any_peer", "reliable")
func _s_logout(token: String) -> void:
	var id := _sender()
	if accounts == null or not _ok(id) or not peer_account.has(id):
		return
	accounts.logout(peer_account[id], token)
	peer_account.erase(id)
	_refresh_member(id)


## Called by a room's Game (server). No-op for guests and servers without accounts.
func add_xp(id: int, amount: int, reason: String) -> void:
	if accounts == null or not peer_account.has(id) or amount <= 0:
		return
	var res: Array = accounts.add_xp(peer_account[id], amount)
	var unlocked := []
	if res[1] > res[0]:
		for fish in AccountsScript.FISH_UNLOCK:
			var need: int = AccountsScript.FISH_UNLOCK[fish]
			if need > res[0] and need <= res[1]:
				unlocked.append(fish)
		_refresh_member(id)
	_to_peer(id, "_c_xp", [amount, reason, accounts.profile(peer_account[id]), unlocked])


# --- client side ---

@rpc("authority", "reliable")
func _c_server_info(has_accounts: bool) -> void:
	accounts_enabled = has_accounts
	if has_accounts and _saved_token() != "":
		_to_server("_s_resume", [_saved_token()])
	account_changed.emit()


@rpc("authority", "reliable")
func _c_auth(ok: bool, profile: Dictionary, token: String, error: String) -> void:
	if ok:
		account = profile
		if token != "":
			_save_token(token)
		status.emit("")
	else:
		account = {}
		if error == "" or error.begins_with("Logged in somewhere"):
			_save_token("")
		if error != "":
			status.emit(error)
	account_changed.emit()


@rpc("authority", "reliable")
func _c_xp(amount: int, reason: String, profile: Dictionary, unlocked: Array) -> void:
	account = profile
	xp_gained.emit(amount, reason, unlocked)
	account_changed.emit()


# =============================================================================
# Steam (desktop only)
# =============================================================================

func _init_steam() -> void:
	if not Engine.has_singleton("Steam") or DisplayServer.get_name() == "headless":
		return
	steam = Engine.get_singleton("Steam")
	var res: Dictionary = steam.steamInitEx(STEAM_APP_ID, true)
	steam_ok = res.get("status", 1) == 0
	if not steam_ok:
		print("Steam unavailable: ", res)
		return
	steam.lobby_created.connect(_on_lobby_created)
	steam.lobby_joined.connect(_on_lobby_joined)
	steam.lobby_match_list.connect(_on_lobby_match_list)
	steam.join_requested.connect(func(lid, _sid): join_steam_lobby(lid))
	var args := OS.get_cmdline_args()
	var i := args.find("+connect_lobby")
	if i != -1 and i + 1 < args.size():
		join_steam_lobby.call_deferred(args[i + 1].to_int())


func steam_name() -> String:
	return steam.getPersonaName() if steam_ok else ""


func host_steam(pname: String) -> void:
	if not steam_ok:
		status.emit("Steam isn't running.")
		return
	my_name = pname
	status.emit("Opening a Steam lobby...")
	steam.createLobby(2, MAX_PLAYERS)  # LOBBY_TYPE_PUBLIC


func _on_lobby_created(result: int, lid: int) -> void:
	if result != 1:
		status.emit("Steam couldn't create a lobby (code %d)." % result)
		return
	lobby_id = lid
	steam.setLobbyData(lid, "game", LOBBY_TAG)
	steam.setLobbyData(lid, "host", my_name)
	var peer = ClassDB.instantiate("SteamMultiplayerPeer")
	if peer.host_with_lobby(lid) != OK:
		status.emit("Steam networking failed to start.")
		return
	multiplayer.multiplayer_peer = peer
	_host_setup(my_name)
	status.emit("")


func find_steam_lobbies() -> void:
	if not steam_ok:
		status.emit("Steam isn't running.")
		return
	steam.addRequestLobbyListStringFilter("game", LOBBY_TAG, 0)
	steam.addRequestLobbyListDistanceFilter(3)
	steam.requestLobbyList()
	status.emit("Looking for lobbies...")


func _on_lobby_match_list(lobbies: Array) -> void:
	var list := []
	for lid in lobbies:
		list.append({"id": lid, "host": steam.getLobbyData(lid, "host"),
			"count": steam.getNumLobbyMembers(lid)})
	status.emit("" if list.size() > 0 else "No open lobbies. Host one!")
	lobbies_found.emit(list)


func join_steam_lobby(lid: int) -> void:
	if not steam_ok or lid == 0:
		return
	if is_online():
		leave()
	if my_name == "Fish":
		my_name = steam_name()
	status.emit("Joining Steam lobby...")
	steam.joinLobby(lid)


func _on_lobby_joined(lid: int, _perms: int, _locked: bool, response: int) -> void:
	if response != 1:
		status.emit("Couldn't join that lobby (it may be full or closed).")
		return
	lobby_id = lid
	if steam.getLobbyOwner(lid) == steam.getSteamID():
		return
	var peer = ClassDB.instantiate("SteamMultiplayerPeer")
	if peer.connect_to_lobby(lid) != OK:
		status.emit("Steam networking failed to connect.")
		return
	multiplayer.multiplayer_peer = peer


func invite_friends() -> void:
	if steam_ok and lobby_id != 0:
		steam.activateGameOverlayInviteDialog(lobby_id)


func _set_lobby_joinable(joinable: bool) -> void:
	if steam_ok and lobby_id != 0 and multiplayer.is_server():
		steam.setLobbyJoinable(lobby_id, joinable)


# =============================================================================
# Shared UI theme ("cozy dock" look)
# =============================================================================

func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 18
	var text := Color("e8edf2")

	var btn := StyleBoxFlat.new()
	btn.bg_color = Color("3b5166")
	btn.set_corner_radius_all(4)
	btn.content_margin_left = 14; btn.content_margin_right = 14
	btn.content_margin_top = 6; btn.content_margin_bottom = 6
	var hover := btn.duplicate() as StyleBoxFlat
	hover.bg_color = Color("4a6580")
	var pressed := btn.duplicate() as StyleBoxFlat
	pressed.bg_color = Color("2c3e50")
	var disabled := btn.duplicate() as StyleBoxFlat
	disabled.bg_color = Color("2f3d4a")
	for s in ["normal", "focus"]:
		t.set_stylebox(s, "Button", btn)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", text)
	t.set_color("font_disabled_color", "Button", Color(text, 0.4))

	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("2a3a4a")
	panel.set_corner_radius_all(4)
	panel.set_content_margin_all(16)
	t.set_stylebox("panel", "PanelContainer", panel)

	var row := StyleBoxFlat.new()
	row.bg_color = Color("324456")
	row.set_corner_radius_all(3)
	row.set_content_margin_all(6)
	t.set_type_variation("PanelRow", "PanelContainer")
	t.set_stylebox("panel", "PanelRow", row)

	var edit := StyleBoxFlat.new()
	edit.bg_color = Color("1e2a36")
	edit.set_corner_radius_all(3)
	edit.set_content_margin_all(6)
	for ctl in ["LineEdit", "SpinBox"]:
		t.set_stylebox("normal", ctl, edit)
		t.set_stylebox("focus", ctl, edit)
	for s in ["normal", "hover", "pressed", "focus", "hover_pressed", "disabled"]:
		t.set_stylebox(s, "CheckBox", StyleBoxEmpty.new())
	for ctl in ["Label", "LineEdit", "CheckBox", "OptionButton"]:
		t.set_color("font_color", ctl, text)
	t.set_color("font_hover_color", "CheckBox", text)
	t.set_color("font_pressed_color", "CheckBox", text)
	t.set_color("font_placeholder_color", "LineEdit", Color(text, 0.35))
	return t
