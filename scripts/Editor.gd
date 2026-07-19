extends Node3D
class_name Editor
## 編集モード：3Dピッキング選択、地面ドラッグ配置、追加/削除、
## 外部モデル割当、スクリプト適用、モデルの保存/読込を担う。

signal selection_changed(obj)
signal model_rebuilt()
signal transform_changed(obj)
## 右クリックでオブジェクト上に文脈メニューを開く要求（UI が PopupMenu を表示）。
##   obj: 対象 FlowObject / screen_pos: ビューポート座標（メニュー表示位置）
signal context_requested(obj, screen_pos)

var io: ModelIO
var model_root: Node3D
var ctx: Dictionary = {}

var edit_mode: bool = false
var measure_mode: bool = false
var wiring_mode: bool = false
var selected: FlowObject = null
## 選択中の資源ユニット（Operator / Transporter）。FlowObject 選択(selected)とは排他:
## 片方を選ぶともう片方は必ず null になる。型付き selected に代入できない Node3D 由来の
## ユニットを扱うため並行フィールドとして持ち、移動/改名/回転は _active() で一本化する。
var selected_unit = null
var measure: MeasureViz = null

# CAD 設定
var snap_enabled: bool = true
var snap_size: float = 1.0
var rot_snap_deg: float = 15.0

var _dragging: bool = false
var _drag_offset: Vector3 = Vector3.ZERO
var _drag_start_pos: Vector3 = Vector3.ZERO
# 右クリック：カメラ回転(右ドラッグ)と文脈メニュー(右クリック)を区別するため
# 押下位置を保持し、離した位置がほぼ同じ（＝ドラッグでない）ときのみメニューを開く。
var _rmb_press_pos: Vector2 = Vector2.ZERO
var _uid: int = 0
var _obj_seq: int = 0

# Undo/Redo（スナップショット式）
var _undo: Array = []
var _redo: Array = []
var _move_snap = null

# ドラッグ配線
var _wire_from: FlowObject = null
var _wire_mi: MeshInstance3D
var _wire_im: ImmediateMesh

# クリックで設置（配置モード）
var _placing: bool = false
var _pending_place_type: String = ""
var _ghost: MeshInstance3D = null

func setup(io_ref: ModelIO, root: Node3D, initial_ctx: Dictionary) -> void:
	io = io_ref
	model_root = root
	ctx = initial_ctx

func set_edit_mode(on: bool) -> void:
	edit_mode = on
	if on:
		Sim.pause()
	else:
		cancel_place()
		select(null)

func set_measure_mode(on: bool) -> void:
	measure_mode = on
	if on:
		cancel_place()
		wiring_mode = false
		select(null)

func set_wiring_mode(on: bool) -> void:
	wiring_mode = on
	if on:
		cancel_place()
		measure_mode = false
		select(null)
	_wire_from = null
	_ensure_wire()
	_wire_im.clear_surfaces()

## 文脈メニュー「配線元に設定」用。配線モードへ入り obj を配線元に据える。
## 次に接続先を左クリックすると obj→接続先 が接続される（_wire_input が元を維持）。
func begin_wire_from(obj) -> void:
	if obj == null:
		return
	set_wiring_mode(true)
	_wire_from = obj
	select(obj)
	Scripts.log_msg("🔗 配線元: %s — 接続先をクリック" % obj.obj_name)

## 配線を安全に中断する。配線元参照を解除し、配線モードを抜けてプレビュー線を消す。
## 配線元オブジェクトの削除／Undo(rebuild) で dangling 参照が残るのを防ぐ。
func _cancel_wiring() -> void:
	_wire_from = null
	wiring_mode = false
	if _wire_im != null:
		_wire_im.clear_surfaces()

func set_snap(on: bool) -> void:
	snap_enabled = on

# ---------------------------------------------------------------
# Undo / Redo
# ---------------------------------------------------------------
func _snapshot() -> Dictionary:
	return io.to_dict(ctx)

func push_undo() -> void:
	_undo.append(_snapshot())
	if _undo.size() > 100:
		_undo.pop_front()
	_redo.clear()

func can_undo() -> bool:
	return _undo.size() > 0

func can_redo() -> bool:
	return _redo.size() > 0

func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(_snapshot())
	var m: Dictionary = _undo.pop_back()
	rebuild(m)
	Scripts.log_msg("↶ 元に戻す")

func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append(_snapshot())
	var m: Dictionary = _redo.pop_back()
	rebuild(m)
	Scripts.log_msg("↷ やり直し")

func snap_vec(v: Vector3) -> Vector3:
	if not snap_enabled or snap_size <= 0.0:
		return v
	return Vector3(round(v.x / snap_size) * snap_size, v.y, round(v.z / snap_size) * snap_size)

