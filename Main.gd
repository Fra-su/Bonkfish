extends Control
## Title menu, room browser and room lobby. Built in code so it's easy to tweak.
## Text is plain ASCII on purpose: the web build's default font has no bullet/star glyphs
## (they showed up as boxes like "25CF"), so swatches are drawn with ColorRects instead.

const SETTINGS := "user://settings.cfg"
const Fish := preload("res://Fish.gd")

# --- menu (not connected) ---
var menu_panel: PanelContainer
var name_edit: LineEdit
var server_edit: LineEdit
var ip_edit: LineEdit
var lobby_browser: VBoxContainer   # Steam lobby results

# --- browser (connected, not in a room) ---
var browser_panel: PanelContainer
var room_rows: VBoxContainer
var code_edit: LineEdit
var new_name: LineEdit
var new_public: CheckBox
var new_max: SpinBox
var new_mode: OptionButton
var new_wins: SpinBox
var new_endless: CheckBox
var refresh_timer := 0.0

# --- lobby (in a room) ---
var lobby_panel: PanelContainer
var room_title: Label
var room_info: Label
var player_list: VBoxContainer
var team_row: HBoxContainer
var settings_box: GridContainer
var set_public: CheckBox
var set_max: SpinBox
var set_mode: OptionButton
var set_wins: SpinBox
var set_endless: CheckBox
var fish_label: Label
var fish_stats: Label
var chat_text: Label
var chat_scroll: ScrollContainer
var chat_edit: LineEdit
var start_btn: Button
var share_box: GridContainer
var share_web: Label
var share_lan: Label
var invite_btn: Button

var status_label: Label
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
	Net.room_list.connect(_show_rooms)
	Net.chat_line.connect(func(_l): _show_chat())
	if Net.steam_ok:
		Net.lobbies_found.connect(_show_steam_lobbies)
	if Net.pending_status != "":
		status_label.text = Net.pending_status
		Net.pending_status = ""
	_refresh()
	if Net.is_online() and not Net.in_room():
		Net.refresh_rooms()


# =============================================================================
# Building the UI
# =============================================================================

func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	center.add_child(col)

	title = Label.new()
	title.text = "BONKFISH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 92)
	title.add_theme_color_override("font_color", Color("ffd166"))
	title.add_theme_color_override("font_outline_color", Color("1d3557"))
	title.add_theme_constant_override("outline_size", 20)
	col.add_child(title)
	var sub := _white_label("last fish standing wins", 22)
	col.add_child(sub)

	_build_menu(col)
	_build_browser(col)
	_build_lobby(col)

	status_label = _white_label("", 18)
	col.add_child(status_label)
	col.add_child(_white_label("WASD move  |  Space jump  |  Shift sprint  |  Click BONK (hold to charge)  |  T camera  |  Esc menu", 15))


func _build_menu(col: VBoxContainer) -> void:
	menu_panel = PanelContainer.new()
	menu_panel.custom_minimum_size.x = 440
	col.add_child(menu_panel)
	var m := VBoxContainer.new()
	m.add_theme_constant_override("separation", 10)
	menu_panel.add_child(m)
	m.add_child(_small("YOUR NAME"))
	name_edit = LineEdit.new()
	name_edit.max_length = 14
	name_edit.placeholder_text = "Fish"
	m.add_child(name_edit)
	m.add_child(_small("ONLINE  (leave empty for the official server, or paste a friend's address)"))
	server_edit = LineEdit.new()
	server_edit.placeholder_text = "Official server"
	m.add_child(server_edit)
	m.add_child(_button("Play Online", _on_play_online))
	if OS.has_feature("web"):
		return  # browsers can't host, do Steam, or quit
	m.add_child(HSeparator.new())
	m.add_child(_small("HOST ON THIS PC  (you get ~0 ping; friends join with the link it shows)"))
	m.add_child(_button("Host Game on This PC", _on_host_online))
	m.add_child(HSeparator.new())
	if Net.steam_ok:
		m.add_child(_small("STEAM (signed in as %s)" % Net.steam_name()))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(_expand(_button("Host Steam Lobby", func(): _save_settings(); Net.host_steam(_pname()))))
		row.add_child(_expand(_button("Find Lobbies", func(): Net.find_steam_lobbies())))
		m.add_child(row)
		lobby_browser = VBoxContainer.new()
		m.add_child(lobby_browser)
		m.add_child(HSeparator.new())
	m.add_child(_button("Quit", func(): get_tree().quit()))


