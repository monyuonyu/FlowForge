extends FlowObject
class_name FlowSeparator
## 分割（イベント駆動）。1 個受け取り split_qty 個に分けて下流へ送る。
## 増えた分だけ WIP を加算。全て送り出すまで次を受け取らない。

var split_qty: int = 2
var _pending: Array = []

const PALETTE := [
	Color(0.90, 0.30, 0.30), Color(0.95, 0.78, 0.25),
	Color(0.35, 0.75, 1.00), Color(0.55, 0.85, 0.45),
]

func _init() -> void:
	obj_name = "Separator"
	body_color = Color(0.35, 0.55, 0.45)

func type_name() -> String:
	return "Separator"

func get_params() -> Dictionary:
	return {"split_qty": split_qty}

func set_params(d: Dictionary) -> void:
	if d.has("split_qty"): split_qty = max(1, int(d["split_qty"]))

func reset_object() -> void:
	super.reset_object()
	_pending = []
	set_state("empty")

func receive_item(item: FlowItem) -> bool:
	if _pending.size() > 0:
		return false
	input_count += 1
	_fire("on_entry", item)
	_pending.append(item)
	for _i in range(split_qty - 1):
		var c := FlowItem.new()
		c.setup(item.item_type, PALETTE[item.item_type % PALETTE.size()], Sim.visuals_enabled)
		c.created_time = item.created_time
		c.id = Sim.next_item_id()
		if Sim.visuals_enabled:
			c.set_pos_now(global_position + Vector3(0, 0.8, 0))
		Sim.wip_inc()
		_pending.append(c)
	_flush()
	return true

func _retry_push() -> void:
	_flush()

func _flush() -> void:
	# 先頭を pop してから try_push（再入時の二重送出を防ぐ）。失敗なら先頭へ戻して break。
	while _pending.size() > 0:
		var it: FlowItem = _pending.pop_front()
		if not try_push(it):
			_pending.push_front(it)
			break
	if _pending.size() == 0:
		set_state("empty")
		_notify_space()
	else:
		set_state("blocked")
