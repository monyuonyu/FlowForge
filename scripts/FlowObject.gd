extends Node3D
class_name FlowObject
## フロー部品の基底（イベント駆動）。
## - バックプレッシャー：下流が満杯なら送れず、下流が空くと _notify_space→_retry_push で再送
## - 状態時間はイベント境界で正確に集計（in-progress分も加味）
## - 見た目/外部モデル/選択コリジョン/スクリプトトリガーは従来通り

## 純粋通知シグナル（Process Flow が3Dモデルを観測するためのフック・stage 1/3）。
##   item_entered(item): このオブジェクトが下流としてアイテムを受理した瞬間。
##   item_exited(item) : このオブジェクトからアイテムを下流へ送出できた瞬間。
## どちらも try_push 内で「既存の状態/統計更新の後」に発火する passive notify であり、
##   ・乱数（Rng.stream）を一切引かない
##   ・イベントを schedule/cancel しない
##   ・制御フロー/イベント順/抽選順を一切変えない
## 既定では接続リスナーが存在しないため発火は事実上ノーオペとなり、既存マーカー値は
## バイト同一を保つ（HARD INVARIANT 2）。新機能はリスナー接続時のみ働く opt-in。
signal item_entered(item)
signal item_exited(item)

var id: String = ""
var obj_name: String = "Object"
var body_color: Color = Color(0.3, 0.34, 0.42)

var outputs: Array = []
var inputs: Array = []

# 外部モデル
var model_path: String = ""
var model_scale: float = 1.0
var _model_holder: Node3D

# スクリプト
var script_source: String = ""
var logic: LogicBase = null

# 統計（イベント境界で集計）
var state: String = "idle"
var _state_time: Dictionary = {}
var _last_change: float = 0.0
var input_count: int = 0
var output_count: int = 0

# 状態タイムライン記録（ガントチャート用・既定オフ）。
# ON でも乱数/イベント順に一切触れず、set_state で終了セグメントを追記するだけ。
# 実験(visuals_enabled=false)や大規模時は Sim.visuals_enabled ゲートで記録しない
# → 決定論・性能に無影響。上限 timeline_cap でリングバッファ（古いものを破棄）。
var record_timeline: bool = false
var timeline_cap: int = 2000
var _state_log: Array = []   # 要素: {"state","start","end"}

# バックプレッシャー
var _blocked_upstreams: Array = []   # 自分が満杯で送れず待っている上流
var _blocked_on: Array = []          # 自分が送れず登録している下流

# 見た目
var _label: Label3D
var _status_light: MeshInstance3D
var _status_mat: StandardMaterial3D
var _sel_box: MeshInstance3D
var _picker: StaticBody3D

const STATE_COLORS := {
	"idle": Color(0.45, 0.45, 0.5), "empty": Color(0.45, 0.45, 0.5),
	"generating": Color(0.30, 0.70, 1.0), "storing": Color(0.95, 0.78, 0.25),
	"busy": Color(0.35, 0.80, 0.40), "running": Color(0.35, 0.80, 0.40),
	"collecting": Color(0.35, 0.80, 0.40), "waiting": Color(0.95, 0.55, 0.20),
	"blocked": Color(0.90, 0.30, 0.30), "full": Color(0.90, 0.30, 0.30),
	"down": Color(0.75, 0.15, 0.20), "setup": Color(0.30, 0.75, 0.85),
}

func _ready() -> void:
	Sim.register(self)
	_model_holder = Node3D.new()
	add_child(_model_holder)
	_rebuild_visual()
	_build_status_overlay()
	_build_picker()
	reset_object()

# ---------------------------------------------------------------
# リセット / 統計
# ---------------------------------------------------------------
func reset_object() -> void:
	_state_time = {}
	_last_change = Sim.sim_time
	input_count = 0
	output_count = 0
	_blocked_upstreams = []
	_blocked_on = []
	state = "idle"
	_state_log = []   # タイムラインは統計と同じくリセット（record_timeline フラグは維持）
	_fire0("on_reset")

func reset_stats() -> void:
	_state_time = {}
	_last_change = Sim.sim_time
	input_count = 0
	output_count = 0
	_state_log = []   # warmup 打ち切りに合わせタイムラインも起点を揃える

## Sim開始時に一度呼ばれる（Sourceが初回生成を仕込む等）
func on_sim_start() -> void:
	pass

func rng(purpose: String) -> RandomNumberGenerator:
	return Rng.stream("%s:%s" % [id, purpose])

# ---------------------------------------------------------------
# 接続
# ---------------------------------------------------------------
func connect_to(other: FlowObject) -> void:
	if not outputs.has(other):
		outputs.append(other)
		other.inputs.append(self)

