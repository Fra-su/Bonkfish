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
	var err := peer.create_server(port)
	if err != OK:
		push_error("Bonkfish server: couldn't listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	dedicated = true
	multiplayer.multiplayer_peer = peer
	print("Bonkfish dedicated server listening on ws://0.0.0.0:%d" % port)


## LAN host: ENet server + my own room that others drop into.
func host_game(pname: String) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, 32) != OK:
		status.emit("Couldn't host - is port %d already in use?" % PORT)
		return false
	multiplayer.multiplayer_peer = peer
	_host_setup(pname)
	return true


func _host_setup(pname: String) -> void:
	my_name = pname
	rooms.clear()
	peer_room.clear()
	peer_names.clear()
	peer_names[1] = _clean_name(pname)
	_create(1, {"name": "%s's pond" % _clean_name(pname), "public": true, "max": MAX_PLAYERS,
		"mode": MODE_FFA, "wins": 3})


func join_game(ip: String, pname: String) -> bool:
	my_name = pname
	_online_url = ""
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(ip, PORT) != OK:
		status.emit("That address doesn't look right.")
		return false
	multiplayer.multiplayer_peer = peer
	status.emit("Casting a line to %s..." % ip)
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
		status.emit("That server address doesn't look right.")
		return
	multiplayer.multiplayer_peer = peer
	status.emit("Casting a line to the server..." if _retries == 0 else "Waking the server up... (try %d)" % (_retries + 1))


## Disconnect completely.
func leave() -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if steam_ok and lobby_id != 0:
		steam.leaveLobby(lobby_id)
	lobby_id = 0
	_online_url = ""
	room = {}
	players = {}
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
		status.emit("Waking the server up...")
		return
	leave()
	status.emit("Couldn't connect. Is the server running?")


func _on_server_gone() -> void:
	var was_online := _online_url != ""
	leave()
	pending_status = "Lost connection to the server." if was_online else "The host left the pond."
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		_leave(id)
		peer_names.erase(id)


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


## Leave the current match from the pause menu.
func leave_match() -> void:
	if multiplayer.is_server():
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

func _clean_name(n: String) -> String:
	n = n.strip_edges().substr(0, 14)
	return n if n != "" else "Fish"


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
		"mode": r["mode"], "wins": r["wins"], "leader": r["leader"], "in_game": r["in_game"]}


func _push(code: String) -> void:
	if not rooms.has(code):
		return
	var r: Dictionary = rooms[code]
	var info := _room_info(r)
	for id in r["players"]:
		_to_peer(id, "_c_room", [info, r["players"]])


func _room_say(code: String, line: String) -> void:
	if rooms.has(code):
		for id in rooms[code]["players"]:
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
	if peer_room.has(id):
		_leave(id)
	var code := _new_code()
	var rname: String = String(s.get("name", "")).strip_edges().substr(0, 24)
	if rname == "":
		rname = "%s's pond" % peer_names.get(id, "Fish")
	rooms[code] = {"code": code, "name": rname, "public": bool(s.get("public", true)),
		"max": clampi(int(s.get("max", MAX_PLAYERS)), 2, MAX_PLAYERS),
		"mode": clampi(int(s.get("mode", MODE_FFA)), 0, MODES.size() - 1),
		"wins": clampi(int(s.get("wins", 3)), 1, 9),
		"leader": id, "in_game": false, "players": {}, "game": null, "joined": 0}
	print("Room %s created (%s)" % [code, "public" if rooms[code]["public"] else "private"])
	_join(id, code)


func _join(id: int, code: String) -> void:
	if not rooms.has(code):
		_to_peer(id, "_c_error", ["No room with code %s." % code])
		return
	var r: Dictionary = rooms[code]
	if peer_room.get(id, "") == code:
		return
	if r["in_game"]:
		_to_peer(id, "_c_error", ["That match is in progress - try again in a bit."])
		return
	if r["players"].size() >= r["max"]:
		_to_peer(id, "_c_error", ["That room is full."])
		return
	if peer_room.has(id):
		_leave(id)
	r["joined"] += 1
	r["players"][id] = {"name": peer_names.get(id, "Fish"), "color": Color.WHITE, "score": 0,
		"fish": 0, "team": _smaller_team(r), "joined": r["joined"]}
	peer_room[id] = code
	_recolor(r)
	_push(code)
	_room_say(code, "%s joined the dock" % peer_names.get(id, "Fish"))


func _leave(id: int) -> void:
	if not peer_room.has(id):
		return
	var code: String = peer_room[id]
	peer_room.erase(id)
	if not rooms.has(code):
		return
	var r: Dictionary = rooms[code]
	var pname: String = r["players"].get(id, {}).get("name", "Someone")
	r["players"].erase(id)
	player_left.emit(code, id)  # the room's Game node on the server reacts
	if r["players"].is_empty():
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
	return rooms.get(code, {})


@rpc("any_peer", "reliable")
func _s_hello(pname: String) -> void:
	var id := _sender()
	peer_names[id] = _clean_name(pname)
	if not dedicated and not rooms.is_empty():
		_join(id, rooms.keys()[0])   # LAN/Steam: straight into the host's room
	else:
		_to_peer(id, "_c_welcome")


