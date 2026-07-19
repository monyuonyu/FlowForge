extends Node3D
class_name Operator
## 作業者（イベント駆動の資源）。移動時間はイベントで表現し、稼働時間は「作業中」のみ計上。
## 見た目は目標位置へ補間（ロジックと分離）。

var op_name: String = "Op"
## 編集用の安定な一意 id と表示名。obj_name は op_name と常に同値に保つ（サブクラス無しで
## Editor/UI が FlowObject と同じ経路（select/rename/インスペクタ）で扱えるようにする窓口）。
var id: String = ""
var obj_name: String = "Op"
var move_speed: float = 5.0
var home: Vector3 = Vector3.ZERO
var available: bool = true
var model_path: String = ""
## シフトカレンダー（既定=空=常時稼働）。周期 shift_period 内の稼働区間 [on,off) の配列。
## 例 shift=[{"on":0,"off":28800}], shift_period=86400。off 中は新規割当対象外。
var shift: Array = []
var shift_period: float = 0.0
## 論理位置（決定的な移動時間計算の基準）。帰投を廃止し、解放後もその場に留まる。
var logical_pos: Vector3 = Vector3.ZERO

var _state: String = "idle"      # idle / going / working / returning
var _busy_time: float = 0.0
var _work_start: float = 0.0
var _target_pos = null
var _model_holder: Node3D
var _label: Label3D
var _sel_box: MeshInstance3D
var _picker: StaticBody3D

func _ready() -> void:
	Sim.register(self)
	_build_visual()
	_build_selection()

func setup(nm: String, home_pos: Vector3) -> void:
	op_name = nm
	obj_name = nm
	home = home_pos
	logical_pos = home_pos
	global_position = home_pos

## 編集モードの型表示（インスペクタ「型: …」）。FlowObject.type_name() と同じ窓口。
func type_name() -> String:
	return "Operator"

func apply_model(path: String) -> void:
	model_path = path
	if _model_holder == null:
		return
	for c in _model_holder.get_children():
		c.queue_free()
	if path != "":
		var m: Node3D = Assets.load_model(path)
		if m != null:
			_model_holder.add_child(m)
			return
	_build_default_body()

func reset_object() -> void:
	available = true
	_state = "idle"
	_busy_time = 0.0
	_target_pos = null
	logical_pos = home
	global_position = home

func reset_stats() -> void:
	_busy_time = 0.0
	if _state == "working":
		_work_start = Sim.sim_time

func on_sim_start() -> void:
	pass

# --- シフトカレンダー ---
## 時刻 t にシフト稼働中か（shift 空なら常に true）。
func on_shift(t: float) -> bool:
	if shift.is_empty():
		return true
	var tt: float = t
	if shift_period > 0.0:
		tt = fposmod(t, shift_period)
	for iv in shift:
		var on_t: float = float(iv.get("on", 0.0))
		var off_t: float = float(iv.get("off", 0.0))
		if tt >= on_t and tt < off_t:
			return true
	return false

## t より後で最初に off→on へ切り替わる絶対時刻（無ければ INF）。
func next_on_time(t: float) -> float:
	if shift.is_empty():
		return INF
	if shift_period <= 0.0:
		var b0: float = INF
		for iv in shift:
			var on0: float = float(iv.get("on", 0.0))
			if on0 > t and on0 < b0:
				b0 = on0
		return b0
	var base: float = floor(t / shift_period) * shift_period
	var best: float = INF
	for cyc in [0, 1]:
		for iv in shift:
			var on_abs: float = base + float(cyc) * shift_period + float(iv.get("on", 0.0))
			if on_abs > t and on_abs < best:
				best = on_abs
	return best

# --- 移動時間（現在の論理位置ベース＝決定的。帰投を廃止し無駄な往復を除去） ---
func travel_time(target: Vector3) -> float:
	return max(0.05, logical_pos.distance_to(target) / move_speed)

## 目的地へ移動。論理位置を更新し、視覚も目標へ補間させる。
## 注意: travel_time は go_to より前に（更新前の logical_pos で）計算すること。
func go_to(pos: Vector3) -> void:
	_target_pos = pos
	_state = "going" if pos != home else "returning"
	logical_pos = pos

func start_working() -> void:
	# 冪等: 既に working なら _work_start を巻き戻さない（段取り→加工の連続稼働で
	# 途中区間を失わないため）。実処理の開始/再開時にのみ計上起点を立てる。
	if _state == "working":
		return
	_state = "working"
	_work_start = Sim.sim_time

func stop_working() -> void:
	if _state == "working":
		_busy_time += Sim.sim_time - _work_start
	_state = "idle"

func set_idle() -> void:
	_state = "idle"

func utilization() -> float:
	var busy: float = _busy_time
	if _state == "working":
		busy += Sim.sim_time - _work_start
	return clamp(busy / Sim.stats_elapsed(), 0.0, 1.0)

# --- 見た目 ---
func _build_visual() -> void:
	_model_holder = Node3D.new()
	add_child(_model_holder)
	_build_default_body()
	_label = Label3D.new()
	_label.text = op_name
	_label.position = Vector3(0, 2.1, 0)
	_label.font_size = 24
	_label.outline_size = 5
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0010
	add_child(_label)

func _build_default_body() -> void:
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.28
	cap.height = 1.3
	body.mesh = cap
	body.position = Vector3(0, 0.85, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.55, 0.15)
	mat.roughness = 0.6
	body.material_override = mat
	_model_holder.add_child(body)

# --- 選択ピッカー＋ハイライト（FlowObject と同じ流儀。Editor._pick が当てられるように
#     StaticBody3D+コリジョンを持ち、選択中はシアンの発光シェルを表示する） ---
func _build_selection() -> void:
	# 選択ハイライト：FlowObject._sel_box と同じスタイル（両面発光の控えめなシアン halo）。
	_sel_box = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 1.9, 1.0)
	_sel_box.mesh = bm
	_sel_box.position = Vector3(0, 0.9, 0)
	_sel_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := StandardMaterial3D.new()
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.albedo_color = Color(0.30, 0.95, 1.0, 0.34)
	sm.emission_enabled = true
	sm.emission = Color(0.35, 0.95, 1.0)
	sm.emission_energy_multiplier = 2.6
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_sel_box.material_override = sm
	_sel_box.visible = false
	add_child(_sel_box)
	# ピッカー：レイキャストで拾えるよう owner_obj メタを載せた StaticBody3D。
	_picker = StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.8, 1.7, 0.8)
	col.shape = shape
	col.position = Vector3(0, 0.85, 0)
	_picker.add_child(col)
	_picker.set_meta("owner_obj", self)
	add_child(_picker)

## 選択ハイライトの表示切替（Editor.select_unit から呼ばれる）。
func set_selected(sel: bool) -> void:
	if _sel_box != null:
		_sel_box.visible = sel

var _last_lbl_state: String = "?"

func _process(delta: float) -> void:
	if _target_pos != null:
		global_position = global_position.move_toward(_target_pos, delta * move_speed * max(1.0, Sim.speed))
		if global_position.distance_to(_target_pos) < 0.03:
			_target_pos = null
	if _label != null and _state != _last_lbl_state:
		_last_lbl_state = _state
		_label.text = "%s\n[%s]" % [op_name, _state]
