extends Control
class_name StateBar
## 1設備の状態内訳を横スタックバーで描画（FlexSimのステートチャート相当）。

var obj = null

const ORDER := ["busy", "running", "collecting", "setup", "generating",
	"storing", "waiting", "blocked", "down", "full", "empty", "idle"]

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if obj == null or not is_instance_valid(obj):
		draw_rect(Rect2(0, 0, w, h), Color(0.18, 0.19, 0.23))
		return
	var dur: Dictionary = obj.state_durations()
	var total: float = 0.0
	for k in dur:
		total += dur[k]
	if total <= 0.0:
		draw_rect(Rect2(0, 0, w, h), Color(0.18, 0.19, 0.23))
		return
	var x: float = 0.0
	for s in ORDER:
		var v: float = float(dur.get(s, 0.0))
		if v <= 0.0:
			continue
		var seg: float = w * v / total
		var col: Color = FlowObject.STATE_COLORS.get(s, Color(0.5, 0.5, 0.5))
		draw_rect(Rect2(x, 0, seg, h), col)
		x += seg
