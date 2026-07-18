extends Control
class_name GanttChart
## 設備別の状態タイムライン（ガントチャート）。
## 横軸=時間・縦軸=設備の帯で、各設備の状態セグメントを STATE_COLORS で色分け描画する。
## FlowObject.record_timeline=ON（Sim.set_timeline_recording）で記録されたセグメントを表示。
## 記録OFF/未記録の設備は帯を出さない（既定は「記録OFF」の案内のみ）。

var objects: Array = []   # 対象 FlowObject 配列（UI が設定）

const BG := Color(0.07, 0.08, 0.11)
const LABEL_W := 66.0
const LEGEND_H := 16.0
const TOP_PAD := 4.0

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(0, 0, w, h), BG)
	var font := ThemeDB.fallback_font
	# 記録があり有効な設備だけを行にする
	var rows: Array = []
	for o in objects:
		if o == null or not is_instance_valid(o):
			continue
		if not o.record_timeline:
			continue
		rows.append(o)
	if rows.is_empty():
		draw_string(font, Vector2(8, h * 0.5), "記録OFF（実行で記録開始）",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.62, 0.7))
		return
	# 時間レンジ（全設備の全セグメント）
	var t_min: float = INF
	var t_max: float = -INF
	var seg_cache: Array = []
	var used_states: Dictionary = {}
	for o in rows:
		var segs: Array = o.timeline_segments()
		seg_cache.append(segs)
		for seg in segs:
			t_min = min(t_min, float(seg.start))
			t_max = max(t_max, float(seg.end))
			used_states[seg.state] = true
	if t_min == INF:
		draw_string(font, Vector2(8, h * 0.5), "データ収集中…",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.62, 0.7))
		return
	if t_max <= t_min:
		t_max = t_min + 1.0
	var plot_x: float = LABEL_W
	var plot_w: float = max(1.0, w - LABEL_W - 4.0)
	var avail_h: float = h - LEGEND_H - TOP_PAD
	var row_h: float = avail_h / float(rows.size())
	var span: float = t_max - t_min
	for i in rows.size():
		var o = rows[i]
		var y: float = TOP_PAD + float(i) * row_h
		# 設備名（左ラベル）
		draw_string(font, Vector2(2, y + row_h * 0.62), str(o.obj_name),
			HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 4.0, 11, Color(0.78, 0.8, 0.86))
		# 行の下地
		draw_rect(Rect2(plot_x, y + 1.0, plot_w, max(1.0, row_h - 2.0)), Color(0.14, 0.15, 0.19))
		for seg in seg_cache[i]:
			var x0: float = plot_x + (float(seg.start) - t_min) / span * plot_w
			var x1: float = plot_x + (float(seg.end) - t_min) / span * plot_w
			var col: Color = FlowObject.STATE_COLORS.get(seg.state, Color(0.5, 0.5, 0.5))
			draw_rect(Rect2(x0, y + 1.0, max(1.0, x1 - x0), max(1.0, row_h - 2.0)), col)
	# 下段: 時間レンジ＋簡易凡例（使用された状態のみ）を1行にまとめる
	var ly: float = h - LEGEND_H + 2.0
	var range_txt: String = "%.0f–%.0fs" % [t_min, t_max]
	draw_string(font, Vector2(2, ly + 9.0), range_txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.65, 0.67, 0.74))
	var lx: float = 2.0 + float(range_txt.length()) * 6.0 + 10.0
	for st in used_states.keys():
		var col2: Color = FlowObject.STATE_COLORS.get(st, Color(0.5, 0.5, 0.5))
		draw_rect(Rect2(lx, ly, 9.0, 9.0), col2)
		draw_string(font, Vector2(lx + 12.0, ly + 9.0), str(st),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.7, 0.72, 0.78))
		lx += 12.0 + float(str(st).length()) * 6.5 + 8.0
		if lx > w - 40.0:
			break
