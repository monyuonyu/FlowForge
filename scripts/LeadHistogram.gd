extends Control
class_name LeadHistogram
## 滞留時間（リードタイム）のヒストグラム。単一色相の逐次バー＋平均線。

var data: Array = []
var bins: int = 22

const BG := Color("#12141c")        # プロット面
const BAR := Color("#3987e5")       # 逐次単一色相（青）
const AXIS := Color("#3a4150")      # ベースライン
const MEANC := Color("#f0b429")     # 平均線（琥珀・バーと明確に対比）
const MUTED := Color("#9aa0ac")     # 軸ラベル

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(0, 0, w, h), BG)
	var font := ThemeDB.fallback_font
	if data.size() < 2:
		draw_string(font, Vector2(8, h * 0.5), "データ収集中…", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, MUTED)
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
	var base_y: float = h - pad_bottom
	var bw: float = w / bins
	# バー（2px のサーフェスギャップで隣接を分離）
	for i in bins:
		var bh: float = float(counts[i]) / maxc * (base_y - 4.0)
		if bh > 0.0:
			draw_rect(Rect2(i * bw + 1.0, base_y - bh, bw - 2.0, bh), BAR)
	# ベースライン軸
	draw_line(Vector2(0, base_y), Vector2(w, base_y), AXIS, 1.0)
	# 平均線＋ラベル
	var mx: float = (mean - lo) / (hi - lo) * w
	draw_line(Vector2(mx, 4), Vector2(mx, base_y), MEANC, 1.5)
	draw_string(font, Vector2(mx + 4.0, 14), "μ=%.0fs" % mean, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MEANC)
	# 軸ラベル（左=最小・右=最大、ミュート）
	draw_string(font, Vector2(2, h - 3), "%.0fs" % lo, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
	draw_string(font, Vector2(w - 44, h - 3), "%.0fs" % hi, HORIZONTAL_ALIGNMENT_RIGHT, 42.0, 11, MUTED)