# ---------------------------------------------------------------
# 入力
# ---------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	# キーボード
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event.keycode)

	# 配置モード（クリックで設置）：選択/ドラッグ/配線/計測より優先。
	# 非配置時は一切介入しないため、既存の選択・ドラッグ挙動は不変。
	if _placing:
		_place_input(event)
		return

	# 配線モード
	if wiring_mode:
		_wire_input(event)
		return

	# メジャーモード（編集/実行に関わらず計測できる）
	if measure_mode:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var gp := _ground_point(event.position)
			if gp != Vector3.INF and measure != null:
				measure.add_point(snap_vec(gp))
		return

	if not edit_mode:
		return
	# 右クリック：オブジェクト上で文脈メニュー。右ドラッグ(カメラ回転)は妨げない
	# ため、押下→離すの移動量が小さいクリックのときだけメニューを開く。配置中は
	# _placing 分岐（上流）が右クリックを取消に使うので、ここへは来ない。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_rmb_press_pos = event.position
		elif event.position.distance_to(_rmb_press_pos) <= 6.0:
			var cobj = _pick(event.position)
			if cobj != null:
				select_any(cobj)
				# 文脈メニュー（複製/削除/配線元）は FlowObject 専用。ユニットは選択のみ。
				if cobj is FlowObject:
					emit_signal("context_requested", cobj, event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var obj = _pick(event.position)
			select_any(obj)   # FlowObject / ユニットを型で振り分けて選択
			if obj != null:
				var g := _ground_point(event.position)
				if g == Vector3.INF:
					return   # 地面をクリックできない角度：ドラッグ開始しない
				_dragging = true
				_drag_start_pos = obj.position
				_move_snap = _snapshot()   # 移動前の状態を保持
				_drag_offset = obj.position - Vector3(g.x, 0, g.z)
		else:
			# 移動が確定：実際に動いていたら undo に積む（FlowObject/ユニット共通）
			var a = _active()
			if _dragging and a != null and _move_snap != null:
				if a.position.distance_to(_drag_start_pos) > 0.001:
					_undo.append(_move_snap)
					_redo.clear()
			_dragging = false
			_move_snap = null
	elif event is InputEventMouseMotion and _dragging and _active() != null:
		var g := _ground_point(event.position)
		if g != Vector3.INF:
			var new_pos := Vector3(g.x, 0, g.z) + Vector3(_drag_offset.x, 0, _drag_offset.z)
			new_pos = snap_vec(new_pos)
			# Shift で軸拘束（直交スナップ）
			if Input.is_key_pressed(KEY_SHIFT):
				if abs(new_pos.x - _drag_start_pos.x) >= abs(new_pos.z - _drag_start_pos.z):
					new_pos.z = _drag_start_pos.z
				else:
					new_pos.x = _drag_start_pos.x
			_move_selected(new_pos)
			emit_signal("transform_changed", _active())

func _wire_input(event: InputEvent) -> void:
	# 配線元が破棄済み（削除／Undo 経由）なら freed 参照へ触れる前に安全に中断する。
	if _wire_from != null and not is_instance_valid(_wire_from):
		_cancel_wiring()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 文脈メニュー「配線元に設定」で据えた配線元は press で上書きしない。
			# 通常のドラッグ配線は release 時に _wire_from=null へ戻るため常に null 始まりで、
			# この分岐に影響しない（従来挙動は不変）。
			if _wire_from == null:
				# ユニットにもピッカーが付いたため、配線は FlowObject のみを対象にする。
				var wpick = _pick(event.position)
				if wpick is FlowObject:
					_wire_from = wpick
					select(wpick)
		else:
			var target = _pick(event.position)
			if _wire_from != null and target is FlowObject:
				# ドラッグ配線もインスペクタと同じ can_connect で検証する。自己ループ/重複/
				# 受理不能先は理由付きで拒否し、push_undo しない（空の Undo を作らない）。
				var wres: Dictionary = can_connect(_wire_from, target)
				if wres.ok:
					push_undo()
					_wire_from.connect_to(target)
					Scripts.log_msg("🔗 配線: %s → %s" % [_wire_from.obj_name, target.obj_name])
					Sim.reset_sim()
					emit_signal("model_rebuilt")
				elif target != _wire_from:
					# 同一オブジェクトのクリックは「配線の取消」なので黙って無視。
					# それ以外の拒否（重複・受理不能先）は理由を提示する。
					Scripts.log_msg("⚠ 配線不可: %s" % wres.reason)
			_wire_from = null
			_wire_im.clear_surfaces()
	elif event is InputEventMouseMotion and _wire_from != null:
		var g := _ground_point(event.position)
		if g != Vector3.INF:
			_draw_wire(_wire_from.global_position + Vector3(0, 1.0, 0), g + Vector3(0, 0.5, 0))

func _ensure_wire() -> void:
	if _wire_mi != null:
		return
	_wire_mi = MeshInstance3D.new()
	_wire_im = ImmediateMesh.new()
	_wire_mi.mesh = _wire_im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.95, 1.0)
	mat.no_depth_test = true
	_wire_mi.material_override = mat
	add_child(_wire_mi)