func disconnect_all() -> void:
	for o in outputs:
		o.inputs.erase(self)
	outputs.clear()

# ---------------------------------------------------------------
# 状態時間
# ---------------------------------------------------------------
func set_state(s: String) -> void:
	var d: float = Sim.sim_time - _last_change
	if d > 0.0:
		_state_time[state] = float(_state_time.get(state, 0.0)) + d
		# 終了した state のセグメントをタイムラインへ追記（記録ON かつ可視モード時のみ）。
		# 乱数/イベントには一切触れないので決定論に無影響。
		if record_timeline and Sim.visuals_enabled:
			_log_segment(state, _last_change, Sim.sim_time)
	_last_change = Sim.sim_time
	state = s

## タイムラインへ1セグメントを追記（上限超過で最古を破棄＝リングバッファ）。
func _log_segment(st: String, a: float, b: float) -> void:
	_state_log.append({"state": st, "start": a, "end": b})
	if _state_log.size() > timeline_cap:
		_state_log.pop_front()

## 記録済みセグメント＋進行中(未クローズ)の末尾セグメントを合わせた配列を返す。
## Σ(セグメント長) == 経過時間 になる（状態時間は時間軸の分割なので）。描画/検証用。
func timeline_segments() -> Array:
	var segs: Array = _state_log.duplicate()
	var d: float = Sim.sim_time - _last_change
	if d > 0.0:
		segs.append({"state": state, "start": _last_change, "end": Sim.sim_time})
	return segs

func state_durations() -> Dictionary:
	var d: Dictionary = _state_time.duplicate()
	var extra: float = Sim.sim_time - _last_change
	if extra > 0.0:
		d[state] = float(d.get(state, 0.0)) + extra
	return d

func utilization() -> float:
	var d: Dictionary = state_durations()
	var total: float = 0.0
	for k in d:
		total += d[k]
	if total <= 0.0:
		return 0.0
	var busy: float = float(d.get("busy", 0.0)) + float(d.get("running", 0.0)) + float(d.get("collecting", 0.0))
	return busy / total

# ---------------------------------------------------------------
# バックプレッシャー付き送出
# ---------------------------------------------------------------
func try_push(item: FlowItem) -> bool:
	var idx: int = _override_output(item)
	if idx >= 0:
		if idx < outputs.size():
			if outputs[idx].receive_item(item):
				output_count += 1
				_fire("on_exit", item)
				_notify_transfer(outputs[idx], item)
				return true
			_register_blocked([outputs[idx]])
			return false
		else:
			Scripts.log_msg("⚠ [%s] select_output=%d は出力ポート範囲外。既定ルーティングにフォールバック。" % [obj_name, idx])
	for o in outputs:
		if o.receive_item(item):
			output_count += 1
			_fire("on_exit", item)
			_notify_transfer(o, item)
			return true
	_register_blocked(outputs)
	return false

## 純粋通知：下流受理が確定した後に item_exited(self) と item_entered(dest) を発火する。
## 既存の統計更新（output_count/_fire）の後に置かれる passive notify。乱数/イベント/
## 制御フローに一切触れないため、リスナー未接続の既定では観測不能でマーカー値に無影響。
func _notify_transfer(dest: FlowObject, item: FlowItem) -> void:
	item_exited.emit(item)
	if dest != null:
		dest.item_entered.emit(item)

func _register_blocked(targets: Array) -> void:
	for t in targets:
		if not t._blocked_upstreams.has(self):
			t._blocked_upstreams.append(self)
		if not _blocked_on.has(t):
			_blocked_on.append(t)

func _unregister_blocked() -> void:
	for t in _blocked_on:
		t._blocked_upstreams.erase(self)
	_blocked_on.clear()

## 空きが出た時に上流へ再送を促す（FIFO順で決定的）
func _notify_space() -> void:
	if _blocked_upstreams.is_empty():
		return
	var ups: Array = _blocked_upstreams.duplicate()
	_blocked_upstreams.clear()
	for up in ups:
		up._blocked_on.erase(self)
		up._retry_push()

## 上流としての再送（サブクラスで実装）
func _retry_push() -> void:
	pass

func receive_item(_item: FlowItem) -> bool:
	return false

# ---------------------------------------------------------------
# スクリプト
# ---------------------------------------------------------------
func set_logic(source: String) -> Dictionary:
	script_source = source
	var res: Dictionary = Scripts.compile(source, self)
	logic = res.get("instance", null)
	return res

func _fire(method: String, item) -> void:
	if logic != null:
		Scripts.api.current_obj = self
		if Scripts.verbose:
			Scripts.log_msg("▶ call %s.%s(item) …" % [obj_name, method])
		logic.call(method, item)

