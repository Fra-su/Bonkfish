extends Control
## Title menu + lobby. Built in code so it's easy to tweak.

const SETTINGS := "user://settings.cfg"

var menu_panel: PanelContainer
var lobby_panel: PanelContainer
var name_edit: LineEdit
var ip_edit: LineEdit
var status_label: Label
var player_list: VBoxContainer
var start_btn: Button
var lobby_info: Label
var lobby_browser: VBoxContainer
var invite_btn: Button
var server_edit: LineEdit
var fish_label: Label
var fish_stats: Label
const Fish := preload("res://Fish.gd")
var title: Label
var t := 0.0
var bubbles := []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_anchors_preset(PRESET_FULL_RECT)
	theme = Net.make_theme()
	for i in 34:
		bubbles.append(Vector3(randf(), randf(), randf_range(4, 16)))
	_build()
	_load_settings()
	Net.players_changed.connect(_refresh)
	Net.status.connect(func(m): status_label.text = m)
	if Net.pending_status != "":
		status_label.text = Net.pending_status
		Net.pending_status = ""
	_refresh()


func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	title = Label.new()
	title.text = "BONKFISH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 110)
	title.add_theme_color_override("font_color", Color("ffd166"))
	title.add_theme_color_override("font_outline_color", Color("1d3557"))
	title.add_theme_constant_override("outline_size", 22)
	col.add_child(title)

	var sub := Label.new()
	sub.text = "last fish standing wins"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 26)
	sub.add_theme_color_override("font_color", Color.WHITE)
	sub.add_theme_color_override("font_outline_color", Color("1d3557"))
	sub.add_theme_constant_override("outline_size", 8)
	col.add_child(sub)

	# --- main menu ---
	menu_panel = PanelContainer.new()
	menu_panel.custom_minimum_size.x = 440
	col.add_child(menu_panel)
	var m := VBoxContainer.new()
	m.add_theme_constant_override("separation", 12)
	menu_panel.add_child(m)
	m.add_child(_small("YOUR NAME"))
	name_edit = LineEdit.new()
	name_edit.max_length = 14
	name_edit.placeholder_text = "Fish"
	m.add_child(name_edit)
	# Online: dedicated WebSocket server (works in the browser build too)
	m.add_child(_small("ONLINE"))
	server_edit = LineEdit.new()
	server_edit.placeholder_text = Net.DEFAULT_SERVER_URL
	server_edit.visible = not OS.has_feature("web") or OS.is_debug_build()
	m.add_child(server_edit)
	m.add_child(_button("Play Online", _on_play_online))
	if OS.has_feature("web"):
		_build_lobby(col)  # browsers can't do Steam, LAN/ENet, or quitting
		return
	m.add_child(HSeparator.new())
	if Net.steam_ok:
		m.add_child(_small("STEAM (signed in as %s)" % Net.steam_name()))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var hs := _button("Host Steam Lobby", func(): _save_settings(); Net.host_steam(_pname()))
		hs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var fs := _button("Find Lobbies", func(): Net.find_steam_lobbies())
		fs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(hs)
		row.add_child(fs)
		m.add_child(row)
		lobby_browser = VBoxContainer.new()
		m.add_child(lobby_browser)
		Net.lobbies_found.connect(_show_lobbies)
	else:
		m.add_child(_small("Steam not running - LAN / IP play only"))
	m.add_child(HSeparator.new())
	m.add_child(_small("LAN / DIRECT IP"))
	m.add_child(_button("Host Game", _on_host))
	m.add_child(_small("HOST IP"))
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "127.0.0.1"
	m.add_child(ip_edit)
	m.add_child(_button("Join Game", _on_join))
	m.add_child(HSeparator.new())
	m.add_child(_button("Quit", func(): get_tree().quit()))
	_build_lobby(col)


func _build_lobby(col: VBoxContainer) -> void:
	# --- lobby ---
	lobby_panel = PanelContainer.new()
	lobby_panel.custom_minimum_size.x = 440
	col.add_child(lobby_panel)
	var l := VBoxContainer.new()
	l.add_theme_constant_override("separation", 12)
	lobby_panel.add_child(l)
	var lt := Label.new()
	lt.text = "THE DOCK"
	lt.add_theme_font_size_override("font_size", 34)
	lt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_child(lt)
	lobby_info = _small("")
	lobby_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_child(lobby_info)
	player_list = VBoxContainer.new()
	l.add_child(player_list)
	l.add_child(HSeparator.new())
	l.add_child(_small("YOUR FISH"))
	var pick := HBoxContainer.new()
	pick.add_theme_constant_override("separation", 10)
	pick.add_child(_button("<", func(): _cycle_fish(-1)))
	fish_label = Label.new()
	fish_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fish_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fish_label.add_theme_font_size_override("font_size", 26)
	pick.add_child(fish_label)
	pick.add_child(_button(">", func(): _cycle_fish(1)))
	l.add_child(pick)
	fish_stats = _small("")
	fish_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_child(fish_stats)
	l.add_child(HSeparator.new())
	start_btn = _button("Start Match", func(): Net.request_start())
	l.add_child(start_btn)
	invite_btn = _button("Invite Steam Friends", func(): Net.invite_friends())
	l.add_child(invite_btn)
	l.add_child(_button("Leave", func(): Net.leave(); status_label.text = ""))

	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_color_override("font_color", Color.WHITE)
	status_label.add_theme_color_override("font_outline_color", Color("1d3557"))
	status_label.add_theme_constant_override("outline_size", 6)
	col.add_child(status_label)

	var help := Label.new()
	help.text = "WASD move  ·  Space jump  ·  Shift sprint  ·  Click BONK  ·  T camera  ·  Esc menu"
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.add_theme_font_size_override("font_size", 16)
	help.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	col.add_child(help)