func _draw_wire(a: Vector3, b: Vector3) -> void:
	_ensure_wire()
	_wire_im.clear_surfaces()
	_wire_im.surface_begin(Mesh.PRIMITIVE_LINES)
	_wire_im.surface_add_vertex(a)
	_wire_im.surface_add_vertex(b)
	_wire_im.surface_end()

# ---------------------------------------------------------------
# クリックで設置（配置モード）
# ---------------------------------------------------------------
## 配置モードへ入る。次の左クリックで地面上（スナップ後）に type_str を新規設置し、
## 配置モードを抜ける。Esc / 右クリックで取消。編集モード時のみ有効。
func begin_place(type_str: String) -> void:
	if not edit_mode:
		return
	_placing = true
	_pending_place_type = type_str
	# 他モードと排他（配置を最優先）
	wiring_mode = false
	_wire_from = null
	if _wire_im != null:
		_wire_im.clear_surfaces()
	measure_mode = false
	select(null)
	_ensure_ghost()
	_ghost.visible = true
	Scripts.log_msg("配置: %s — クリックで設置 / Escで取消" % type_str)

func cancel_place() -> void:
	_placing = false
	_pending_place_type = ""
	if _ghost != null:
		_ghost.visible = false

func is_placing() -> bool:
	return _placing

func placing_type() -> String:
	return _pending_place_type

func _place_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var g := _ground_point(event.position)
		if g != Vector3.INF and _ghost != null:
			var gp := snap_vec(Vector3(g.x, 0, g.z))
			_ghost.position = Vector3(gp.x, 0.5, gp.z)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var g := _ground_point(event.position)
			if g == Vector3.INF:
				return   # 地面をクリックできない角度：設置しない（配置モード継続）
			var pos := snap_vec(Vector3(g.x, 0, g.z))
			var t := _pending_place_type
			cancel_place()
			add_object_at(t, pos)   # push_undo + Sim.reset_sim は add_object_at 内
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			cancel_place()
			Scripts.log_msg("配置を取消")

func _ensure_ghost() -> void:
	if _ghost != null:
		return
	_ghost = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 1.0, 2.0)
	_ghost.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.4, 0.9, 1.0, 0.35)
	_ghost.material_override = mat
	_ghost.visible = false
	add_child(_ghost)

func _handle_key(kc: int) -> void:
	# テキスト入力中（LineEdit / TextEdit にフォーカス）はショートカットを奪わない。
	# 名前欄・パラメータ/スクリプト編集中の Delete / 矢印 / Ctrl+Z などは各フィールドへ委ねる。
	var foc = get_viewport().gui_get_focus_owner()
	if foc is LineEdit or foc is TextEdit:
		return
	# Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y / Ctrl+D
	if Input.is_key_pressed(KEY_CTRL):
		if kc == KEY_Z:
			if Input.is_key_pressed(KEY_SHIFT):
				redo()
			else:
				undo()
			return
		if kc == KEY_Y:
			redo()
			return
		if kc == KEY_D:
			duplicate_selected()
			return
	match kc:
		KEY_R:
			if _active() != null:
				rotate_selected(rot_snap_deg)
		KEY_DELETE, KEY_BACKSPACE:
			if selected != null:
				delete_selected()
		KEY_ESCAPE:
			if _placing:
				cancel_place()
				Scripts.log_msg("配置を取消")
			elif _dragging and _active() != null:
				# ドラッグ中の Esc はドラッグを取消（開始位置へ復元）。deselect より優先。
				# これをしないと release 条件が外れ移動が undo 未記録になりスタックがずれる。
				_cancel_drag()
				Scripts.log_msg("移動を取消")
			elif measure_mode and measure != null:
				measure.finish_line()
			else:
				select(null)
		# 矢印キー：選択オブジェクト/ユニットを snap_size 刻みで X/Z にナッジ（undo記録・1押下1スナップ）
		KEY_LEFT:
			if _active() != null:
				nudge_selected(-snap_size, 0.0)
		KEY_RIGHT:
			if _active() != null:
				nudge_selected(snap_size, 0.0)
		KEY_UP:
			if _active() != null:
				nudge_selected(0.0, -snap_size)
		KEY_DOWN:
			if _active() != null:
				nudge_selected(0.0, snap_size)

func _move_selected(new_pos: Vector3) -> void:
	# 資源ユニット：見た目位置に加え、論理位置(logical_pos)とホーム(home)も同期する。
	# logical_pos は移動時間/最近傍ディスパッチの基準、home は reset/直列化(home キー)の基準。
	# 3者を一致させることで「ドラッグした場所」がそのまま round-trip し reset でも保たれる。
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.position = new_pos
		selected_unit.logical_pos = new_pos
		selected_unit.home = new_pos
		return
	if selected == null:
		return
	var delta := new_pos - selected.position
	selected.position = new_pos
	if selected is Conveyor:
		selected.start_point += delta
		selected.end_point += delta
		selected.build_belt()

