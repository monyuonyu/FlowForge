extends FlowObject
class_name Source
## 発生源（イベント駆動）。次の生成をイベントで予約。下流が詰まれば生成を止め、
## 空きが出たら（_retry_push）再開する。

var interarrival: Dictionary = {"type": "exp", "a": 3.0}
var type_count: int = 3
## 到着スケジュール（既定 null=従来通り interarrival 固定）。
## 例 [{"from":0,"interarrival":{...}},{"from":3600,"interarrival":{...}}]
## 現在 sim_time 以下で最大の "from" を持つ区間の分布を使う。
var arrival_schedule = null
var item_palette: Array = [
	Color(0.90, 0.30, 0.30), Color(0.95, 0.78, 0.25),
	Color(0.35, 0.75, 1.00), Color(0.55, 0.85, 0.45),
]

var created: int = 0
## 品種循環専用カウンタ（統計とは無関係。reset_stats でリセットしない）。
## warmup 境界で created が 0 に戻っても型循環（段取り/分岐のダイナミクス）が
## 途切れないよう、生成通番として独立に増加させる。
var _type_seq: int = 0
var _held: FlowItem = null

func _init() -> void:
	obj_name = "Source"
	body_color = Color(0.20, 0.45, 0.65)

func type_name() -> String:
	return "Source"

func get_params() -> Dictionary:
	var d := {"interarrival": interarrival, "type_count": type_count}
	if arrival_schedule != null:
		d["arrival_schedule"] = arrival_schedule
	return d

func set_params(d: Dictionary) -> void:
	if d.has("interarrival"): interarrival = d["interarrival"]
	if d.has("type_count"): type_count = int(d["type_count"])
	if d.has("arrival_schedule"): arrival_schedule = d["arrival_schedule"]

func reset_object() -> void:
	super.reset_object()
	created = 0
	_type_seq = 0
	_held = null
	set_state("generating")

func reset_stats() -> void:
	# warmup 跨ぎで created（統計用の生成数）はリセットするが、
	# 品種循環カウンタ _type_seq は保持して型循環の連続性を壊さない。
	super.reset_stats()
	created = 0

func on_sim_start() -> void:
	_schedule_next()

## 現在 sim_time に該当する到着分布を返す（スケジュール未設定なら interarrival 固定）。
func _current_interarrival() -> Dictionary:
	if arrival_schedule is Array and not (arrival_schedule as Array).is_empty():
		var chosen: Dictionary = interarrival
		var best_from: float = -INF
		for seg in arrival_schedule:
			var f: float = float(seg.get("from", 0.0))
			if Sim.sim_time >= f and f >= best_from:
				best_from = f
				chosen = seg.get("interarrival", interarrival)
		return chosen
	return interarrival

func _schedule_next() -> void:
	# 分離モード（Sim.sources_enabled=false）では既定 Source は到着を自走生成しない。
	# 既定 true のため通常はこのガードを素通りし、抽選順・イベント順は従来と完全同一。
	if not Sim.sources_enabled:
		return
	var t: float = _override_num("interarrival", Dist.sample(_current_interarrival(), rng("gen")))
	Sim.schedule(t, _gen)

func _gen() -> void:
	# 分離を実行途中で有効化した場合に、予約済み _gen イベントが発火しても生成しない安全弁。
	if not Sim.sources_enabled:
		return
	var item := _spawn_item()
	_fire("on_create", item)
	if try_push(item):
		set_state("generating")
		_schedule_next()
	else:
		_held = item
		set_state("blocked")

func _retry_push() -> void:
	if _held != null and try_push(_held):
		_held = null
		set_state("generating")
		_schedule_next()
	else:
		set_state("blocked")

func _spawn_item() -> FlowItem:
	var item := FlowItem.new()
	var tc: int = max(1, type_count)
	var idx: int = _type_seq % tc
	item.setup(idx, item_palette[idx % item_palette.size()], Sim.visuals_enabled)
	item.created_time = Sim.sim_time
	item.id = Sim.next_item_id()
	if Sim.visuals_enabled:
		item.set_pos_now(global_position + Vector3(0, 0.8, 0))
	created += 1
	_type_seq += 1
	input_count += 1
	Sim.wip_inc()
	return item