func _build_browser(col: VBoxContainer) -> void:
	browser_panel = PanelContainer.new()
	browser_panel.custom_minimum_size = Vector2(820, 0)
	col.add_child(browser_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	browser_panel.add_child(v)
	v.add_child(_heading("FIND A POND"))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 22)
	v.add_child(cols)

	# Left: public rooms
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	cols.add_child(left)
	var lh := HBoxContainer.new()
	lh.add_child(_expand(_small("PUBLIC ROOMS")))
	lh.add_child(_button("Refresh", func(): Net.refresh_rooms()))
	left.add_child(lh)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(400, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	room_rows = VBoxContainer.new()
	room_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_rows.add_theme_constant_override("separation", 6)
	scroll.add_child(room_rows)

	# Right: join by code + create
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 340
	right.add_theme_constant_override("separation", 8)
	cols.add_child(right)
	right.add_child(_small("JOIN A PRIVATE ROOM"))
	var cr := HBoxContainer.new()
	cr.add_theme_constant_override("separation", 8)
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "CODE"
	code_edit.max_length = 4
	code_edit.text_changed.connect(func(s):
		var c := code_edit.caret_column
		code_edit.text = s.to_upper()
		code_edit.caret_column = c)
	code_edit.text_submitted.connect(func(_s): _join_code())
	cr.add_child(_expand(code_edit))
	cr.add_child(_button("Join", _join_code))
	right.add_child(cr)
	right.add_child(HSeparator.new())
	right.add_child(_small("CREATE A ROOM"))
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 6)
	right.add_child(g)
	new_name = LineEdit.new()
	new_name.max_length = 24
	new_name.placeholder_text = "Room name"
	g.add_child(_small("Name"))
	g.add_child(_expand(new_name))
	new_public = CheckBox.new()
	new_public.text = "Public (listed)"
	new_public.button_pressed = true
	g.add_child(_small("Visibility"))
	g.add_child(new_public)
	new_max = _spin(2, Net.MAX_PLAYERS, Net.MAX_PLAYERS)
	g.add_child(_small("Max players"))
	g.add_child(new_max)
	new_mode = _mode_picker()
	g.add_child(_small("Mode"))
	g.add_child(new_mode)
	new_wins = _spin(1, 9, 3)
	g.add_child(_small("Wins to take it"))
	g.add_child(new_wins)
	new_endless = CheckBox.new()
	new_endless.text = "Endless (no winner, play forever)"
	new_endless.toggled.connect(func(on): new_wins.editable = not on)
	g.add_child(_small(""))
	g.add_child(new_endless)
	right.add_child(_button("Create Room", _create_room))

	v.add_child(HSeparator.new())
	v.add_child(_button("Disconnect", func(): Net.leave(); status_label.text = ""))