func _small(text: String) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 15)
	lb.add_theme_color_override("font_color", Color("457b9d"))
	return lb


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


func _pname() -> String:
	var n := name_edit.text.strip_edges()
	if n == "" and Net.steam_ok:
		n = Net.steam_name().substr(0, 14)
	return n if n != "" else "Fish%d" % (randi() % 100)


func _on_host() -> void:
	_save_settings()
	if Net.host_game(_pname()):
		status_label.text = ""


func _on_play_online() -> void:
	_save_settings()
	var url := server_edit.text.strip_edges()
	if url == "":
		url = Net.DEFAULT_SERVER_URL
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		url = "wss://" + url
	Net.join_online(url, _pname())


func _on_join() -> void:
	_save_settings()
	var ip := ip_edit.text.strip_edges()
	Net.join_game(ip if ip != "" else "127.0.0.1", _pname())


func _refresh() -> void:
	var in_lobby := Net.is_online() and Net.players.has(multiplayer.get_unique_id())
	menu_panel.visible = not in_lobby
	lobby_panel.visible = in_lobby
	if not in_lobby:
		return
	if in_lobby and status_label.text.begins_with("Casting"):
		status_label.text = ""
	for c in player_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var p = Net.players[id]
		var row := Label.new()
		row.text = "●  %s  -  %s%s" % [p["name"], Fish.stats(p.get("fish", 0))["name"], "   (leader)" if id == Net.leader_id() else ""]
		row.add_theme_color_override("font_color", p["color"].darkened(0.25))
		row.add_theme_font_size_override("font_size", 24)
		player_list.add_child(row)
	var fs := Fish.stats(_my_fish())
	fish_label.text = fs["name"]
	fish_stats.text = "%s\nReach %s   Power %s\nSpeed %s   Swing %s" % [fs["desc"], _bar(fs["reach"]), _bar(fs["power"]),
		_bar(fs["speed"]), _bar(0.5 / fs["cooldown"])]
	start_btn.visible = Net.am_leader()
	invite_btn.visible = Net.lobby_id != 0
	start_btn.text = "Start Match  (first to %d)" % Net.WIN_SCORE if ids.size() > 1 else "Start Solo Practice"
	if Net.am_leader():
		if Net.lobby_id != 0:
			lobby_info.text = "Steam lobby open - invite friends below"
		elif multiplayer.is_server():
			lobby_info.text = "Friends join with:  " + _lan_ip()
		else:
			lobby_info.text = "You're the leader - start when everyone's here"
	else:
		var lead = Net.players.get(Net.leader_id(), {}).get("name", "the leader")
		lobby_info.text = "Waiting for %s to start..." % lead


func _my_fish() -> int:
	var me = Net.players.get(multiplayer.get_unique_id(), {})
	return me.get("fish", 0)


func _cycle_fish(d: int) -> void:
	Net.choose_fish(_my_fish() + d)


func _bar(v: float) -> String:
	var n := clampi(roundi(v * 4), 1, 8)
	return "■".repeat(n) + "□".repeat(8 - n)


func _show_lobbies(list: Array) -> void:
	for c in lobby_browser.get_children():
		c.queue_free()
	for lob in list:
		var b := _button("Join %s's pond  (%d/%d)" % [lob["host"], lob["count"], Net.MAX_PLAYERS],
			func(): _save_settings(); Net.my_name = _pname(); Net.join_steam_lobby(lob["id"]))
		lobby_browser.add_child(b)


func _lan_ip() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
	return "127.0.0.1"


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS) == OK:
		name_edit.text = cf.get_value("p", "name", "")
		server_edit.text = cf.get_value("p", "server", "")
		if ip_edit:
			ip_edit.text = cf.get_value("p", "ip", "")


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("p", "name", name_edit.text)
	cf.set_value("p", "server", server_edit.text)
	if ip_edit:
		cf.set_value("p", "ip", ip_edit.text)
	cf.save(SETTINGS)


func _process(delta: float) -> void:
	t += delta
	title.pivot_offset = title.size / 2
	title.rotation = sin(t * 1.6) * 0.035
	title.scale = Vector2.ONE * (1.0 + sin(t * 2.3) * 0.02)
	for i in bubbles.size():
		var b: Vector3 = bubbles[i]
		b.y -= delta * (0.03 + b.z * 0.004)
		if b.y < -0.05:
			b = Vector3(randf(), 1.05, randf_range(4, 16))
		bubbles[i] = b
	queue_redraw()


func _draw() -> void:
	var s := size
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(s.x, 0), s, Vector2(0, s.y)]),
		PackedColorArray([Color("8ecae6"), Color("8ecae6"), Color("1d5c7a"), Color("1d5c7a")]))
	for b in bubbles:
		var p := Vector2(b.x * s.x + sin(t + b.z) * 12.0, b.y * s.y)
		draw_circle(p, b.z, Color(1, 1, 1, 0.12))
		draw_arc(p, b.z, 0, TAU, 20, Color(1, 1, 1, 0.35), 1.5)
