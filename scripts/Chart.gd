extends Control
class_name Chart
## スループット(個/時)とWIP(仕掛)の時系列を描く簡易チャート。

var thr: Array = []
var wip: Array = []
var max_points: int = 240

const COL_THR := Color(0.35, 0.85, 0.5)
const COL_WIP := Color(0.95, 0.65, 0.25)
const BG := Color(0.07, 0.08, 0.11)

func push_sample(t_val: float, w_val: float) -> void:
	thr.append(t_val)
	wip.append(w_val)
	if thr.size() > max_points:
		thr.pop_front()
		wip.pop_front()
	queue_redraw()

func reset() -> void:
	thr.clear()
	wip.clear()
	queue_redraw()

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(0, 0, w, h), BG)
	# 目盛り（横4分割）
	for i in range(1, 4):
		var y: float = h * i / 4.0
		draw_line(Vector2(0, y), Vector2(w, y), Color(0.2, 0.22, 0.27), 1.0)
	_draw_series(thr, COL_THR, w, h)
	_draw_series(wip, COL_WIP, w, h)
	# 凡例
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(6, 14), "● スループット(個/時)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_THR)
	draw_string(font, Vector2(6, 28), "● WIP(仕掛)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_WIP)
	if thr.size() > 0:
		draw_string(font, Vector2(w - 90, 14), "%.0f 個/時" % thr[thr.size() - 1],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_THR)
		draw_string(font, Vector2(w - 90, 28), "%d 個" % int(wip[wip.size() - 1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_WIP)

func _draw_series(data: Array, col: Color, w: float, h: float) -> void:
	if data.size() < 2:
		return
	var mx: float = 0.0001
	for v in data:
		mx = max(mx, float(v))
	var n: int = data.size()
	var pts := PackedVector2Array()
	for i in n:
		var x: float = w * float(i) / float(max_points - 1)
		var y: float = h - (float(data[i]) / mx) * (h - 8.0) - 4.0
		pts.append(Vector2(x, y))
	for i in range(n - 1):
		draw_line(pts[i], pts[i + 1], col, 1.6)
