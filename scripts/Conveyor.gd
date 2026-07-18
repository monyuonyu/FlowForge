extends FlowObject
class_name Conveyor
## コンベヤ（スロット式アキュムレーション・イベント駆動）。
## コンベヤを capacity 個のスロット列としてモデル化する。アイテムは 1 スロットの
## 移動に slot_time = travel_time/capacity を要し、前スロットが空いた時だけ前進する。
## 出口スロットのアイテムは try_push し、下流が満杯なら出口で停止する。後続は空きが
## 無ければスロットを詰めたまま停止し、詰まりが後方へ伝播する（アキュムレーション）。
## 入口スロットが埋まっていれば receive_item は false を返し上流をブロックする。
##
## パラメータ:
##   travel_time … 端から端までの搬送時間（length/speed 指定時は length/speed）。
##   length(m) / speed(m/s) … 与えられれば travel_time を上書き。length は容量算出にも使う。
##   item_spacing(m) … アイテム間隔（既定 0.5）。容量未指定時 capacity=max(1,floor(length/spacing))。
##   capacity … 明示指定を尊重。未指定なら幾何長から自動算出。
## 決定論: 乱数不使用。全遷移はイベント/同期カスケードで一意（schedule seq 順）。

var travel_time: float = 5.0
var capacity: int = 20
var length: float = 0.0
var belt_speed: float = 0.0
var item_spacing: float = 0.5
var start_point: Vector3 = Vector3.ZERO
var end_point: Vector3 = Vector3(6, 0, 0)

var _capacity_explicit: bool = false
var _cap: int = 1                # 実効スロット数
var _slot_time: float = 5.0      # 1スロット移動時間
var _slots: Array = []           # 各スロットの FlowItem または null（index 0=入口, _cap-1=出口）
var _ready_flags: Array = []           # 各スロットのアイテムが当該区間を走破済みか（前進可能か）
var _belt: MeshInstance3D

func _init() -> void:
	obj_name = "Conveyor"
	body_color = Color(0.30, 0.32, 0.38)

func type_name() -> String:
	return "Conveyor"

func get_params() -> Dictionary:
	var d := {"travel_time": travel_time, "capacity": _cap, "item_spacing": item_spacing}
	if length > 0.0: d["length"] = length
	if belt_speed > 0.0: d["speed"] = belt_speed
	return d

func set_params(d: Dictionary) -> void:
	if d.has("travel_time"): travel_time = float(d["travel_time"])
	if d.has("capacity"):
		capacity = int(d["capacity"])
		_capacity_explicit = true
	if d.has("length"): length = float(d["length"])
	if d.has("speed"): belt_speed = float(d["speed"])
	if d.has("item_spacing"): item_spacing = max(0.0001, float(d["item_spacing"]))
	if length > 0.0 and belt_speed > 0.0:
		travel_time = length / belt_speed
	_recompute_geometry()

# ---------------------------------------------------------------
# 実効容量 / スロット時間の算出
# ---------------------------------------------------------------
func _effective_length() -> float:
	if length > 0.0:
		return length
	return start_point.distance_to(end_point)

func _recompute_geometry() -> void:
	if _capacity_explicit:
		_cap = max(1, capacity)
	else:
		var L: float = _effective_length()
		_cap = max(1, int(floor(L / max(0.0001, item_spacing))))
	_slot_time = travel_time / float(_cap)

func capacity_effective() -> int:
	return _cap

## 現在コンベヤ上に存在するアイテム数（占有スロット数）。上限は capacity。
func occupancy() -> int:
	var n: int = 0
	for s in _slots:
		if s != null:
			n += 1
	return n

func reset_object() -> void:
	super.reset_object()
	_recompute_geometry()
	_slots = []
	_ready_flags = []
	for _i in range(_cap):
		_slots.append(null)
		_ready_flags.append(false)
	set_state("empty")

