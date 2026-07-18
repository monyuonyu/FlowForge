extends FlowObject
class_name Combiner
## 組立（イベント駆動）。batch_size 個を集めて 1 個に統合し下流へ送る。
## 統合で消えた分だけ WIP を減算して系内在庫の整合を保つ。

var batch_size: int = 3
var _accum: Array = []
var _finished: FlowItem = null

func _init() -> void:
	obj_name = "Combiner"
	body_color = Color(0.45, 0.35, 0.55)

func type_name() -> String:
	return "Combiner"

func get_params() -> Dictionary:
	return {"batch_size": batch_size}

func set_params(d: Dictionary) -> void:
	if d.has("batch_size"): batch_size = max(1, int(d["batch_size"]))

func reset_object() -> void:
	super.reset_object()
	_accum = []
	_finished = null
	set_state("empty")

func receive_item(item: FlowItem) -> bool:
	if _finished != null or _accum.size() >= batch_size:
		return false
	_accum.append(item)
	input_count += 1
	_fire("on_entry", item)
	if Sim.visuals_enabled:
		item.move_to(global_position + Vector3(0, 0.8 + _accum.size() * 0.2, 0))
	if _accum.size() >= batch_size:
		_combine()
	else:
		set_state("storing")
	return true

func _combine() -> void:
	var keep: FlowItem = _accum[0]
	# 残りを統合（消滅）→ WIP 減算
	for i in range(1, _accum.size()):
		var it: FlowItem = _accum[i]
		Sim.wip_dec()
		it.dispose()
	keep.set_label("batch", batch_size)
	_accum = []
	if try_push(keep):
		set_state("empty")
		_notify_space()
	else:
		_finished = keep
		set_state("blocked")

func _retry_push() -> void:
	if _finished != null and try_push(_finished):
		_finished = null
		set_state("empty")
		_notify_space()
