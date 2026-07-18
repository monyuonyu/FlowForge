extends Control
class_name Chart
## スループット(個/時)とWIP(仕掛)の時系列を描く簡易チャート。
## 各系列はそれぞれの最大値で正規化して描画する（従来どおり・意味は不変）。

var thr: Array = []
var wip: Array = []
var max_points: int = 240

# dataviz カテゴリ配色（青／琥珀）。ダーク面で高コントラスト・CVD分離良好。
const COL_THR := Color("#3987e5")   # スループット＝系列1（青）
const COL_WIP := Color("#e39a2e")   # WIP＝系列2（琥珀）
const BG := Color("#12141c")        # プロット面（パネルより一段暗いインセット）
const GRID := Color("#242a37")      # 目盛り（ヘアライン）
const AXIS := Color("#3a4150")      # ベースライン
const MUTED := Color("#9aa0ac")     # 軸ラベル（ミュート）

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
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(0, 0, w, h), BG)
	var top_pad: float = 32.0   # 凡例帯の高さ
	# 目盛り（横4分割のヘアライン）
	for i in range(1, 4):
		var y: float = top_pad + (h - top_pad) * i / 4.0
		draw_line(Vector2(0, y), Vector2(w, y), GRID, 1.0)
	# ベースライン
	draw_line(Vector2(0, h - 1.0), Vector2(w, h - 1.0), AXIS, 1.0)
	_draw_series(thr, COL_THR, w, h, top_pad)
	_draw_series(wip, COL_WIP, w, h, top_pad)
	# コンパクト凡例（スウォッチ＋ミュート見出し＋現在値）
	_legend_item(font, 6.0, 12.0, COL_THR, "スループット", "%.0f 個/時" % (thr[thr.size() - 1] if thr.size() > 0 else 0.0), w)
	_legend_item(font, 6.0, 26.0, COL_WIP, "WIP", "%d 個" % (int(wip[wip.size() - 1]) if wip.size() > 0 else 0), w)

func _legend_item(font, x: float, y: float, col: Color, name: String, val: String, w: float) -> void:
	# 8px スウォッチ（丸）＋名称（ミュート）＋現在値（系列色）
	draw_circle(Vector2(x + 4.0, y - 3.0), 4.0, col)
	draw_string(font, Vector2(x + 13.0, y + 1.0), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
	draw_string(font, Vector2(w - 78.0, y + 1.0), val, HORIZONTAL_ALIGNMENT_LEFT, 74.0, 11, col)

func _draw_series(data: Array, col: Color, w: float, h: float, top_pad: float) -> void:
	if data.size() < 2:
		return
	var mx: float = 0.0001
	for v in data:
		mx = max(mx, float(v))
	var n: int = data.size()
	var plot_h: float = h - top_pad
	var pts := PackedVector2Array()
	for i in n:
		var x: float = w * float(i) / float(max_points - 1)
		var y: float = top_pad + plot_h - (float(data[i]) / mx) * (plot_h - 8.0) - 4.0
		pts.append(Vector2(x, y))
	# 細い連続線（アンチエイリアス）
	if pts.size() >= 2:
		draw_polyline(pts, col, 1.6, true)