## ドラッグ中の Esc：開始位置(_drag_start_pos)へ戻して状態を破棄する。正味移動ゼロなので
## release の undo 記録条件に載らず、Undo スタックが1件ずれる不整合を防ぐ（キャンセル＝復元）。
func _cancel_drag() -> void:
	var a = _active()
	if a != null and is_instance_valid(a):
		_move_selected(_drag_start_pos)
		emit_signal("transform_changed", a)
	_dragging = false
	_move_snap = null

# 数値トランスフォーム（インスペクタから）
func set_obj_position(x: float, z: float) -> void:
	if _active() == null:
		return
	push_undo()
	_move_selected(Vector3(x, 0, z))
	emit_signal("transform_changed", _active())

# 矢印キーのナッジ（選択オブジェクトを (dx,0,dz) 平行移動）。undo記録込み。
# 構造変更ではなく座標のみの変更なので Sim.reset_sim は不要（既存の移動系と同様）。
func nudge_selected(dx: float, dz: float) -> void:
	var a = _active()
	if a == null:
		return
	push_undo()
	_move_selected(Vector3(a.position.x + dx, 0, a.position.z + dz))
	emit_signal("transform_changed", a)

# 名称変更（インスペクタから）。同名なら push_undo せず二重積みを避ける。
# FlowObject もユニットも obj_name を持つため _active() で一本化する。
func rename_selected(new_name: String) -> void:
	var a = _active()
	if a == null:
		return
	if a.obj_name == new_name:
		return
	push_undo()
	a.obj_name = new_name
	# ユニットは sim/ラベルが参照する op_name/t_name も同値に保つ（名前の窓口を一本化）。
	if a is Operator:
		a.op_name = new_name
	elif a is Transporter:
		a.t_name = new_name
	emit_signal("selection_changed", a)

func rotate_selected(deg: float) -> void:
	var a = _active()
	if a == null:
		return
	push_undo()
	a.rotation.y += deg_to_rad(deg)
	emit_signal("transform_changed", a)

func set_rotation_deg(deg: float) -> void:
	var a = _active()
	if a == null:
		return
	push_undo()
	a.rotation.y = deg_to_rad(deg)
	emit_signal("transform_changed", a)

func set_obj_scale(s: float) -> void:
	if selected == null:
		return
	push_undo()
	selected.apply_model(selected.model_path, max(0.05, s))
	emit_signal("transform_changed", selected)

# ---------------------------------------------------------------
# 選択
# ---------------------------------------------------------------
## FlowObject（または null）を選択する。ユニット選択は必ず解除する（相互排他）。
## selected_unit が常に null の従来経路では、追加した解除処理は no-op でバイト同一。
func select(obj) -> void:
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = null
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selected = obj
	if selected != null:
		selected.set_selected(true)
	emit_signal("selection_changed", selected)

## 資源ユニット（Operator / Transporter）を選択する。FlowObject 選択は必ず解除する。
## UI は selection_changed に載る型（is Operator / is Transporter）で編集面を切り替える。
func select_unit(unit) -> void:
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selected = null
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = unit
	if selected_unit != null:
		selected_unit.set_selected(true)
	emit_signal("selection_changed", selected_unit)

## ピック結果（FlowObject / ユニット / null）を型で振り分けて選択する。
## _pick はコリジョンの owner_obj を返すため、片方の select 系へ確実に流し込む。
func select_any(obj) -> void:
	if obj is FlowObject:
		select(obj)
	elif obj is Operator or obj is Transporter:
		select_unit(obj)
	else:
		select(null)

## 現在アクティブな選択（ユニット優先、無ければ FlowObject）。移動/改名/回転/ドラッグの
## 対象を一本化する窓口。ユニット未選択の従来経路では常に selected と等価。
func _active():
	if selected_unit != null and is_instance_valid(selected_unit):
		return selected_unit
	return selected

## UI 参照用の公開版（インスペクタが座標/回転の現在値を読むために使う）。
func selected_node():
	return _active()

func _pick(screen_pos: Vector2):
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var col = hit.get("collider", null)
	if col != null and col.has_meta("owner_obj"):
		return col.get_meta("owner_obj")
	return null

func _ground_point(screen_pos: Vector2) -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.INF
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if abs(dir.y) < 1e-5:
		return Vector3.INF
	var t := -from.y / dir.y
	if t < 0:
		return Vector3.INF
	return from + dir * t