@rpc("any_peer", "reliable")
func _s_list() -> void:
	var list := []
	for r in rooms.values():
		if r["public"]:
			list.append({"code": r["code"], "name": r["name"], "count": r["players"].size(),
				"max": r["max"], "mode": r["mode"], "wins": r["wins"], "in_game": r["in_game"]})
	_to_peer(_sender(), "_c_list", [list])


@rpc("any_peer", "reliable")
func _s_create(s: Dictionary) -> void:
	_create(_sender(), s)


@rpc("any_peer", "reliable")
func _s_join(code: String) -> void:
	_join(_sender(), code)


@rpc("any_peer", "reliable")
func _s_leave() -> void:
	var id := _sender()
	_leave(id)
	_to_peer(id, "_c_room", [{}, {}])


@rpc("any_peer", "reliable")
func _s_settings(s: Dictionary) -> void:
	var id := _sender()
	var r := _member_room(id)
	if r.is_empty() or r["leader"] != id or r["in_game"]:
		return
	if s.has("name"):
		var n := String(s["name"]).strip_edges().substr(0, 24)
		if n != "":
			r["name"] = n
	if s.has("public"):
		r["public"] = bool(s["public"])
	if s.has("max"):
		r["max"] = clampi(int(s["max"]), maxi(2, r["players"].size()), MAX_PLAYERS)
	if s.has("wins"):
		r["wins"] = clampi(int(s["wins"]), 1, 9)
	if s.has("mode"):
		var m := clampi(int(s["mode"]), 0, MODES.size() - 1)
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
	var r := _member_room(id)
	if r.is_empty() or r["in_game"]:
		return
	r["players"][id]["fish"] = posmod(i, preload("res://Fish.gd").LINEUP.size())
	_push(r["code"])


@rpc("any_peer", "reliable")
func _s_team(t: int) -> void:
	var id := _sender()
	var r := _member_room(id)
	if r.is_empty() or r["in_game"] or r["mode"] != MODE_TEAMS:
		return
	r["players"][id]["team"] = clampi(t, 0, 1)
	_recolor(r)
	_push(r["code"])


@rpc("any_peer", "reliable")
func _s_kick(target: int) -> void:
	var id := _sender()
	var r := _member_room(id)
	if r.is_empty() or r["leader"] != id or target == id or not r["players"].has(target):
		return
	_leave(target)
	_to_peer(target, "_c_kicked")


@rpc("any_peer", "reliable")
func _s_chat(text: String) -> void:
	var id := _sender()
	var r := _member_room(id)
	text = text.strip_edges().substr(0, 120)
	if r.is_empty() or text == "":
		return
	_room_say(r["code"], "%s: %s" % [r["players"][id]["name"], text])


@rpc("any_peer", "reliable")
func _s_start() -> void:
	var id := _sender()
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
	pending_status = "You were removed from the room."
	get_tree().change_scene_to_file("res://Main.tscn")


@rpc("authority", "reliable")
func _c_go_game(code: String) -> void:
	var g := _make_game(code)
	get_tree().change_scene_to_node(g)
	if multiplayer.is_server() and rooms.has(code):
		rooms[code]["game"] = g


@rpc("authority", "reliable")
func _c_go_lobby() -> void:
	get_tree().change_scene_to_file("res://Main.tscn")


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
	t.default_font_size = 20
	var navy := Color("1d3557")

	var btn := StyleBoxFlat.new()
	btn.bg_color = Color("fff3d6")
	btn.border_color = Color("e0b872")
	btn.border_width_bottom = 5
	btn.set_corner_radius_all(14)
	btn.content_margin_left = 18; btn.content_margin_right = 18
	btn.content_margin_top = 8; btn.content_margin_bottom = 10
	var hover := btn.duplicate() as StyleBoxFlat
	hover.bg_color = Color("ffd166")
	hover.border_color = Color("d99a2b")
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.border_width_bottom = 1
	pressed.content_margin_top = 12
	var disabled := btn.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(1, 1, 1, 0.35)
	for s in ["normal", "focus"]:
		t.set_stylebox(s, "Button", btn)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", navy)
	t.set_color("font_disabled_color", "Button", Color(navy, 0.5))

	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(1, 1, 1, 0.9)
	panel.set_corner_radius_all(22)
	panel.set_content_margin_all(22)
	panel.shadow_color = Color(0, 0.1, 0.2, 0.25)
	panel.shadow_size = 14
	t.set_stylebox("panel", "PanelContainer", panel)

	var row := StyleBoxFlat.new()
	row.bg_color = Color("eef6fb")
	row.set_corner_radius_all(10)
	row.set_content_margin_all(6)
	t.set_type_variation("PanelRow", "PanelContainer")
	t.set_stylebox("panel", "PanelRow", row)

	var edit := StyleBoxFlat.new()
	edit.bg_color = Color("eef6fb")
	edit.border_color = Color("a8d8ea")
	edit.set_border_width_all(2)
	edit.set_corner_radius_all(10)
	edit.set_content_margin_all(8)
	for ctl in ["LineEdit", "SpinBox"]:
		t.set_stylebox("normal", ctl, edit)
		t.set_stylebox("focus", ctl, edit)
	t.set_color("font_color", "LineEdit", navy)
	t.set_color("font_color", "Label", navy)
	t.set_color("font_color", "CheckBox", navy)
	t.set_color("font_hover_color", "CheckBox", navy)
	t.set_color("font_pressed_color", "CheckBox", navy)
	t.set_color("font_color", "OptionButton", navy)
	return t
