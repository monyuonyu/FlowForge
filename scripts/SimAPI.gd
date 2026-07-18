extends RefCounted
class_name SimAPI
## ユーザースクリプトに渡す API（`sim`）。乱数は Rng ストリーム経由で決定的。

## 現在スクリプトを実行中の設備（FlowObject）。設備別に独立した乱数ストリームを配るために使う。
## FlowObject 側がユーザーメソッド呼び出しの直前に設定する。
var current_obj = null

func _s() -> RandomNumberGenerator:
	# 設備別の script ストリーム（設備をまたいで乱数系列が干渉しない）。
	if current_obj != null:
		return Rng.stream("%s:script" % current_obj.id)
	return Rng.stream("script")

func now() -> float:
	return Sim.sim_time

func log(msg) -> void:
	Scripts.log_msg(msg)

func rand(a: float, b: float) -> float:
	return _s().randf_range(a, b)

func rand_int(a: int, b: int) -> int:
	return _s().randi_range(a, b)

func exp(mean: float) -> float:
	return Dist.exponential(_s(), mean)

func normal(mean: float, sd: float) -> float:
	return Dist.normal(_s(), mean, sd)

func uniform(a: float, b: float) -> float:
	return Dist.uniform(_s(), a, b)

func find(id: String):
	return Scripts.find(id)

func speed() -> float:
	return Sim.speed