# ---------------------------------------------------------------
# 追加 / 削除 / 割当 / スクリプト
# ---------------------------------------------------------------
# 既定配置位置（カメラ注視点あたり・スナップ後）。
func _default_place_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	var p := Vector3(0, 0, 0)
	if cam != null:
		var fwd := -cam.global_transform.basis.z
		p = cam.global_position + fwd * 12.0
		p.y = 0
	return snap_vec(p)

# 既定位置に追加（従来API・互換維持）。実体は add_object_at。
func add_object(type_str: String) -> FlowObject:
	return add_object_at(type_str, _default_place_pos())

# 指定位置に新規 FlowObject を設置する。undo 記録込み・構造変更として Sim.reset_sim。
func add_object_at(type_str: String, pos: Vector3) -> FlowObject:
	var o: FlowObject = io._make(type_str)
	if o == null:
		return null
	push_undo()
	o.id = _new_id(type_str)
	o.obj_name = "%s %d" % [type_str, ctx.flow_objects.size() + 1]
	var p := snap_vec(pos)
	p.y = 0
	o.position = p
	model_root.add_child(o)
	if o is Processor and ctx.pool != null:
		o.operator_pool = ctx.pool
	if o is Processor and ctx.get("transport_pool", null) != null:
		o.transport_pool = ctx.transport_pool
	if o is Conveyor:
		o.start_point = p + Vector3(-3, 0, 0)
		o.end_point = p + Vector3(3, 0, 0)
		o.build_belt()
	ctx.registry[o.id] = o
	ctx.flow_objects.append(o)
	Scripts.register_object(o.id, o)
	if o is Source:
		ctx.source = o
	if o is Sink:
		ctx.sink = o
	Scripts.log_msg("＋ 追加: %s (%s)" % [o.obj_name, o.id])
	Sim.reset_sim()   # 構造変更 → イベントカレンダーを再構築
	select(o)
	emit_signal("model_rebuilt")
	return o

func _new_id(type_str: String) -> String:
	_obj_seq += 1
	var base := "%s_%d" % [type_str.to_lower(), _obj_seq]
	while ctx.registry.has(base):
		_obj_seq += 1
		base = "%s_%d" % [type_str.to_lower(), _obj_seq]
	return base

# 選択オブジェクトを複製する。型・全パラメータ（分布含む）・回転・モデル・縮尺・スクリプトを
# ModelIO と同じ get_params/set_params 経路で丸ごとコピーし、原本から (snap_size,0,snap_size)
# ずらして配置、複製を選択する。undo記録込み・構造変更として Sim.reset_sim。
func duplicate_selected() -> FlowObject:
	if selected == null:
		return null
	var src: FlowObject = selected
	var type_str: String = src.type_name()
	var o: FlowObject = io._make(type_str)
	if o == null:
		return null
	# 原本の全状態を先に採取（select 後に selected が変わるため）
	var src_params: Dictionary = src.get_params().duplicate(true)
	var src_script: String = src.script_source
	var offset := Vector3(snap_size, 0, snap_size)
	push_undo()
	o.id = _new_id(type_str)
	o.obj_name = "%s のコピー" % src.obj_name
	var p := snap_vec(src.position + offset)
	p.y = 0
	o.position = p
	o.rotation.y = src.rotation.y
	o.model_path = src.model_path
	o.model_scale = src.model_scale
	model_root.add_child(o)   # _ready でモデル込みの見た目を構築
	if o is Processor and ctx.pool != null:
		o.operator_pool = ctx.pool
	if o is Processor and ctx.get("transport_pool", null) != null:
		o.transport_pool = ctx.transport_pool
	# 全パラメータ（分布・容量・故障設定 等）を丸ごと復元（保存/読込と同じ経路）
	o.set_params(src_params)
	if o is Conveyor and src is Conveyor:
		o.start_point = src.start_point + offset
		o.end_point = src.end_point + offset
		o.build_belt()
	ctx.registry[o.id] = o
	ctx.flow_objects.append(o)
	Scripts.register_object(o.id, o)
	# source/sink の主参照は既存を尊重（複製で上書きしない）
	if o is Source and ctx.get("source", null) == null:
		ctx.source = o
	if o is Sink and ctx.get("sink", null) == null:
		ctx.sink = o
	if src_script != "":
		o.set_logic(src_script)
	Scripts.log_msg("⧉ 複製: %s → %s (%s)" % [src.obj_name, o.obj_name, o.id])
	Sim.reset_sim()   # 構造変更 → イベントカレンダーを再構築
	select(o)
	emit_signal("model_rebuilt")
	return o

