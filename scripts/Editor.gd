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
				select(cobj)
				emit_signal("context_requested", cobj, event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var obj = _pick(event.position)
			select(obj)
			if obj != null:
				var g := _ground_point(event.position)
				if g == Vector3.INF:
					return   # 地面をクリックできない角度：ドラッグ開始しない
				_dragging = true
				_drag_start_pos = obj.position
				_move_snap = _snapshot()   # 移動前の状態を保持
				_drag_offset = obj.position - Vector3(g.x, 0, g.z)
		else:
			# 移動が確定：実際に動いていたら undo に積む
			if _dragging and selected != null and _move_snap != null:
				if selected.position.distance_to(_drag_start_pos) > 0.001:
					_undo.append(_move_snap)
					_redo.clear()
			_dragging = false
			_move_snap = null
	elif event is InputEventMouseMotion and _dragging and selected != null:
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
			emit_signal("transform_changed", selected)

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
				_wire_from = _pick(event.position)
				select(_wire_from)
		else:
			var target = _pick(event.position)
			if _wire_from != null and target != null and target != _wire_from:
				push_undo()
				_wire_from.connect_to(target)
				Scripts.log_msg("🔗 配線: %s → %s" % [_wire_from.obj_name, target.obj_name])
				Sim.reset_sim()
				emit_signal("model_rebuilt")
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
			if selected != null:
				rotate_selected(rot_snap_deg)
		KEY_DELETE, KEY_BACKSPACE:
			if selected != null:
				delete_selected()
		KEY_ESCAPE:
			if _placing:
				cancel_place()
				Scripts.log_msg("配置を取消")
			elif _dragging and selected != null:
				# ドラッグ中の Esc はドラッグを取消（開始位置へ復元）。deselect より優先。
				# これをしないと release 条件が外れ移動が undo 未記録になりスタックがずれる。
				_cancel_drag()
				Scripts.log_msg("移動を取消")
			elif measure_mode and measure != null:
				measure.finish_line()
			else:
				select(null)
		# 矢印キー：選択オブジェクトを snap_size 刻みで X/Z にナッジ（undo記録・1押下1スナップ）
		KEY_LEFT:
			if selected != null:
				nudge_selected(-snap_size, 0.0)
		KEY_RIGHT:
			if selected != null:
				nudge_selected(snap_size, 0.0)
		KEY_UP:
			if selected != null:
				nudge_selected(0.0, -snap_size)
		KEY_DOWN:
			if selected != null:
				nudge_selected(0.0, snap_size)

func _move_selected(new_pos: Vector3) -> void:
	var delta := new_pos - selected.position
	selected.position = new_pos
	if selected is Conveyor:
		selected.start_point += delta
		selected.end_point += delta
		selected.build_belt()

## ドラッグ中の Esc：開始位置(_drag_start_pos)へ戻して状態を破棄する。正味移動ゼロなので
## release の undo 記録条件に載らず、Undo スタックが1件ずれる不整合を防ぐ（キャンセル＝復元）。
func _cancel_drag() -> void:
	if selected != null and is_instance_valid(selected):
		_move_selected(_drag_start_pos)
		emit_signal("transform_changed", selected)
	_dragging = false
	_move_snap = null

# 数値トランスフォーム（インスペクタから）
func set_obj_position(x: float, z: float) -> void:
	if selected == null:
		return
	push_undo()
	_move_selected(Vector3(x, 0, z))
	emit_signal("transform_changed", selected)

# 矢印キーのナッジ（選択オブジェクトを (dx,0,dz) 平行移動）。undo記録込み。
# 構造変更ではなく座標のみの変更なので Sim.reset_sim は不要（既存の移動系と同様）。
func nudge_selected(dx: float, dz: float) -> void:
	if selected == null:
		return
	push_undo()
	_move_selected(Vector3(selected.position.x + dx, 0, selected.position.z + dz))
	emit_signal("transform_changed", selected)

# 名称変更（インスペクタから）。同名なら push_undo せず二重積みを避ける。
func rename_selected(new_name: String) -> void:
	if selected == null:
		return
	if selected.obj_name == new_name:
		return
	push_undo()
	selected.obj_name = new_name
	emit_signal("selection_changed", selected)

func rotate_selected(deg: float) -> void:
	if selected == null:
		return
	push_undo()
	selected.rotation.y += deg_to_rad(deg)
	emit_signal("transform_changed", selected)

func set_rotation_deg(deg: float) -> void:
	if selected == null:
		return
	push_undo()
	selected.rotation.y = deg_to_rad(deg)
	emit_signal("transform_changed", selected)

func set_obj_scale(s: float) -> void:
	if selected == null:
		return
	push_undo()
	selected.apply_model(selected.model_path, max(0.05, s))
	emit_signal("transform_changed", selected)

# ---------------------------------------------------------------
# 選択
# ---------------------------------------------------------------
func select(obj) -> void:
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selected = obj
	if selected != null:
		selected.set_selected(true)
	emit_signal("selection_changed", selected)

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

func connect_selected_to(target_id: String) -> void:
	if selected == null:
		return
	var b = ctx.registry.get(target_id, null)
	if b != null and b != selected:
		push_undo()
		selected.connect_to(b)
		Scripts.log_msg("→ 接続: %s → %s" % [selected.obj_name, b.obj_name])
		Sim.reset_sim()
		emit_signal("model_rebuilt")

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

# 作業者の追加/削除
func add_operator() -> void:
	if ctx.get("pool", null) == null:
		return
	push_undo()
	var op := Operator.new()
	model_root.add_child(op)
	op.setup("Op%d" % (ctx.operators.size() + 1), Vector3(0, 0, 9))
	ctx.pool.add_operator(op)
	ctx.operators.append(op)
	Scripts.log_msg("＋ 作業者追加: %s" % op.op_name)
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func remove_operator() -> void:
	if ctx.operators.size() <= 0:
		return
	push_undo()
	var op = ctx.operators.pop_back()
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
	tr.setup("T%d" % (ctx.get("transporters", []).size() + 1), Vector3(0, 0, 9))
	ctx.transport_pool.add_transporter(tr)
	ctx.transporters.append(tr)
	Scripts.log_msg("＋ 搬送者追加: %s" % tr.t_name)
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func remove_transporter() -> void:
	if ctx.get("transporters", []).size() <= 0:
		return
	push_undo()
	var tr = ctx.transporters.pop_back()
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