func _build_lobby(col: VBoxContainer) -> void:
	lobby_panel = PanelContainer.new()
	lobby_panel.custom_minimum_size = Vector2(860, 0)
	col.add_child(lobby_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	lobby_panel.add_child(v)
	room_title = _heading("")
	v.add_child(room_title)
	room_info = _small("")
	room_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(room_info)
	# Hosting on this PC: how friends get in
	share_box = GridContainer.new()
	share_box.columns = 3
	share_box.add_theme_constant_override("h_separation", 10)
	v.add_child(share_box)
	share_box.add_child(_small("Website link (anyone):"))
	share_web = Label.new()
	share_web.clip_text = true
	share_web.custom_minimum_size.x = 520
	share_box.add_child(share_web)
	share_box.add_child(_button("Copy", func(): DisplayServer.clipboard_set(Net.share_link())))
	share_box.add_child(_small("Same Wi-Fi (desktop app):"))
	share_lan = Label.new()
	share_box.add_child(share_lan)
	share_box.add_child(_button("Copy", func(): DisplayServer.clipboard_set(share_lan.text)))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 22)
	v.add_child(cols)

	# Left: players, teams, room settings
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	cols.add_child(left)
	left.add_child(_small("PLAYERS"))
	player_list = VBoxContainer.new()
	player_list.add_theme_constant_override("separation", 4)
	left.add_child(player_list)
	team_row = HBoxContainer.new()
	team_row.add_theme_constant_override("separation", 8)
	for i in 2:
		var tb := _button("Join %s" % Net.TEAM_NAMES[i], func(): Net.choose_team(i))
		tb.add_theme_color_override("font_color", Net.TEAM_COLORS[i].darkened(0.3))
		team_row.add_child(_expand(tb))
	left.add_child(team_row)
	left.add_child(HSeparator.new())
	left.add_child(_small("ROOM SETTINGS (leader)"))
	settings_box = GridContainer.new()
	settings_box.columns = 2
	settings_box.add_theme_constant_override("h_separation", 10)
	settings_box.add_theme_constant_override("v_separation", 6)
	left.add_child(settings_box)
	set_public = CheckBox.new()
	set_public.text = "Public (listed)"
	set_public.toggled.connect(func(on): Net.set_room_settings({"public": on}))
	settings_box.add_child(_small("Visibility"))
	settings_box.add_child(set_public)
	set_max = _spin(2, Net.MAX_PLAYERS, Net.MAX_PLAYERS)
	set_max.value_changed.connect(func(x): Net.set_room_settings({"max": int(x)}))
	settings_box.add_child(_small("Max players"))
	settings_box.add_child(set_max)
	set_mode = _mode_picker()
	set_mode.item_selected.connect(func(i): Net.set_room_settings({"mode": i}))
	settings_box.add_child(_small("Mode"))
	settings_box.add_child(set_mode)
	set_wins = _spin(1, 9, 3)
	set_wins.value_changed.connect(func(x): Net.set_room_settings({"wins": int(x)}))
	settings_box.add_child(_small("Wins to take it"))
	settings_box.add_child(set_wins)
	set_endless = CheckBox.new()
	set_endless.text = "Endless (no winner)"
	set_endless.toggled.connect(func(on): Net.set_room_settings({"wins": 0 if on else maxi(1, int(set_wins.value))}))
	settings_box.add_child(_small(""))
	settings_box.add_child(set_endless)

	# Right: fish + chat
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 360
	right.add_theme_constant_override("separation", 8)
	cols.add_child(right)
	right.add_child(_small("YOUR FISH"))
	var pick := HBoxContainer.new()
	pick.add_theme_constant_override("separation", 10)
	pick.add_child(_button("<", func(): _cycle_fish(-1)))
	fish_label = Label.new()
	fish_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fish_label.add_theme_font_size_override("font_size", 24)
	pick.add_child(_expand(fish_label))
	pick.add_child(_button(">", func(): _cycle_fish(1)))
	right.add_child(pick)
	fish_stats = _small("")
	fish_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(fish_stats)
	right.add_child(HSeparator.new())
	right.add_child(_small("CHAT"))
	chat_scroll = ScrollContainer.new()
	chat_scroll.custom_minimum_size = Vector2(340, 150)
	chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(chat_scroll)
	chat_text = Label.new()
	chat_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chat_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_text.add_theme_font_size_override("font_size", 16)
	chat_scroll.add_child(chat_text)
	var cr := HBoxContainer.new()
	cr.add_theme_constant_override("separation", 8)
	chat_edit = LineEdit.new()
	chat_edit.max_length = 120
	chat_edit.placeholder_text = "Say something..."
	chat_edit.text_submitted.connect(func(_s): _send_chat())
	cr.add_child(_expand(chat_edit))
	cr.add_child(_button("Send", _send_chat))
	right.add_child(cr)

	v.add_child(HSeparator.new())
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	v.add_child(bottom)
	start_btn = _button("Start Match", func(): Net.request_start())
	_expand(start_btn)
	bottom.add_child(start_btn)
	invite_btn = _button("Invite Steam Friends", func(): Net.invite_friends())
	bottom.add_child(invite_btn)
	bottom.add_child(_button("Leave Room", _leave_room))


# --- small widget helpers ---

func _white_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color("1d3557"))
	l.add_theme_constant_override("outline_size", 7)
	return l


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 30)
	return l


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