func delete_selected() -> void:
	if selected == null:
		return
	push_undo()
	var o := selected
	select(null)
	# 配線中に対象を消すと _wire_from が dangling 参照になり _wire_input がクラッシュする。
	# キーボード Delete（_handle_key はモード判定より前に走る）を含め、削除時は配線を中断する。
	_cancel_wiring()
	# 上流・下流の接続を解除
	for up in ctx.flow_objects:
		up.outputs.erase(o)
	o.disconnect_all()
	ctx.flow_objects.erase(o)
	ctx.registry.erase(o.id)
	Scripts.objects_by_id.erase(o.id)
	Sim.unregister(o)
	if ctx.source == o:
		ctx.source = null
	if ctx.sink == o:
		ctx.sink = null
	Scripts.log_msg("－ 削除: %s" % o.obj_name)
	o.queue_free()
	Sim.reset_sim()   # 構造変更 → イベント/アイテムをクリアして再構築
	emit_signal("model_rebuilt")

## 配線の妥当性を理由付きで判定する（実際の接続は行わない純粋クエリ）。
## 弾く条件: (1) 対象が無効/null、(2) 自己ループ(a→a)、(3) 既に張られた重複エッジ、
## (4) 入力を受理できない先（Source 等 can_receive_input()==false ＝ 永久ブロック）。
## 戻り値 {"ok":bool, "reason":String}（ok=true のとき reason は空）。
func can_connect(src, dst) -> Dictionary:
	if src == null or dst == null or not is_instance_valid(src) or not is_instance_valid(dst):
		return {"ok": false, "reason": "対象が無効です"}
	if src == dst:
		return {"ok": false, "reason": "自己ループ（同一オブジェクトへの接続）はできません"}
	if src.outputs.has(dst):
		return {"ok": false, "reason": "既に接続済みです（%s → %s）" % [src.obj_name, dst.obj_name]}
	if not dst.can_receive_input():
		return {"ok": false, "reason": "%s は入力を受け取れません（受理不能な先への配線は不可）" % dst.obj_name}
	return {"ok": true, "reason": ""}

func connect_selected_to(target_id: String) -> void:
	if selected == null:
		return
	var b = ctx.registry.get(target_id, null)
	# 無効/自己ループ/重複（＝no-op 再接続）/受理不能先は理由付きで拒否し、
	# push_undo しない（空の Undo エントリを作らない）。
	var res: Dictionary = can_connect(selected, b)
	if not res.ok:
		Scripts.log_msg("⚠ 接続不可: %s" % res.reason)
		return
	push_undo()
	selected.connect_to(b)
	Scripts.log_msg("→ 接続: %s → %s" % [selected.obj_name, b.obj_name])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 単一の出力エッジ（ポート index）を解除する。全解除の clear_selected_outputs と対に、
## リストの × ボタンから1本ずつ外すための API。push_undo＋Sim.reset_sim（構造変更）。
func remove_output(index: int) -> void:
	if selected == null:
		return
	if index < 0 or index >= selected.outputs.size():
		return
	push_undo()
	var t = selected.outputs[index]
	selected.outputs.remove_at(index)
	if t != null and is_instance_valid(t):
		t.inputs.erase(selected)   # 逆向き参照（inputs）も1件だけ解除（重複エッジは張れない）
	var tname: String = (t.obj_name if (t != null and is_instance_valid(t)) else "?")
	Scripts.log_msg("✂ 接続解除: %s → %s [port %d]" % [selected.obj_name, tname, index])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 出力エッジの並び順（＝ポート番号）を入れ替える。ポート番号は outputs 配列の添字で、
## スクリプトの select_output が参照する送出優先順。ユーザーがこの順を制御できる。
## from==to や範囲外への実質no-opでは push_undo しない（空の Undo を作らない）。
func reorder_output(from_index: int, to_index: int) -> void:
	if selected == null:
		return
	var n: int = selected.outputs.size()
	if from_index < 0 or from_index >= n:
		return
	to_index = clampi(to_index, 0, n - 1)
	if from_index == to_index:
		return
	push_undo()
	var t = selected.outputs[from_index]
	selected.outputs.remove_at(from_index)
	selected.outputs.insert(to_index, t)
	Scripts.log_msg("↕ ポート順変更: %s [%d → %d]" % [selected.obj_name, from_index, to_index])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## ポート index を1つ上へ（番号を1つ小さく）。境界では reorder_output 側で no-op。
func move_output_up(index: int) -> void:
	reorder_output(index, index - 1)

## ポート index を1つ下へ（番号を1つ大きく）。境界では reorder_output 側で no-op。
func move_output_down(index: int) -> void:
	reorder_output(index, index + 1)

func clear_selected_outputs() -> void:
	if selected == null:
		return
	push_undo()
	selected.disconnect_all()
	Scripts.log_msg("接続クリア: %s" % selected.obj_name)
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func assign_model_to_selected(path: String) -> void:
	if selected == null:
		return
	push_undo()
	var ok := selected.apply_model(path)
	Scripts.log_msg(("🧩 モデル割当: %s" % path) if ok else ("⚠ モデル割当失敗: %s" % path))

