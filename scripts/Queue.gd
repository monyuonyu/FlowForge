extends FlowObject
class_name Queue
## 待ち行列（イベント駆動）。容量まで貯め、下流が空くとFIFOで流す。

var capacity: int = 12
var items: Array = []

# 統計
var _len_area: float = 0.0
var _len_last_t: float = 0.0
var _wait_sum: float = 0.0
var _wait_n: int = 0

func _init() -> void:
	obj_name = "Queue"
	body_color = Color(0.55, 0.45, 0.20)

func type_name() -> String:
	return "Queue"

func get_params() -> Dictionary:
	return {"capacity": capacity}

func set_params(d: Dictionary) -> void:
	if d.has("capacity"): capacity = int(d["capacity"])

func reset_object() -> void:
	super.reset_object()
	items = []
	_len_area = 0.0
	_len_last_t = Sim.sim_time
	_wait_sum = 0.0
	_wait_n = 0
	set_state("empty")

func reset_stats() -> void:
	super.reset_stats()
	_len_area = 0.0
	_len_last_t = Sim.sim_time
	_wait_sum = 0.0
	_wait_n = 0

func _len_accum() -> void:
	_len_area += float(items.size()) * (Sim.sim_time - _len_last_t)
	_len_last_t = Sim.sim_time

func avg_length() -> float:
	_len_accum()
	return _len_area / Sim.stats_elapsed()

func avg_wait() -> float:
	if _wait_n == 0:
		return 0.0
	return _wait_sum / _wait_n

func receive_item(item: FlowItem) -> bool:
	if items.size() >= capacity:
		return false
	_len_accum()
	items.append(item)
	item.enqueue_time = Sim.sim_time
	input_count += 1
	_fire("on_entry", item)
	_arrange()
	_try_flush()
	_update_state()
	return true

func _retry_push() -> void:
	_try_flush()
	_update_state()

func _try_flush() -> void:
	# 先頭を pop してから try_push する。try_push の同期連鎖中に自分へ再入しても
	# 取り出し済みの要素は items に無いため二重送出しない。失敗したら先頭へ戻して break。
	var removed: int = 0
	while items.size() > 0:
		_len_accum()   # pop 前に現在の長さで面積を確定
		var it: FlowItem = items.pop_front()
		if try_push(it):
			_wait_sum += Sim.sim_time - it.enqueue_time
			_wait_n += 1
			removed += 1
		else:
			items.push_front(it)
			break
	if removed > 0:
		_arrange()
		_notify_space()

func _update_state() -> void:
	if items.size() == 0:
		set_state("empty")
	elif items.size() >= capacity:
		set_state("full")
	else:
		set_state("storing")

func _arrange() -> void:
	if not Sim.visuals_enabled:
		return
	var cols: int = 4
	for i in items.size():
		var col: int = i % cols
		var row: int = i / cols
		var pos: Vector3 = global_position + Vector3(-0.6 + col * 0.4, 0.6 + row * 0.4, 0.0)
		items[i].move_to(pos)