func _expand(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _spin(lo: int, hi: int, val: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = val
	s.rounded = true
	return s


func _mode_picker() -> OptionButton:
	var o := OptionButton.new()
	for m in Net.MODES:
		o.add_item(m)
	return o


func _swatch(c: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = c
	r.custom_minimum_size = Vector2(16, 16)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


# =============================================================================
# Actions
# =============================================================================

func _pname() -> String:
	var n := name_edit.text.strip_edges()
	if n == "" and Net.steam_ok:
		n = Net.steam_name().substr(0, 14)
	return n if n != "" else "Fish%d" % (randi() % 100)


func _on_play_online() -> void:
	_save_settings()
	var url := server_edit.text.strip_edges()
	if url == "":
		url = Net.DEFAULT_SERVER_URL
	url = url.replace("https://", "wss://").replace("http://", "ws://")
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		# Bare LAN addresses (192.168.x.x[:port]) are plain ws://, anything else is wss://
		var host := url.split(":")[0]
		var is_lan := host.begins_with("192.168.") or host.begins_with("10.") or host.begins_with("172.") \
			or host == "localhost" or host == "127.0.0.1"
		url = ("ws://" if is_lan else "wss://") + url
		if is_lan and not ":" in url.trim_prefix("ws://"):
			url += ":%d" % Net.PORT
	Net.join_online(url, _pname())


func _on_host_online() -> void:
	_save_settings()
	if Net.host_online(_pname()):
		status_label.text = ""


func _on_host() -> void:
	_save_settings()
	if Net.host_game(_pname()):
		status_label.text = ""


func _on_join() -> void:
	_save_settings()
	var ip := ip_edit.text.strip_edges()
	Net.join_game(ip if ip != "" else "127.0.0.1", _pname())


func _join_code() -> void:
	var c := code_edit.text.strip_edges().to_upper()
	if c.length() != 4:
		status_label.text = "Room codes are 4 letters."
		return
	Net.join_room(c)


func _create_room() -> void:
	Net.create_room({"name": new_name.text, "public": new_public.button_pressed,
		"max": int(new_max.value), "mode": new_mode.selected,
		"wins": 0 if new_endless.button_pressed else int(new_wins.value)})


func _leave_room() -> void:
	if multiplayer.is_server():
		Net.leave()   # a LAN/Steam host closing their room ends it for everyone
	else:
		Net.leave_room()


func _send_chat() -> void:
	var s := chat_edit.text.strip_edges()
	if s != "":
		Net.send_chat(s)
	chat_edit.text = ""


func _my_fish() -> int:
	return Net.players.get(Net.my_id(), {}).get("fish", 0)


func _cycle_fish(d: int) -> void:
	Net.choose_fish(_my_fish() + d)


func _wins_text(w: int) -> String:
	return "endless" if w == 0 else "first to %d" % w


func _bar(v: float) -> String:
	var n := clampi(roundi(v * 4), 1, 8)
	return "#".repeat(n) + "-".repeat(8 - n)


# =============================================================================
# Refresh views
# =============================================================================

func _refresh() -> void:
	var online := Net.is_online()
	var in_room := online and Net.in_room()
	menu_panel.visible = not online
	browser_panel.visible = online and not in_room
	lobby_panel.visible = in_room
	if status_label.text.begins_with("Casting") and online:
		status_label.text = ""
	if in_room:
		_refresh_lobby()


func _show_rooms(list: Array) -> void:
	for c in room_rows.get_children():
		c.queue_free()
	if list.is_empty():
		var l := _small("No public rooms right now - create one!")
		room_rows.add_child(l)
		return
	list.sort_custom(func(a, b): return [a["in_game"], -a["count"]] < [b["in_game"], -b["count"]])
	for r in list:
		var row := PanelContainer.new()
		row.theme_type_variation = "PanelRow"
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		row.add_child(h)
		var info := VBoxContainer.new()
		info.add_theme_constant_override("separation", 0)
		var nm := Label.new()
		nm.text = r["name"]
		nm.add_theme_font_size_override("font_size", 19)
		nm.clip_text = true
		info.add_child(nm)
		info.add_child(_small("%d/%d  |  %s  |  %s%s%s" % [r["count"], r["max"], Net.MODES[r["mode"]],
			_wins_text(r["wins"]), "  |  IN MATCH" if r["in_game"] else "",
			("  |  %d watching" % r.get("watching", 0)) if r.get("watching", 0) > 0 else ""]))
		h.add_child(_expand(info))
		if r["in_game"]:
			h.add_child(_button("Spectate", func(): Net.spectate_room(r["code"])))
		else:
			var full: bool = r["count"] >= r["max"]
			var b := _button("Full" if full else "Join", func(): Net.join_room(r["code"]))
			b.disabled = full
			h.add_child(b)
		room_rows.add_child(row)


func _show_steam_lobbies(list: Array) -> void:
	if lobby_browser == null:
		return
	for c in lobby_browser.get_children():
		c.queue_free()
	for lob in list:
		lobby_browser.add_child(_button("Join %s's pond  (%d/%d)" % [lob["host"], lob["count"], Net.MAX_PLAYERS],
			func(): _save_settings(); Net.my_name = _pname(); Net.join_steam_lobby(lob["id"])))


func _refresh_lobby() -> void:
	var r := Net.room
	var leader := Net.am_leader()
	var teams := Net.is_teams()
	room_title.text = r["name"]
	share_box.visible = Net.hosting
	if Net.hosting:
		share_lan.text = "%s:%d" % [Net.lan_ip(), Net.PORT]
		share_web.text = Net.share_link() if Net.tunnel_url != "" else \
			"(install cloudflared to get an internet link - see DEPLOY.md)" if Net._tunnel_pid < 0 else "(opening link...)"
	room_info.text = "Code: %s   |   %s   |   %d/%d players   |   %s   |   %s" % [
		r["code"], "Public" if r["public"] else "Private (share the code)", Net.players.size(), r["max"],
		Net.MODES[r["mode"]], _wins_text(r["wins"])]

	# Players
	for c in player_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort_custom(func(a, b): return [Net.players[a]["team"] if teams else 0, Net.players[a]["joined"]] \
		< [Net.players[b]["team"] if teams else 0, Net.players[b]["joined"]])
	for id in ids:
		var p: Dictionary = Net.players[id]
		var row := PanelContainer.new()
		row.theme_type_variation = "PanelRow"
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		row.add_child(h)
		h.add_child(_swatch(p["color"]))
		var nm := Label.new()
		var tags := []
		if teams:
			tags.append(Net.TEAM_NAMES[p["team"]])
		tags.append(Fish.stats(p.get("fish", 0))["name"])
		if id == r["leader"]:
			tags.append("leader")
		if id == Net.my_id():
			tags.append("you")
		nm.text = "%s   (%s)" % [p["name"], ", ".join(tags)]
		h.add_child(_expand(nm))
		if leader and id != Net.my_id():
			h.add_child(_button("Kick", func(): Net.kick(id)))
		player_list.add_child(row)
	team_row.visible = teams

	# Settings: leader edits, others just read the info line
	settings_box.visible = leader
	set_public.set_pressed_no_signal(r["public"])
	set_max.set_value_no_signal(r["max"])
	set_mode.select(r["mode"])
	set_endless.set_pressed_no_signal(r["wins"] == 0)
	set_wins.editable = r["wins"] != 0
	if r["wins"] > 0:
		set_wins.set_value_no_signal(r["wins"])

	# Fish
	var fs := Fish.stats(_my_fish())
	fish_label.text = fs["name"]
	fish_stats.text = "%s\nReach %s   Power %s\nSpeed %s   Swing %s" % [fs["desc"], _bar(fs["reach"]),
		_bar(fs["power"]), _bar(fs["speed"]), _bar(0.5 / fs["cooldown"])]

	start_btn.visible = leader
	start_btn.text = "Start Match" if Net.players.size() > 1 else "Start Solo Practice"
	invite_btn.visible = Net.lobby_id != 0
	_show_chat()


func _show_chat() -> void:
	chat_text.text = "\n".join(Net.chat_log)
	await get_tree().process_frame
	chat_scroll.scroll_vertical = int(chat_scroll.get_v_scroll_bar().max_value)


# =============================================================================
# Settings file + background
# =============================================================================

func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS) == OK:
		name_edit.text = cf.get_value("p", "name", "")
		server_edit.text = cf.get_value("p", "server", "")
	# Website opened from a host's share link: bonkfish.up.railway.app/?server=abc.trycloudflare.com
	if OS.has_feature("web"):
		var s = JavaScriptBridge.eval("new URLSearchParams(location.search).get('server') || ''", true)
		if typeof(s) == TYPE_STRING and s != "":
			server_edit.text = s
			status_label.text = "Joining a friend's game - enter your name and press Play Online."
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
	# Keep the public room list fresh while browsing
	if browser_panel.visible:
		refresh_timer -= delta
		if refresh_timer <= 0.0:
			refresh_timer = 4.0
			Net.refresh_rooms()
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