func apply_script_to_selected(src: String) -> Dictionary:
	if selected == null:
		return {"ok": false, "error": "no selection"}
	push_undo()
	return selected.set_logic(src)

func apply_params(d: Dictionary) -> void:
	if selected == null:
		return
	push_undo()
	selected.set_params(d)
	# パラメータ変更（mtbf_basis / transport_out / process_time 等）は
	# calendar 初回故障(on_sim_start)の再仕込みを要する → add/delete/connect と同様に
	# reset_sim でイベントカレンダーを作り直す（変更が確実に発火する）。
	Sim.reset_sim()
	emit_signal("model_rebuilt")

# ---------------------------------------------------------------
# モデル全体の保存/読込/再構築
# ---------------------------------------------------------------
func current_dict() -> Dictionary:
	return io.to_dict(ctx)

func save_model(path: String) -> void:
	io.save_json(path, io.to_dict(ctx))

func load_model(path: String, allow_scripts: bool = true) -> void:
	var m := io.load_json(path)
	if m.is_empty():
		Scripts.log_msg("⚠ 読込失敗または空: %s" % path)
		return
	rebuild(m, allow_scripts)
	Scripts.log_msg("📂 モデルを読込: %s%s" % [path, ("" if allow_scripts else "（スクリプトは無効化）")])

# ---------------------------------------------------------------
# 資源ユニット（作業者/搬送者）の配置ヘルパー
# ---------------------------------------------------------------
## 既存ユニットと重ならない配置セルを小グリッド探索で求める（連続追加が積み重ならない）。
## anchor から snap 格子（列 cols）で順に走査し、既存 position と近接しない最初のセルを返す。
## これにより固定座標へ N 個スタックしていた不具合を解消し、追加毎に別位置へ広がる。
func _free_unit_pos(anchor: Vector3, existing: Array) -> Vector3:
	var step: float = max(snap_size, 2.0)
	var cols: int = 5
	for i in range(256):
		var col: int = i % cols
		var row: int = i / cols
		var cand := snap_vec(anchor + Vector3(float(col) * step, 0, float(row) * step))
		var occupied := false
		for u in existing:
			if is_instance_valid(u) and u.position.distance_to(cand) < 0.5:
				occupied = true
				break
		if not occupied:
			return cand
	return snap_vec(anchor)

## ユニットの安定な一意 id を採番する（prefix_N。既存 id と衝突しない最小 N）。
func _new_unit_id(prefix: String, existing: Array) -> String:
	var used := {}
	for u in existing:
		if is_instance_valid(u):
			used[str(u.id)] = true
	var n: int = 1
	while used.has("%s_%d" % [prefix, n]):
		n += 1
	return "%s_%d" % [prefix, n]

# 作業者の追加/削除
func add_operator() -> void:
	if ctx.get("pool", null) == null:
		return
	push_undo()
	var op := Operator.new()
	model_root.add_child(op)
	var nm: String = "Op%d" % (ctx.operators.size() + 1)
	# 固定座標へのスタックを廃し、既存作業者と重ならない空きセルへ配置する。
	var pos: Vector3 = _free_unit_pos(Vector3(-6, 0, 9), ctx.get("operators", []))
	op.setup(nm, pos)
	op.id = _new_unit_id("op", ctx.get("operators", []))
	ctx.pool.add_operator(op)
	ctx.operators.append(op)
	select_unit(op)
	Scripts.log_msg("＋ 作業者追加: %s (%s)" % [op.op_name, op.id])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func remove_operator() -> void:
	if ctx.operators.size() <= 0:
		return
	push_undo()
	var op = ctx.operators.pop_back()
	if selected_unit == op:
		select(null)   # 選択中を消す前に選択解除（dangling 参照防止）
	ctx.pool.operators.erase(op)
	Sim.unregister(op)
	op.queue_free()
	Scripts.log_msg("－ 作業者削除")
	Sim.reset_sim()
	emit_signal("model_rebuilt")

