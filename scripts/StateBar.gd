extends Control
class_name StateBar
## 1設備の状態内訳を横スタックバーで描画（FlexSimのステートチャート相当）。
## 色は FlowObject.STATE_COLORS（統一パレット）を参照＝3D灯／ガントと同色。

var obj = null

const ORDER := ["busy", "running", "collecting", "setup", "generating",
	"storing", "waiting", "blocked", "down", "full", "empty", "idle"]
const TRACK := Color("#1c2029")   # 下地（空／未計測）

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	# 角丸の下地トラック
	draw_rect(Rect2(0, 0, w, h), TRACK)
	if obj == null or not is_instance_valid(obj):
		return
	var dur: Dictionary = obj.state_durations()
	var total: float = 0.0
	for k in dur:
		total += dur[k]
	if total <= 0.0:
		return
	var x: float = 0.0
	for s in ORDER:
		var v: float = float(dur.get(s, 0.0))
		if v <= 0.0:
			continue
		var seg: float = w * v / total
		var col: Color = FlowObject.STATE_COLORS.get(s, Color(0.5, 0.5, 0.5))
		# 1px のサーフェスギャップ（トラックが覗く）で隣接セグメントを分離
		draw_rect(Rect2(x, 0, max(1.0, seg - 1.0), h), col)
		x += seg
