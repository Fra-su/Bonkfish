extends CanvasLayer
## Autoload. Web only: allow one active Bonkfish tab per browser.
## Tabs talk over a BroadcastChannel. A newly opened tab that finds an active one shows a
## blocking screen; "Play here instead" takes over and the old tab disconnects and shows it.

const JS := """
(function () {
  if (window.bfTab) return;
  var me = Math.random().toString(36).slice(2);
  window.bfTab = { id: me, state: 'ok' };
  if (!('BroadcastChannel' in window)) return;
  var ch = new BroadcastChannel('bonkfish-tab');
  ch.onmessage = function (e) {
    var m = e.data || {};
    if (m.t === 'hello' && m.id !== me && window.bfTab.state === 'ok') {
      ch.postMessage({ t: 'here', id: me, to: m.id });
    } else if (m.t === 'here' && m.to === me && window.bfTab.state === 'ok') {
      window.bfTab.state = 'blocked';
    } else if (m.t === 'takeover' && m.id !== me) {
      window.bfTab.state = 'kicked';
    }
  };
  window.bfTakeover = function () { window.bfTab.state = 'ok'; ch.postMessage({ t: 'takeover', id: me }); };
  ch.postMessage({ t: 'hello', id: me });
})();
"""

var overlay: ColorRect
var msg: Label
var _ready_to_check := false
var _was := "ok"


func _ready() -> void:
	if not OS.has_feature("web"):
		set_process(false)
		return
	layer = 100
	JavaScriptBridge.eval(JS, true)
	_build()
	await get_tree().create_timer(0.7).timeout   # give other tabs time to answer
	_ready_to_check = true


func _build() -> void:
	overlay = ColorRect.new()
	overlay.color = Color(0.07, 0.2, 0.3, 0.96)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP   # block clicks to the game underneath
	overlay.visible = false
	overlay.theme = Net.make_theme()
	add_child(overlay)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 520
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)
	var title := Label.new()
	title.text = "BONKFISH IS OPEN ELSEWHERE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	v.add_child(title)
	msg = Label.new()
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(msg)
	var b := Button.new()
	b.text = "Play here instead"
	b.pressed.connect(_take_over)
	v.add_child(b)


func _take_over() -> void:
	JavaScriptBridge.eval("window.bfTakeover && window.bfTakeover();", true)
	_was = "ok"
	overlay.visible = false


func _process(_delta: float) -> void:
	if not _ready_to_check:
		return
	var state = JavaScriptBridge.eval("window.bfTab ? window.bfTab.state : 'ok'", true)
	if state == _was:
		return
	_was = state
	match state:
		"blocked":
			msg.text = "Bonkfish is already open in another tab of this browser.\nSwitch to that tab, or play here instead (the other tab will disconnect)."
			overlay.visible = true
		"kicked":
			msg.text = "You opened Bonkfish in another tab, so this one was disconnected.\nSwitch to the new tab, or play here instead."
			overlay.visible = true
			if Net.is_online():
				Net.leave()
			if get_tree().current_scene and get_tree().current_scene.scene_file_path != "res://Main.tscn":
				get_tree().change_scene_to_file("res://Main.tscn")
		_:
			overlay.visible = false
