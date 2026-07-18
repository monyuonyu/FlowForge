extends FlowObject
class_name Rack
## ラック/倉庫ストレージ（イベント駆動）。間口(bays)×段(levels)=容量 のセルを持つ格納設備。
## FlexSim の Rack 相当。構造化容量＋入出庫時間＋払い出し方策を持つ。
## - 入庫: 空きセルがあれば受理（容量到達で receive_item=false → 上流ブロック）。
##         put_time>0 なら Sim.schedule で入庫時間を計上（その間もセル占有）。
## - 出庫: 下流が空けば retrieve_policy 順に払い出す（fifo/lifo/by_label）。
##         get_time>0 なら出庫時間を計上（逐次リトリーブ・単一チャネル）。
## - バックプレッシャー: Queue と同様（_notify_space/_retry_push）。決定的。
## - 統計: 平均在庫（時間加重, Queue の Lq と同型）・占有率。

var bays: int = 3          # 間口
var levels: int = 2        # 段
var put_time: float = 0.0  # 入庫時間（秒, 既定0=即時）
var get_time: float = 0.0  # 出庫時間（秒, 既定0=即時）
var retrieve_policy: String = "fifo"   # "fifo" / "lifo" / "by_label"
var label_key: String = "priority"     # by_label 時の昇順キー

var items: Array = []      # 格納済み（利用可能）アイテム。挿入順を保持。
var _inbound: int = 0      # 入庫中（put_time 経過待ち）のセル占有数
var _retrieving: FlowItem = null   # 出庫中（get_time 経過待ち）のアイテム
var _out_held: FlowItem = null     # 出庫完了したが下流満杯で保持中のアイテム

# 統計（イベント境界で集計・Queue と同型）
var _inv_area: float = 0.0
var _inv_last_t: float = 0.0
var _wait_sum: float = 0.0
var _wait_n: int = 0

func _init() -> void:
	obj_name = "Rack"
	body_color = Color(0.40, 0.42, 0.50)

func type_name() -> String:
	return "Rack"

func get_params() -> Dictionary:
	return {
		"bays": bays, "levels": levels,
		"put_time": put_time, "get_time": get_time,
		"retrieve_policy": retrieve_policy, "label_key": label_key,
	}

func set_params(d: Dictionary) -> void:
	if d.has("bays"): bays = max(1, int(d["bays"]))
	if d.has("levels"): levels = max(1, int(d["levels"]))
	if d.has("put_time"): put_time = max(0.0, float(d["put_time"]))
	if d.has("get_time"): get_time = max(0.0, float(d["get_time"]))
	if d.has("retrieve_policy"): retrieve_policy = str(d["retrieve_policy"])
	if d.has("label_key"): label_key = str(d["label_key"])

func reset_object() -> void:
	super.reset_object()
	items = []
	_inbound = 0
	_retrieving = null
	_out_held = null
	_inv_area = 0.0
	_inv_last_t = Sim.sim_time
	_wait_sum = 0.0
	_wait_n = 0
	set_state("empty")

func reset_stats() -> void:
	super.reset_stats()
	_inv_area = 0.0
	_inv_last_t = Sim.sim_time
	_wait_sum = 0.0
	_wait_n = 0

# ---------------------------------------------------------------
# 容量・占有アクセサ
# ---------------------------------------------------------------
## 総容量 = 間口×段。
func get_capacity() -> int:
	return bays * levels

## 現在ラックに物理的に存在するアイテム数（入庫中/出庫中/払出待ちを含む）。
## = 占有セル数。容量判定・在庫平均・保存則の基準。
func occupancy() -> int:
	return items.size() + _inbound + (1 if _retrieving != null else 0) + (1 if _out_held != null else 0)

func is_full() -> bool:
	return occupancy() >= get_capacity()

# ---------------------------------------------------------------
# 統計（時間加重在庫）
# ---------------------------------------------------------------
func _inv_accum() -> void:
	_inv_area += float(occupancy()) * (Sim.sim_time - _inv_last_t)
	_inv_last_t = Sim.sim_time

## 平均在庫（時間加重, Queue の Lq と同型）。
func avg_inventory() -> float:
	_inv_accum()
	return _inv_area / Sim.stats_elapsed()

## 占有率（平均在庫 / 容量）。
func occupancy_rate() -> float:
	var cap: int = get_capacity()
	if cap <= 0:
		return 0.0
	return avg_inventory() / float(cap)

## 平均在庫時間（払い出したアイテムのラック内滞留の平均）。
func avg_dwell() -> float:
	if _wait_n == 0:
		return 0.0
	return _wait_sum / _wait_n