# ---------------------------------------------------------------
# 受け入れ（入口スロットが空いている時のみ）
# ---------------------------------------------------------------
func receive_item(item: FlowItem) -> bool:
	if _cap <= 0 or _slots[0] != null:
		return false   # 入口スロット占有 → 上流ブロック
	_slots[0] = item
	_ready_flags[0] = false
	input_count += 1
	_fire("on_entry", item)
	if Sim.visuals_enabled:
		item.set_pos_now(_slot_pos(0))
	Sim.schedule(_slot_time, func(): _on_slot_ready(item))
	_update_state()
	return true

# ---------------------------------------------------------------
# スロット走破完了 → 前進 or 出口送出を試みる
# ---------------------------------------------------------------
func _on_slot_ready(item: FlowItem) -> void:
	var i: int = _slot_of(item)
	if i < 0:
		return   # 既にコンベヤ外（防御的）
	_ready_flags[i] = true
	_try_advance(i)
	_update_state()

## スロット i の（走破済み）アイテムを前進または送出する。
func _try_advance(i: int) -> void:
	if i < 0 or i >= _cap:
		return
	var item = _slots[i]
	if item == null or not _ready_flags[i]:
		return
	if i == _cap - 1:
		# 出口スロット: 下流へ送出を試みる
		if try_push(item):
			_slots[i] = null
			_ready_flags[i] = false
			_on_slot_freed(i)
		# 失敗時は出口で停止（blocked）。下流回復時 _retry_push で再試行。
	else:
		if _slots[i + 1] == null:
			# 前スロットが空 → 前進
			_slots[i + 1] = item
			_ready_flags[i + 1] = false
			_slots[i] = null
			_ready_flags[i] = false
			if Sim.visuals_enabled:
				item.move_to(_slot_pos(i + 1))
			Sim.schedule(_slot_time, func(): _on_slot_ready(item))
			_on_slot_freed(i)
		# 前スロット占有 → その場で停止（後方伝播で蓄積）

## スロット i が空いた: 後方の（走破済み）アイテムを前進させ、入口なら上流へ通知。
func _on_slot_freed(i: int) -> void:
	if i - 1 >= 0 and _slots[i - 1] != null and _ready_flags[i - 1]:
		_try_advance(i - 1)
	if i == 0:
		_notify_space()

## 下流が空いた時に呼ばれる（出口で停止していたアイテムの再送出）。
func _retry_push() -> void:
	var i: int = _cap - 1
	if i >= 0 and _slots[i] != null and _ready_flags[i]:
		_try_advance(i)
	_update_state()

func _slot_of(item: FlowItem) -> int:
	for i in range(_cap):
		if _slots[i] == item:
			return i
	return -1

## 出口スロットに走破済みアイテムが停止している（＝下流満杯で送れない）か。
func _exit_stuck() -> bool:
	return _cap > 0 and _slots[_cap - 1] != null and _ready_flags[_cap - 1]

func _update_state() -> void:
	if occupancy() == 0:
		set_state("empty")
	elif _exit_stuck():
		set_state("blocked")
	else:
		set_state("running")

# ---------------------------------------------------------------
# 見た目
# ---------------------------------------------------------------
## スロット i の中心ワールド座標（start→end を等分）。
func _slot_pos(i: int) -> Vector3:
	var frac: float = (float(i) + 0.5) / float(max(1, _cap))
	return start_point.lerp(end_point, frac) + Vector3(0, 0.6, 0)

# 既定台座は描かない
func _build_default_visual() -> void:
	pass

func build_belt() -> void:
	if _belt != null and is_instance_valid(_belt):
		_belt.queue_free()
	var mid: Vector3 = (start_point + end_point) * 0.5
	var length_v: float = start_point.distance_to(end_point)
	_belt = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(max(0.1, length_v), 0.2, 1.0)
	_belt.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = body_color
	mat.roughness = 0.9
	_belt.material_override = mat
	add_child(_belt)
	var dir: Vector3 = (end_point - start_point)
	_belt.global_position = mid + Vector3(0, 0.5, 0)
	_belt.rotation.y = atan2(-dir.z, dir.x)