func _fire0(method: String) -> void:
	if logic != null:
		Scripts.api.current_obj = self
		if Scripts.verbose:
			Scripts.log_msg("▶ call %s.%s() …" % [obj_name, method])
		logic.call(method)

func _override_num(method: String, default_val: float) -> float:
	if logic == null:
		return default_val
	Scripts.api.current_obj = self
	if Scripts.verbose:
		Scripts.log_msg("▶ call %s.%s() …" % [obj_name, method])
	var v = logic.call(method)
	if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and float(v) >= 0.0:
		return float(v)
	return default_val

func _override_output(item: FlowItem) -> int:
	if logic == null:
		return -1
	Scripts.api.current_obj = self
	if Scripts.verbose:
		Scripts.log_msg("▶ call %s.select_output(item) …" % obj_name)
	var v = logic.call("select_output", item)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)
	return -1

# ---------------------------------------------------------------
# パラメータ（サブクラスで上書き）
# ---------------------------------------------------------------
func type_name() -> String:
	return "FlowObject"

## 搬送者が積載/投下のために移動する位置（既定は自身の位置）。
func transport_pickup_pos() -> Vector3:
	return global_position

func get_params() -> Dictionary:
	return {}

func set_params(_d: Dictionary) -> void:
	pass

# ---------------------------------------------------------------
# 見た目
# ---------------------------------------------------------------
func apply_model(path: String, scale_factor: float = 1.0) -> bool:
	model_path = path
	model_scale = scale_factor
	return _rebuild_visual()

func _rebuild_visual() -> bool:
	for c in _model_holder.get_children():
		c.queue_free()
	if model_path != "":
		var m: Node3D = Assets.load_model(model_path)
		if m != null:
			m.scale = Vector3.ONE * model_scale
			_model_holder.add_child(m)
			return true
		else:
			Scripts.log_msg("⚠ モデル読込失敗のため既定表示: %s" % model_path)
	_build_default_visual()
	_model_holder.scale = Vector3.ONE * model_scale
	return false

func _build_default_visual() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.7, 0.5, 1.7)
	mesh.mesh = box
	mesh.position = Vector3(0, 0.25, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = body_color
	mat.roughness = 0.7
	mesh.material_override = mat
	_model_holder.add_child(mesh)

func _build_status_overlay() -> void:
	_label = Label3D.new()
	_label.text = obj_name
	_label.position = Vector3(0, 2.4, 0)
	_label.font_size = 28
	_label.outline_size = 6
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0010
	add_child(_label)

	_status_light = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.18
	sph.height = 0.36
	_status_light.mesh = sph
	_status_light.position = Vector3(0, 2.0, 0)
	_status_mat = StandardMaterial3D.new()
	_status_mat.emission_enabled = true
	_status_light.material_override = _status_mat
	add_child(_status_light)

	# 選択ハイライト：控えめだが一目で分かる発光シェル。内側は透過して対象を残しつつ、
	# 明るいシアンの縁取り（両面描画＝全方位から見える halo）で「選択中」を明示する。
	_sel_box = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.35, 2.75, 2.35)
	_sel_box.mesh = bm
	_sel_box.position = Vector3(0, 1.35, 0)
	_sel_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := StandardMaterial3D.new()
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.albedo_color = Color(0.30, 0.95, 1.0, 0.34)
	sm.emission_enabled = true
	sm.emission = Color(0.35, 0.95, 1.0)
	sm.emission_energy_multiplier = 2.6   # 発光を強め、白い機器の上でも明瞭なシアンに
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED   # 両面描画で全方位から縁が見える
	_sel_box.material_override = sm
	_sel_box.visible = false
	add_child(_sel_box)

func _build_picker() -> void:
	_picker = StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.2, 2.6, 2.2)
	col.shape = shape
	col.position = Vector3(0, 1.3, 0)
	_picker.add_child(col)
	_picker.set_meta("owner_obj", self)
	add_child(_picker)

func set_selected(sel: bool) -> void:
	if _sel_box != null:
		_sel_box.visible = sel

var _last_vis_key: String = "?"

func _process(_delta: float) -> void:
	var key: String = state + "|" + obj_name
	if key == _last_vis_key:
		return
	_last_vis_key = key
	if _label != null:
		_label.text = "%s\n[%s]" % [obj_name, state]
	if _status_mat != null:
		var c: Color = STATE_COLORS.get(state, Color(0.5, 0.5, 0.5))
		_status_mat.albedo_color = c
		_status_mat.emission = c
		_status_mat.emission_energy_multiplier = 1.6