# ---------------------------------------------------------------
# 入庫
# ---------------------------------------------------------------
func receive_item(item: FlowItem) -> bool:
	if occupancy() >= get_capacity():
		return false   # 容量到達 → 上流ブロック
	_inv_accum()
	input_count += 1
	_fire("on_entry", item)
	item.enqueue_time = Sim.sim_time   # 入庫時刻（払い出し時に滞留時間を集計）
	if put_time > 0.0:
		_inbound += 1
		Sim.schedule(put_time, _on_put_done.bind(item))
	else:
		items.append(item)
		_try_flush()
	_arrange()
	_update_state()
	return true

func _on_put_done(item: FlowItem) -> void:
	# 入庫完了: 占有はそのまま（in-transit→格納）。利用可能在庫へ加える。
	_inbound -= 1
	items.append(item)
	_arrange()
	_try_flush()
	_update_state()

# ---------------------------------------------------------------
# 出庫（払い出し）
# ---------------------------------------------------------------
## 上流としての再送（下流に空きが出た時）。
func _retry_push() -> void:
	_try_flush()
	_update_state()

func _try_flush() -> void:
	if get_time <= 0.0:
		_flush_immediate()
	else:
		_pump_retrieval()

## get_time=0: 方策順に即時払い出し（Queue と同型のブロック安全ループ）。
func _flush_immediate() -> void:
	var removed: int = 0
	while items.size() > 0:
		_inv_accum()   # 払い出し前に現在の在庫で面積を確定
		var idx: int = _pick_index()
		var it: FlowItem = items[idx]
		items.remove_at(idx)
		if try_push(it):
			_wait_sum += Sim.sim_time - it.enqueue_time
			_wait_n += 1
			removed += 1
		else:
			items.insert(idx, it)   # 失敗 → 元位置へ戻して停止（二重送出しない）
			break
	if removed > 0:
		_arrange()
		_notify_space()

## get_time>0: 逐次リトリーブ（単一チャネル）。
func _pump_retrieval() -> void:
	# 出庫完了済みで保持中があれば先に押し出す。
	if _out_held != null:
		if try_push(_out_held):
			_inv_accum()
			_wait_sum += Sim.sim_time - _out_held.enqueue_time
			_wait_n += 1
			_out_held = null
			_notify_space()
		else:
			return   # まだ下流満杯 → 待つ
	# リトリーブ進行中なら待つ。
	if _retrieving != null:
		return
	if items.size() == 0:
		return
	# 次のアイテムを方策順に取り出し、出庫時間を計上。
	var idx: int = _pick_index()
	var it: FlowItem = items[idx]
	items.remove_at(idx)   # 占有は継続（_retrieving で保持）
	_retrieving = it
	Sim.schedule(get_time, _on_get_done.bind(it))

func _on_get_done(it: FlowItem) -> void:
	_retrieving = null
	if try_push(it):
		_inv_accum()
		_wait_sum += Sim.sim_time - it.enqueue_time
		_wait_n += 1
		_notify_space()
		_pump_retrieval()   # 次を継続
	else:
		_out_held = it       # 下流満杯 → 保持（_retry_push で再送）
	_update_state()

## 方策に従い払い出すアイテムの items 内インデックスを返す（items は非空前提）。
func _pick_index() -> int:
	match retrieve_policy:
		"lifo":
			return items.size() - 1
		"by_label":
			var best_i: int = 0
			var best_v = items[0].get_label(label_key, 0)
			for i in range(1, items.size()):
				var v = items[i].get_label(label_key, 0)
				if _label_less(v, best_v):
					best_v = v
					best_i = i
			return best_i
		_:   # "fifo"（既定）
			return 0

## 昇順比較（数値/文字列に対応。型不一致は数値化して比較）。
func _label_less(a, b) -> bool:
	if (typeof(a) == TYPE_STRING) and (typeof(b) == TYPE_STRING):
		return String(a) < String(b)
	return float(a) < float(b)

# ---------------------------------------------------------------
func _update_state() -> void:
	var c: int = occupancy()
	if c == 0:
		set_state("empty")
	elif c >= get_capacity():
		set_state("full")
	else:
		set_state("storing")

func _arrange() -> void:
	if not Sim.visuals_enabled:
		return
	var cols: int = max(1, bays)
	for i in items.size():
		var col: int = i % cols
		var row: int = i / cols
		var pos: Vector3 = global_position + Vector3(-0.6 + col * 0.4, 0.5 + row * 0.5, 0.0)
		items[i].move_to(pos)
