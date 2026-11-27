extends Node
## Autoload: lobby + networking for Bonkfish.
## Transports: ENet (LAN/IP), Steam (GodotSteam), WebSocket (browser + dedicated server).

signal players_changed
signal status(msg: String)
signal player_left(id: int)

var PORT := 7777
const MAX_PLAYERS := 8
const WIN_SCORE := 3
const COLORS := [Color("ff6b6b"), Color("4dabf7"), Color("ffd43b"), Color("69db7c"),
	Color("da77f2"), Color("ff922b"), Color("3bc9db"), Color("f783ac")]

var players := {}          # peer id -> {"name", "color", "score", "fish", "joined"}
var my_name := "Fish"
var in_game := false
var pending_status := ""   # shown by the menu after a scene change

# --- Online (WebSocket dedicated server, e.g. on Railway) ---
## Default server for "Play Online". Replace with your Railway domain (wss:// = TLS, which Railway provides).
const DEFAULT_SERVER_URL := "wss://bonkfish-production.up.railway.app"
var dedicated := false     # true when this instance is a headless server, not a player
var _join_counter := 0
var _online_url := ""
var _retries := 0

# --- Steam (GodotSteam GDExtension, Spacewar test app 480) ---
signal lobbies_found(list: Array)
const STEAM_APP_ID := 480
const LOBBY_TAG := "bonkfish"
var steam: Object = null    # the Steam singleton, or null when Steam isn't available
var steam_ok := false
var lobby_id := 0


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	if is_dedicated_launch():
		host_dedicated.call_deferred()
		return
	_init_steam()


## Server mode: a "dedicated_server" export, or launched with `-- --server`.
func is_dedicated_launch() -> bool:
	return OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_user_args()


func host_dedicated() -> void:
	var port := OS.get_environment("PORT").to_int()   # Railway injects $PORT
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
	players.clear()
	print("Bonkfish dedicated server listening on ws://0.0.0.0:%d" % port)


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


## The lobby leader starts matches. With a player-host that's the host; on a dedicated server
## it's whoever has been in the lobby longest.
func leader_id() -> int:
	var best := -1
	var best_t := 1 << 30
	for id in players:
		if players[id].get("joined", 0) < best_t:
			best_t = players[id].get("joined", 0)
			best = id
	return best


func am_leader() -> bool:
	return players.has(multiplayer.get_unique_id()) and leader_id() == multiplayer.get_unique_id()


func request_start() -> void:
	if multiplayer.is_server():
		start_match()
	else:
		_req_start.rpc_id(1)


@rpc("any_peer", "reliable")
func _req_start() -> void:
	if multiplayer.is_server() and not in_game and multiplayer.get_remote_sender_id() == leader_id():
		start_match()


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
	# Launched from a Steam invite while the game was closed: "+connect_lobby <id>"
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
	players.clear()
	_add_player(1, my_name)
	status.emit("")
	players_changed.emit()


func find_steam_lobbies() -> void:
	if not steam_ok:
		status.emit("Steam isn't running.")
		return
	steam.addRequestLobbyListStringFilter("game", LOBBY_TAG, 0)  # equal
	steam.addRequestLobbyListDistanceFilter(3)                   # worldwide
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
		return  # we're the host; host_with_lobby already set up the peer
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


func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func host_game(pname: String) -> bool:
	my_name = pname
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, MAX_PLAYERS) != OK:
		status.emit("Couldn't host - is port %d already in use?" % PORT)
		return false
	multiplayer.multiplayer_peer = peer
	players.clear()
	_add_player(1, pname)
	players_changed.emit()
	return true


func join_game(ip: String, pname: String) -> bool:
	my_name = pname
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(ip, PORT) != OK:
		status.emit("That address doesn't look right.")
		return false
	multiplayer.multiplayer_peer = peer
	status.emit("Casting a line to %s..." % ip)
	return true


func leave() -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if steam_ok and lobby_id != 0:
		steam.leaveLobby(lobby_id)
	lobby_id = 0
	_online_url = ""
	players.clear()
	in_game = false
	players_changed.emit()