# 搬送者の追加/削除（add_operator/remove_operator を踏襲）
func add_transporter() -> void:
	if ctx.get("transport_pool", null) == null:
		return
	push_undo()
	var tr := Transporter.new()
	model_root.add_child(tr)
	var nm: String = "T%d" % (ctx.get("transporters", []).size() + 1)
	# 固定座標へのスタックを廃し、既存搬送者と重ならない空きセルへ配置する。
	var pos: Vector3 = _free_unit_pos(Vector3(6, 0, 9), ctx.get("transporters", []))
	tr.setup(nm, pos)
	tr.id = _new_unit_id("t", ctx.get("transporters", []))
	ctx.transport_pool.add_transporter(tr)
	ctx.transporters.append(tr)
	select_unit(tr)
	Scripts.log_msg("＋ 搬送者追加: %s (%s)" % [tr.t_name, tr.id])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func remove_transporter() -> void:
	if ctx.get("transporters", []).size() <= 0:
		return
	push_undo()
	var tr = ctx.transporters.pop_back()
	if selected_unit == tr:
		select(null)   # 選択中を消す前に選択解除（dangling 参照防止）
	if ctx.get("transport_pool", null) != null:
		ctx.transport_pool.transporters.erase(tr)
	Sim.unregister(tr)
	tr.queue_free()
	Scripts.log_msg("－ 搬送者削除")
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 全作業者に共通シフトを設定（最小の一括編集）。period<=0 で常時稼働へ戻す。
func set_operator_shift(on_t: float, off_t: float, period: float) -> void:
	push_undo()
	for op in ctx.get("operators", []):
		if period <= 0.0:
			op.shift = []
			op.shift_period = 0.0
		else:
			op.shift = [{"on": on_t, "off": off_t}]
			op.shift_period = period
	Scripts.log_msg("🕑 全作業者シフト: on=%.0f off=%.0f period=%.0f" % [on_t, off_t, period])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中のユニット（作業者/搬送者）の移動速度を設定。undo記録込み。速度は travel_time に
## 効くので、変更を確実に反映するよう reset_sim + model_rebuilt で再構成する
## （既存の資源パラメータ編集 set_operator_shift と同じ流儀）。過小値は安全側へクランプ。
func set_unit_speed(v: float) -> void:
	var a = _active()
	if a == null or not (a is Operator or a is Transporter):
		return
	push_undo()
	a.move_speed = max(0.01, v)
	Scripts.log_msg("⚙ %s 速度: %.2f" % [a.obj_name, a.move_speed])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中の作業者1名のシフトを設定（period<=0 で常時稼働へ戻す）。undo記録込み。
## 全作業者一括の set_operator_shift とは別に、per-unit で個別設定できる窓口。
func set_selected_operator_shift(on_t: float, off_t: float, period: float) -> void:
	var a = _active()
	if not (a is Operator):
		return
	push_undo()
	if period <= 0.0:
		a.shift = []
		a.shift_period = 0.0
	else:
		a.shift = [{"on": on_t, "off": off_t}]
		a.shift_period = period
	Scripts.log_msg("🕑 %s シフト: on=%.0f off=%.0f period=%.0f" % [a.obj_name, on_t, off_t, period])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中の搬送者の運搬パラメータ（容量/積載時間/投下時間/優先度）を一括設定。undo記録込み。
## 1回の適用で undo は1件（4項目まとめて）。容量<1・時間<0 は安全側へクランプする。
func set_transporter_params(cap: int, load_t: float, unload_t: float, prio: int) -> void:
	var a = _active()
	if not (a is Transporter):
		return
	push_undo()
	a.capacity = max(1, cap)
	a.load_time = max(0.0, load_t)
	a.unload_time = max(0.0, unload_t)
	a.priority = prio
	Scripts.log_msg("⚙ %s: cap=%d load=%.2f unload=%.2f prio=%d" % [
		a.obj_name, a.capacity, a.load_time, a.unload_time, a.priority])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 資源ディスパッチ規則を全プールへ設定（"fifo"=既定 / "nearest"）。
func set_dispatch_rule(rule: String) -> void:
	push_undo()   # 変更前の規則をスナップショット（Undo で復元可能に）
	if ctx.get("pool", null) != null and ctx.pool.has_method("set_dispatch_rule"):
		ctx.pool.set_dispatch_rule(rule)
	if ctx.get("transport_pool", null) != null and ctx.transport_pool.has_method("set_dispatch_rule"):
		ctx.transport_pool.set_dispatch_rule(rule)
	Scripts.log_msg("⚙ ディスパッチ規則: %s" % rule)
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func rebuild(model: Dictionary, allow_scripts: bool = true) -> void:
	select(null)
	# rebuild は全 flow_objects を破棄するため、配線元(_wire_from)が dangling 参照になる。
	# Undo/Redo/読込のいずれでも配線を中断してプレビュー線を消す（次入力でのクラッシュ防止）。
	_cancel_wiring()
	# 既存を破棄
	for o in ctx.get("flow_objects", []):
		Sim.unregister(o)
		o.queue_free()
	for op in ctx.get("operators", []):
		Sim.unregister(op)
		op.queue_free()
	for tr in ctx.get("transporters", []):
		Sim.unregister(tr)
		tr.queue_free()
	if ctx.get("pool", null) != null:
		ctx.pool.queue_free()
	if ctx.get("pool", null) != null:
		Sim.unregister(ctx.pool)
	if ctx.get("transport_pool", null) != null:
		Sim.unregister(ctx.transport_pool)
		ctx.transport_pool.queue_free()
	Sim.running = false
	# 再構築
	ctx = io.build(model, model_root, allow_scripts)
	Sim.reset_sim()   # イベント/アイテムをクリアして初期イベントを仕込む
	emit_signal("model_rebuilt")
