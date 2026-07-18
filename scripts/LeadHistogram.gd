extends Control
class_name LeadHistogram
## 滞留時間（リードタイム）のヒストグラム。

var data: Array = []
var bins: int = 22

const BG := Color(0.07, 0.08, 0.11)
const BAR := Color(0.45, 0.72, 0.95)
const MEANC := Color(0.95, 0.65, 0.25)

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(0, 0, w, h), BG)
	var font := ThemeDB.fallback_font
	if data.size() < 2:
		draw_string(font, Vector2(8, h * 0.5), "データ収集中…", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.62, 0.7))
		return
	var lo: float = data[0]
	var hi: float = data[0]
	var sum: float = 0.0
	for v in data:
		lo = min(lo, float(v))
		hi = max(hi, float(v))
		sum += float(v)
	var mean: float = sum / data.size()
	if hi <= lo:
		hi = lo + 1.0
	var counts := []
	counts.resize(bins)
	counts.fill(0)
	for v in data:
		var bi: int = int((float(v) - lo) / (hi - lo) * bins)
		bi = clamp(bi, 0, bins - 1)
		counts[bi] += 1
	var maxc: int = 1
	for c in counts:
		maxc = max(maxc, c)
	var pad_bottom: float = 16.0
	var bw: float = w / bins
	for i in bins:
		var bh: float = float(counts[i]) / maxc * (h - pad_bottom - 4.0)
		draw_rect(Rect2(i * bw + 1.0, h - pad_bottom - bh, bw - 2.0, bh), BAR)
	# 平均線
	var mx: float = (mean - lo) / (hi - lo) * w
	draw_line(Vector2(mx, 4), Vector2(mx, h - pad_bottom), MEANC, 1.5)
	# 軸ラベル
	draw_string(font, Vector2(2, h - 3), "%.0fs" % lo, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.72, 0.78))
	draw_string(font, Vector2(w - 44, h - 3), "%.0fs" % hi, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.72, 0.78))
	draw_string(font, Vector2(mx + 3, 14), "μ=%.0fs" % mean, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MEANC)