func _add_player(id: int, pname: String) -> void:
	var used := []
	for p in players.values():
		used.append(p["color"])
	var col: Color = COLORS[0]
	for c in COLORS:
		if not used.has(c):
			col = c
			break
	_join_counter += 1
	players[id] = {"name": pname, "color": col, "score": 0, "fish": 0, "joined": _join_counter}


func choose_fish(i: int) -> void:
	_set_fish.rpc_id(1, i)


@rpc("any_peer", "call_local", "reliable")
func _set_fish(i: int) -> void:
	if not multiplayer.is_server() or in_game:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	if players.has(id):
		players[id]["fish"] = posmod(i, preload("res://Fish.gd").LINEUP.size())
		sync_players.rpc(players)
		players_changed.emit()


func _on_connected() -> void:
	_register.rpc_id(1, my_name)


@rpc("any_peer", "reliable")
func _register(pname: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if in_game or players.size() >= MAX_PLAYERS:
		_rejected.rpc_id(id, "That pond is full or mid-match. Try again soon!")
		get_tree().create_timer(0.5).timeout.connect(func():
			if not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
				multiplayer.multiplayer_peer.disconnect_peer(id))
		return
	_add_player(id, pname.strip_edges().substr(0, 14))
	sync_players.rpc(players)
	players_changed.emit()


@rpc("authority", "call_remote", "reliable")
func sync_players(p: Dictionary) -> void:
	players = p
	players_changed.emit()


@rpc("authority", "reliable")
func _rejected(msg: String) -> void:
	leave()
	status.emit(msg)


func _on_peer_disconnected(id: int) -> void:
	if players.has(id):
		players.erase(id)
		players_changed.emit()
	if multiplayer.is_server():
		sync_players.rpc(players)
	player_left.emit(id)
	# Dedicated server: everyone left mid-match -> reset to the lobby.
	if dedicated and players.is_empty() and in_game:
		go_lobby()


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


# --- match flow -------------------------------------------------------------

func start_match() -> void:
	if not multiplayer.is_server():
		return
	for id in players:
		players[id]["score"] = 0
	sync_players.rpc(players)
	_set_lobby_joinable(false)
	_go_game.rpc()


@rpc("authority", "call_local", "reliable")
func _go_game() -> void:
	in_game = true
	get_tree().change_scene_to_file("res://Game.tscn")


@rpc("authority", "call_local", "reliable")
func go_lobby() -> void:
	in_game = false
	_set_lobby_joinable(true)
	get_tree().change_scene_to_file("res://Main.tscn")


# --- shared UI theme ("cozy dock" look) -------------------------------------

func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 22
	var navy := Color("1d3557")

	var btn := StyleBoxFlat.new()
	btn.bg_color = Color("fff3d6")
	btn.border_color = Color("e0b872")
	btn.border_width_bottom = 5
	btn.set_corner_radius_all(14)
	btn.content_margin_left = 22; btn.content_margin_right = 22
	btn.content_margin_top = 10; btn.content_margin_bottom = 12
	var hover := btn.duplicate() as StyleBoxFlat
	hover.bg_color = Color("ffd166")
	hover.border_color = Color("d99a2b")
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.border_width_bottom = 1
	pressed.content_margin_top = 14
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
	panel.bg_color = Color(1, 1, 1, 0.88)
	panel.set_corner_radius_all(22)
	panel.set_content_margin_all(26)
	panel.shadow_color = Color(0, 0.1, 0.2, 0.25)
	panel.shadow_size = 14
	t.set_stylebox("panel", "PanelContainer", panel)

	var edit := StyleBoxFlat.new()
	edit.bg_color = Color("eef6fb")
	edit.border_color = Color("a8d8ea")
	edit.set_border_width_all(2)
	edit.set_corner_radius_all(10)
	edit.set_content_margin_all(10)
	t.set_stylebox("normal", "LineEdit", edit)
	t.set_stylebox("focus", "LineEdit", edit)
	t.set_color("font_color", "LineEdit", navy)
	t.set_color("font_color", "Label", navy)
	return t
