extends FlowObject
class_name Sink
## 出口（イベント駆動）。回収して集計。統計は warmup 以降の値で評価する。

var total: int = 0
var sum_time_in_system: float = 0.0
var leadtimes: Array = []   # 滞留時間（ヒストグラム用, 直近のみ保持）

func _init() -> void:
	obj_name = "Sink"
	body_color = Color(0.45, 0.25, 0.45)

func type_name() -> String:
	return "Sink"

func reset_object() -> void:
	super.reset_object()
	total = 0
	sum_time_in_system = 0.0
	leadtimes = []
	set_state("idle")

func reset_stats() -> void:
	super.reset_stats()
	total = 0
	sum_time_in_system = 0.0
	leadtimes = []

func receive_item(item: FlowItem) -> bool:
	_fire("on_entry", item)   # アイテム破棄の前にトリガーを発火
	total += 1
	input_count += 1
	var lt: float = Sim.sim_time - item.created_time
	sum_time_in_system += lt
	leadtimes.append(lt)
	if leadtimes.size() > 6000:
		leadtimes.pop_front()
	Sim.wip_dec()
	item.dispose()
	return true

func avg_time_in_system() -> float:
	if total == 0:
		return 0.0
	return sum_time_in_system / total

func throughput_per_hour() -> float:
	return float(total) / Sim.stats_elapsed() * 3600.0
